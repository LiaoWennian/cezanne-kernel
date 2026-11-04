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
#   GCC64_DIR     aarch64 GCC 4.9     默认 ./toolchain/gcc64
#   KSU_DIR       KernelSU 源码目录   默认 ./KernelSU
#   LOCALVERSION  版本后缀（含前导 -） 默认 -perf-00252-g2f26b5917fd6
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
GCC64_DIR=${GCC64_DIR:-$HERE/toolchain/gcc64}
LOCALVERSION=${LOCALVERSION:--perf-00252-g2f26b5917fd6}
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
[ -x "$GCC64_DIR/bin/aarch64-linux-android-gcc" ] || die "找不到 GCC 4.9: $GCC64_DIR"

export PATH="$CLANG_DIR/bin:$GCC64_DIR/bin:$PATH"

# 与官方 build.config.mtk.aarch64 保持一致：clang + lld
MAKE_VARS="ARCH=arm64 O=$OUT CC=clang CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-android- LD=ld.lld NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump READELF=llvm-readelf AR=llvm-ar STRIP=llvm-strip"

log "内核版本: $(sed -n 's/^\(VERSION\|PATCHLEVEL\|SUBLEVEL\) *= *//p' "$KERNEL_DIR/Makefile" | paste -sd. -)"
log "clang   : $("$CLANG_DIR/bin/clang" --version | head -n1)"
log "EROFS=$ENABLE_EROFS  KSU=$ENABLE_KSU  LOCALVERSION='$LOCALVERSION'  JOBS=$JOBS"

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
	FRAGMENTS="$HERE/configs/erofs.fragment"
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
	"$KERNEL_DIR/scripts/config" --file "$cfg" -d LOCALVERSION_AUTO
	"$KERNEL_DIR/scripts/config" --file "$cfg" --set-str LOCALVERSION "$LOCALVERSION"

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
}

integrate_kernelsu
apply_config
verify_config
build

log "全部完成"
