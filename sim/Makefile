# mycpu_top 功能仿真（Verilator）。用法：
#   make        生成 test.hex、编译、运行自检
#   make clean
SRC_DIR = ../src
SRCS = $(SRC_DIR)/cpu_pkg.sv $(SRC_DIR)/tools.sv $(SRC_DIR)/alu.sv $(SRC_DIR)/mul.sv \
       $(SRC_DIR)/decoder.sv $(SRC_DIR)/regfile.sv \
       $(SRC_DIR)/bpu.sv $(SRC_DIR)/icache.sv \
       $(SRC_DIR)/IF.sv $(SRC_DIR)/ID.sv $(SRC_DIR)/RR.sv $(SRC_DIR)/DP.sv \
       $(SRC_DIR)/IS.sv $(SRC_DIR)/RF.sv $(SRC_DIR)/EX.sv $(SRC_DIR)/WB.sv \
       $(SRC_DIR)/CM.sv $(SRC_DIR)/mycpu_top.sv

VFLAGS = --binary --timing --top-module tb -o Vtb \
         -Wno-WIDTH -Wno-DECLFILENAME -Wno-UNUSED -Wno-VARHIDDEN \
         -Wno-EOFNEWLINE -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC

# 始终从 asm.py 重新生成 test.hex (避免与 make rand 写的随机 test.hex 混淆)
run:
	python3 asm.py 2>/dev/null
	verilator $(VFLAGS) $(SRCS) tb.sv
	./obj_dir/Vtb

lint:
	verilator --lint-only --top-module mycpu_top $(SRCS)

# ---- 随机指令 DiffTest ----
# 用法: make rand            (默认 SEED=1)
#       make rand SEED=42 N=200
#       make fuzz            (循环 SEED=1..COUNT, 首个失败即停)
SEED  ?= 1
N     ?= 120
RFLAGS = --binary --timing --top-module tb_rand -o Vtb_rand \
         -Wno-WIDTH -Wno-DECLFILENAME -Wno-UNUSED -Wno-VARHIDDEN \
         -Wno-EOFNEWLINE -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC

rand:
	python3 randgen.py --seed $(SEED) --n $(N) 2>/dev/null
	verilator $(RFLAGS) $(SRCS) tb_rand.sv
	./obj_dir/Vtb_rand

# 编译一次, 循环换 seed 重新生成激励并跑 (COUNT 个种子)
COUNT ?= 50
fuzz:
	verilator $(RFLAGS) $(SRCS) tb_rand.sv
	@for s in $$(seq 1 $(COUNT)); do \
	    python3 randgen.py --seed $$s --n $(N) 2>/dev/null; \
	    out=$$(./obj_dir/Vtb_rand); \
	    if echo "$$out" | grep -q "RAND TEST PASSED"; then \
	        echo "seed $$s: PASS"; \
	    else \
	        echo "seed $$s: FAIL"; echo "$$out"; \
	        echo "==> 复现: make rand SEED=$$s N=$(N)"; exit 1; \
	    fi; \
	done; \
	echo "==== ALL $(COUNT) SEEDS PASSED ===="

clean:
	rm -rf obj_dir test.hex golden_trace.hex golden_mem.hex golden.meta
