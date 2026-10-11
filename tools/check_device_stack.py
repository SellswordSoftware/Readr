#!/usr/bin/env python3
"""Flag large ARM local stack reservations, including generated stdlib code.

This is a per-function guard, not a bound on complete call chains or SDK stack
use. Run after rebuilding the device ELF; hardware testing is still required.
"""

import argparse
import re
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("elf", nargs="?", default="zig-out/pdx_source_dir/pdex.elf")
    parser.add_argument("--disassembly", type=Path, help="inspect saved objdump text")
    parser.add_argument("--max-local-bytes", type=int, default=2048)
    args = parser.parse_args()
    assembly = (
        args.disassembly.read_text()
        if args.disassembly
        else subprocess.check_output(["arm-none-eabi-objdump", "-d", args.elf], text=True)
    )
    functions = list(re.finditer(r"^[0-9a-fA-F]+ <([^>]+)>:\s*$", assembly, re.M))
    reservations = []
    unknown = []
    for index, match in enumerate(functions):
        end = functions[index + 1].start() if index + 1 < len(functions) else len(assembly)
        body = assembly[match.end():end]
        # Sum all immediate adjustments, including split large-frame prologues.
        # Multiple paths can overestimate, which is safe for this guard.
        adjustments = re.findall(r"\bsub(?:\.w)?\s+sp,\s*(?:sp,\s*)?([^;\n]+)", body)
        total = 0
        for adjustment in adjustments:
            literal = re.fullmatch(r"#(\d+)\s*", adjustment)
            if literal:
                total += int(literal.group(1))
            else:
                unknown.append((match.group(1), adjustment.strip()))
        reservations.append((total, match.group(1)))
    if not functions:
        raise SystemExit("FAIL: no ARM functions found")
    largest = sorted(reservations, reverse=True)[:5]
    for size, name in largest:
        print(f"{size:>6} local bytes: {name}")
    failures = [(size, name) for size, name in reservations if size > args.max_local_bytes]
    for size, name in failures:
        print(f"FAIL: {name} reserves {size} local bytes (limit {args.max_local_bytes})")
    for name, adjustment in unknown:
        print(f"FAIL: inspect dynamic stack adjustment in {name}: {adjustment}")
    if failures or unknown:
        raise SystemExit(1)
    print(f"PASS: {len(functions)} functions checked; local reservations <= {args.max_local_bytes} bytes")


if __name__ == "__main__":
    main()
