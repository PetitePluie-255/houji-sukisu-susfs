#!/usr/bin/env python3
"""Build a flashable boot image from a stock boot image + a new kernel.

The trick is to keep the *stock* AVB footer instead of generating a new one:

  * the stock boot image carries a vendor-signed AVB footer, and the stock
    vbmeta has a Chain Partition descriptor for `boot` that requires that
    vendor signature;
  * a freshly generated footer (avbtool add_hash_footer without a key) comes
    out as `Algorithm: NONE` and is rejected by the bootloader, which then
    falls back to fastboot;
  * the footer's hash descriptor is stale after we swap the kernel, but the
    signature is still valid, which is what the chain check cares about.

This mirrors what AnyKernel3-style installers do in place.

Usage:
    make-stale-boot.py --stock stock-boot.img \
                       --kernel out/arch/arm64/boot/Image \
                       --output new-boot.img
"""

from __future__ import annotations

import argparse
import struct
from pathlib import Path

PAGE_SIZE = 4096
HEADER_SIZE = 1584  # boot header v4, occupies the first 4096-byte page


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stock", required=True, type=Path)
    parser.add_argument("--kernel", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    image = bytearray(args.stock.read_bytes())
    kernel = args.kernel.read_bytes()

    if image[:8] != b"ANDROID!":
        raise SystemExit("stock image does not have Android boot magic")

    header_version = struct.unpack_from("<I", image, 40)[0]
    header_size = struct.unpack_from("<I", image, 20)[0]
    ramdisk_size = struct.unpack_from("<I", image, 12)[0]
    if header_version != 4 or header_size != HEADER_SIZE:
        raise SystemExit(
            f"expected boot header v4 (size {HEADER_SIZE}), "
            f"got v{header_version} size {header_size}"
        )
    if ramdisk_size != 0:
        raise SystemExit(f"expected empty boot ramdisk, got {ramdisk_size} bytes")

    old_size = struct.unpack_from("<I", image, 8)[0]
    if PAGE_SIZE + len(kernel) > len(image):
        raise SystemExit("new kernel does not fit in the stock boot image")

    struct.pack_into("<I", image, 8, len(kernel))
    image[PAGE_SIZE : PAGE_SIZE + len(kernel)] = kernel

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(bytes(image))

    print(f"kernel_size: {old_size} -> {len(kernel)}")
    print(f"image size : {len(image)} (stock footer kept)")
    print(f"output     : {args.output}")


if __name__ == "__main__":
    main()
