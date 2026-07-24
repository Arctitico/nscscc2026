#!/usr/bin/env python3
"""Analyze per-load-PC D-cache miss traces emitted by dcache_pc_trace.sv."""

import argparse
from collections import Counter, deque


def percent(value, total):
    return 100.0 * value / total if total else 0.0


class PcStats:
    def __init__(self):
        self.count = 0
        self.history = deque(maxlen=4)
        self.delta = {distance: Counter() for distance in range(1, 5)}
        self.timely = {distance: Counter() for distance in range(1, 5)}
        self.opportunities = Counter()

    def add(self, miss_cycle, fill_cycle, line):
        for distance in range(1, min(4, len(self.history)) + 1):
            old_line, _, old_fill = self.history[-distance]
            delta = line - old_line
            self.delta[distance][delta] += 1
            self.opportunities[distance] += 1
            if miss_cycle - old_fill >= 8:
                self.timely[distance][delta] += 1
        self.history.append((line, miss_cycle, fill_cycle))
        self.count += 1


class StrideEntry:
    def __init__(self, pc, line):
        self.pc = pc
        self.last_line = line
        self.stride = None
        self.confidence = 0


class BufferModel:
    """Eight-entry direct-mapped PC stride table plus FIFO candidate buffers."""

    def __init__(self, capacity):
        self.capacity = capacity
        self.table = [None] * 8
        self.buffers = []
        self.inserted = 0
        self.useful = 0
        self.timely = 0
        self.evicted = 0

    def access(self, miss_cycle, fill_cycle, pc, line):
        for index, (target, issue_cycle) in enumerate(self.buffers):
            if target == line:
                self.useful += 1
                if miss_cycle - issue_cycle >= 8:
                    self.timely += 1
                del self.buffers[index]
                break

        table_index = (pc >> 2) & 7
        entry = self.table[table_index]
        if entry is None or entry.pc != pc:
            self.table[table_index] = StrideEntry(pc, line)
            return

        observed = line - entry.last_line
        if entry.stride is None:
            entry.stride = observed
            entry.confidence = 0
        elif observed == entry.stride:
            entry.confidence = min(3, entry.confidence + 1)
        elif entry.confidence:
            entry.confidence -= 1
        else:
            entry.stride = observed

        entry.last_line = line
        if entry.confidence < 2:
            return

        target = line + entry.stride
        if any(buffer_target == target for buffer_target, _ in self.buffers):
            return
        if len(self.buffers) == self.capacity:
            self.buffers.pop(0)
            self.evicted += 1
        self.buffers.append((target, fill_cycle))
        self.inserted += 1


def analyze(name, path):
    pc_stats = {}
    buffers = {capacity: BufferModel(capacity) for capacity in (1, 2, 4)}
    total = 0
    global_next = 0
    previous_line = None

    with open(path, encoding="ascii") as trace:
        for row in trace:
            miss_text, fill_text, pc_text, line_text = row.split()
            miss_cycle = int(miss_text)
            fill_cycle = int(fill_text)
            pc = int(pc_text, 16)
            line = int(line_text, 16) >> 4

            total += 1
            if previous_line is not None and line == previous_line + 1:
                global_next += 1
            previous_line = line

            stats = pc_stats.setdefault(pc, PcStats())
            stats.add(miss_cycle, fill_cycle, line)
            for model in buffers.values():
                model.access(miss_cycle, fill_cycle, pc, line)

    print(f"\n===== {name.upper()} =====")
    print(
        f"misses={total} unique_pcs={len(pc_stats)} "
        f"global_next={global_next}/{max(total - 1, 0)} "
        f"({percent(global_next, total - 1):.2f}%)"
    )

    for distance in range(1, 5):
        opportunities = 0
        correct = 0
        timely = 0
        for stats in pc_stats.values():
            opportunities += stats.opportunities[distance]
            if stats.delta[distance]:
                delta, count = stats.delta[distance].most_common(1)[0]
                correct += count
                timely += stats.timely[distance][delta]
        print(
            f"local_delta lookahead={distance}: "
            f"correct={correct}/{opportunities} "
            f"({percent(correct, opportunities):.2f}%) timely={timely}"
        )

    for capacity, model in buffers.items():
        print(
            f"buffer={capacity}: inserted={model.inserted} "
            f"useful={model.useful} timely={model.timely} "
            f"evicted={model.evicted} live={len(model.buffers)}"
        )

    print("top_pcs:")
    ranked = sorted(
        ((stats.count, pc, stats) for pc, stats in pc_stats.items()),
        reverse=True,
    )
    for count, pc, stats in ranked[:8]:
        deltas = ", ".join(
            f"{delta:+d}:{occurrences}"
            for delta, occurrences in stats.delta[1].most_common(2)
        )
        print(f"  pc={pc:08x} misses={count} deltas=[{deltas or '-'}]")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "traces",
        nargs="+",
        metavar="NAME=PATH",
        help="workload name and trace path",
    )
    args = parser.parse_args()
    for item in args.traces:
        name, separator, path = item.partition("=")
        if not separator:
            parser.error(f"expected NAME=PATH, got {item!r}")
        analyze(name, path)


if __name__ == "__main__":
    main()
