# 2026 LoongArch 个人赛 CPU

当前分支 `inorder-dual-issue` 是九级顺序双发主开发线。CPU、板级 SoC、引脚约束和 Vivado 构建流程都由本仓管理；最终实现使用 CPU 私有类 SRAM 口直连 BaseRAM、ExtRAM 和 UART，不再经过 AXI 或官方参考 SoC。

## 目录

- `src/`：CPU 主源码，包含九级顺序双发、I-cache、D-cache 和 write buffer。
- `soc/`：2026 板级顶层、PLL、Base/Ext SRAM 控制器和仓内 UART。
- `fpga/`：Vivado 工程创建/构建 Tcl 与 2026 板卡引脚、时序约束。
- `sim/`：CPU 核定向测试与随机 DiffTest。
- `sim_soc/`：直连 SoC 定向/随机、一级功能和 supervisor 启动测试。
- `build_fpga.sh`：从本仓源码独立生成并签核 bitstream。

## 当前能力

- 复位 PC：`0x1c000000`。
- 普通指令：supervisor、STREAM、MATRIX、CryptoNight、MIXED 所需完整子集。
- 对齐 8B 双取指、顺序双发射、4 读 2 写寄存器堆和最多双提交；每拍最多一个访存、一个乘法和一个分支，并支持安全的 MU+ME/MU+B/ME+B 共发。
- `cpucfg`：采用架构无 Cache 路线，`CPUCFG[0x10]` 报告 I/D Cache 均不存在；内部 Cache 对软件透明。
- 2 路、16B line 的 I-cache 和 4 KiB D-cache；D-cache 为 write-through/no-write-allocate，带两项 write buffer。
- 取指为四字突发类 SRAM 通道；数据为分离读写请求/完成通道。`mem_bridge` 直接仲裁两片物理 SRAM。
- SRAM 读访问、写脉冲和写后保持均可独立配置；构建脚本按实际 CPU 频率把纳秒要求向上取整为控制器周期。默认采用 `20 ns / 20 ns / 1 拍`：写后保持固定为一个完整 CPU 周期。
- PLL 未锁定和 CPU 复位期间，顶层强制撤销两片 SRAM 的片选/读写使能与数据驱动，避免与 BaseRAM 下载控制器争用。
- UART 为 115200/8N1，`TX_READY` 只在完整停止位发送完毕后置位。
- 内部 `debug0/debug1_wb_*` 提供双提交信息，包括原始指令。

尚未实现架构可见 Cache、CSR/DMW/cacop。官方参考 SoC 的 AXI 包装文件仍留作历史兼容，但 `fpga/create_project.tcl` 不会把它们加入最终工程。

## 独立 Vivado 构建

从仓库根目录直接运行：

```bash
./build_fpga.sh --freq 50 --recreate-project
./build_fpga.sh --freq 90 --print-config
./build_fpga.sh --freq 90
```

脚本以 50 MHz 板载时钟为输入，自动选择合法的 Artix-7 PLL 整数参数，将实际频率同时传给 UART 分频，并把 SRAM 的纳秒要求换算为实际频率下的整数拍数。默认读访问和写脉冲均为 `20 ns`，写后保持固定 `1` 拍；可用 `--sram-read-ns`、`--sram-write-pulse-ns` 和 `--sram-write-hold-cycles` 覆盖。若需要按时间而不是拍数配置保持窗口，也可用 `--sram-write-hold-ns`。纳秒换算均向上取整，绝不会缩短请求的物理时间；`--print-config` 只显示 PLL、拍数和实际时间，不启动 Vivado。

例如 90 MHz 下显式指定当前上板候选配置：

```bash
./build_fpga.sh --freq 90 \
  --sram-read-ns 20 \
  --sram-write-pulse-ns 20 \
  --sram-write-hold-cycles 1
```

这会生成 `2/2/1` 拍，实际约 `22.22/22.22/11.11 ns`。构建结果还会把请求值、换算拍数和实际纳秒数写入 `build_summary.txt`，并归档 bit、SHA-256、clock/check_timing、setup/hold 和资源报告。工程位于 `fpga/project/`，结果位于 `output/`；两者均不提交 Git。

首个直连候选 `output/fpga_50mhz_20260724_121743/` 网站实测无法启动 monitor。修复后的 50 MHz 候选位于 `output/fpga_50mhz_20260724_123734/`：WNS `+1.808 ns`、TNS `0`、WHS `+0.037 ns`，0 个 setup 失败端点、no-clock pin 和 unconstrained internal endpoint；资源为 8175 LUT、4209 Register、6 RAMB18、3 DSP。该候选已完成网站六项签核：Level1/Level3 通过，MATRIX/STREAM/CryptoNight/MIXED 为 `200/130/922/9 ms`，全部 100 分。

当前高频上板候选为 `output/fpga_90mhz_20_20_1_board_20260724/`：目标/PLL 实际频率 `90 MHz`，SRAM 为 `2/2/1` 拍，WNS `+0.194 ns`、TNS `0`、WHS `+0.055 ns`，0 个 setup 失败端点、no-clock pin 和 unconstrained internal endpoint。92.5 MHz 虽以 WNS/WHS `+0.010/+0.010 ns` 勉强通过，95 MHz 已失败，因此当前 STA 边界在 `92.5–95 MHz`，推荐先用 90 MHz 候选完成板上 A/B。

## 本仓回归

```bash
cd sim
make
make rand SEED=42 N=300
make fuzz COUNT=50 N=200
make lint

cd ../sim_soc
make
make uart
make sram-timing
make level1
make supervisor
make rand SEED=42 N=300
make fuzz COUNT=30 N=200
make lint
```

`make clean` 只清理生成的 hex/meta 和 `obj_dir/`。
