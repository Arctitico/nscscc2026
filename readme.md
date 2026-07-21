# 2026 LoongArch 个人赛 baseline

当前 `main` 是顺序单发射 baseline；顺序双发射演进保存在 `dual-issue-wip` 分支。

## 目录

- `src/`：九级顺序单发射 CPU，内部含分支预测和透明 I-cache。
- `soc/`：ThinPAD 物理顶层、BaseRAM/ExtRAM 桥和最小 16550 UART。
- `sim/`：CPU 核定向测试与随机 DiffTest。
- `sim_soc/`：SoC 定向/随机回归、第一阶段测试和 supervisor 启动测试。

## 当前 baseline 能力

- 复位 PC：`0x1c000000`。
- BaseRAM：`0x1c000000–0x1c3fffff`；ExtRAM：`0x1c400000–0x1c7fffff`。
- UART：`0x1f000000` 数据、`0x1f000005` 状态，115200/8N1。
- 普通指令：当前 supervisor 与 STREAM/MATRIX/CRYPTONIGHT/MIXED 所需完整子集。
- `cpucfg`：无 Cache 路线，`CPUCFG[0x10]` 报告 I/D Cache 均不存在。
- 尚未实现：AXI 顶层、架构可见 Cache 路线的 CSR/DMW/cacop、完整 A/D/G/R 自动回归。

## 回归

```bash
cd sim
make                         # 定向指令/前递/分支/访存
make rand SEED=42 N=300      # 单个随机种子
make fuzz COUNT=50 N=200     # 多种子 DiffTest
make lint

cd ../sim_soc
make                         # 多周期 SRAM + 新地址空间
make level1                  # 52 字节程序、64 项 Fibonacci
make supervisor              # auto kernel + CPUCFG + 115200 UART 欢迎词
make rand SEED=42 N=300
make fuzz COUNT=30 N=200
make lint
```

`make supervisor` 默认使用 `../../bin/kernel_07161555.bin`；可通过 `KERNEL_BIN=...` 指定其它兼容镜像。加 `+trace_boot` 需要手动运行生成的仿真程序，用于打印启动取指和提交流。

生成物包括 `test.hex`、`level1.hex`、`kernel.hex`、`golden_trace.hex`、`golden_mem.hex` 和 `obj_dir/`，`make clean` 会清理。
