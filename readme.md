# 2026 LoongArch 个人赛 CPU

当前 `main` 工作区是九级顺序双发射实现，改动尚未 Git commit；旧的实验版本仍保存在 `dual-issue-wip` 分支，但后续开发以已经对齐 2026 标准的 `main` 为准。当前实现已接入官方 `nscscc-solo-la-soc` AXI 模板，通过完整 Verilator supervisor 套件、XSIM SIMPLE、100 MHz Vivado 时序签核和网站四项性能测试。

## 目录

- `src/`：CPU 唯一主源码，包含九级顺序双发射核心、I-cache、`core_top` 和 AXI bridge。
- `soc/`：旧 ThinPAD 物理 SRAM/UART 外壳，保留用于兼容回归，不再是最终推荐集成目标。
- `sim/`：CPU 核定向测试与随机 DiffTest。
- `sim_soc/`：旧 SoC 定向/随机、一级功能和旧 supervisor 启动测试。
- `scripts/sync_official_soc.sh`：把 `src/` 同步到官方模板的 `rtl/ip/myCPU/`。

## 当前能力

- 复位 PC：`0x1c000000`。
- 普通指令：官方 supervisor、STREAM、MATRIX、CryptoNight、MIXED 所需完整子集。
- 对齐 8B 双取指、保守双发射、4 读 2 写寄存器堆和最多双提交；每拍最多一个访存，乘法独占发射。
- `cpucfg`：采用架构无 Cache 路线，`CPUCFG[0x10]` 报告 I/D Cache 均不存在。
- 内部透明 2 路 I-cache，16B cache line；数据口写入相同指令行时自动失效，支持 monitor 下载代码后执行。
- 官方 `core_top` 32 位 AXI master：I-cache 四拍 burst、load 单拍读、store 独立 AW/W 握手并等待 B 响应。
- 内部 `debug0/debug1_wb_*` 双提交信息，包括原始指令；官方 `core_top` 合同只导出 `debug0`。

尚未实现架构可见 Cache 路线的 D-cache、CSR/DMW/cacop。100 MHz bitstream 已生成并跑网站四项性能测试；当前已知 CryptoNight 为 1510 ms，其余三项相对单发射变化小于 1 ms。

## 官方模板集成

`individual/src/` 是唯一需要手工修改的 CPU 源码。修改后执行：

```bash
cd nscscc2026/individual
./scripts/sync_official_soc.sh

cd ../nscscc-solo-la-soc
git submodule update --init --recursive
python3 sim/run.py sdk/software/examples/supervisor/sim/suite.json --prepare
```

同步时 `cpu_pkg.sv` 会复制为 `00_cpu_pkg.sv`，确保官方按文件名排序收集源码时，类型定义先于使用它的模块。官方模板是独立嵌套 Git 仓库；不要在模板副本里单独修改 CPU，否则下一次同步会覆盖改动。

当前官方套件已验证：

- SIMPLE 启动和执行；
- STREAM 3 MiB 结果比对；
- MATRIX 64 KiB 结果比对；
- MIXED 20B signature；
- CryptoNight 2 MiB 结果比对；
- Fibonacci `A/D/G/R/D` UART 闭环。

## 本仓回归

```bash
cd sim
make
make rand SEED=42 N=300
make fuzz COUNT=50 N=200
make lint

cd ../sim_soc
make
make level1
make supervisor
make rand SEED=42 N=300
make fuzz COUNT=30 N=200
make lint
```

`make clean` 只清理生成的 hex/meta 和 `obj_dir/`。
