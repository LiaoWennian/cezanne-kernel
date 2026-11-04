#!/bin/sh
# ---------------------------------------------------------------------------
# Redmi K30 Ultra (cezanne / MT6889) 4.14.186 内核构建脚本
#
# 目标：在官方源码基础上加入 EROFS 支持（澎湃 OS4 系统层必需），
#       并保持 LOCALVERSION 与官方一致，使原厂 vendor .ko 可直接加载。
#
# 环境变量（均有默认值，CI 与本地 Linux 通用）：
#   KERNEL_DIR    内核源码目录        默认 ./kernel
#   OUT           编译输出目录        默认 ./out
#   CLANG_DIR     clang-r383902       默认 ./toolchain/clang
#   CROSS_COMPILE 交叉工具前缀        默认 aarch64-linux-gnu-（apt 提供）
#   KSU_DIR       KernelSU 源码目录   默认 ./KernelSU
#   KERNEL_LOCALVERSION  版本后缀（含前导 -） 默认 -perf-00252-g2f26b5917fd6
#   ENABLE_EROFS  是否已移植 erofs    默认 1
#   ENABLE_KSU    是否集成 KernelSU   默认 0
#   JOBS          并行度              默认 nproc
# ---------------------------------------------------------------------------
set -eu

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*"; }
die()  { printf '[error] %s\n' "$*" >&2; exit 1; }

HERE=$(cd "$(dirname "$0")/.." && pwd)

KERNEL_DIR=${KERNEL_DIR:-$HERE/kernel}
OUT=${OUT:-$HERE/out}
KSU_DIR=${KSU_DIR:-$HERE/KernelSU}
CLANG_DIR=${CLANG_DIR:-$HERE/toolchain/clang}
# 交叉工具前缀：由 apt 的 binutils-aarch64-linux-gnu / gcc-aarch64-linux-gnu 提供。
# 代码本身全部用 clang 编译（CC=clang），这里的前缀只用于兜底调用 as/ld/objcopy。
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
# 注意：这里刻意不叫 LOCALVERSION。scripts/setlocalversion 里有一行
#   res="${res}${CONFIG_LOCALVERSION}${LOCALVERSION}"
# 会把 CONFIG_LOCALVERSION 和 make 变量 LOCALVERSION 各追加一次。
# 如果环境里存在同名变量 LOCALVERSION，make 会继承它，导致后缀重复两遍。
KERNEL_LOCALVERSION=${KERNEL_LOCALVERSION:-${LOCALVERSION:--perf-00252-g2f26b5917fd6}}
unset LOCALVERSION
EXPECTED_RELEASE=${EXPECTED_RELEASE:-4.14.186${KERNEL_LOCALVERSION}}
ENABLE_EROFS=${ENABLE_EROFS:-1}
ENABLE_KSU=${ENABLE_KSU:-0}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}
DEFCONFIG=cezanne_user_defconfig

KERNEL_DIR=$(cd "$KERNEL_DIR" && pwd)
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

[ -f "$KERNEL_DIR/Makefile" ] || die "找不到内核源码: $KERNEL_DIR"
[ -f "$KERNEL_DIR/arch/arm64/configs/$DEFCONFIG" ] || die "找不到 $DEFCONFIG（请确认分支为 cezanne-r-oss）"
[ -x "$CLANG_DIR/bin/clang" ] || die "找不到 clang: $CLANG_DIR/bin/clang"
[ -x "$CLANG_DIR/bin/ld.lld" ] || die "找不到 ld.lld: $CLANG_DIR/bin/ld.lld（LTO/CFI 必需）"
command -v "${CROSS_COMPILE}as" >/dev/null 2>&1 || \
	die "找不到 ${CROSS_COMPILE}as，请先安装 binutils-aarch64-linux-gnu"

export PATH="$CLANG_DIR/bin:$PATH"

# 与官方 build.config.mtk.aarch64 保持一致：clang + lld，binutils 全部用 llvm 版
MAKE_VARS="ARCH=arm64 O=$OUT LOCALVERSION= CC=clang CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=$CROSS_COMPILE LD=ld.lld NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump READELF=llvm-readelf AR=llvm-ar STRIP=llvm-strip"

log "内核版本: $(sed -n 's/^\(VERSION\|PATCHLEVEL\|SUBLEVEL\) *= *//p' "$KERNEL_DIR/Makefile" | paste -sd. -)"
log "clang   : $("$CLANG_DIR/bin/clang" --version | head -n1)"
log "交叉工具: $("${CROSS_COMPILE}as" --version | head -n1)"
log "EROFS=$ENABLE_EROFS  KSU=$ENABLE_KSU  后缀='$KERNEL_LOCALVERSION'  JOBS=$JOBS"

# ---------------------------------------------------------------------------
# 1. 集成 KernelSU（可选）
# ---------------------------------------------------------------------------
integrate_kernelsu() {
	[ "$ENABLE_KSU" = "1" ] || return 0
	[ -d "$KSU_DIR/kernel" ] || die "找不到 KernelSU 源码: $KSU_DIR/kernel"

	log "集成 KernelSU 到 drivers/kernelsu"
	rm -rf "$KERNEL_DIR/drivers/kernelsu"
	cp -a "$KSU_DIR/kernel" "$KERNEL_DIR/drivers/kernelsu"

	grep -q 'kernelsu/' "$KERNEL_DIR/drivers/Makefile" || \
		printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$KERNEL_DIR/drivers/Makefile"
	grep -q 'drivers/kernelsu/Kconfig' "$KERNEL_DIR/drivers/Kconfig" || \
		printf '\nsource "drivers/kernelsu/Kconfig"\n' >> "$KERNEL_DIR/drivers/Kconfig"

	# 源码脱离 .git 后 KSU_VERSION 会退回 16，按上游公式显式固定
	if [ -d "$KSU_DIR/.git" ]; then
		n=$(git -C "$KSU_DIR" rev-list --count HEAD 2>/dev/null || true)
		if [ -n "$n" ]; then
			v=$((10000 + n + 200))
			sed -i "s/-DKSU_VERSION=16/-DKSU_VERSION=$v/" "$KERNEL_DIR/drivers/kernelsu/Makefile"
			log "KernelSU 版本号固定为 $v"
		fi
	fi
}

# ---------------------------------------------------------------------------
# 2. 生成 .config：官方 defconfig + 片段覆盖
# ---------------------------------------------------------------------------
apply_config() {
	log "生成 $DEFCONFIG"
	make -C "$KERNEL_DIR" $MAKE_VARS "$DEFCONFIG" >/dev/null

	cfg="$OUT/.config"
	# vermagic.fragment 必须最先应用，保证 MODVERSIONS 等基础开关就位
	FRAGMENTS="$HERE/configs/vermagic.fragment $HERE/configs/erofs.fragment"
	[ "$ENABLE_KSU" = "1" ] && FRAGMENTS="$FRAGMENTS $HERE/configs/ksu.fragment"

	for frag in $FRAGMENTS; do
		[ -f "$frag" ] || die "找不到配置片段: $frag"
		log "应用配置片段: $(basename "$frag")"
		while IFS= read -r line || [ -n "$line" ]; do
			line=$(printf '%s' "$line" | tr -d '\r')
			case "$line" in ''|'#'*) continue ;; esac
			sym=${line%%=*}
			val=${line#*=}
			sym=${sym#CONFIG_}
			case "$val" in
				y) "$KERNEL_DIR/scripts/config" --file "$cfg" -e "$sym" ;;
				n) "$KERNEL_DIR/scripts/config" --file "$cfg" -d "$sym" ;;
				*) "$KERNEL_DIR/scripts/config" --file "$cfg" --set-str "$sym" "$(printf '%s' "$val" | tr -d '"')" ;;
			esac
		done < "$frag"
	done

	# 关掉 LOCALVERSION_AUTO：否则会拼上 -g<sha>，原厂 .ko 的 vermagic 就对不上
	# 用 sed 直接改 .config：LOCALVERSION 的值以 '-' 开头，
	# 走 scripts/config --set-str 会被当成命令行选项解析，导致写入错误。
	sed -i.bak -e 's/^CONFIG_LOCALVERSION_AUTO=.*/# CONFIG_LOCALVERSION_AUTO is not set/' "$cfg"
	sed -i -e '/^CONFIG_LOCALVERSION=/d' "$cfg"
	printf 'CONFIG_LOCALVERSION="%s"\n' "$KERNEL_LOCALVERSION" >> "$cfg"
	grep -q '^# CONFIG_LOCALVERSION_AUTO is not set' "$cfg" || echo 'CONFIG_LOCALVERSION_AUTO=n' >> "$cfg"
	rm -f "$cfg.bak"

	make -C "$KERNEL_DIR" $MAKE_VARS olddefconfig >/dev/null
}

# ---------------------------------------------------------------------------
# 3. 回读校验：任何一项没生效立刻终止，避免白跑一小时
# ---------------------------------------------------------------------------
verify_config() {
	log "校验关键配置"
	cfg="$OUT/.config"
	missing=""
	check_y() { grep -qx "CONFIG_$1=y" "$cfg" || missing="$missing CONFIG_$1"; }
	check_not_set() { grep -qx "# CONFIG_$1 is not set" "$cfg" || missing="$missing CONFIG_$1=n"; }

	if [ "$ENABLE_EROFS" = "1" ]; then
		check_y EROFS_FS
		check_y EROFS_FS_XATTR
	fi
	if [ "$ENABLE_KSU" = "1" ]; then
		check_y KSU
		check_y KPROBES
	fi
	check_y MODVERSIONS
	check_not_set LOCALVERSION_AUTO
	# vermagic 对齐：这四项决定模块能否被原厂 .ko 接受
	check_y SMP
	check_y PREEMPT
	check_y MODULE_UNLOAD

	# 软检查：符号不存在时（部分树没有 randstruct）不当作失败
	grep -qx '# CONFIG_MODULE_FORCE_UNLOAD is not set' "$cfg" || \
		warn "CONFIG_MODULE_FORCE_UNLOAD 未显式关闭，vermagic 可能多出 force_unload"
	grep -qx '# CONFIG_GCC_PLUGIN_RANDSTRUCT is not set' "$cfg" || \
		warn "CONFIG_GCC_PLUGIN_RANDSTRUCT 状态未知（若为 y 会导致 vermagic 不一致）"

	[ -z "$missing" ] || die "以下配置未生效，请检查依赖链:$missing"
	log "配置校验通过"
}

# ---------------------------------------------------------------------------
# 4. 编译
# ---------------------------------------------------------------------------
build() {
	log "开始编译（并行 $JOBS）"
	make -C "$KERNEL_DIR" $MAKE_VARS -j"$JOBS" Image.gz
	[ -f "$OUT/arch/arm64/boot/Image.gz" ] || die "编译结束但找不到 Image.gz"

	log "构建 Image.gz-dtb（追加 mt6889 dtb）"
	if make -C "$KERNEL_DIR" $MAKE_VARS -j"$JOBS" Image.gz-dtb; then
		[ -f "$OUT/arch/arm64/boot/Image.gz-dtb" ] && log "已生成 Image.gz-dtb"
	else
		warn "Image.gz-dtb 构建失败，将只用 Image.gz"
	fi

	log "内核 release: $(cat "$OUT/include/config/kernel.release" 2>/dev/null || echo unknown)"
	verify_vermagic
}

# ---------------------------------------------------------------------------
# 5. 终极校验：直接从编出来的 Image 里找 vermagic 字符串
#    内核里 vermagic 是 kernel/module.c 的一个常量，一定以明文躺在 Image 里。
#    对不上 = 原厂 .ko 全部拒载，此时不如直接失败，别浪费刷机时间。
# ---------------------------------------------------------------------------
verify_vermagic() {
	img="$OUT/arch/arm64/boot/Image"
	[ -f "$img" ] || { warn "找不到 $img，跳过 vermagic 校验"; return 0; }

	rel=$(cat "$OUT/include/config/kernel.release" 2>/dev/null || echo "")
	[ -n "$rel" ] || { warn "读不到 kernel.release，跳过"; return 0; }

	# 硬校验：release 必须逐字符等于预期值。
	# 不能拿"编出来的 release"去比对"编出来的镜像"——那样自己跟自己对得上，
	# 后缀重复两遍也能通过（真实踩过这个坑：setlocalversion 会同时追加
	# CONFIG_LOCALVERSION 和 make 变量 LOCALVERSION）。
	if [ "$rel" != "$EXPECTED_RELEASE" ]; then
		warn "kernel.release 不符：实际 '$rel'，预期 '$EXPECTED_RELEASE'"
		die "版本后缀不对，原厂 vendor .ko 的 vermagic 会对不上"
	fi

	expect="$EXPECTED_RELEASE SMP preempt mod_unload modversions aarch64"
	log "校验 vermagic: $expect"

	if grep -aqF "$expect" "$img"; then
		log "✅ vermagic 与预期完全一致"
	else
		echo "----- 实际找到的 vermagic 候选 -----"
		grep -ao "[0-9]\+\.[0-9]\+\.[0-9]\+[^\"']\{0,60\} SMP [a-z_ ]\{0,60\}" "$img" \
			| sort -u | head -5 || true
		echo "-----------------------------------"
		die "vermagic 不匹配，原厂 vendor .ko 会加载失败；请检查后缀 / MODVERSIONS / PREEMPT"
	fi
}

integrate_kernelsu
apply_config
verify_config

# ---------------------------------------------------------------------------
# 2.5 预检模式：只编 fs/erofs，用 -k 把所有错误一次性抖出来
#     （移植第三方驱动的调试期用这个，一轮就能看全，不用逐轮试错）
# ---------------------------------------------------------------------------
if [ "${PRECHECK:-0}" = "1" ]; then
	log "预检：单编 fs/erofs（-k 收集全部错误）"
	make -C "$KERNEL_DIR" $MAKE_VARS prepare >/dev/null 2>&1 || true
	set +e
	out=$(make -C "$KERNEL_DIR" $MAKE_VARS -k -j"$JOBS" fs/erofs/ 2>&1)
	set -e
	printf '%s\n' "$out" | grep -E "error:|fatal error|Error [0-9]" | head -80
	if printf '%s\n' "$out" | grep -qE "error:|Error [0-9]"; then
		die "fs/erofs 预检失败（以上是全部错误）"
	fi
	log "fs/erofs 预检通过"
	exit 0
fi

build

log "全部完成"
