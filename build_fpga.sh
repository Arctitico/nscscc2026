#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fpga_dir="${script_dir}/fpga"
vivado="${VIVADO:-D:/vivado/vivado20192/Vivado/2019.2/bin/vivado.bat}"
frequency=""
jobs=4
recreate_project=0
output_dir=""
sram_read_ns=60
sram_write_pulse_ns=60
sram_write_hold_ns=20
print_config=0

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
  --sram-read-ns NS   SRAM 读访问时间，默认 60 ns
  --sram-write-pulse-ns NS
                      SRAM 写脉冲时间，默认 60 ns
  --sram-write-hold-ns NS
                      WE# 上升后的地址/数据保持时间，默认 20 ns
  --print-config      只显示 PLL 和 SRAM 周期换算，不启动 Vivado
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
        --sram-read-ns)
            (( $# >= 2 )) || die "--sram-read-ns 需要纳秒数"
            sram_read_ns="$2"
            shift 2
            ;;
        --sram-write-pulse-ns)
            (( $# >= 2 )) || die "--sram-write-pulse-ns 需要纳秒数"
            sram_write_pulse_ns="$2"
            shift 2
            ;;
        --sram-write-hold-ns)
            (( $# >= 2 )) || die "--sram-write-hold-ns 需要纳秒数"
            sram_write_hold_ns="$2"
            shift 2
            ;;
        --print-config)
            print_config=1
            shift
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
for timing_value in "$sram_read_ns" "$sram_write_pulse_ns" "$sram_write_hold_ns"; do
    [[ "$timing_value" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
        die "SRAM 时序必须是正数纳秒：$timing_value"
    awk -v value="$timing_value" 'BEGIN { exit !(value > 0.0) }' ||
        die "SRAM 时序必须大于 0 ns：$timing_value"
done

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

ns_to_cycles() {
    local requested_ns="$1"
    awk -v ns="$requested_ns" -v hz="$cpu_hz" '
    BEGIN {
        exact = ns * hz / 1000000000.0
        cycles = int(exact)
        if (cycles < exact - 1e-12)
            cycles++
        if (cycles < 1)
            cycles = 1
        if (cycles > 65535)
            exit 1
        print cycles
    }'
}

cycles_to_ns() {
    local cycles="$1"
    awk -v cycles="$cycles" -v hz="$cpu_hz" \
        'BEGIN { printf "%.6f", cycles * 1000000000.0 / hz }'
}

sram_read_cycles="$(ns_to_cycles "$sram_read_ns")" ||
    die "SRAM 读访问周期数超过 65535"
sram_write_cycles="$(ns_to_cycles "$sram_write_pulse_ns")" ||
    die "SRAM 写脉冲周期数超过 65535"
sram_write_hold_cycles="$(ns_to_cycles "$sram_write_hold_ns")" ||
    die "SRAM 写保持周期数超过 65535"
sram_read_effective_ns="$(cycles_to_ns "$sram_read_cycles")"
sram_write_effective_ns="$(cycles_to_ns "$sram_write_cycles")"
sram_write_hold_effective_ns="$(cycles_to_ns "$sram_write_hold_cycles")"

echo "==> 配置 ${frequency} MHz（PLL ${pll_mult}/${pll_divclk}/${pll_outdiv}，实际 ${actual_mhz} MHz）"
echo "    SRAM 读 : ${sram_read_ns} ns -> ${sram_read_cycles} 拍（实际 ${sram_read_effective_ns} ns）"
echo "    SRAM 写 : ${sram_write_pulse_ns} ns -> ${sram_write_cycles} 拍（实际 ${sram_write_effective_ns} ns）"
echo "    写后保持: ${sram_write_hold_ns} ns -> ${sram_write_hold_cycles} 拍（实际 ${sram_write_hold_effective_ns} ns）"

if (( print_config )); then
    exit 0
fi

command -v cmd.exe >/dev/null 2>&1 || die "找不到 cmd.exe"
command -v wslpath >/dev/null 2>&1 || die "找不到 wslpath"
command -v sha256sum >/dev/null 2>&1 || die "找不到 sha256sum"

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

echo "==> 启动 Vivado 构建"
report_path_for_vivado="$(wslpath -m "$output_dir")"
pushd "$fpga_dir" >/dev/null
cmd.exe /d /s /c "$vivado" -mode batch -nojournal -nolog \
    -source build.tcl \
    -tclargs "$cpu_hz" "$pll_divclk" "$pll_mult" "$pll_outdiv" \
    "$sram_read_cycles" "$sram_write_cycles" "$sram_write_hold_cycles" \
    "$jobs" "$report_path_for_vivado"
popd >/dev/null

summary_file="${output_dir}/build_summary.txt"
bit_file="${output_dir}/soc_top.bit"
[[ -f "$summary_file" ]] || die "未找到构建摘要：$summary_file"
[[ -f "$bit_file" ]] || die "未找到 bitstream：$bit_file"
sed -i 's/\r$//' "$summary_file"
sha256sum "$bit_file" >"${bit_file}.sha256"
{
    printf 'SRAM_READ_REQUESTED_NS=%s\n' "$sram_read_ns"
    printf 'SRAM_READ_EFFECTIVE_NS=%s\n' "$sram_read_effective_ns"
    printf 'SRAM_WRITE_PULSE_REQUESTED_NS=%s\n' "$sram_write_pulse_ns"
    printf 'SRAM_WRITE_PULSE_EFFECTIVE_NS=%s\n' "$sram_write_effective_ns"
    printf 'SRAM_WRITE_HOLD_REQUESTED_NS=%s\n' "$sram_write_hold_ns"
    printf 'SRAM_WRITE_HOLD_EFFECTIVE_NS=%s\n' "$sram_write_hold_effective_ns"
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
