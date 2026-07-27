#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/sync_official_soc.sh [--check|--apply] [--target REPOSITORY]

Compare or copy the signed-off direct-SoC RTL from individual to the official
preT202610699009694 repository. The default mode is read-only --check.

The script never stages, commits, pushes, deletes, or modifies official-only
files such as CI flow, README.md, or design.pdf. The direct thinpad_top RTL and
its board constraint are managed design sources and are synchronized.
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
individual_dir="$(cd "${script_dir}/.." && pwd)"
workspace_2026="$(cd "${individual_dir}/.." && pwd)"
target_repo="${workspace_2026}/preT202610699009694"
mode=check

while (($#)); do
    case "$1" in
        --check)
            mode=check
            shift
            ;;
        --apply)
            mode=apply
            shift
            ;;
        --target)
            if (($# < 2)); then
                echo "error: --target requires a repository path" >&2
                exit 2
            fi
            target_repo="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

source_branch="$(git -C "${individual_dir}" branch --show-current)"
if [[ "${source_branch}" != "inorder-dual-issue" ]]; then
    echo "error: source branch must be inorder-dual-issue, got ${source_branch:-detached HEAD}" >&2
    exit 1
fi

if [[ ! -d "${target_repo}/.git" ]]; then
    echo "error: target is not a Git worktree: ${target_repo}" >&2
    exit 1
fi
target_repo="$(git -C "${target_repo}" rev-parse --show-toplevel)"
target_dir="${target_repo}/src/soc"
source_constraint="${individual_dir}/fpga/constraints/soc.xdc"
target_constraint="${target_repo}/run_vivado/constraints/thinpad_top.xdc"

target_remote="$(git -C "${target_repo}" remote get-url origin 2>/dev/null || true)"
if [[ "${target_remote}" != *"preT202610699009694.git" ]]; then
    echo "error: target origin is not preT202610699009694: ${target_remote:-missing}" >&2
    exit 1
fi
target_branch="$(git -C "${target_repo}" branch --show-current)"
if [[ "${target_branch}" != "inorder-dual-issue" ]]; then
    echo "error: target branch must be inorder-dual-issue, got ${target_branch:-detached HEAD}" >&2
    exit 1
fi
if [[ ! -f "${target_dir}/thinpad_top.sv" ]]; then
    echo "error: official top is missing: ${target_dir}/thinpad_top.sv" >&2
    exit 1
fi
if [[ ! -f "${target_constraint}" ]]; then
    echo "error: official constraint is missing: ${target_constraint}" >&2
    exit 1
fi

cpu_sources=(
    cpu_pkg.sv tools.sv alu.sv mul.sv decoder.sv regfile.sv bpu.sv
    icache.sv write_buffer.sv dcache.sv
    IF.sv ID.sv DP.sv IS.sv RF.sv EX1.sv EX2.sv CM.sv
    mycpu_top.sv
)
soc_sources=(
    sram_ctrl.sv uart_phy.sv uart_mm.sv mem_bridge.sv board_clock.sv
    thinpad_top.sv
)
# 已退出流水线、但按本脚本“不删除目标文件”的约定允许留在官方仓库。
retired_sources=(WB.sv)
expected_sources=("${cpu_sources[@]}" "${soc_sources[@]}" "${retired_sources[@]}")

is_expected_source() {
    local candidate="$1"
    local expected
    for expected in "${expected_sources[@]}"; do
        [[ "${candidate}" == "${expected}" ]] && return 0
    done
    return 1
}

unexpected=0
for target_source in "${target_dir}"/*.sv; do
    target_name="${target_source##*/}"
    if ! is_expected_source "${target_name}"; then
        echo "error: unmanaged SystemVerilog file requires review: ${target_source}" >&2
        unexpected=1
    fi
done
((unexpected == 0)) || exit 1

if [[ "${mode}" == "apply" ]]; then
    if [[ -n "$(git -C "${individual_dir}" status --short)" ]]; then
        echo "error: source worktree must be clean for --apply" >&2
        exit 1
    fi
    if [[ -n "$(git -C "${target_repo}" status --short)" ]]; then
        echo "error: target worktree must be clean for --apply" >&2
        exit 1
    fi
fi

differences=0
for source in "${cpu_sources[@]}"; do
    source_path="${individual_dir}/src/${source}"
    target_path="${target_dir}/${source}"
    if [[ ! -f "${source_path}" ]]; then
        echo "error: managed source is missing: ${source_path}" >&2
        exit 1
    fi
    if ! cmp -s "${source_path}" "${target_path}"; then
        echo "${mode}: src/${source} -> src/soc/${source}"
        differences=$((differences + 1))
        if [[ "${mode}" == "apply" ]]; then
            install -m 0644 "${source_path}" "${target_path}"
        fi
    fi
done
for source in "${soc_sources[@]}"; do
    source_path="${individual_dir}/soc/${source}"
    target_path="${target_dir}/${source}"
    if [[ ! -f "${source_path}" ]]; then
        echo "error: managed source is missing: ${source_path}" >&2
        exit 1
    fi
    if ! cmp -s "${source_path}" "${target_path}"; then
        echo "${mode}: soc/${source} -> src/soc/${source}"
        differences=$((differences + 1))
        if [[ "${mode}" == "apply" ]]; then
            install -m 0644 "${source_path}" "${target_path}"
        fi
    fi
done
if [[ ! -f "${source_constraint}" ]]; then
    echo "error: managed constraint is missing: ${source_constraint}" >&2
    exit 1
fi
if ! cmp -s "${source_constraint}" "${target_constraint}"; then
    echo "${mode}: fpga/constraints/soc.xdc -> run_vivado/constraints/thinpad_top.xdc"
    differences=$((differences + 1))
    if [[ "${mode}" == "apply" ]]; then
        install -m 0644 "${source_constraint}" "${target_constraint}"
    fi
fi

source_sha="$(git -C "${individual_dir}" rev-parse HEAD)"
source_label="${source_sha}"
if [[ -n "$(git -C "${individual_dir}" status --short --untracked-files=no)" ]]; then
    source_label="${source_sha}-dirty"
fi
if ((differences == 0)); then
    echo "Official SoC sources match individual ${source_label}"
elif [[ "${mode}" == "check" ]]; then
    echo "Official SoC sources differ from individual ${source_label}: ${differences} file(s)" >&2
    exit 1
else
    echo "Applied individual ${source_label} to ${target_repo}: ${differences} file(s)"
    echo "Review and commit the official repository separately."
fi
