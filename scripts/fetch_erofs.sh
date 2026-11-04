#!/bin/sh
# ---------------------------------------------------------------------------
# 把 EROFS 驱动移植进 cezanne 的 4.14.186 内核树
#
# 为什么这么做：
#   Linux 主线 4.19 才有 fs/erofs，小米 cezanne-r-oss（4.14.186）里没有。
#   澎湃 OS4 的 system/product/system_ext 全是 erofs，没有驱动就挂不上。
#   这里从同为 4.14.186 的 MTK 平台内核（OPPO/Realme Dimensity 1000L）
#   拷入 fs/erofs —— 同一 LTS 基线，接口基本对得上。
#
# 需要做三处适配（都是实测出来的，不是猜的）：
#   1. include/trace/events/erofs.h 不在 fs/erofs 里，必须单独拷
#      （super.c 里 #include <trace/events/erofs.h>，漏了直接 fatal error）
#   2. internal.h 用了 atomic_cond_read_relaxed()，这是 4.20+ 的原子 API，
#      4.14.186 没有；用 compat 头里的等价实现替换
#   3. OS4 的 erofs 镜像是「未压缩」的（feature_incompat = 0），
#      所以其实不需要 EROFS_FS_ZIP；但原厂 config 本来就开着 LZ4，
#      保留 ZIP 不引入新依赖，多一层保险。
# ---------------------------------------------------------------------------
set -eu

log() { printf '\n==> %s\n' "$*"; }
die() { printf '[error] %s\n' "$*" >&2; exit 1; }

HERE=$(cd "$(dirname "$0")/.." && pwd)
KERNEL_DIR=${KERNEL_DIR:-$HERE/kernel}
SRC_REPO=${SRC_REPO:-https://github.com/Winkmoon/oppo_kernel_mt6885-mt6853-clean}
SRC_REF=${SRC_REF:-android12}

[ -f "$KERNEL_DIR/Makefile" ] || die "找不到内核源码: $KERNEL_DIR"

if [ -d "$KERNEL_DIR/fs/erofs" ]; then
	log "fs/erofs 已存在，跳过"
	exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

log "下载 erofs 来源: $SRC_REPO @ $SRC_REF"
curl -fL --retry 5 --retry-delay 3 -o "$TMP/src.tar.gz" \
	"$SRC_REPO/archive/refs/heads/$SRC_REF.tar.gz"
tar -xzf "$TMP/src.tar.gz" -C "$TMP"

SRC=$(find "$TMP" -type d -path '*/fs/erofs' | head -n1)
[ -n "$SRC" ] || die "压缩包里没有 fs/erofs，换个来源分支试试"
SRC_ROOT=${SRC%/fs/erofs}

log "拷贝 fs/erofs（$(ls -1 "$SRC" | wc -l) 个文件）"
cp -a "$SRC" "$KERNEL_DIR/fs/erofs"

# --- 步骤 1：补上 trace 头文件（super.c 依赖，漏了必挂） ---
TRACE_SRC="$SRC_ROOT/include/trace/events/erofs.h"
[ -f "$TRACE_SRC" ] || die "来源树里没有 include/trace/events/erofs.h"
mkdir -p "$KERNEL_DIR/include/trace/events"
cp -a "$TRACE_SRC" "$KERNEL_DIR/include/trace/events/erofs.h"
log "已补 include/trace/events/erofs.h"

# --- 步骤 2：atomic_cond_read_relaxed 的 4.14 兼容层 ---
cat > "$KERNEL_DIR/fs/erofs/erofs_compat.h" <<'COMPAT'
/* SPDX-License-Identifier: GPL-2.0 */
/*
 * 4.14 兼容层
 *
 * 来源驱动（OPPO/Realme MT6885, 4.14.186）的 internal.h 用了
 * atomic_cond_read_relaxed()，该宏在 4.20 才进主线，
 * cezanne 官方 4.14.186 树里没有。这里给出语义等价实现：
 * 自旋等待直到值不再等于 locked，返回观察到的值。
 */
#ifndef __EROFS_COMPAT_414_H
#define __EROFS_COMPAT_414_H

#include <linux/types.h>
#include <linux/atomic.h>
#include <linux/compiler.h>
#include <asm/processor.h>

static inline int erofs_compat_cond_read_relaxed(atomic_t *v, int locked)
{
	int val;

	for (;;) {
		val = atomic_read(v);
		if (val != locked)
			break;
		cpu_relax();
	}
	smp_mb();
	return val;
}

#endif /* __EROFS_COMPAT_414_H */
COMPAT

python3 - "$KERNEL_DIR/fs/erofs/internal.h" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='replace').read()
orig = s

# 1) 引入 compat 头（放在 erofs_fs.h 之后，保证基础类型已就绪）
if 'erofs_compat.h' not in s:
    s = s.replace('#include "erofs_fs.h"',
                  '#include "erofs_fs.h"\n#include "erofs_compat.h"', 1)
    if 'erofs_compat.h' not in s:
        s = '#include "erofs_compat.h"\n' + s

# 2) 替换掉 4.20+ 的原子读宏
s2 = re.sub(
    r'atomic_cond_read_relaxed\(\s*&([A-Za-z0-9_>.\-]+)\s*,\s*'
    r'VAL\s*!=\s*([A-Za-z0-9_]+)\s*\)',
    r'erofs_compat_cond_read_relaxed(&\1, \2)', s)
if s2 == s and 'atomic_cond_read_relaxed' in s:
    print('[warn] 未能自动替换 atomic_cond_read_relaxed，可能需要手工适配')
s = s2

open(p, 'w', encoding='utf-8').write(s)
print('internal.h 补丁完成，变更:', 'yes' if s != orig else 'no')
PY

# --- 步骤 3：挂进 fs/Makefile 与 fs/Kconfig ---
if ! grep -q 'CONFIG_EROFS_FS' "$KERNEL_DIR/fs/Makefile"; then
	printf '\nobj-$(CONFIG_EROFS_FS) += erofs/\n' >> "$KERNEL_DIR/fs/Makefile"
	log "已写入 fs/Makefile"
fi

if ! grep -q 'fs/erofs/Kconfig' "$KERNEL_DIR/fs/Kconfig"; then
	printf '\nsource "fs/erofs/Kconfig"\n' >> "$KERNEL_DIR/fs/Kconfig"
	log "已写入 fs/Kconfig"
fi

# --- 校验 ---
for f in Kconfig Makefile super.c inode.c data.c dir.c namei.c erofs_fs.h internal.h erofs_compat.h; do
	[ -f "$KERNEL_DIR/fs/erofs/$f" ] || die "移植后缺少 fs/erofs/$f"
done
[ -f "$KERNEL_DIR/include/trace/events/erofs.h" ] || die "缺少 include/trace/events/erofs.h"
grep -q 'erofs_compat_cond_read_relaxed' "$KERNEL_DIR/fs/erofs/internal.h" || \
	die "internal.h 里没有替换成兼容函数，SMP 构建会失败"

log "EROFS 移植完成（来源 $SRC_ROOT）"
log "已适配：trace 头文件、atomic_cond_read_relaxed → erofs_compat"
