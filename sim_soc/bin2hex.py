#!/usr/bin/env python3
"""把小端二进制镜像转换为 $readmemh 使用的 32 位字文本。"""

import argparse
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input")
    parser.add_argument("output")
    args = parser.parse_args()

    data = Path(args.input).read_bytes()
    if len(data) % 4:
        data += bytes(4 - len(data) % 4)

    words = [int.from_bytes(data[i:i + 4], "little") for i in range(0, len(data), 4)]
    Path(args.output).write_text("".join(f"{word:08x}\n" for word in words), encoding="ascii")


if __name__ == "__main__":
    main()
