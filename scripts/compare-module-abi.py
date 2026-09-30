#!/usr/bin/env python3
"""Compare stock Android module version CRCs against a new kernel build.

Checks every `__versions` entry of the given modules against the symbol CRCs
exported by a freshly built kernel (Module.symvers):

    compare-module-abi.py out/Module.symvers path/to/modules/

Requires: pip install pyelftools

Note: passing this check only proves ABI-level compatibility. It does *not*
prove runtime behaviour -- modules can still be rejected by kernel policy
(see docs/01-root-cause.md, section 1).
"""

from __future__ import annotations

import argparse
import json
import struct
from collections import Counter, defaultdict
from pathlib import Path

from elftools.elf.elffile import ELFFile


def load_symvers(path: Path) -> dict[str, int]:
    result: dict[str, int] = {}
    for line in path.read_text().splitlines():
        fields = line.split()
        if len(fields) >= 2:
            result[fields[1]] = int(fields[0], 16)
    return result


def module_info(path: Path) -> tuple[dict[str, int], set[str]]:
    with path.open("rb") as handle:
        elf = ELFFile(handle)
        versions_section = elf.get_section_by_name("__versions")
        versions: dict[str, int] = {}
        if versions_section is not None:
            data = versions_section.data()
            if len(data) % 64:
                raise ValueError(f"{path}: unexpected __versions size {len(data)}")
            for offset in range(0, len(data), 64):
                crc = struct.unpack_from("<Q", data, offset)[0]
                name = data[offset + 8 : offset + 64].split(b"\0", 1)[0].decode()
                versions[name] = crc

        exports: set[str] = set()
        symbols = elf.get_section_by_name(".symtab")
        if symbols is not None:
            for symbol in symbols.iter_symbols():
                if symbol.name.startswith("__ksymtab_"):
                    exports.add(symbol.name.removeprefix("__ksymtab_"))
        return versions, exports


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("symvers", type=Path)
    parser.add_argument("module_dirs", nargs="+", type=Path)
    args = parser.parse_args()

    kernel = load_symvers(args.symvers)
    modules: list[Path] = []
    for directory in args.module_dirs:
        modules.extend(sorted(directory.rglob("*.ko")))

    module_versions: dict[Path, dict[str, int]] = {}
    module_exports: set[str] = set()
    for path in modules:
        versions, exports = module_info(path)
        module_versions[path] = versions
        module_exports.update(exports)

    matches = Counter()
    mismatches: dict[str, dict] = {}
    unresolved = defaultdict(list)
    vendor_resolved = Counter()
    module_layout = Counter()

    for path, versions in module_versions.items():
        for symbol, stock_crc in versions.items():
            if symbol == "module_layout":
                module_layout[f"0x{stock_crc:08x}"] += 1
            if symbol in kernel:
                if stock_crc == kernel[symbol]:
                    matches[symbol] += 1
                else:
                    record = mismatches.setdefault(
                        symbol,
                        {
                            "stock_crc": f"0x{stock_crc:08x}",
                            "new_crc": f"0x{kernel[symbol]:08x}",
                            "modules": [],
                        },
                    )
                    record["modules"].append(str(path))
            elif symbol in module_exports:
                vendor_resolved[symbol] += 1
            else:
                unresolved[symbol].append(str(path))

    report = {
        "module_count": len(modules),
        "new_kernel_export_count": len(kernel),
        "stock_module_export_count": len(module_exports),
        "matched_symbol_count": len(matches),
        "matched_reference_count": sum(matches.values()),
        "mismatched_symbol_count": len(mismatches),
        "unresolved_symbol_count": len(unresolved),
        "vendor_resolved_symbol_count": len(vendor_resolved),
        "module_layout_crcs": dict(module_layout),
        "new_module_layout_crc": (
            f"0x{kernel['module_layout']:08x}" if "module_layout" in kernel else None
        ),
        "mismatches": mismatches,
        "unresolved": dict(sorted(unresolved.items())),
    }
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
