#!/usr/bin/env python3
"""Generate the directed self-modifying-code program for tb_selfmod."""

BASE = 0x1C000000
TARGET_INDEX = 32
TARGET_ADDR = BASE + 4 * TARGET_INDEX


def i12(value):
    return value & 0xFFF


def i20(value):
    return value & 0xFFFFF


def enc_2ri12(base, rd, rj, imm):
    return base | (i12(imm) << 10) | ((rj & 31) << 5) | (rd & 31)


def enc_1ri20(base, rd, imm):
    return base | (i20(imm) << 5) | (rd & 31)


def enc_i26(base, word_offset):
    offset = word_offset & 0x3FFFFFF
    return base | ((offset & 0xFFFF) << 10) | ((offset >> 16) & 0x3FF)


def addi(rd, rj, imm):
    return enc_2ri12(0x02800000, rd, rj, imm)


def ori(rd, rj, imm):
    return enc_2ri12(0x03800000, rd, rj, imm)


def lu12i(rd, imm):
    return enc_1ri20(0x14000000, rd, imm)


def st_w(rd, rj, imm):
    return enc_2ri12(0x29800000, rd, rj, imm)


def branch(src_index, dst_index, link=False):
    return enc_i26(0x54000000 if link else 0x50000000,
                   dst_index - src_index)


def jirl(rd, rj, word_offset):
    return 0x4C000000 | ((word_offset & 0xFFFF) << 10) | \
           ((rj & 31) << 5) | (rd & 31)


new_target_inst = addi(11, 0, 0x123)
words = [
    addi(10, 0, 0),                         # target visit count
    addi(11, 0, 0),                         # value written by new code
    addi(12, 0, 0),                         # store slot1 execution count
    addi(13, 0, 0),                         # old-branch fallthrough count
    lu12i(20, BASE >> 12),                  # BaseRAM/code base
    lu12i(21, 0x1C400),                     # ExtRAM/result base
    branch(6, TARGET_INDEX, link=True),      # train target's BTB entry
    lu12i(22, new_target_inst >> 12),
    ori(22, 22, new_target_inst & 0xFFF),
    addi(23, 20, TARGET_ADDR - BASE),
    st_w(22, 23, 0),                        # slot0: modify resident code
    addi(12, 12, 1),                        # slot1: kill, refetch, execute once
    branch(12, TARGET_INDEX, link=True),     # execute modified instruction
    st_w(10, 21, 0),
    st_w(11, 21, 4),
    st_w(12, 21, 8),
    st_w(13, 21, 12),
    addi(25, 0, 0x55),
    st_w(25, 21, 16),                       # completion marker
    branch(19, 19),                         # halt
]

while len(words) < TARGET_INDEX:
    words.append(addi(0, 0, 0))

words.extend([
    branch(TARGET_INDEX, TARGET_INDEX + 2),  # old target: taken branch
    addi(13, 13, 1),                        # only new code falls through
    addi(10, 10, 1),
    jirl(0, 1, 0),
])

with open("selfmod.hex", "w", encoding="ascii") as output:
    for word in words:
        output.write(f"{word & 0xFFFFFFFF:08x}\n")

print(f"selfmod target={TARGET_ADDR:08x} replacement={new_target_inst:08x}")
