# SoC 级功能仿真（Verilator）：thinpad_top（mycpu_top + mem_bridge）+ 行为级异步 SRAM。
# 验证多周期访存停顿 / 地址译码 / 同片「访存优先」仲裁。用法：
#   make        生成 test.hex（复用 ../sim/asm.py）、编译、运行自检
#   make lint   仅 lint 板级顶层
#   make supervisor  启动当前 2026 auto kernel 并核对 UART 欢迎字符串
#   make level1      运行 52 字节/64 项 Fibonacci 第一阶段测试
#   make clean
SRC_DIR = ../src
SOC_DIR = ../soc
ASYNC   = ../../../nscscc2025/2025_nscscc_个人赛模版工程_la32r/thinpad_top.srcs/sources_1/new/async.v

CPU_SRCS = $(SRC_DIR)/cpu_pkg.sv $(SRC_DIR)/tools.sv $(SRC_DIR)/alu.sv $(SRC_DIR)/mul.sv \
           $(SRC_DIR)/decoder.sv $(SRC_DIR)/regfile.sv $(SRC_DIR)/preg_free_list.sv $(SRC_DIR)/bpu.sv \
           $(SRC_DIR)/icache.sv $(SRC_DIR)/write_buffer.sv $(SRC_DIR)/dcache.sv \
           $(SRC_DIR)/IF.sv $(SRC_DIR)/ID.sv $(SRC_DIR)/RR.sv $(SRC_DIR)/DP.sv \
           $(SRC_DIR)/IS.sv $(SRC_DIR)/RF.sv $(SRC_DIR)/EX.sv $(SRC_DIR)/WB.sv \
           $(SRC_DIR)/CM.sv $(SRC_DIR)/mycpu_top.sv

SOC_SRCS = $(SOC_DIR)/sram_ctrl.sv $(SOC_DIR)/uart_mm.sv $(SOC_DIR)/mem_bridge.sv \
           $(SOC_DIR)/thinpad_top.sv $(ASYNC)

SRCS = $(CPU_SRCS) $(SOC_SRCS)

VFLAGS = --binary --timing --top-module tb_soc -o Vtb_soc \
         -Wno-WIDTH -Wno-DECLFILENAME -Wno-UNUSED -Wno-VARHIDDEN \
         -Wno-EOFNEWLINE -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT \
         -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-PINMISSING

# 始终从 asm.py 重新生成 (避免与 make rand 写的随机 test.hex 混淆)
run:
	python3 ../sim/asm.py 2>/dev/null
	verilator $(VFLAGS) $(SRCS) tb_soc.sv
	./obj_dir/Vtb_soc

# ---- 随机指令 DiffTest (复用 ../sim/randgen.py) ----
# 用法: make rand SEED=42 N=120 ; make fuzz COUNT=30
SEED  ?= 1
N     ?= 120
COUNT ?= 30
MR    ?= 0.30
BR    ?= 0.0
GENFLAGS = --mem-ratio $(MR) --branch-ratio $(BR)
RFLAGS = --binary --timing --top-module tb_soc_rand -o Vtb_soc_rand \
         -Wno-WIDTH -Wno-DECLFILENAME -Wno-UNUSED -Wno-VARHIDDEN \
         -Wno-EOFNEWLINE -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT \
         -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-PINMISSING
SFLAGS = --binary --timing --top-module tb_supervisor -o Vtb_supervisor \
         -Wno-WIDTH -Wno-DECLFILENAME -Wno-UNUSED -Wno-VARHIDDEN \
         -Wno-EOFNEWLINE -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT \
         -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-PINMISSING
LFLAGS = --binary --timing --top-module tb_level1 -o Vtb_level1 \
         -Wno-WIDTH -Wno-DECLFILENAME -Wno-UNUSED -Wno-VARHIDDEN \
         -Wno-EOFNEWLINE -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT \
         -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-PINMISSING

rand:
	python3 ../sim/randgen.py --seed $(SEED) --n $(N) $(GENFLAGS) 2>/dev/null
	verilator $(RFLAGS) $(SRCS) tb_soc_rand.sv
	./obj_dir/Vtb_soc_rand

# ---- 2026 supervisor 启动 + UART 回归 ----
KERNEL_BIN ?= ../../bin/kernel_07161555.bin
supervisor:
	python3 bin2hex.py $(KERNEL_BIN) kernel.hex
	verilator $(SFLAGS) $(SRCS) tb_supervisor.sv
	./obj_dir/Vtb_supervisor

level1:
	python3 level1.py
	verilator $(LFLAGS) $(SRCS) tb_level1.sv
	./obj_dir/Vtb_level1

fuzz:
	verilator $(RFLAGS) $(SRCS) tb_soc_rand.sv
	@for s in $$(seq 1 $(COUNT)); do \
	    python3 ../sim/randgen.py --seed $$s --n $(N) $(GENFLAGS) 2>/dev/null; \
	    out=$$(./obj_dir/Vtb_soc_rand); \
	    if echo "$$out" | grep -q "SOC RAND TEST PASSED"; then \
	        echo "seed $$s: PASS"; \
	    else \
	        echo "seed $$s: FAIL"; echo "$$out"; \
	        echo "==> 复现: make rand SEED=$$s N=$(N)"; exit 1; \
	    fi; \
	done; \
	echo "==== ALL $(COUNT) SEEDS PASSED ===="

# -Wno-WIDTH* 仅为屏蔽第三方 async.v(官方 UART PHY) 的良性位宽告警；本仓 soc/*.sv 全干净
lint:
	verilator --lint-only --top-module thinpad_top -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND $(SRCS)

clean:
	rm -rf obj_dir test.hex level1.hex kernel.hex golden_trace.hex golden_mem.hex golden.meta
