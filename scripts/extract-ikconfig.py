#!/usr/bin/env python3
"""Extract the gzip-compressed IKCONFIG payload embedded in a Linux kernel.

Writes to a file when OUTPUT is given, otherwise prints to stdout::

    python3 extract-ikconfig.py boot-kernel > stock-kernel.config
"""

from __future__ import annotations

import argparse
import gzip
import sys
from pathlib import Path


START = b"IKCFG_ST"
END = b"IKCFG_ED"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("kernel", type=Path)
    parser.add_argument("output", type=Path, nargs="?")
    args = parser.parse_args()

    data = args.kernel.read_bytes()
    start = data.find(START)
    if start < 0:
        raise SystemExit("IKCONFIG start marker not found")
    start += len(START)
    end = data.find(END, start)
    if end < 0:
        raise SystemExit("IKCONFIG end marker not found")

    config = gzip.decompress(data[start:end])
    if args.output is None:
        sys.stdout.buffer.write(config)
    else:
        args.output.write_bytes(config)
        print(f"wrote {len(config)} bytes to {args.output}")


if __name__ == "__main__":
    main()
