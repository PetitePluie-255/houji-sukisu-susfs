#!/usr/bin/env python3
"""Repack a header-v4 Android boot image with a replacement kernel.

.. warning::

   This produces an image **without** an AVB footer. It is only useful as the
   intermediate step of a pipeline that would then run ``avbtool
   add_hash_footer`` -- and that pipeline does **not** produce a flashable
   image on this device, because the resulting footer is unsigned
   (``Algorithm: NONE``) and the bootloader rejects it when booting from the
   partition (see docs/01-root-cause.md, section 3).

   For a flashable image use ``make-stale-boot.py`` instead, which keeps the
   stock vendor-signed footer.
"""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


PAGE_SIZE = 4096


def align(value: int) -> int:
    return (value + PAGE_SIZE - 1) // PAGE_SIZE * PAGE_SIZE


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stock", required=True, type=Path)
    parser.add_argument("--kernel", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    stock = args.stock.read_bytes()
    kernel = args.kernel.read_bytes()
    if stock[:8] != b"ANDROID!":
        raise SystemExit("stock image does not have Android boot magic")
    header_version = struct.unpack_from("<I", stock, 40)[0]
    header_size = struct.unpack_from("<I", stock, 20)[0]
    ramdisk_size = struct.unpack_from("<I", stock, 12)[0]
    if header_version != 4 or header_size != 1584:
        raise SystemExit(f"expected boot v4 header, got v{header_version} size {header_size}")
    if ramdisk_size != 0:
        raise SystemExit(f"expected empty boot ramdisk, got {ramdisk_size} bytes")

    header_page = bytearray(stock[:PAGE_SIZE])
    struct.pack_into("<I", header_page, 8, len(kernel))
    output = bytes(header_page) + kernel
    output += b"\0" * (align(len(output)) - len(output))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(output)
    print(f"kernel_size={len(kernel)} unsigned_boot_size={len(output)}")


if __name__ == "__main__":
    main()
