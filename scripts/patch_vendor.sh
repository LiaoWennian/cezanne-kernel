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

# ---------------------------------------------------------------------------
# 符号版本 CRC 放行（由 RELAX_MODVERSIONS=1 控制）
#
# 为什么必须这么做：
#   出厂内核的 config（我们从 IKCFG 提取）里出现了 MIHW / MIGT / MILLET /
#   DEBUG_KINFO / MI_MEMORY_SYSFS / MTK_SOCINFO / UNIX_SCM /
#   MITIGATE_SPECTRE_BRANCH_HISTORY 这些符号 —— 它们在 cezanne-r-oss 开源树里
#   根本不存在。也就是说：小米出货内核 = 开源树 + 内部私有驱动 + CAF 回溯补丁，
#   结构体布局与开源树不一致（DEBUG_KINFO 会往 struct task_struct 加字段）。
#   实测：module_layout 的 CRC 原厂 0x5c148880，本树编出来 0x6876a8fb，
#   533 个可比对符号里 246 个对不上 —— 靠调配置永远调不齐。
#
#   不放开这一关，10 个原厂 vendor .ko（wlan/gps/触摸/指纹/充电…）会全部
#   报 "disagrees about version of symbol xxx" 拒绝加载，手机等于砖。
#   放开之后：模块能加载，但结构体布局差异带来的 ABI 风险只能靠上机实测。
# ---------------------------------------------------------------------------
if os.environ.get("RELAX_MODVERSIONS", "0") == "1":
    PATCHES.append((
        "kernel/module.c",
        "\t/* Exporting module didn't supply crcs?  OK, we're already tainted. */\n"
        "\tif (!crc)\n\t\treturn 1;\n",
        "\t/* Exporting module didn't supply crcs?  OK, we're already tainted. */\n"
        "\tif (!crc)\n\t\treturn 1;\n"
        "\n"
        "\t/* cezanne-port: 开源树与出厂树的结构体布局不同，符号 CRC 无法对齐，\n"
        "\t * 这里放行全部版本校验，否则原厂 vendor .ko 全部拒载。\n"
        "\t * 只影响符号版本检查，vermagic 校验（check_modstruct_version 之外的\n"
        "\t * same_magic）仍然生效。*/\n"
        "\treturn 1;\n",
        "放行符号版本 CRC 校验（原厂 .ko 与开源树 CRC 必然不一致）",
    ))

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
