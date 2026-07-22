#!/usr/bin/env python3
# ============================================================================
# randgen.py —— LA32R 2026 baseline 随机指令生成器 + 黄金模型(DiffTest 参考)
#
# 思路(DiffTest / 协同仿真):
#   1) 随机生成算术/逻辑/移位/访存，并可选插入只向前跳的分支，
#      因此程序仍然必定终止。
#   2) 黄金模型对「编码后的 32 位指令字」做*独立*译码+执行(不复用编码器的语义),
#      产出 in-order 提交流(每条写寄存器指令一条记录: pc/wnum/wdata)与最终内存镜像。
#   3) tb_rand.sv 把 CPU 每拍提交(debug_wb_*)与黄金提交流逐条比对(锁步),
#      首个不一致即报 pc;运行结束再比对 scratch 内存。
#
# 输出文件(写到 --out-dir, 默认当前目录):
#   test.hex          —— 指令字, $readmemh 装载到 0x1c000000
#   golden_trace.hex  —— 每行 "<pc> <wnum> <wdata>" (hex), 即期望提交流
#   golden_mem.hex    —— scratch 区(0x1c400000 起)最终镜像, 每行一字(hex)
#   golden.meta       —— "ncommit nmemword" 两个十进制数, 供 tb 读取计数
#   并向 stderr 打印可读清单。
#
# 关键约定(与 RTL 对齐, 见 decoder.sv / regfile.sv / CM.sv):
#   - dest 寄存器只用 1..30: r0 恒 0(写被忽略), r31 保留作 scratch 基址指针。
#     这样每条写寄存器指令的 wnum 都 !=0, 与 CPU 的 debug_wb 脉冲一一对应。
#   - 寄存器复位初值视为 0 (Verilator 2-state 默认 0 初始化, 与黄金模型一致)。
#   - scratch 区固定从 ExtRAM 0x1c400000 开始，字访存 4 对齐、字节访存任意。
# ============================================================================
import sys, argparse, random

BASE        = 0x1C000000          # 代码装载基址 / 复位 PC
SCRATCH     = 0x1C400000          # ExtRAM scratch 基址 (放进 r31)
SCRATCH_REG = 31                  # 保留作基址指针, 不作 dest

# ---- 编码助手(与 asm.py 同一套底层编码) ----
def i12(x): return x & 0xFFF
def i16(x): return x & 0xFFFF
def i20(x): return x & 0xFFFFF

def enc_3r(base, rd, rj, rk):   return base | ((rk&31)<<10) | ((rj&31)<<5) | (rd&31)
def enc_2ri12(base, rd, rj, im):return base | (i12(im)<<10) | ((rj&31)<<5) | (rd&31)
def enc_2ri5(base, rd, rj, u5): return base | ((u5&31)<<10) | ((rj&31)<<5) | (rd&31)
def enc_2ri16(base, rd, rj, off):return base | (i16(off)<<10) | ((rj&31)<<5) | (rd&31)
def enc_1ri20(base, rd, im):    return base | (i20(im)<<5) | (rd&31)
def enc_i26(base, off):
    o = off & 0x3FFFFFF
    return base | ((o&0xFFFF)<<10) | ((o>>16)&0x3FF)

OP_3R = {"add.w":0x00100000,"sub.w":0x00110000,"slt":0x00120000,
         "and":0x00148000,"or":0x00150000,"xor":0x00158000,
         "sll.w":0x00170000,"mul.w":0x001C0000}
OP_12 = {"addi.w":0x02800000,"andi":0x03400000,"ori":0x03800000,
         "ld.b":0x28000000,"ld.w":0x28800000,"st.b":0x29000000,"st.w":0x29800000}
OP_5  = {"slli.w":0x00408000,"srli.w":0x00448000}

def sext(v, bits):
    m = 1 << (bits-1)
    return (v ^ m) - m
def u32(v): return v & 0xFFFFFFFF

# ============================================================================
# 黄金模型: 对 32 位指令字独立译码 + 执行
# ============================================================================
class Golden:
    def __init__(self):
        self.R   = [0]*32          # 复位初值 0
        self.mem = {}              # 字节地址 -> 字节值 (默认 0)
        self.trace = []            # (pc, wnum, wdata)
    def rb(self, a):  return self.mem.get(a, 0) & 0xFF
    def wb(self, a, v): self.mem[a] = v & 0xFF
    def lw(self, a):
        return self.rb(a) | (self.rb(a+1)<<8) | (self.rb(a+2)<<16) | (self.rb(a+3)<<24)
    def sw(self, a, v):
        for k in range(4): self.wb(a+k, (v>>(8*k))&0xFF)
    def commit(self, pc, rd, val):
        # 模拟 RTL: rf_we 指令都产生脉冲; r0 写被 regfile 忽略(架构值不变),
        # 但本生成器从不用 r0/r31 作 dest, 故 rd 必在 1..30。
        if rd != 0:
            self.R[rd] = u32(val)
        self.trace.append((pc, rd, u32(val)))

    def step(self, pc, inst):
        op6  = (inst>>26)&0x3F
        if op6 in (0x13, 0x14, 0x15, 0x16, 0x17):
            rd = inst & 31
            rj = (inst>>5) & 31
            off16 = sext((inst>>10) & 0xFFFF, 16) << 2
            off26 = sext(((inst & 0x3FF) << 16) | ((inst>>10) & 0xFFFF), 26) << 2
            if op6 == 0x14:                                      # b
                return u32(pc + off26)
            if op6 == 0x15:                                      # bl
                self.commit(pc, 1, pc + 4)
                return u32(pc + off26)
            if op6 == 0x13:                                      # jirl
                target = u32(self.R[rj] + off16)
                self.commit(pc, rd, pc + 4)
                return target
            taken = (self.R[rj] == self.R[rd]) if op6 == 0x16 else (self.R[rj] != self.R[rd])
            return u32(pc + off16) if taken else u32(pc + 4)

        op22 = (inst>>22)&0xF
        op20 = (inst>>20)&0x3
        op15 = (inst>>15)&0x1F
        rd = inst & 31
        rj = (inst>>5) & 31
        rk = (inst>>10) & 31
        ui5 = (inst>>10) & 31
        i12f = (inst>>10) & 0xFFF
        i20f = (inst>>5) & 0xFFFFF
        Rj, Rk, Rd = self.R[rj], self.R[rk], self.R[rd]

        if (op6 == 0x00 and op22 == 0x0 and op20 == 0x0 and
                op15 == 0x00 and rk == 0x1b):                      # cpucfg
            # 无 Cache baseline：当前实现的所有配置字均为 0。
            self.commit(pc, rd, 0)
        elif op6 == 0x00 and op22 == 0x0 and op20 == 0x1:         # 3R 类
            if   op15 == 0x00: self.commit(pc, rd, Rj + Rk)        # add.w
            elif op15 == 0x02: self.commit(pc, rd, Rj - Rk)        # sub.w
            elif op15 == 0x04: self.commit(pc, rd, int(sext(Rj, 32) < sext(Rk, 32))) # slt
            elif op15 == 0x09: self.commit(pc, rd, Rj & Rk)        # and
            elif op15 == 0x0a: self.commit(pc, rd, Rj | Rk)        # or
            elif op15 == 0x0b: self.commit(pc, rd, Rj ^ Rk)        # xor
            elif op15 == 0x0e: self.commit(pc, rd, Rj << (Rk & 31)) # sll.w
            elif op15 == 0x18: self.commit(pc, rd, Rj * Rk)        # mul.w low 32
            else: raise ValueError("bad 3R %08x" % inst)
        elif op6 == 0x00 and op22 == 0x1 and op20 == 0x0:         # 移位
            if   op15 == 0x01: self.commit(pc, rd, Rj << ui5)      # slli.w
            elif op15 == 0x09: self.commit(pc, rd, (Rj & 0xFFFFFFFF) >> ui5)  # srli.w
            else: raise ValueError("bad shift %08x" % inst)
        elif op6 == 0x00 and op22 == 0xa:                          # addi.w
            self.commit(pc, rd, Rj + sext(i12f, 12))
        elif op6 == 0x00 and op22 == 0xd:                          # andi (零扩展)
            self.commit(pc, rd, Rj & i12f)
        elif op6 == 0x00 and op22 == 0xe:                          # ori
            self.commit(pc, rd, Rj | i12f)
        elif op6 == 0x05:                                          # lu12i.w
            self.commit(pc, rd, i20f << 12)
        elif op6 == 0x07:                                          # pcaddu12i
            self.commit(pc, rd, pc + (i20f << 12))
        elif op6 == 0x0a:                                          # 访存
            imm = sext(i12f, 12)
            addr = u32(Rj + imm)
            if   op22 == 0x2: self.commit(pc, rd, self.lw(addr))           # ld.w
            elif op22 == 0x0: self.commit(pc, rd, sext(self.rb(addr), 8))  # ld.b
            elif op22 == 0x6: self.sw(addr, Rd)                            # st.w
            elif op22 == 0x4: self.wb(addr, Rd & 0xFF)                     # st.b
            else: raise ValueError("bad mem %08x" % inst)
        else:
            raise ValueError("unhandled inst %08x @ pc=%08x" % (inst, pc))
        return u32(pc + 4)

    def run(self, words, max_steps=None):
        """执行 words[]（可含前向分支）；最后的自旋 b 表示结束。"""
        n = len(words)
        if max_steps is None: max_steps = n * 4 + 64
        pc = BASE
        steps = 0
        while steps < max_steps:
            idx = (pc - BASE) >> 2
            if idx < 0 or idx >= n:
                break
            inst = words[idx]
            next_pc = self.step(pc, inst)
            if next_pc == pc:
                break
            pc = next_pc
            steps += 1

# ============================================================================
# 随机程序生成
# ============================================================================
DP_OPS  = ["add.w","sub.w","slt","and","or","xor","sll.w","mul.w",
           "slli.w","srli.w","addi.w","andi","ori","lu12i.w","pcaddu12i","cpucfg"]
MEM_OPS = ["ld.w","ld.b","st.w","st.b"]

def gen(seed, n, window_words, mem_ratio, branch_ratio=0.0):
    rng = random.Random(seed)
    win_bytes = window_words * 4
    words = []
    asm   = []   # 可读清单 (mnemonic, args)

    # 偏置: 倾向选取最近写过的寄存器, 多压前递/load-use 路径
    recent = []
    def pick_src():
        if recent and rng.random() < 0.5:
            return rng.choice(recent[-4:])
        return rng.randint(0, 31)           # 含 r0 / r31(基址)
    def pick_dst():
        r = rng.randint(1, 30)              # 排除 r0 与 r31(保留)
        recent.append(r)
        return r

    # 架构 NOP：andi r0,r0,0。
    words.append(OP_12["andi"])
    asm.append(("nop", ("andi r0,r0,0",)))

    # 序言: r31 = SCRATCH (lu12i.w r31, SCRATCH>>12)
    words.append(enc_1ri20(0x14000000, SCRATCH_REG, SCRATCH >> 12))
    asm.append(("lu12i.w", (SCRATCH_REG, hex(SCRATCH >> 12), "; scratch base")))

    for i in range(n):
        if branch_ratio > 0 and rng.random() < branch_ratio:
            max_words = max(1, min(8, n - i))
            offset = rng.randint(1, max_words)
            op = rng.choice(("b", "beq", "bne"))
            if op == "b":
                words.append(enc_i26(0x50000000, offset))
                asm.append((op, ("+%dw" % offset,)))
            else:
                rj, rd = pick_src(), pick_src()
                base = 0x58000000 if op == "beq" else 0x5C000000
                words.append(enc_2ri16(base, rd, rj, offset))
                asm.append((op, (rj, rd, "+%dw" % offset)))
            continue
        if rng.random() < mem_ratio:
            op = rng.choice(MEM_OPS)
            if op in ("ld.w", "st.w"):
                off = rng.randrange(0, win_bytes, 4)        # 4 对齐
            else:
                off = rng.randrange(0, win_bytes)           # 字节任意
            if op == "ld.w":
                d = pick_dst(); words.append(enc_2ri12(OP_12[op], d, SCRATCH_REG, off)); asm.append((op,(d,SCRATCH_REG,off)))
            elif op == "ld.b":
                d = pick_dst(); words.append(enc_2ri12(OP_12[op], d, SCRATCH_REG, off)); asm.append((op,(d,SCRATCH_REG,off)))
            elif op == "st.w":
                s = pick_src(); words.append(enc_2ri12(OP_12[op], s, SCRATCH_REG, off)); asm.append((op,(s,SCRATCH_REG,off)))
            else:  # st.b
                s = pick_src(); words.append(enc_2ri12(OP_12[op], s, SCRATCH_REG, off)); asm.append((op,(s,SCRATCH_REG,off)))
        else:
            op = rng.choice(DP_OPS)
            if op in OP_3R:
                d, a, b = pick_dst(), pick_src(), pick_src()
                words.append(enc_3r(OP_3R[op], d, a, b)); asm.append((op,(d,a,b)))
            elif op in ("slli.w","srli.w"):
                d, a, sh = pick_dst(), pick_src(), rng.randint(0,31)
                words.append(enc_2ri5(OP_5[op], d, a, sh)); asm.append((op,(d,a,sh)))
            elif op == "addi.w":
                d, a, im = pick_dst(), pick_src(), rng.randint(-2048,2047)
                words.append(enc_2ri12(OP_12[op], d, a, im)); asm.append((op,(d,a,im)))
            elif op in ("andi","ori"):
                d, a, im = pick_dst(), pick_src(), rng.randint(0,4095)
                words.append(enc_2ri12(OP_12[op], d, a, im)); asm.append((op,(d,a,im)))
            elif op == "lu12i.w":
                d, im = pick_dst(), rng.randint(0,0xFFFFF)
                words.append(enc_1ri20(0x14000000, d, im)); asm.append((op,(d,hex(im))))
            elif op == "pcaddu12i":
                d, im = pick_dst(), rng.randint(0,0xFFFFF)
                words.append(enc_1ri20(0x1C000000, d, im)); asm.append((op,(d,hex(im))))
            elif op == "cpucfg":
                d, a = pick_dst(), pick_src()
                words.append(0x00006C00 | ((a&31)<<5) | (d&31)); asm.append((op,(d,a)))

    # 结尾自旋: b 0 (跳自身)
    halt_idx = len(words)
    words.append(enc_i26(0x50000000, 0))
    asm.append(("b", ("halt(self)",)))

    words = [w & 0xFFFFFFFF for w in words]
    return words, asm, win_bytes

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--n", type=int, default=120, help="随机指令条数(不含序言/结尾)")
    ap.add_argument("--window", type=int, default=64, help="scratch 窗口字数")
    ap.add_argument("--mem-ratio", type=float, default=0.30, help="访存指令占比")
    ap.add_argument("--branch-ratio", type=float, default=0.0, help="前向 b/beq/bne 占比")
    ap.add_argument("--out-dir", default=".")
    args = ap.parse_args()

    words, asm, win_bytes = gen(args.seed, args.n, args.window,
                                args.mem_ratio, args.branch_ratio)

    g = Golden()
    g.run(words)

    od = args.out_dir.rstrip("/")
    with open(od + "/test.hex", "w") as f:
        for w in words: f.write("%08x\n" % w)
    with open(od + "/golden_trace.hex", "w") as f:
        for pc, rd, val in g.trace:
            f.write("%08x %02x %08x\n" % (pc, rd, val))
    memwords = args.window
    with open(od + "/golden_mem.hex", "w") as f:
        for k in range(memwords):
            f.write("%08x\n" % g.lw(SCRATCH + k*4))
    with open(od + "/golden.meta", "w") as f:
        f.write("%d %d\n" % (len(g.trace), memwords))

    # 可读清单到 stderr
    pc = BASE
    for (m, a), w in zip(asm, words):
        sys.stderr.write("0x%08x: %08x  %-10s %s\n" % (pc, w, m, a))
        pc += 4
    sys.stderr.write("seed=%d n=%d commits=%d memwords=%d scratch=%08x window=%dB\n"
                     % (args.seed, args.n, len(g.trace), memwords, SCRATCH, win_bytes))

if __name__ == "__main__":
    main()
