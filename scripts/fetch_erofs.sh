#!/bin/sh
# ---------------------------------------------------------------------------
# 把 EROFS 驱动移植进 cezanne 的 4.14.186 内核树
#
# 为什么这么做：
#   Linux 主线 4.19 才有 fs/erofs，小米 cezanne-r-oss（4.14.186）里没有。
#   澎湃 OS4 的 system/product/system_ext 全是 erofs，没有驱动就挂不上。
#   这里从同为 4.14.186 的 MTK 平台内核（OPPO/Realme Dimensity 1000L）
#   拷入 fs/erofs —— 同一 LTS 基线，接口完全对得上，属于复制即用。
#
#   注意：OS4 的 erofs 镜像是「未压缩」的（feature_incompat = 0），
#   所以不需要开 EROFS_FS_ZIP，也就不引入 lz4 依赖，改动面最小。
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

# 挂进 fs/Makefile
if ! grep -q 'CONFIG_EROFS_FS' "$KERNEL_DIR/fs/Makefile"; then
	printf '\nobj-$(CONFIG_EROFS_FS) += erofs/\n' >> "$KERNEL_DIR/fs/Makefile"
	log "已写入 fs/Makefile"
fi

# 挂进 fs/Kconfig
if ! grep -q 'fs/erofs/Kconfig' "$KERNEL_DIR/fs/Kconfig"; then
	printf '\nsource "fs/erofs/Kconfig"\n' >> "$KERNEL_DIR/fs/Kconfig"
	log "已写入 fs/Kconfig"
fi

# 校验关键文件齐不齐
for f in Kconfig Makefile super.c inode.c data.c dir.c namei.c erofs_fs.h internal.h; do
	[ -f "$KERNEL_DIR/fs/erofs/$f" ] || die "移植后缺少 fs/erofs/$f"
done

log "EROFS 移植完成（来源 $SRC_ROOT）"
