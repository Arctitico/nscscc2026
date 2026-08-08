# mycpu_top 功能仿真（Verilator）。用法：
#   make        生成 test.hex、编译、运行自检
#   make clean
SRC_DIR = ../src
SRCS = $(SRC_DIR)/cpu_pkg.sv $(SRC_DIR)/tools.sv $(SRC_DIR)/alu.sv $(SRC_DIR)/mul.sv \
       $(SRC_DIR)/decoder.sv $(SRC_DIR)/regfile.sv \
       $(SRC_DIR)/bpu.sv $(SRC_DIR)/icache.sv $(SRC_DIR)/write_buffer.sv $(SRC_DIR)/dcache.sv \
       $(SRC_DIR)/IF.sv $(SRC_DIR)/ID.sv $(SRC_DIR)/DP.sv \
       $(SRC_DIR)/IS.sv $(SRC_DIR)/RF.sv $(SRC_DIR)/EX1.sv $(SRC_DIR)/EX2.sv \
       $(SRC_DIR)/CM.sv $(SRC_DIR)/mycpu_top.sv

.PHONY: run lint rand fuzz p1-regress full-int mul-pipe late-bypass waw-raw \
        intra-raw control-flow clean

VFLAGS = --binary --timing --top-module tb -o Vtb \
         -Wno-WIDTH -Wno-DECLFILENAME -Wno-UNUSED -Wno-VARHIDDEN \
         -Wno-EOFNEWLINE -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC

# 始终从 asm.py 重新生成 test.hex (避免与 make rand 写的随机 test.hex 混淆)
run:
	python3 asm.py 2>/dev/null
	verilator $(VFLAGS) $(SRCS) tb.sv
	./obj_dir/Vtb

lint:
	verilator --lint-only --top-module mycpu_top -Wno-WIDTHEXPAND $(SRCS)

# ---- 随机指令 DiffTest ----
# 用法: make rand            (默认 SEED=1)
#       make rand SEED=42 N=200
#       make fuzz            (循环 SEED=1..COUNT, 首个失败即停)
#       make p1-regress      (FIFO 定向用例 + 高反压/分支随机 DiffTest)
#       make mul-pipe        (连续 MUL II=1 + RAW/前递定向验证)
#       make late-bypass     (load->store-data 晚旁路及地址依赖互锁)
#       make waw-raw         (年轻 ready WAW 覆盖老 pending producer)
#       make intra-raw       (专用 SLL->ADD/XOR bundle 内 RAW 契约)
#       make control-flow    (bl/jirl/r0/反向循环)
#       make full-int        (全部新增非除法整数指令及边界值)
SEED  ?= 1
N     ?= 120
MR    ?= 0.30
BR    ?= 0.0
WINDOW ?= 64
INIT_MODE ?= random
GENFLAGS = --mem-ratio $(MR) --branch-ratio $(BR) --window $(WINDOW) \
           --init-mode $(INIT_MODE)
RFLAGS = --binary --timing --top-module tb_rand -o Vtb_rand \
         -Wno-WIDTH -Wno-DECLFILENAME -Wno-UNUSED -Wno-VARHIDDEN \
         -Wno-EOFNEWLINE -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC

rand:
	python3 randgen.py --seed $(SEED) --n $(N) $(GENFLAGS) --quiet
	verilator $(RFLAGS) $(SRCS) tb_rand.sv
	./obj_dir/Vtb_rand

mul-pipe:
	python3 fifo_regress.py --case mul_pipe >/dev/null
	verilator $(RFLAGS) $(SRCS) tb_rand.sv
	./obj_dir/Vtb_rand +CHECK_MUL_PIPE

late-bypass:
	python3 fifo_regress.py --case late_bypass >/dev/null
	verilator $(RFLAGS) $(SRCS) tb_rand.sv
	./obj_dir/Vtb_rand +CHECK_LATE_BYPASS

waw-raw:
	python3 fifo_regress.py --case waw_raw_load >/dev/null
	verilator $(RFLAGS) $(SRCS) tb_rand.sv
	./obj_dir/Vtb_rand +CHECK_WAW_RAW +EXPECT_WAW_LOAD
	python3 fifo_regress.py --case waw_raw_mul >/dev/null
	./obj_dir/Vtb_rand +CHECK_WAW_RAW +EXPECT_WAW_MUL

intra-raw:
	python3 fifo_regress.py --case intra_raw >/dev/null
	verilator $(RFLAGS) $(SRCS) tb_rand.sv
	./obj_dir/Vtb_rand +CHECK_INTRA_RAW +SLOW_DATA_RESPONSE $(INTRA_ARGS)

control-flow:
	python3 fifo_regress.py --case control_flow >/dev/null
	verilator $(RFLAGS) $(SRCS) tb_rand.sv
	./obj_dir/Vtb_rand

full-int:
	python3 fifo_regress.py --case full_int >/dev/null
	verilator $(RFLAGS) $(SRCS) tb_rand.sv
	./obj_dir/Vtb_rand

# 编译一次，循环换 seed 重新生成激励并跑。共享 runner 会逐轮删除旧向量、
# 检查生成器/模拟器退出码、PASS marker 以及 random.meta 的 seed/参数。
COUNT ?= 50
START_SEED ?= 1
fuzz:
	verilator $(RFLAGS) $(SRCS) tb_rand.sv
	python3 fuzz.py \
	    --generator ./randgen.py --simulator ./obj_dir/Vtb_rand \
	    --pass-marker "RAND TEST PASSED" \
	    --start-seed $(START_SEED) --count $(COUNT) --n $(N) \
	    --window $(WINDOW) --mem-ratio $(MR) --branch-ratio $(BR) \
	    --init-mode $(INIT_MODE)

P1_COUNT ?= 20
P1_N     ?= 300
P1_CASES  = compact conflicts redirect pressure full_int
p1-regress:
	verilator $(RFLAGS) $(SRCS) tb_rand.sv
	@set -e; \
	for c in $(P1_CASES); do \
	    python3 fifo_regress.py --case $$c >/dev/null; \
	    out=$$(./obj_dir/Vtb_rand); \
	    if printf '%s\n' "$$out" | grep -q "RAND TEST PASSED"; then \
	        echo "directed $$c: PASS"; \
	    else \
	        echo "directed $$c: FAIL"; printf '%s\n' "$$out"; \
	        echo "==> 复现: python3 fifo_regress.py --case $$c && ./obj_dir/Vtb_rand"; exit 1; \
	    fi; \
	done
	python3 fuzz.py \
	    --generator ./randgen.py --simulator ./obj_dir/Vtb_rand \
	    --pass-marker "RAND TEST PASSED" \
	    --start-seed 1 --count $(P1_COUNT) --n $(P1_N) \
	    --window $(WINDOW) --mem-ratio 0.55 --branch-ratio 0.12 \
	    --init-mode $(INIT_MODE)
	@echo "==== FIFO P1 REGRESSION PASSED: $(words $(P1_CASES)) directed + $(P1_COUNT) random ===="

clean:
	rm -rf obj_dir test.hex initial_mem.hex golden_trace.hex golden_mem.hex \
	    golden.meta random.meta
