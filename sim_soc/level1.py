#!/usr/bin/env python3
"""生成 52 字节的 2026 第一阶段 Fibonacci 测试程序。"""


def i12(value):
    return value & 0xFFF


def enc_3r(base, rd, rj, rk):
    return base | ((rk & 31) << 10) | ((rj & 31) << 5) | (rd & 31)


def enc_2ri12(base, rd, rj, imm):
    return base | (i12(imm) << 10) | ((rj & 31) << 5) | (rd & 31)


def enc_bne(rj, rd, word_offset):
    return 0x5C000000 | ((word_offset & 0xFFFF) << 10) | ((rj & 31) << 5) | (rd & 31)


words = [
    0x14000000 | (0x1C400 << 5) | 4,      # lu12i.w r4,0x1c400
    enc_2ri12(0x02800000, 5, 0, 1),       # a=1
    enc_2ri12(0x02800000, 6, 0, 1),       # b=1
    enc_2ri12(0x02800000, 7, 0, 64),      # count=64
    enc_3r(0x00100000, 8, 5, 6),          # next=a+b
    enc_2ri12(0x29800000, 8, 4, 0),       # st.w next,[ptr]
    enc_2ri12(0x28800000, 9, 4, 0),       # ld.w readback,[ptr]
    enc_bne(9, 8, 0),                     # mismatch -> self loop
    enc_2ri12(0x02800000, 4, 4, 4),       # ptr+=4
    enc_2ri12(0x02800000, 5, 6, 0),       # a=b
    enc_2ri12(0x02800000, 6, 8, 0),       # b=next
    enc_2ri12(0x02800000, 7, 7, -1),      # count--
    enc_bne(7, 0, -8),                    # loop (index 12 -> 4)
]

assert len(words) * 4 == 52
with open("level1.hex", "w", encoding="ascii") as output:
    output.writelines(f"{word & 0xFFFFFFFF:08x}\n" for word in words)
