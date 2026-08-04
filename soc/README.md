# 2026 直连类 SRAM SoC 指南

本目录是正式 2026 板级实现。`mycpu_top` 的私有取指/数据通道直接连接到 ThinPAD 两片异步 SRAM 和 UART，不经过 AXI，也没有 CPU/SoC 跨时钟桥。

## 模块关系

```text
thinpad_top
├── board_clock     50 MHz 输入到参数化 CPU PLL
├── mycpu_top       九级顺序双发射 CPU
└── mem_bridge      地址译码与 Base/Ext 仲裁
    ├── sram_ctrl   BaseRAM 多周期控制器
    ├── sram_ctrl   ExtRAM 多周期控制器
    └── uart_mm     115200/8N1 最小 16550 UART
        └── uart_phy 仓内收发器
```

`thinpad_top.sv` 是唯一的 2026 物理引脚边界，也是官方模板要求名称的
顶层模块。它直接负责 PLL/复位、CPU/桥连接、SRAM `inout` 三态和未使用
外设禁用，不再在官方仓外包一层参考 wrapper。`SIMULATION=1` 时同一模块
旁路 PLL，SoC testbench 因而也直接覆盖正式板级顶层。

## 地址空间

| 物理地址范围 | 设备 |
| --- | --- |
| `0x1c000000–0x1c3fffff` | 4 MiB BaseRAM |
| `0x1c400000–0x1c7fffff` | 4 MiB ExtRAM |
| `0x1f000000–0x1f0fffff` | UART 窗口 |

CPU 复位后从 `0x1c000000` 取指。`mem_bridge.sv` 检查完整高地址位，RAM 片内字地址为 `addr[21:2]`。BaseRAM 和 ExtRAM 各有独立控制器，可以并行；同片同时出现数据访问和取指重填时，较老的数据访问优先，已经开始的取指突发不会被中断。

不要恢复往届的 `0x80000000/0x80400000/0xBFD003F8` 映射。

## CPU 侧握手

取指使用整行突发读：

```text
inst_rd_req + inst_rd_addr
    -> inst_rd_rdy
    -> inst_ret_valid + inst_ret_data + inst_ret_last
```

数据访问使用分离的单请求保持协议：

```text
data_rd_req/addr -> data_rd_ok + data_rd_data
data_wr_req/addr/strb/data -> data_wr_ok
```

`sram_ctrl.sv` 把请求转换为异步 SRAM 的 `CE/OE/WE/BE` 多周期时序。写结束、`WE#` 上升后，`ram_wdrive[3:0]` 按有效字节车道继续保持一个完整 CPU 周期；地址、字节使能和写数据在该周期内也不更新。物理数据线三态在 `thinpad_top` 按 8 bit 车道处理。读完成在控制器的同一寄存边界拆成取指/数据两类返回，避免 `tag_out` 再进入跨模块长组合链。

EX1 另输出只依赖本级寄存 payload 的 `store_pending` 窄令牌。D-cache 用它在 store 真正发出前阻止新的 I-cache miss 越过，不把 `EX2_allow_in` 或 `data_addr_ok` 串入取指到 SRAM 引脚的控制链；数据请求握手和访问拍数不变。

正式板级构建固定为读 2 拍、写 2 拍、写后保持 1 拍。
`build_fpga.sh` 不再按纳秒换算，也不接受其它 SRAM 构建配置；120 MHz
下等效窗口为 `16.6667/16.6667/8.3333 ns`。RTL 参数仍保留，供
`sim_soc` 的协议边界回归覆盖其它拍数组合。

协议状态机使用同步复位，只有直接连接 SRAM 的地址、控制、写数据和三态使能寄存器使用异步复位。PLL 未锁定或 CPU reset 有效时，物理 `CE#`、`OE#`、`WE#` 与数据驱动必须立即撤销；不要重新在顶层加入高扇出的组合 reset 门控。

## UART

直连串口固定为 115200 baud、8N1，分频参数随 `CPU_CLK_HZ` 自动变化：

| 地址 | 含义 |
| --- | --- |
| `0x1f000000` | `UART_DATA`，写低字节发送，读低字节接收 |
| `0x1f000005` | `UART_STATUS`，bit0=`RX_READY`，bit5=`TX_READY` |

`uart_mm.sv` 还接受 supervisor 初始化使用的 `+1/+2/+3/+4` 写入，并用 LCR bit7 跟踪 DLAB，避免写 DLL 时误发串口字符。由于 CPU 用 `ld.b` 读取 `+5`，状态字节会放在返回总线的 byte lane 1，再由 WB 按地址低位选出。

当前 baseline 通过 `CPUCFG[0x10]=0` 留在直接地址模式，因此 UART 直接访问物理地址。若未来启用 Cache/DMW，软件将通过 `0xbf000000/0xbf000005` uncached 别名访问，CPU 地址转换后仍应向本桥发出 `0x1f...` 物理地址。

## 验证

```bash
cd ../sim_soc
make             # 定向指令 + 多周期 SRAM
make rand         # SoC 随机 DiffTest
make level1       # 第一阶段 52 字节 Fibonacci
make supervisor   # auto kernel 启动并核对 UART 欢迎词
make lint
```

行为 SRAM testbench 的写入必须受复位门控。否则 Verilator 2-state 初值会在第一个时钟沿把 BaseRAM 第 0 字误写为 0，表现为 CPU 丢失复位入口第一条指令。

## Vivado

```bash
cd ..
./build_fpga.sh --freq 120 --print-config
./build_fpga.sh --freq 120 --recreate-project
```

`fpga/create_project.tcl` 以官方 CI 相同的 `xc7a200tfbg676-2` 为目标，只收集当前 CPU 与直连 SoC 所需模块，不加入 `core_top.sv` 或 `cpu_axi_bridge.sv`。`board_clock.sv` 直接例化 `PLLE2_ADV`，因此也不依赖外部 XCI/DCP。引脚、PLL 生成时钟和 SRAM I/O delay 均由仓内 `fpga/constraints/soc.xdc` 约束。

当前正式板级基线为 120 MHz、PLL `24/1/10`、SRAM `2/2/1`。Linux CI
与本地 fresh route 的 WNS/TNS/WHS 均为
`+0.035/0/+0.048 ns`，Pipeline `#16764` 的同一 CI 位流已通过真板
Level1、Level3 和四项性能；35 ps setup 余量不能外推到修改后的新快照。
