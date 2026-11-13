#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Split a large file into parts the iOS app joins back together.

    split_parts.py FILE PART_MB OUT_DIR

Writes OUT_DIR/NAME.001 ... NAME.NNN plus the manifest OUT_DIR/NAME.parts:

    parts=N
    bytes=TOTAL
    sha256.001=HEX
    ...

Each part stays under GitHub's 2 GiB per-file release limit when PART_MB is 1900. The app joins
the parts into NAME once all of them are in Machines/Win11, checking every part's SHA-256.
"""

import hashlib
import sys
from pathlib import Path


def main():
    src, part_mb, out_dir = Path(sys.argv[1]), int(sys.argv[2]), Path(sys.argv[3])
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob(src.name + ".*"):
        old.unlink()
    part_bytes = part_mb << 20
    total = src.stat().st_size
    lines = []
    count = 0
    with open(src, "rb") as f:
        while True:
            chunk = f.read(min(8 << 20, part_bytes))
            if not chunk:
                break
            count += 1
            digest = hashlib.sha256()
            written = 0
            with open(out_dir / f"{src.name}.{count:03d}", "wb") as part:
                while chunk:
                    part.write(chunk)
                    digest.update(chunk)
                    written += len(chunk)
                    if written >= part_bytes:
                        break
                    chunk = f.read(min(8 << 20, part_bytes - written))
            lines.append(f"sha256.{count:03d}={digest.hexdigest()}")
    manifest = [f"parts={count}", f"bytes={total}"] + lines
    (out_dir / f"{src.name}.parts").write_text("\n".join(manifest) + "\n", encoding="utf-8")
    print(f"{src.name}: {total} bytes -> {count} part(s) of up to {part_mb} MB", flush=True)
    for p in sorted(out_dir.glob(src.name + ".*")):
        print(f"  {p.name:28s} {p.stat().st_size:>14d} bytes", flush=True)


if __name__ == "__main__":
    main()
