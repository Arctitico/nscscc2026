#!/usr/bin/env python3
# 2026 LA32R baseline 极简汇编器，两遍汇编解析标号。
# 输出 test.hex（每行一个 32 位指令，hex），程序装载基址 0x1c000000。
import sys

BASE = 0x1C000000

# 程序：助记符 + 操作数。寄存器用整数；标号用字符串。
# 覆盖：算术/逻辑/移位/立即数/访存(字+字节)/分支/调用返回/前递/load-use。
PROG = [
    ("start",   "addi.w", 4, 0, 0),         # r4 = 0  (sum)
    (None,      "addi.w", 2, 0, 10),        # r2 = 10 (i)
    ("loop",    "add.w",  4, 4, 2),         # sum += i
    (None,      "addi.w", 2, 2, -1),        # i--
    (None,      "bne",    2, 0, "loop"),    # while i!=0  -> r4=55, r2=0
    (None,      "lu12i.w",20, 0x1C400),     # r20 = 0x1c400000 (ExtRAM)
    (None,      "st.w",   4, 20, 0),        # mem[base] = 55
    (None,      "ld.w",   3, 20, 0),        # r3 = 55
    (None,      "add.w",  5, 3, 3),         # r5 = 110  (load-use)
    (None,      "addi.w", 6, 0, 0x1ff),     # r6 = 0x1ff
    (None,      "st.b",   6, 20, 4),        # mem.b[base+4] = 0xff
    (None,      "ld.b",   7, 20, 4),        # r7 = sext(0xff) = 0xffffffff
    (None,      "add.w",  8, 7, 3),         # r8 = -1 + 55 = 54  (load-use)
    (None,      "lu12i.w",9, 0xABCDE),      # r9 = 0xABCDE000
    (None,      "ori",    9, 9, 0xF01),     # r9 = 0xABCDEF01    (EX 前递)
    (None,      "andi",   10, 9, 0xFFF),    # r10 = 0xF01        (EX 前递)
    (None,      "slli.w", 11, 10, 4),       # r11 = 0xF010       (EX 前递)
    (None,      "srli.w", 12, 11, 8),       # r12 = 0xF0         (EX 前递)
    (None,      "xor",    13, 9, 9),        # r13 = 0
    (None,      "or",     14, 10, 12),      # r14 = 0xFF1
    (None,      "and",    15, 9, 10),       # r15 = 0xF01
    (None,      "sub.w",  16, 4, 2),        # r16 = 55 - 0 = 55
    (None,      "pcaddu12i", 17, 0),        # r17 = pc(本指令)
    (None,      "beq",    13, 0, "eqok"),   # r13==0 -> 跳转
    (None,      "addi.w", 18, 0, 0xBAD),    # （被跳过）
    ("eqok",    "addi.w", 18, 0, 0x18),     # r18 = 0x18
    (None,      "bl",     "func"),          # r1 = pc+4; 跳 func
    (None,      "b",      "after"),         # 返回点：跳 after
    ("func",    "addi.w", 19, 0, 0x19),     # r19 = 0x19
    (None,      "jirl",   0, 1, 0),         # 返回 (r1)
    ("after",   "addi.w", 21, 0, 0x21),     # r21 = 0x21
    (None,      "addi.w", 22, 0, 0x10),     # CPUCFG index 0x10
    (None,      "cpucfg", 22, 22),           # 无 Cache baseline -> 0
    (None,      "addi.w", 23, 0, -1),        # r23 = -1
    (None,      "slt",    24, 23, 0),        # signed(-1) < 0 -> 1
    (None,      "addi.w", 25, 0, 3),
    (None,      "addi.w", 26, 0, 5),
    (None,      "sll.w",  27, 25, 26),       # 3 << 5 = 96
    (None,      "mul.w",  28, 23, 26),       # -1 * 5 = -5
    (None,      "st.w",   21, 20, 8),        # mem[base+8] = 0x21 (结束标志)
    (None,      "st.w",   28, 20, 12),       # 新增运算结束标志
    ("halt",    "b",      "halt"),          # 自旋
]

def i12(x):  return x & 0xFFF
def i16(x):  return x & 0xFFFF
def i20(x):  return x & 0xFFFFF

def enc_3r(base, rd, rj, rk):
    return base | ((rk & 31) << 10) | ((rj & 31) << 5) | (rd & 31)
def enc_2ri12(base, rd, rj, imm):
    return base | (i12(imm) << 10) | ((rj & 31) << 5) | (rd & 31)
def enc_2ri5(base, rd, rj, ui5):
    return base | ((ui5 & 31) << 10) | ((rj & 31) << 5) | (rd & 31)
def enc_1ri20(base, rd, imm):
    return base | (i20(imm) << 5) | (rd & 31)
def enc_2ri16(base, rd, rj, off):   # off 已是字偏移（带符号）
    return base | (i16(off) << 10) | ((rj & 31) << 5) | (rd & 31)
def enc_i26(base, off):             # off 字偏移；inst[9:0]=off[25:16], inst[25:10]=off[15:0]
    o = off & 0x3FFFFFF
    return base | ((o & 0xFFFF) << 10) | ((o >> 16) & 0x3FF)

BASE3R = {"add.w":0x00100000,"sub.w":0x00110000,"slt":0x00120000,
          "and":0x00148000,"or":0x00150000,"xor":0x00158000,
          "sll.w":0x00170000,"mul.w":0x001C0000}
BASE12 = {"addi.w":0x02800000,"andi":0x03400000,"ori":0x03800000,
          "ld.b":0x28000000,"ld.w":0x28800000,"st.b":0x29000000,"st.w":0x29800000}
BASE5  = {"slli.w":0x00408000,"srli.w":0x00448000}

# 第一遍：标号 -> pc
labels = {}
pc = BASE
for item in PROG:
    if item[0] is not None:
        labels[item[0]] = pc
    pc += 4

# 第二遍：编码
words = []
pc = BASE
for item in PROG:
    m = item[1]; ops = item[2:]
    if m in BASE3R:
        w = enc_3r(BASE3R[m], ops[0], ops[1], ops[2])
    elif m == "addi.w" or m in ("ld.b","ld.w","st.b","st.w"):
        w = enc_2ri12(BASE12[m], ops[0], ops[1], ops[2])
    elif m in ("andi","ori"):
        w = enc_2ri12(BASE12[m], ops[0], ops[1], ops[2])
    elif m in BASE5:
        w = enc_2ri5(BASE5[m], ops[0], ops[1], ops[2])
    elif m == "lu12i.w":
        w = enc_1ri20(0x14000000, ops[0], ops[1])
    elif m == "pcaddu12i":
        w = enc_1ri20(0x1C000000, ops[0], ops[1])
    elif m == "cpucfg":
        # cpucfg rd, rj: bits[14:10] 固定为 0x1b
        w = 0x00006C00 | ((ops[1]&31) << 5) | (ops[0]&31)
    elif m in ("beq","bne"):
        base = 0x58000000 if m=="beq" else 0x5C000000
        off = (labels[ops[2]] - pc) >> 2
        w = enc_2ri16(base, ops[0], ops[1], off)   # rd=ops[0]? beq rj,rd: inst rd=ops[1]? 见下
        # LA: beq rj, rd, off -> inst[9:5]=rj, inst[4:0]=rd. 我们约定 ops=(rj, rd, label)
        w = base | (i16(off) << 10) | ((ops[0]&31) << 5) | (ops[1]&31)
    elif m == "jirl":
        # jirl rd, rj, off(label or int word-offset)
        off = ops[2] if isinstance(ops[2], int) else ((labels[ops[2]] - pc) >> 2)
        w = 0x4C000000 | (i16(off) << 10) | ((ops[1]&31) << 5) | (ops[0]&31)
    elif m == "b":
        off = (labels[ops[0]] - pc) >> 2
        w = enc_i26(0x50000000, off)
    elif m == "bl":
        off = (labels[ops[0]] - pc) >> 2
        w = enc_i26(0x54000000, off)
    else:
        raise ValueError("unknown mnemonic: " + m)
    words.append(w & 0xFFFFFFFF)
    pc += 4

with open("test.hex","w") as f:
    for w in words:
        f.write("%08x\n" % w)

# 同时输出可读清单到 stderr
pc = BASE
for item, w in zip(PROG, words):
    sys.stderr.write("0x%08x: %08x  %-9s %s\n" % (pc, w, item[1], item[2:]))
    pc += 4
sys.stderr.write("labels: %s\n" % {k: hex(v) for k,v in labels.items()})
