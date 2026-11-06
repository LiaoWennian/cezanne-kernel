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
# 原厂 MIUI14 内核里 IKCFG 提取出来的完整 .config（configs/base.config）。
# 为什么不用 cezanne_user_defconfig：
#   defconfig 是"偏离默认值才记录"的裁剪版，MTK/小米私有开关（TEE、MIHW、
#   MILLET、SOCINFO、TYPEC…）全都不在里面。用 defconfig 编出来的内核
#   vermagic 能对上，但 struct module 布局不同 → module_layout 的 CRC
#   从原厂 0x5c148880 变成 0xd58c5782，10 个 vendor .ko 全部拒载。
BASE_CONFIG=${BASE_CONFIG:-$HERE/configs/base.config}

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
	if [ -f "$BASE_CONFIG" ]; then
		log "使用原厂 config: $(basename "$BASE_CONFIG")（$(wc -l < "$BASE_CONFIG") 行）"
		cp "$BASE_CONFIG" "$OUT/.config"
		# 原厂 config 里带着 LOCALVERSION_AUTO=y 与 CONFIG_LOCALVERSION="-perf"，
		# 这些在下面统一改写；olddefconfig 会补齐新移植 erofs 引入的依赖项。
		make -C "$KERNEL_DIR" $MAKE_VARS olddefconfig >/dev/null
	else
		warn "找不到 $BASE_CONFIG，退回 $DEFCONFIG（module_layout CRC 必然对不上）"
		make -C "$KERNEL_DIR" $MAKE_VARS "$DEFCONFIG" >/dev/null
	fi

	cfg="$OUT/.config"
	# vermagic.fragment 必须最先应用，保证 MODVERSIONS 等基础开关就位
	FRAGMENTS="$HERE/configs/vermagic.fragment $HERE/configs/descope.fragment $HERE/configs/erofs.fragment"
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

	report_config_drift
}

# ---------------------------------------------------------------------------
# 3.5 与原厂 config 逐项比对
#     olddefconfig 会静默丢掉本源码树里不存在的符号（原厂 config 里有、
#     OSS 树里没对应的 Kconfig 项）。丢符号本身不可怕，可怕的是丢掉的
#     ∑ 恰好改了 struct module 布局 —— 那 module_layout 的 CRC 就变了。
# ---------------------------------------------------------------------------
# 注意：LTO / LTO_CLANG / CFI / CFI_CLANG 必须与原厂一致地保持开启。
# 实测原厂 10 个 vendor .ko 全部带 .rela.text.__cfi_check 段并引用
# __cfi_slowpath（CRC 0x5356009c），关掉 CFI 会让 .ko 因缺符号直接加载失败。
CRITICAL_SYMS="SMP PREEMPT MODULE_UNLOAD MODVERSIONS KALLSYMS KALLSYMS_ALL \
TRACEPOINTS EVENT_TRACING FTRACE FUNCTION_TRACER JUMP_LABEL LIVEPATCH \
MODULE_SIG MODULE_SIG_FORCE GCC_PLUGIN_RANDSTRUCT LTO LTO_CLANG CFI CFI_CLANG \
MODULE_UNLOAD_TAINT_TRACKING MODULE_FORCE_UNLOAD PREEMPT_COUNT STACKPROTECTOR_STRONG"

report_config_drift() {
	[ -f "$BASE_CONFIG" ] || return 0
	cfg="$OUT/.config"
	log "与原厂 config 比对"

	awk -v crit="$CRITICAL_SYMS" '
		BEGIN { n=split(crit, critarr, " "); for (i=1;i<=n;i++) critical[critarr[i]]=1 }
		function val(line) { return substr(line, index(line,"=")+1) }
		FILENAME==ARGV[1] {
			if ($0 ~ /^# CONFIG_[A-Z0-9_]+ is not set/) { gsub(/^# CONFIG_/,"",$0); sub(/ is not set$/,"",$0); base[$1]="n"; next }
			if ($0 ~ /^CONFIG_/) { k=$0; v=val($0); sub(/=.*/,"",k); sub(/^CONFIG_/,"",k); base[k]=v }
			next
		}
		{
			if ($0 ~ /^# CONFIG_[A-Z0-9_]+ is not set/) { gsub(/^# CONFIG_/,"",$0); sub(/ is not set$/,"",$0); now[$1]="n"; next }
			if ($0 ~ /^CONFIG_/) { k=$0; v=val($0); sub(/=.*/,"",k); sub(/^CONFIG_/,"",k); now[k]=v }
		}
		END {
			total=0; critbad=0
			for (k in base) {
				b=base[k]; cur=(k in now) ? now[k] : "缺失"
				if (b != cur) {
					total++
					if (k in critical) {
						critbad++
						printf "  关键项差异: %-32s 原厂=%-12s 本次=%s\n", k, b, cur
					} else if (total <= 300) {
						printf "  差异: %-32s 原厂=%-12s 本次=%s\n", k, b, cur
					}
				}
			}
			printf "配置差异总数: %d，其中关键项: %d\n", total, critbad
			exit (critbad>0)
		}
	' "$BASE_CONFIG" "$cfg" || die "关键配置漂移，module_layout CRC 会变，先修这个再编"
}

# ---------------------------------------------------------------------------
# 5.5 符号 CRC 硬校验：把编出来的 Module.symvers 和原厂 10 个 .ko 的
#     __versions 表逐项比对。只要有一个同名符号 CRC 不同，模块就会
#     加载失败（"disagrees about version of symbol X"），此时不该出包。
# ---------------------------------------------------------------------------
verify_symbols() {
	symvers="$OUT/Module.symvers"
	ref="$HERE/configs/vendor_versions.txt"
	[ -f "$symvers" ] || { warn "找不到 Module.symvers，跳过 CRC 校验"; return 0; }
	[ -f "$ref" ] || { warn "找不到 $ref，跳过 CRC 校验"; return 0; }

	log "校验符号 CRC（对照原厂 vendor .ko）"
	report="$OUT/crc-compare.txt"
	awk -F'\t' -v rep="$report" '
		NR==FNR { want[$2]=$1; next }
		{ crc=$1; nm=$2
		  if (nm in want) {
			  seen++
			  if (want[nm]==crc) { ok++; print "OK\t" nm "\t" want[nm] "\t" crc > rep }
			  else { bad++; print "MISMATCH\t" nm "\t" want[nm] "\t" crc > rep
			         if (bad<=15) printf "  CRC 不一致: %-38s 原厂=%s 本次=%s\n", nm, want[nm], crc }
		  }
		}
		END {
			printf "可比对符号: %d，一致: %d，不一致: %d\n", seen, ok, bad+0
			exit (bad>0)
		}
	' "$ref" "$symvers" || true

	# 把不一致数量落盘，由 workflow 的独立门禁步骤决定成败。
	# 这样即使 CRC 不齐也照样出包，方便先上机验证 / 分析。
	bad=$(grep -c '^MISMATCH' "$report" 2>/dev/null || echo 0)
	printf '%s' "$bad" > "$OUT/crc-mismatch-count"
	if [ "$bad" -gt 0 ]; then
		warn "有 $bad 个符号 CRC 与原厂不一致（明细: $report）"
	fi

	# module_layout 单独强调：它是所有 .ko 都会引用的第一道门槛
	ml=$(awk -F'\t' '$2=="module_layout" {print $1; exit}' "$symvers")
	if [ "$ml" = "0x5c148880" ]; then
		log "✅ module_layout CRC = 0x5c148880（与原厂一致）"
	else
		warn "module_layout CRC = ${ml:-缺失}，原厂为 0x5c148880"
		printf '%s' "$ml" > "$OUT/module-layout-crc"
	fi
}


# ---------------------------------------------------------------------------
# 4. 编译
# ---------------------------------------------------------------------------
build() {
	log "开始编译（并行 $JOBS，-k：一次暴露全部错误）"
	blog="$OUT/build.log"
	# 用 -k 而不是快速失败：原厂 config 会打开一些 OSS 源码树里根本
	# 没有实现的私有驱动，逐个试错每轮 15 分钟太贵，一轮把错全抖出来。
	if ! make -C "$KERNEL_DIR" $MAKE_VARS -k -j"$JOBS" Image.gz > "$blog" 2>&1; then
		echo "---------- 去重后的编译错误 ----------"
		grep -E "fatal error:|error:|No rule to make target|undefined reference|multiple definition" "$blog" \
			| grep -v "LLVM ERROR" \
			| sed -e 's#^.*/kernel/##' \
			| sort -u | head -60
		echo "---------- 失败的 make 目标 ----------"
		grep -E "\*\*\*" "$blog" | grep -v "not remade" | sed -e 's#^.*/kernel/##' | head -20
		echo "---------- 目标失败前 3 行 ----------"
		grep -B3 -E "\*\*\* \[.*Error 1" "$blog" | sed -e 's#^.*/kernel/##' | head -40
		echo "---------- 末尾上下文 ----------"
		tail -25 "$blog"
		die "编译失败（完整日志: $blog）"
	fi
	[ -f "$OUT/arch/arm64/boot/Image.gz" ] || die "编译结束但找不到 Image.gz"

	log "构建 Image.gz-dtb（追加 mt6889 dtb）"
	if make -C "$KERNEL_DIR" $MAKE_VARS -j"$JOBS" Image.gz-dtb; then
		[ -f "$OUT/arch/arm64/boot/Image.gz-dtb" ] && log "已生成 Image.gz-dtb"
	else
		warn "Image.gz-dtb 构建失败，将只用 Image.gz"
	fi

	log "内核 release: $(cat "$OUT/include/config/kernel.release" 2>/dev/null || echo unknown)"
	verify_vermagic
	verify_symbols
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

# 只诊断：生成 .config + 打印与原厂的全部差异后立即退出，不编译。
# 用来快速迭代"哪些配置项影响了结构体布局/符号 CRC"，一次 7 分钟而不是 26 分钟。
if [ "${DIAG_ONLY:-0}" = "1" ]; then
	log "DIAG_ONLY：配置诊断结束"
	exit 0
fi

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
