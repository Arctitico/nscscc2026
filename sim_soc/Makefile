# SoC 级功能仿真（Verilator）：thinpad_top（mycpu_top + mem_bridge）+ 行为级异步 SRAM。
# 验证多周期访存停顿 / 地址译码 / 同片「访存优先」仲裁。用法：
#   make        生成 test.hex（复用 ../sim/asm.py）、编译、运行自检
#   make lint   仅 lint 板级顶层
#   make uart   连续两字节 UART 物理帧/停止位自检
#   make sram-timing  SRAM 读/写/写后保持周期参数自检
#   make write-buffer  四项 FIFO/full-turnover/conflict 定向自检
#   make icache-selfmod  全清/在途 refill/同拍取指自修改定向自检
#   make selfmod  CPU 级 store→flush→重取、slot1 精确 kill、BTB 清空自检
#   make dcache-policy  word-only 冷启动/迟滞/probe/recovery 定向自检
#   make dcache-adaptive  word-only/probe/WB-wait D-cache 集成自检
#   make supervisor  启动当前 2026 auto kernel 并核对 UART 欢迎字符串
#   make level1      运行 52 字节/64 项 Fibonacci 第一阶段测试
#   make clean
SRC_DIR = ../src
SOC_DIR = ../soc
CPU_SRCS = $(SRC_DIR)/cpu_pkg.sv $(SRC_DIR)/tools.sv $(SRC_DIR)/alu.sv $(SRC_DIR)/mul.sv \
           $(SRC_DIR)/decoder.sv $(SRC_DIR)/regfile.sv $(SRC_DIR)/bpu.sv \
           $(SRC_DIR)/icache.sv $(SRC_DIR)/write_buffer.sv $(SRC_DIR)/dcache.sv \
           $(SRC_DIR)/IF.sv $(SRC_DIR)/ID.sv $(SRC_DIR)/DP.sv \
           $(SRC_DIR)/IS.sv $(SRC_DIR)/RF.sv $(SRC_DIR)/EX1.sv $(SRC_DIR)/EX2.sv \
           $(SRC_DIR)/CM.sv $(SRC_DIR)/mycpu_top.sv

SOC_SRCS = $(SOC_DIR)/sram_ctrl.sv $(SOC_DIR)/uart_phy.sv $(SOC_DIR)/uart_mm.sv \
           $(SOC_DIR)/mem_bridge.sv $(SOC_DIR)/thinpad_top.sv

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
UFLAGS = --binary --timing --top-module tb_uart -o Vtb_uart \
         -Wno-WIDTH -Wno-DECLFILENAME -Wno-UNUSED \
         -Wno-EOFNEWLINE -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD
TFLAGS = --binary --timing --top-module tb_sram_ctrl \
         -Wno-WIDTH -Wno-DECLFILENAME -Wno-UNUSED \
         -Wno-EOFNEWLINE -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD
WBFLAGS = --binary --timing --top-module tb_write_buffer -o Vtb_write_buffer \
          -Wno-WIDTH -Wno-DECLFILENAME -Wno-UNUSED \
          -Wno-EOFNEWLINE -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD
ICFLAGS = --binary --timing --top-module tb_icache_selfmod \
          -o Vtb_icache_selfmod -Wno-WIDTH -Wno-DECLFILENAME \
          -Wno-UNUSED -Wno-EOFNEWLINE -Wno-WIDTHEXPAND \
          -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD
SMFLAGS = --binary --timing --top-module tb_selfmod \
          -o Vtb_selfmod -Wno-WIDTH -Wno-DECLFILENAME \
          -Wno-UNUSED -Wno-VARHIDDEN -Wno-EOFNEWLINE \
          -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT \
          -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN \
          -Wno-PINMISSING
POLICYFLAGS = --binary --timing --top-module tb_dcache_policy \
              -o Vtb_dcache_policy -Wno-WIDTH -Wno-DECLFILENAME \
              -Wno-UNUSED -Wno-EOFNEWLINE -Wno-WIDTHEXPAND \
              -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD
ADAPTFLAGS = --binary --timing --top-module tb_dcache_adaptive \
             -o Vtb_dcache_adaptive -Wno-WIDTH -Wno-DECLFILENAME \
             -Wno-UNUSED -Wno-EOFNEWLINE -Wno-WIDTHEXPAND \
             -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD
PFLAGS = --binary --timing --top-module tb_perf -o Vtb_perf \
         -Wno-WIDTH -Wno-DECLFILENAME -Wno-UNUSED -Wno-VARHIDDEN \
         -Wno-EOFNEWLINE -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT \
         -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-PINMISSING
PERF_PROFILES = dcache_prefetch_profile.sv dcache_pc_trace.sv \
                issue_compaction_profile.sv late_bypass_profile.sv
DTRACE ?=

SUPERVISOR_BUILD ?= ../../nscscc-solo-la-soc/sdk/software/examples/supervisor/build
PERF_KERNEL       = perf_kernel.hex
PERF_STREAM       = perf_stream.hex
PERF_MATRIX_IN    = perf_matrix_input.hex
PERF_MATRIX_OUT   = perf_matrix_expected.hex
PERF_MIXED_OUT    = perf_mixed_expected.hex
PERF_CRYPTO_OUT   = perf_crypto_expected.hex

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

# ---- 正式直连 90 MHz 2/2/1 SRAM workload 性能画像 ----
perf-images:
	python3 bin2hex.py $(SUPERVISOR_BUILD)/kernel/auto/kernel.bin $(PERF_KERNEL)
	python3 bin2hex.py $(SUPERVISOR_BUILD)/utility/stream/stream_input.bin $(PERF_STREAM)
	python3 bin2hex.py $(SUPERVISOR_BUILD)/utility/matrix/matrix_input.bin $(PERF_MATRIX_IN)
	python3 bin2hex.py $(SUPERVISOR_BUILD)/utility/matrix/matrix_expected.bin $(PERF_MATRIX_OUT)
	python3 bin2hex.py $(SUPERVISOR_BUILD)/utility/mixed/mixed_signature.bin $(PERF_MIXED_OUT)
	python3 bin2hex.py $(SUPERVISOR_BUILD)/utility/crypto/crypto.bin $(PERF_CRYPTO_OUT)

perf-build:
	verilator $(PFLAGS) $(SRCS) tb_perf.sv $(PERF_PROFILES)

perf-simple: perf-images perf-build
	./obj_dir/Vtb_perf \
		+kernel_hex=$(PERF_KERNEL) \
		+expected_hex=$(PERF_KERNEL) +expected_start=0 +expected_words=0 \
		+entry=1c002000 +max_cycles=1000000 $(DTRACE)

perf-stream: perf-images perf-build
	./obj_dir/Vtb_perf \
		+kernel_hex=$(PERF_KERNEL) +base_extra_hex=$(PERF_STREAM) +base_extra_start=40000 \
		+expected_hex=$(PERF_STREAM) +expected_start=0 +expected_words=786432 \
		+entry=1c002008 +max_cycles=50000000 $(DTRACE)

perf-matrix: perf-images perf-build
	./obj_dir/Vtb_perf \
		+kernel_hex=$(PERF_KERNEL) +ext_hex=$(PERF_MATRIX_IN) \
		+expected_hex=$(PERF_MATRIX_OUT) +expected_start=8000 +expected_words=16384 \
		+entry=1c002030 +max_cycles=50000000 $(DTRACE)

perf-mixed: perf-images perf-build
	./obj_dir/Vtb_perf \
		+kernel_hex=$(PERF_KERNEL) \
		+expected_hex=$(PERF_MIXED_OUT) +expected_start=48000 +expected_words=5 \
		+entry=1c002184 +max_cycles=10000000 $(DTRACE)

perf-cryptonight: perf-images perf-build
	./obj_dir/Vtb_perf \
		+kernel_hex=$(PERF_KERNEL) \
		+expected_hex=$(PERF_CRYPTO_OUT) +expected_start=0 +expected_words=524288 \
		+entry=1c0020f0 +max_cycles=100000000 $(DTRACE)

perf-all: perf-simple perf-stream perf-matrix perf-mixed perf-cryptonight

level1:
	python3 level1.py
	verilator $(LFLAGS) $(SRCS) tb_level1.sv
	./obj_dir/Vtb_level1

uart:
	verilator $(UFLAGS) $(SOC_DIR)/uart_phy.sv tb_uart.sv
	./obj_dir/Vtb_uart

write-buffer:
	verilator $(WBFLAGS) $(SRC_DIR)/write_buffer.sv tb_write_buffer.sv
	./obj_dir/Vtb_write_buffer

icache-selfmod:
	verilator $(ICFLAGS) $(SRC_DIR)/icache.sv tb_icache_selfmod.sv
	./obj_dir/Vtb_icache_selfmod

selfmod:
	python3 selfmod.py
	verilator $(SMFLAGS) $(SRCS) tb_selfmod.sv
	./obj_dir/Vtb_selfmod

dcache-policy:
	verilator $(POLICYFLAGS) $(SRC_DIR)/write_buffer.sv \
		$(SRC_DIR)/dcache.sv tb_dcache_policy.sv
	./obj_dir/Vtb_dcache_policy

dcache-adaptive:
	verilator $(ADAPTFLAGS) $(SRC_DIR)/write_buffer.sv \
		$(SRC_DIR)/dcache.sv tb_dcache_adaptive.sv
	./obj_dir/Vtb_dcache_adaptive

sram-timing:
	verilator $(TFLAGS) -o Vtb_sram_ctrl_111 \
		-GREAD_CYCLES=1 -GWRITE_CYCLES=1 -GWRITE_HOLD_CYCLES=1 \
		$(SOC_DIR)/sram_ctrl.sv tb_sram_ctrl.sv
	./obj_dir/Vtb_sram_ctrl_111
	verilator $(TFLAGS) -o Vtb_sram_ctrl_221 \
		-GREAD_CYCLES=2 -GWRITE_CYCLES=2 -GWRITE_HOLD_CYCLES=1 \
		$(SOC_DIR)/sram_ctrl.sv tb_sram_ctrl.sv
	./obj_dir/Vtb_sram_ctrl_221
	verilator $(TFLAGS) -o Vtb_sram_ctrl_331 \
		-GREAD_CYCLES=3 -GWRITE_CYCLES=3 -GWRITE_HOLD_CYCLES=1 \
		$(SOC_DIR)/sram_ctrl.sv tb_sram_ctrl.sv
	./obj_dir/Vtb_sram_ctrl_331

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

lint:
	verilator --lint-only --top-module thinpad_top -GSIMULATION=1 \
		-Wno-WIDTHTRUNC -Wno-WIDTHEXPAND $(SRCS)

clean:
	rm -rf obj_dir test.hex selfmod.hex level1.hex kernel.hex golden_trace.hex golden_mem.hex golden.meta
