#!/usr/bin/env python3
"""Semantic diff of two kernel .config files."""
import re
import sys


def load(path):
    out = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            m = re.match(r"^(CONFIG_[A-Za-z0-9_]+)=(.*)$", line)
            if m:
                out[m.group(1)] = m.group(2)
                continue
            m = re.match(r"^# (CONFIG_[A-Za-z0-9_]+) is not set$", line)
            if m:
                out[m.group(1)] = "n"
    return out


def main():
    a = load(sys.argv[1])
    b = load(sys.argv[2])
    common = sorted(set(a) & set(b))
    diff = [(k, a[k], b[k]) for k in common if a[k] != b[k]]

    print(f"A={sys.argv[1]}")
    print(f"B={sys.argv[2]}")
    print(f"common={len(common)} differing={len(diff)}")
    print("\n-- differing values --")
    for k, x, y in diff:
        print(f"{k}\n    A={x}\n    B={y}")

    only_a = sorted(set(a) - set(b))
    only_b = sorted(set(b) - set(a))
    print(f"\n-- only in A ({len(only_a)}) --")
    for k in only_a:
        print(f"    {k}={a[k]}")
    print(f"\n-- only in B ({len(only_b)}) --")
    for k in only_b:
        print(f"    {k}={b[k]}")


if __name__ == "__main__":
    main()
