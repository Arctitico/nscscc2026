#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
individual_dir="$(cd "${script_dir}/.." && pwd)"
workspace_2026="$(cd "${individual_dir}/.." && pwd)"
source_dir="${individual_dir}/src"
target_dir="${1:-${workspace_2026}/nscscc-solo-la-soc/rtl/ip/myCPU}"

if [[ ! -f "${target_dir}/README.md" ]]; then
    echo "error: target is not the official rtl/ip/myCPU directory: ${target_dir}" >&2
    exit 1
fi

sources=(
    tools.sv alu.sv mul.sv decoder.sv regfile.sv preg_free_list.sv bpu.sv icache.sv
    write_buffer.sv dcache.sv
    IF.sv ID.sv RR.sv DP.sv IS.sv RF.sv EX.sv WB.sv rob.sv CM.sv
    mycpu_top.sv cpu_axi_bridge.sv core_top.sv
)

# The official scripts sort source paths. Prefixing the compilation-unit typedef
# file keeps it before modules that use those types in both Verilator and Vivado.
install -m 0644 "${source_dir}/cpu_pkg.sv" "${target_dir}/00_cpu_pkg.sv"
for source in "${sources[@]}"; do
    install -m 0644 "${source_dir}/${source}" "${target_dir}/${source}"
done

echo "Synced ${#sources[@]} modules plus 00_cpu_pkg.sv to ${target_dir}"
