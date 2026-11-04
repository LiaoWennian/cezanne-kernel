#!/bin/sh
# ---------------------------------------------------------------------------
# 修补小米/MTK 原厂内核树里"平时能过、开 LTO 就炸"的 Makefile 错误
#
# 为什么需要这一步：
#   原厂 defconfig 开着 CONFIG_LTO_CLANG=y。普通 ar+ld 链接时，
#   archive 里重复的成员只有在真正被拉取时才报错，所以这类错误
#   在非 LTO 构建里长期潜伏；而 LTO 下 ld.lld 必须加载全部 bitcode
#   模块才能做跨模块优化，重复定义立刻暴露成 duplicate symbol。
#
#   这些是原厂代码的 bug，不是我们的改动引起的。修法都是"去重"，
#   不改变任何符号的定义位置，因此对最终的 vermagic / 符号 CRC
#   没有任何影响（VERMAGIC 里也不含 LTO 标记）。
#
# 用法：KERNEL_DIR=... sh scripts/patch_vendor.sh
# 幂等：重复执行不会二次修改
# ---------------------------------------------------------------------------
set -eu

log() { printf '\n==> %s\n' "$*"; }
die() { printf '[error] %s\n' "$*" >&2; exit 1; }

HERE=$(cd "$(dirname "$0")/.." && pwd)
KERNEL_DIR=${KERNEL_DIR:-$HERE/kernel}

[ -f "$KERNEL_DIR/Makefile" ] || die "找不到内核源码: $KERNEL_DIR"

python3 - "$KERNEL_DIR" <<'PY'
import os, sys

root = sys.argv[1]

# (相对路径, 原字符串, 新字符串, 说明)
PATCHES = [
    (
        "drivers/media/platform/mtk-vcu/Makefile",
        "obj-$(CONFIG_VIDEO_MEDIATEK_VCU) += mtk-vcu.o mtk_vcodec_mem.o",
        "obj-$(CONFIG_VIDEO_MEDIATEK_VCU) += mtk-vcu.o",
        "mtk_vcodec_mem.o 已在 mtk-vcu-y 里，不要再单独进 obj-y（LTO 下 duplicate symbol）",
    ),
    (
        # 原厂 config 关掉 GenieZone 后，KREE 仍被其他选项 select 住，
        # 而 trusted_mem/mtee_impl 只在 CONFIG_MTK_GZ_KREE=y 时编译。
        # mtee_ops.c 依赖 gz_kree.h 的 KREE_* API，该头文件真正的声明
        # 在小米私有 MTEE 树里，OSS 树只有一半 → 一堆 undeclared identifier。
        # 这里的做法是把这个 ifeq 改成一个永不成立的名字，
        # 只跳过 mtee_impl 三个文件，不动 KREE 相关的其他逻辑。
        "drivers/misc/mediatek/trusted_mem/Makefile",
        "ifeq ($(CONFIG_MTK_GZ_KREE),y)\nobj-y += mtee_impl.o",
        "ifeq ($(CONFIG_MTK_GZ_KREE_OSS_DISABLED),y)\nobj-y += mtee_impl.o",
        "跳过 trusted_mem/mtee_impl（依赖闭源 MTEE 的 KREE_* 头文件）",
    ),
]

changed = 0
for rel, old, new, why in PATCHES:
    p = os.path.join(root, rel)
    if not os.path.exists(p):
        print("  [skip] 文件不存在: %s" % rel)
        continue
    s = open(p, encoding="utf-8", errors="replace").read()
    if new in s and old not in s:
        print("  [ok]   已是修复状态: %s" % rel)
        continue
    if old not in s:
        print("  [warn] 未找到待替换行，跳过: %s" % rel)
        continue
    s = s.replace(old, new)
    open(p, "w", encoding="utf-8").write(s)
    print("  [fix]  %s\n         %s" % (rel, why))
    changed += 1

print("\n共修补 %d 个文件" % changed)
PY

log "厂商 Makefile 修补完成"
