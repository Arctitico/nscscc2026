## src
源码

## soc
源码

## sim 和 sim_soc

本地 Verilator 功能仿真。

```shell
cd sim                      # 或 cd sim_soc，两套命令一致
make rand                   # 默认 SEED=1 N=120，跑一个随机程序
make rand SEED=42 N=200     # 指定种子/指令条数
make fuzz                   # 循环 SEED=1..COUNT，首个失败即停并打印复现命令
make fuzz COUNT=50 N=150    # 跑 50 个种子，每个 150 条随机指令
```

失败时会打印第一处不一致：

```
  FAIL commit #99
    DUT   : pc=800001c0 r1 <= 00000d28
    GOLDEN: pc=800001c0 r1 <= 01000d28
```

生成物：`test.hex`（指令）、`golden_trace.hex`（每行 `pc wnum wdata`，期望提交流）、
`golden_mem.hex`（scratch 区最终镜像）、`golden.meta`（提交条数/内存字数）。`make clean` 一并清掉。