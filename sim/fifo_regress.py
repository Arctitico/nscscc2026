#!/usr/bin/env python3
"""Generate directed whole-core regressions for issue/execute corner cases."""

import argparse

from randgen import (
    BASE,
    BRANCH_OPS,
    SCRATCH,
    Golden,
    OP_3R,
    OP_12,
    OP_5,
    enc_1ri20,
    enc_2ri12,
    enc_2ri16,
    enc_2ri5,
    enc_3r,
    enc_i26,
)


MEM_WORDS = 64


class Program:
    def __init__(self):
        self.words = []
        self.labels = {}
        self.fixups = []

    def emit(self, word):
        self.words.append(word & 0xFFFFFFFF)

    def label(self, name):
        if name in self.labels:
            raise ValueError("duplicate label: %s" % name)
        self.labels[name] = len(self.words)

    def addi(self, rd, rj, imm):
        self.emit(enc_2ri12(OP_12["addi.w"], rd, rj, imm))

    def imm(self, op, rd, rj, imm):
        self.emit(enc_2ri12(OP_12[op], rd, rj, imm))

    def alu(self, op, rd, rj, rk):
        self.emit(enc_3r(OP_3R[op], rd, rj, rk))

    def shift(self, op, rd, rj, amount):
        self.emit(enc_2ri5(OP_5[op], rd, rj, amount))

    def load(self, rd, offset, op="ld.w"):
        self.emit(enc_2ri12(OP_12[op], rd, 31, offset))

    def store(self, rd, offset, op="st.w"):
        self.emit(enc_2ri12(OP_12[op], rd, 31, offset))

    def store_base(self, rd, rj, offset, op="st.w"):
        self.emit(enc_2ri12(OP_12[op], rd, rj, offset))

    def branch(self, op, label, rj=0, rd=0):
        self.fixups.append((len(self.words), op, label, rj, rd))
        self.emit(0)

    def jirl(self, rd, rj, offset=0):
        self.emit(enc_2ri16(0x4C000000, rd, rj, offset))

    def halt(self):
        self.label("halt")
        self.branch("b", "halt")

    def resolve(self):
        words = list(self.words)
        for index, op, label, rj, rd in self.fixups:
            if label not in self.labels:
                raise ValueError("unknown label: %s" % label)
            offset = self.labels[label] - index
            if op in ("b", "bl"):
                base = 0x50000000 if op == "b" else 0x54000000
                words[index] = enc_i26(base, offset)
            elif op in BRANCH_OPS:
                words[index] = enc_2ri16(BRANCH_OPS[op], rd, rj, offset)
            else:
                raise ValueError("unknown branch: %s" % op)
        return words


def init_scratch(p):
    p.emit(enc_1ri20(0x14000000, 31, SCRATCH >> 12))


def load_constant(p, rd, value):
    """Materialize an exact 32-bit value with lu12i.w + ori."""
    value &= 0xFFFFFFFF
    p.emit(enc_1ri20(0x14000000, rd, value >> 12))
    p.imm("ori", rd, rd, value & 0xFFF)


def compact_case():
    """Alternate one- and two-instruction issue across natural fetch groups."""
    p = Program()
    for i in range(7):
        a = 1 + i * 4
        b = a + 1
        c = a + 2
        d = a + 3
        p.addi(a, 0, i + 1)
        p.alu("add.w", b, a, a)       # Adjacent RAW: must split.
        p.addi(c, 0, 0x40 + i)
        p.addi(d, 0, 0x60 + i)        # Independent pair: may co-issue.
        p.alu("xor", a, c, d)
        p.alu("add.w", b, a, c)       # RAW after compaction.

    p.addi(29, 0, 0x111)
    p.addi(29, 0, 0x222)              # Adjacent WAW: must split.
    p.alu("add.w", 30, 29, 1)
    p.addi(29, 0, 0x333)              # WAR is architecturally legal.
    p.halt()
    return p.resolve()


def conflicts_case():
    """Exercise the dependency rules used by the co-issue decision."""
    p = Program()
    init_scratch(p)
    p.addi(1, 0, 3)
    p.addi(2, 0, 5)

    p.alu("add.w", 3, 1, 2)
    p.alu("sub.w", 4, 3, 1)           # RAW through slot0 result.
    p.alu("xor", 5, 4, 2)
    p.alu("or", 6, 5, 3)              # RAW through slot0 result.

    p.addi(7, 0, 0x71)
    p.addi(7, 0, 0x72)                # WAW.
    p.alu("add.w", 8, 7, 1)
    p.addi(7, 0, 0x73)                # WAR.

    p.store(8, 0)
    p.load(9, 0)
    p.alu("add.w", 10, 9, 2)          # Load-use.
    p.store(10, 4)
    p.load(11, 4)
    p.alu("mul.w", 12, 11, 1)
    p.addi(13, 0, 13)                 # Independent of multiply.
    p.alu("mul.w", 14, 12, 2)
    p.alu("add.w", 15, 13, 1)
    p.halt()
    return p.resolve()


def redirect_case():
    """Put poison instructions behind redirects at different alignments."""
    p = Program()
    init_scratch(p)
    p.addi(1, 0, 1)
    p.store(0, 0)

    p.branch("beq", "taken_a", 1, 1)
    p.addi(10, 0, 0x111)              # Poison: may enter slot1.
    p.store(10, 0)                    # Poison: must not reach memory.
    p.label("taken_a")
    p.load(11, 0)

    p.addi(2, 0, 2)                   # Shift the next branch alignment.
    p.branch("bne", "bad_b", 1, 1)    # Not taken.
    p.addi(12, 0, 0x12)
    p.branch("b", "after_b")
    p.label("bad_b")
    p.addi(13, 0, 0x333)              # Poison.
    p.store(13, 4)                    # Poison.
    p.label("after_b")

    p.addi(3, 0, 3)
    p.addi(4, 0, 4)
    p.branch("beq", "taken_c", 3, 3)
    p.addi(14, 0, 0x444)              # Poison at another FIFO position.
    p.addi(15, 0, 0x555)              # Poison.
    p.label("taken_c")
    p.alu("add.w", 16, 12, 3)
    p.store(16, 8)

    # A taken slot0 branch may be paired with a slot1 MUL.  The redirect must
    # suppress the MUL's valid token even though EX2 selects its operand wires
    # independently of the branch kill signal for timing.
    p.branch("beq", "mul_killed", 1, 1)
    p.alu("mul.w", 17, 3, 4)          # Poison: must not write r17.
    p.label("mul_killed")
    p.addi(18, 0, 0x18)
    p.store(18, 12)
    p.halt()
    return p.resolve()


def pressure_case():
    """Keep the back end busy long enough for the six-entry FIFO to fill/drain."""
    p = Program()
    init_scratch(p)
    for i in range(12):
        value = i + 1
        p.addi(1, 0, value)
        p.store(1, i * 4)
        p.load(2, i * 4)
        p.alu("add.w", 3, 2, 1)       # Load-use stall.
        p.alu("mul.w", 4, 3, 1)       # Multi-cycle backpressure.
        p.store(4, (i + 16) * 4)
        p.addi(5, 0, 0x80 + i)        # Independent work behind the stall.
        p.alu("xor", 6, 5, 1)
    p.halt()
    return p.resolve()


def mul_pipe_case():
    """Sustain independent MULs, then cover MUL RAW and ALU-to-MUL forwarding."""
    p = Program()
    init_scratch(p)
    p.addi(1, 0, 3)
    p.addi(2, 0, 5)
    p.addi(3, 0, 7)
    p.addi(4, 0, -11)

    # The miss lets the six-entry instruction FIFO build pressure before the
    # independent run.  A full-rate implementation must then accept MULs on
    # consecutive clocks while the previous product occupies EX2.
    p.load(5, 0)
    for rd in range(8, 24):
        rj = 1 + ((rd - 8) & 1)
        rk = 3 + (((rd - 8) >> 1) & 1)
        p.alu("mul.w", rd, rj, rk)

    # Immediate producer/consumer chains must still wait for EX2 forwarding.
    p.alu("mul.w", 24, 1, 2)
    p.alu("mul.w", 25, 24, 3)
    p.alu("mul.w", 26, 25, 4)

    # Ordinary EX1 forwarding into a following MUL must remain bubble-free.
    p.addi(27, 1, 9)
    p.alu("mul.w", 28, 27, 2)

    p.store(8, 0)
    p.store(23, 4)
    p.store(26, 8)
    p.store(28, 12)
    p.halt()
    return p.resolve()


def late_bypass_case():
    """Cover hit/miss load-to-store-data bypass and the address interlock."""
    p = Program()
    init_scratch(p)
    p.addi(1, 0, 3)
    p.addi(2, 0, 5)

    # A cold word1 miss returns the critical word before the three refill-tail
    # beats.  The dependent store must capture that one-cycle value while
    # D-cache rejects its held request, then retry with the sticky payload.
    p.store(1, 4)
    p.load(3, 4)
    p.store(3, 8)                     # Miss/refill sticky + retry.

    # The line is now resident.  This pair must exercise the cache-hit path
    # where the load result and dependent store request are accepted together.
    p.load(11, 4)
    p.store(11, 12)                   # Hit-side direct late bypass.

    # Store a mapped pointer, miss-load it, then use it as a store address.
    # A stale base value would still point outside mapped SRAM; the unique
    # payload plus mapped destination makes both early and missing requests
    # observable in tb_rand and in the architectural memory image.
    p.addi(10, 0, 0x5A5)
    p.store(31, 16)
    p.load(4, 16)
    p.store_base(10, 4, 32)           # Address dependency: must stay in RF.

    # Keep MUL RAW cases in the same program to verify the conservative
    # interlock still produces the architectural result.
    p.alu("mul.w", 5, 1, 2)
    p.addi(20, 20, 1)
    p.alu("add.w", 6, 5, 1)           # MUL -> ALU src1.
    p.alu("mul.w", 7, 2, 1)
    p.addi(21, 21, 1)
    p.alu("sub.w", 8, 2, 7)           # MUL -> ALU src2.
    p.store(6, 16)
    p.store(8, 20)
    p.halt()
    return p.resolve()


def waw_raw_load_case():
    """A younger ready WAW must hide an older unfinished load."""
    p = Program()
    init_scratch(p)
    p.addi(2, 0, 3)
    p.addi(3, 0, 7)
    p.addi(4, 0, 0x44)

    # ME+N may co-issue.  The slot1 ALU is the architecturally youngest writer
    # of r5, so the following consumer must not wait for the cold slot0 load.
    p.load(5, 0)
    p.addi(5, 0, 0x123)
    p.addi(6, 5, 1)
    p.store(6, 0)
    p.halt()
    return p.resolve()


def waw_raw_mul_case():
    """A younger ready WAW must hide an older unfinished multiply."""
    p = Program()
    init_scratch(p)
    p.addi(2, 0, 3)
    p.addi(3, 0, 7)
    p.addi(4, 0, 0x44)

    # MU+N may co-issue.  The slot1 ALU is the architecturally youngest writer
    # of r10, so the following consumer must not wait for the slot0 multiply.
    p.alu("mul.w", 10, 2, 3)
    p.addi(10, 0, 0x55)
    p.addi(11, 10, 1)
    p.store(11, 4)
    p.halt()
    return p.resolve()


def intra_raw_case():
    """Exercise every contract edge of the dedicated SLL->ADD/XOR fast path."""
    p = Program()

    # Keep setup in complete, pairable groups so every following pair starts at
    # the FIFO head exactly as written.
    init_scratch(p)
    p.addi(1, 0, 3)
    p.addi(2, 0, 5)
    p.addi(3, 0, 7)

    p.shift("slli.w", 4, 1, 1)
    p.alu("add.w", 5, 4, 2)       # slot1 rj only
    p.shift("slli.w", 6, 2, 2)
    p.alu("xor", 7, 1, 6)         # slot1 rkd only
    p.alu("sll.w", 8, 1, 2)
    p.alu("add.w", 9, 8, 8)       # both slot1 sources

    p.shift("slli.w", 0, 1, 1)
    p.alu("add.w", 10, 0, 2)      # r0 is never a producer
    p.shift("slli.w", 11, 1, 3)
    p.alu("xor", 11, 11, 2)       # legal same-rd WAW + RAW

    # The older load/MUL is still pending in EX1/EX2 when the next pair reaches
    # RF.  The younger slot0 SLL must shadow that pending WAW for slot1.
    # This padding aligns each producer/fast-pair quartet to one fetch line.
    p.addi(24, 0, 0x24)
    p.addi(25, 0, 0x25)
    p.load(12, 0)
    p.addi(26, 0, 0x26)
    p.shift("slli.w", 12, 1, 2)
    p.alu("add.w", 13, 12, 3)
    p.alu("mul.w", 14, 1, 2)
    p.addi(27, 0, 0x27)
    p.shift("slli.w", 14, 2, 1)
    p.alu("xor", 15, 1, 14)

    # Hold RF behind a cold load-use long enough for the six-entry FIFO to fill;
    # the following three fast bundles must then transfer on consecutive clocks.
    p.load(28, 64)
    p.addi(24, 0, 0x24)
    p.alu("add.w", 28, 28, 1)
    p.addi(24, 24, 1)

    # Three consecutive bundles also consume the preceding slot1 result.
    p.shift("slli.w", 16, 1, 1)
    p.alu("add.w", 17, 16, 3)
    p.shift("slli.w", 18, 17, 1)
    p.alu("xor", 19, 2, 18)
    p.shift("slli.w", 20, 19, 2)
    p.alu("add.w", 21, 20, 3)

    # A taken slot0 branch must kill both its slot1 and the younger fast pair.
    p.branch("beq", "redirect_target", 1, 1)
    p.addi(25, 0, 0x25)
    p.shift("slli.w", 29, 1, 1)   # unique wrong-path producer
    p.alu("add.w", 30, 29, 2)
    p.label("redirect_target")
    p.shift("slli.w", 22, 2, 1)   # unique valid target producer
    p.alu("xor", 23, 1, 22)
    p.halt()
    return p.resolve()


def control_flow_case():
    """Cover backward branches, BL/JIRL link semantics and r0 writes."""
    p = Program()
    init_scratch(p)
    p.addi(2, 0, 4)
    p.addi(3, 0, 0)

    p.label("loop")
    p.addi(3, 3, 1)
    p.addi(2, 2, -1)
    p.branch("bne", "loop", 2, 0)

    p.branch("bl", "subroutine")
    p.addi(4, 0, 0x44)
    p.branch("b", "after_subroutine")

    p.label("subroutine")
    p.addi(5, 0, 0x55)
    p.jirl(0, 1, 0)

    p.label("after_subroutine")
    p.alu("add.w", 6, 3, 5)
    p.addi(0, 0, 0x123)
    p.alu("add.w", 7, 0, 6)
    p.halt()
    return p.resolve()


def full_int_case():
    """Cover every newly added non-divider instruction and its edge cases."""
    p = Program()
    init_scratch(p)

    # Signed/unsigned extrema and shift counts 31/32 distinguish operations
    # whose results otherwise often coincide on small positive operands.
    load_constant(p, 1, 0xFFFFFFFF)
    load_constant(p, 2, 0x80000000)
    load_constant(p, 3, 0x7FFFFFFF)
    load_constant(p, 4, 0x12345678)
    p.addi(5, 0, 31)
    p.addi(6, 0, 32)

    p.alu("sltu", 7, 1, 2)
    p.store(7, 0)
    p.alu("sltu", 8, 2, 1)
    p.store(8, 4)
    p.alu("nor", 9, 4, 3)
    p.store(9, 8)
    p.alu("srl.w", 10, 2, 5)
    p.store(10, 12)
    p.alu("sra.w", 11, 2, 5)
    p.store(11, 16)
    p.alu("srl.w", 12, 4, 6)       # register shift count is masked to 5 bits
    p.store(12, 20)

    # Independent high-half products are adjacent to exercise multiplier II=1.
    p.alu("mulh.w", 13, 1, 4)
    p.alu("mulh.wu", 14, 1, 4)
    p.alu("mulh.w", 15, 2, 1)
    p.alu("mulh.wu", 16, 1, 1)
    p.store(13, 24)
    p.store(14, 28)
    p.store(15, 32)
    p.store(16, 36)

    p.shift("srai.w", 17, 2, 31)
    p.store(17, 40)
    p.shift("srai.w", 18, 2, 0)
    p.store(18, 44)
    p.imm("xori", 19, 4, 0xFFF)
    p.store(19, 48)
    p.imm("xori", 20, 4, 0)
    p.store(20, 52)
    p.imm("slti", 21, 1, 0)
    p.store(21, 56)
    p.imm("slti", 22, 3, -1)
    p.store(22, 60)
    p.imm("sltui", 23, 3, -1)
    p.store(23, 64)
    p.imm("sltui", 24, 1, -1)
    p.store(24, 68)
    p.imm("slti", 25, 2, -2048)
    p.store(25, 72)
    p.imm("sltui", 26, 1, -2048)
    p.store(26, 76)

    # Byte layout is 01 7f ff 80.  This covers both halfword lanes, signed
    # extension, unsigned byte/half loads, both st.h strobes, and load->store
    # data late bypass for sub-word accesses.
    load_constant(p, 27, 0x80FF7F01)
    p.store(27, 96)
    p.load(20, 96, "ld.h")
    p.store(20, 100)
    p.load(21, 98, "ld.h")
    p.store(21, 104)
    p.load(22, 98, "ld.hu")
    p.store(22, 108)
    p.load(23, 98, "ld.bu")
    p.store(23, 112)
    p.load(24, 99, "ld.bu")
    p.store(24, 116)

    load_constant(p, 25, 0x11223344)
    p.store(25, 120)
    load_constant(p, 26, 0xA1B2C3D4)
    p.store(26, 120, "st.h")
    load_constant(p, 27, 0x55667788)
    p.store(27, 122, "st.h")
    p.load(28, 120)
    p.store(28, 124)

    load_constant(p, 29, 0xDEADBEEF)
    p.store(29, 128)
    p.load(30, 98, "ld.hu")
    p.store(30, 128, "st.h")
    p.load(28, 128)
    p.store(28, 132)
    p.load(30, 96, "ld.hu")
    p.store(30, 130, "st.h")
    p.load(28, 128)
    p.store(28, 136)
    p.load(28, 96, "ld.bu")
    p.store(28, 140)
    p.load(28, 97, "ld.bu")
    p.store(28, 144)
    p.load(28, 96, "ld.hu")
    p.store(28, 148)

    # For each relational branch, an add immediately after it contributes a
    # unique bit only when the branch is not taken.  The final signature 0x96
    # independently checks signed/unsigned and LT/GE polarity.
    p.addi(20, 0, 0)
    branch_cases = (
        ("blt",  1, 3,   1),
        ("bge",  1, 3,   2),
        ("bltu", 1, 3,   4),
        ("bgeu", 1, 3,   8),
        ("blt",  3, 1,  16),
        ("bge",  3, 1,  32),
        ("bltu", 3, 1,  64),
        ("bgeu", 3, 1, 128),
    )
    for index, (op, rj, rd, weight) in enumerate(branch_cases):
        target = "rel_done_%d" % index
        p.branch(op, target, rj, rd)
        p.addi(20, 20, weight)
        p.label(target)
    p.store(20, 152)

    # A taken slot0 relational branch may have launched a younger high-half
    # multiply speculatively; its token must be consumed but never committed.
    p.branch("blt", "rel_mul_killed", 1, 3)
    p.alu("mulh.wu", 30, 1, 1)
    p.label("rel_mul_killed")
    p.addi(30, 0, 0x30)

    # Repeated backward relational branches cover taken-to-not-taken predictor
    # transitions, rather than only one-shot forward redirects.
    p.addi(21, 0, 0)
    p.addi(22, 0, 4)
    p.label("signed_loop")
    p.addi(21, 21, 1)
    p.branch("blt", "signed_loop", 21, 22)
    p.store(21, 156)

    p.addi(23, 0, 3)
    p.addi(24, 0, 0)
    p.label("unsigned_loop")
    p.addi(24, 24, 1)
    p.branch("bgeu", "unsigned_loop", 23, 24)
    p.store(24, 160)

    # ME+MU completion overlap and a younger ready WAW over a high multiply.
    p.load(25, 98, "ld.hu")
    p.alu("mulh.wu", 26, 1, 4)
    p.store(25, 164)
    p.store(26, 168)
    p.alu("mulh.wu", 27, 1, 1)
    p.addi(27, 0, 0x55)
    p.addi(28, 27, 1)
    p.store(28, 172)

    # Architectural r0 remains zero even when a newly added ALU op targets it.
    p.alu("sltu", 0, 2, 1)
    p.store(0, 176)
    p.halt()
    return p.resolve()


FULL_INT_EXPECTED = {
    0: 0x00000000, 1: 0x00000001, 2: 0x80000000,
    3: 0x00000001, 4: 0xFFFFFFFF, 5: 0x12345678,
    6: 0xFFFFFFFF, 7: 0x12345677, 8: 0x00000000,
    9: 0xFFFFFFFE, 10: 0xFFFFFFFF, 11: 0x80000000,
    12: 0x12345987, 13: 0x12345678, 14: 0x00000001,
    15: 0x00000000, 16: 0x00000001, 17: 0x00000000,
    18: 0x00000001, 19: 0x00000000,
    24: 0x80FF7F01, 25: 0x00007F01, 26: 0xFFFF80FF,
    27: 0x000080FF, 28: 0x000000FF, 29: 0x00000080,
    30: 0x7788C3D4, 31: 0x7788C3D4,
    32: 0x7F0180FF, 33: 0xDEAD80FF, 34: 0x7F0180FF,
    35: 0x00000001, 36: 0x0000007F, 37: 0x00007F01,
    38: 0x00000096, 39: 0x00000004, 40: 0x00000004,
    41: 0x000080FF, 42: 0x12345677, 43: 0x00000056,
    44: 0x00000000,
}


CASES = {
    "compact": compact_case,
    "conflicts": conflicts_case,
    "control_flow": control_flow_case,
    "full_int": full_int_case,
    "intra_raw": intra_raw_case,
    "late_bypass": late_bypass_case,
    "mul_pipe": mul_pipe_case,
    "redirect": redirect_case,
    "pressure": pressure_case,
    "waw_raw_load": waw_raw_load_case,
    "waw_raw_mul": waw_raw_mul_case,
}


def write_case(words, out_dir, expected_mem=None):
    golden = Golden()
    golden.run(words)

    if expected_mem is not None:
        for index, expected in expected_mem.items():
            actual = golden.lw(SCRATCH + index * 4)
            if actual != expected:
                raise AssertionError(
                    "golden self-check mem[%d]=%08x expected %08x" %
                    (index, actual, expected))

    with open(out_dir + "/test.hex", "w") as f:
        for word in words:
            f.write("%08x\n" % word)
    with open(out_dir + "/golden_trace.hex", "w") as f:
        for pc, rd, value in golden.trace:
            f.write("%08x %02x %08x\n" % (pc, rd, value))
    with open(out_dir + "/initial_mem.hex", "w") as f:
        for _ in range(MEM_WORDS):
            f.write("00000000\n")
    with open(out_dir + "/golden_mem.hex", "w") as f:
        for index in range(MEM_WORDS):
            f.write("%08x\n" % golden.lw(SCRATCH + index * 4))
    with open(out_dir + "/golden.meta", "w") as f:
        f.write("%d %d\n" % (len(golden.trace), MEM_WORDS))
    return len(golden.trace)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--case", required=True, choices=sorted(CASES))
    parser.add_argument("--out-dir", default=".")
    args = parser.parse_args()

    words = CASES[args.case]()
    expected_mem = FULL_INT_EXPECTED if args.case == "full_int" else None
    commits = write_case(words, args.out_dir.rstrip("/"), expected_mem)
    print("case=%s words=%d commits=%d base=%08x" %
          (args.case, len(words), commits, BASE))


if __name__ == "__main__":
    main()
