#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fpga_dir="${script_dir}/fpga"
vivado="${VIVADO:-D:/vivado/vivado20192/Vivado/2019.2/bin/vivado.bat}"
frequency=""
jobs=4
recreate_project=0
output_dir=""

usage() {
    cat <<'EOF'
用法：
  ./build_fpga.sh --freq MHz [选项]
  ./build_fpga.sh MHz [选项]

创建并构建 Vivado 工程。脚本根据请求频率
选择合法的 7-series PLL 整数参数，不依赖官方参考 SoC、生成 IP 或外部 DCP。

选项：
  -f, --freq MHz      CPU 频率，例如 50、100、92.5
  -j, --jobs N        Vivado 并行任务数，默认 4
  --vivado PATH       Windows Vivado 路径
  --recreate-project  重建 fpga/project
  --output DIR        归档目录，默认 output/fpga_<频率>mhz_<时间戳>
  -h, --help          显示帮助
EOF
}

die() {
    echo "error: $*" >&2
    exit 2
}

while (( $# > 0 )); do
    case "$1" in
        -f|--freq)
            (( $# >= 2 )) || die "$1 需要 MHz"
            frequency="$2"
            shift 2
            ;;
        -j|--jobs)
            (( $# >= 2 )) || die "$1 需要任务数"
            jobs="$2"
            shift 2
            ;;
        --vivado)
            (( $# >= 2 )) || die "--vivado 需要路径"
            vivado="$2"
            shift 2
            ;;
        --recreate-project)
            recreate_project=1
            shift
            ;;
        --output)
            (( $# >= 2 )) || die "--output 需要目录"
            output_dir="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        [0-9]*.[0-9]*|[0-9]*)
            [[ -z "$frequency" ]] || die "频率被重复指定"
            frequency="$1"
            shift
            ;;
        *)
            die "未知参数：$1"
            ;;
    esac
done

[[ -n "$frequency" ]] || die "必须用 --freq MHz 指定 CPU 频率"
[[ "$frequency" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "非法频率：$frequency"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || die "--jobs 必须是正整数"
command -v cmd.exe >/dev/null 2>&1 || die "找不到 cmd.exe"
command -v wslpath >/dev/null 2>&1 || die "找不到 wslpath"
command -v sha256sum >/dev/null 2>&1 || die "找不到 sha256sum"

# Artix-7 PLLE2：输入 50 MHz，PFD >= 19 MHz，VCO 800..1600 MHz。
# 在所有整数参数中选择频差最小、其次 VCO 较低的一组。
pll_choice="$(awk -v target="$frequency" '
BEGIN {
    best_err = 1e99
    for (d = 1; d <= 2; d++) {
        for (m = 2; m <= 64; m++) {
            vco = 50.0 * m / d
            if (vco < 800.0 || vco > 1600.0)
                continue
            for (o = 1; o <= 128; o++) {
                actual = vco / o
                err = actual - target
                if (err < 0) err = -err
                if (err < best_err - 1e-9 ||
                    (err <= best_err + 1e-9 && vco < best_vco)) {
                    best_err = err
                    best_vco = vco
                    best_d = d
                    best_m = m
                    best_o = o
                    best_actual = actual
                }
            }
        }
    }
    if (best_err > 0.001)
        exit 1
    printf "%d %d %d %.6f %.0f\n",
           best_d, best_m, best_o, best_actual, best_actual * 1000000.0
}')"
[[ -n "$pll_choice" ]] || die "无法用整数 PLL 参数精确生成 ${frequency} MHz（容差 1 kHz）"
read -r pll_divclk pll_mult pll_outdiv actual_mhz cpu_hz <<<"$pll_choice"

frequency_tag="${frequency//./_}"
if [[ -z "$output_dir" ]]; then
    timestamp="$(date +%Y%m%d_%H%M%S)"
    output_dir="${script_dir}/output/fpga_${frequency_tag}mhz_${timestamp}"
elif [[ "$output_dir" != /* ]]; then
    output_dir="${script_dir}/${output_dir}"
fi
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"

project_file="${fpga_dir}/project/Individual_SoC.xpr"
if (( recreate_project )) || [[ ! -f "$project_file" ]]; then
    echo "==> 创建 individual Vivado 工程"
    pushd "$fpga_dir" >/dev/null
    cmd.exe /d /s /c "$vivado" -mode batch -nojournal -nolog \
        -source create_project.tcl
    popd >/dev/null
fi
[[ -f "$project_file" ]] || die "Vivado 工程创建失败：$project_file"

echo "==> 构建 ${frequency} MHz（PLL ${pll_mult}/${pll_divclk}/${pll_outdiv}，实际 ${actual_mhz} MHz）"
report_path_for_vivado="$(wslpath -m "$output_dir")"
pushd "$fpga_dir" >/dev/null
cmd.exe /d /s /c "$vivado" -mode batch -nojournal -nolog \
    -source build.tcl \
    -tclargs "$cpu_hz" "$pll_divclk" "$pll_mult" "$pll_outdiv" "$jobs" "$report_path_for_vivado"
popd >/dev/null

summary_file="${output_dir}/build_summary.txt"
bit_file="${output_dir}/soc_top.bit"
[[ -f "$summary_file" ]] || die "未找到构建摘要：$summary_file"
[[ -f "$bit_file" ]] || die "未找到 bitstream：$bit_file"
sed -i 's/\r$//' "$summary_file"
sha256sum "$bit_file" >"${bit_file}.sha256"
{
    printf 'BITSTREAM=%s\n' "$bit_file"
    printf 'BITSTREAM_SHA256=%s\n' "$(cut -d ' ' -f 1 "${bit_file}.sha256")"
} >>"$summary_file"

setup_wns="$(sed -n 's/^DESIGN_SETUP_WNS_NS=//p' "$summary_file")"
setup_tns="$(sed -n 's/^DESIGN_SETUP_TNS_NS=//p' "$summary_file")"
hold_whs="$(sed -n 's/^DESIGN_HOLD_WHS_NS=//p' "$summary_file")"
timing_met="$(sed -n 's/^TIMING_MET=//p' "$summary_file")"

echo "==> 构建结果"
echo "    CPU 时钟 : ${actual_mhz} MHz"
echo "    全设计   : WNS ${setup_wns} ns, TNS ${setup_tns} ns, WHS ${hold_whs} ns"
echo "    Bitstream: ${bit_file}"
echo "    报告目录 : ${output_dir}"

if [[ "$timing_met" != "1" ]]; then
    echo "error: bitstream 已生成，但全设计 setup/hold 时序不满足" >&2
    exit 3
fi

echo "==> bitstream 已生成，全设计 setup/hold 时序满足"
