#!/usr/bin/env python3
"""Fail-fast random DiffTest runner shared by CPU-only and SoC regressions."""

import argparse
import json
from pathlib import Path
import shlex
import subprocess
import sys


ARTIFACTS = (
    "test.hex",
    "initial_mem.hex",
    "golden_trace.hex",
    "golden_mem.hex",
    "golden.meta",
    "random.meta",
)
MAX_RANDOM_INSTRUCTIONS = 65533


def positive_int(text):
    value = int(text)
    if value <= 0:
        raise argparse.ArgumentTypeError("must be > 0")
    return value


def instruction_count(text):
    value = positive_int(text)
    if value > MAX_RANDOM_INSTRUCTIONS:
        raise argparse.ArgumentTypeError(
            "must be <= %d (testbench code-memory limit)" %
            MAX_RANDOM_INSTRUCTIONS)
    return value


def window_words(text):
    value = positive_int(text)
    if value > 512:
        raise argparse.ArgumentTypeError("must be <= 512 words")
    return value


def ratio(text):
    value = float(text)
    if not 0.0 <= value <= 1.0:
        raise argparse.ArgumentTypeError("must be in [0, 1]")
    return value


def repro_command(args, seed):
    command = [
        "make",
        args.repro_target,
        "SEED=%d" % seed,
        "N=%d" % args.n,
        "WINDOW=%d" % args.window,
        "MR=%s" % args.mem_ratio,
        "BR=%s" % args.branch_ratio,
        "INIT_MODE=%s" % args.init_mode,
    ]
    command.extend(args.repro_extra)
    return shlex.join(command)


def fail(args, seed, reason, output=None):
    print("seed %d: FAIL (%s)" % (seed, reason), file=sys.stderr)
    if output:
        print(output, file=sys.stderr, end="" if output.endswith("\n") else "\n")
    print("==> 复现: %s" % repro_command(args, seed), file=sys.stderr)
    return 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--generator", required=True)
    parser.add_argument("--simulator", required=True)
    parser.add_argument("--pass-marker", required=True)
    parser.add_argument("--start-seed", type=int, default=1)
    parser.add_argument("--count", type=positive_int, default=1)
    parser.add_argument("--n", type=instruction_count, default=120)
    parser.add_argument("--window", type=window_words, default=64)
    parser.add_argument("--mem-ratio", type=ratio, default=0.30)
    parser.add_argument("--branch-ratio", type=ratio, default=0.0)
    parser.add_argument("--init-mode", choices=("random", "zero"),
                        default="random")
    parser.add_argument("--repro-target", default="rand")
    parser.add_argument("--repro-extra", action="append", default=[])
    args = parser.parse_args()

    generator = str(Path(args.generator))
    simulator = str(Path(args.simulator))
    expected_common = {
        "branch_ratio": args.branch_ratio,
        "init_mode": args.init_mode,
        "mem_ratio": args.mem_ratio,
        "n": args.n,
        "schema": 2,
        "window": args.window,
    }

    for seed in range(args.start_seed, args.start_seed + args.count):
        # 删除上一轮全部向量；即使生成器在写到一半时失败，也绝不能运行旧测试。
        for name in ARTIFACTS:
            Path(name).unlink(missing_ok=True)

        generate = [
            sys.executable,
            generator,
            "--seed", str(seed),
            "--n", str(args.n),
            "--window", str(args.window),
            "--mem-ratio", str(args.mem_ratio),
            "--branch-ratio", str(args.branch_ratio),
            "--init-mode", args.init_mode,
            "--quiet",
        ]
        result = subprocess.run(generate, check=False)
        if result.returncode != 0:
            return fail(args, seed, "generator exit %d" % result.returncode)

        missing = [
            name for name in ARTIFACTS
            if not Path(name).is_file() or Path(name).stat().st_size == 0
        ]
        if missing:
            return fail(args, seed, "missing/empty artifacts: %s" %
                        ", ".join(missing))

        try:
            metadata = json.loads(Path("random.meta").read_text())
        except (OSError, json.JSONDecodeError) as error:
            return fail(args, seed, "invalid random.meta: %s" % error)
        expected = dict(expected_common, seed=seed)
        if metadata != expected:
            return fail(
                args,
                seed,
                "stale metadata: got %r expected %r" % (metadata, expected),
            )

        sim = subprocess.run(
            [simulator],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        if sim.returncode != 0:
            return fail(args, seed, "simulator exit %d" % sim.returncode,
                        sim.stdout)
        if args.pass_marker not in sim.stdout:
            return fail(args, seed, "missing PASS marker", sim.stdout)
        print("seed %d: PASS" % seed)

    end_seed = args.start_seed + args.count - 1
    print("==== ALL %d SEEDS PASSED (%d..%d) ====" %
          (args.count, args.start_seed, end_seed))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
