#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Find, and optionally download, Microsoft's retail Windows 11 Arm64 ESD.

Reads the public catalog (products.cab) that Microsoft's own Media Creation Tool reads, so the
ESD comes straight from Microsoft's servers and is checked against the catalog's checksum.

  --list                 Print the Arm64 entries for the language. Metadata only: nothing is
                         downloaded besides the small catalog itself.
  --download DIR         Download the matching consumer ESD into DIR and verify it.
  --build-prefix 26300   Require this build family (26300 = 26H2). Exit code 3 when the catalog
                         offers no such ESD.
  --lang en-us           Language code (default en-us).

Needs: curl, and cabextract or bsdtar (macOS tar).
"""

import argparse
import hashlib
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

CATALOG_URL = "https://go.microsoft.com/fwlink/?LinkId=2156292"


def fetch_catalog(tmp: Path) -> Path:
    cab = tmp / "products.cab"
    subprocess.run(["curl", "-fsSL", "--retry", "3", "-o", str(cab), CATALOG_URL], check=True)
    if shutil.which("cabextract"):
        subprocess.run(["cabextract", "-q", "-d", str(tmp), str(cab)], check=True)
    else:
        subprocess.run(["tar", "-xf", str(cab), "-C", str(tmp)], check=True)  # bsdtar (macOS) reads .cab
    xmls = sorted(tmp.glob("*.xml"))
    if not xmls:
        sys.exit("products.cab held no XML catalog")
    return xmls[0]


def catalog_files(xml_path: Path):
    """Every <File> entry as a dict of its child elements."""
    root = ET.parse(xml_path).getroot()
    out = []
    for node in root.iter():
        if node.tag.split("}")[-1] != "File":
            continue
        entry = {child.tag.split("}")[-1]: (child.text or "").strip() for child in node}
        if entry.get("FileName") and entry.get("FilePath"):
            out.append(entry)
    return out


def arm64_esds(entries, lang):
    """Unique Arm64 ESDs for the language, each with the list of editions it carries."""
    by_name = {}
    for e in entries:
        if e.get("Architecture", "").upper() != "ARM64":
            continue
        if e.get("LanguageCode", "").lower() != lang.lower():
            continue
        slot = by_name.setdefault(e["FileName"], dict(e, Editions=[]))
        if e.get("Edition") and e["Edition"] not in slot["Editions"]:
            slot["Editions"].append(e["Edition"])
    return sorted(by_name.values(), key=lambda e: e["FileName"])


def pick(esds, build_prefix):
    """The consumer retail ESD that carries Professional, newest file name first."""
    wanted = [e for e in esds
              if "CLIENTCONSUMER_RET" in e["FileName"].upper() and "Professional" in e["Editions"]]
    if build_prefix:
        wanted = [e for e in wanted if e["FileName"].startswith(build_prefix + ".")]
    return sorted(wanted, key=lambda e: e["FileName"])[-1] if wanted else None


def file_digest(path: Path, algo: str) -> str:
    h = hashlib.new(algo)
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--download", metavar="DIR")
    ap.add_argument("--build-prefix", default="")
    ap.add_argument("--lang", default="en-us")
    args = ap.parse_args()

    with tempfile.TemporaryDirectory() as t:
        entries = catalog_files(fetch_catalog(Path(t)))
    esds = arm64_esds(entries, args.lang)
    print(f"Catalog: {len(entries)} file entries, {len(esds)} Arm64 ESD(s) for {args.lang}", flush=True)
    for e in esds:
        size_gb = int(e.get("Size") or 0) / (1 << 30)
        print(f"  {e['FileName']}")
        print(f"      size {size_gb:.2f} GB | editions: {', '.join(e['Editions']) or '?'}")
        print(f"      checksum fields: {', '.join(k for k in ('Sha1', 'Sha256') if e.get(k)) or 'none'}"
              f" | host: {e['FilePath'].split('/')[2] if '//' in e['FilePath'] else '?'}")

    chosen = pick(esds, args.build_prefix)
    if chosen is None:
        print(f"No consumer Arm64 ESD with Professional"
              f"{' for build ' + args.build_prefix if args.build_prefix else ''} in the catalog.", flush=True)
        sys.exit(3)
    print(f"Selected: {chosen['FileName']}", flush=True)
    if not args.download:
        return

    dest_dir = Path(args.download)
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / chosen["FileName"]
    subprocess.run(["curl", "-fL", "--retry", "5", "--retry-delay", "5", "-C", "-", "-sS",
                    "-o", str(dest), chosen["FilePath"]], check=True)
    size = dest.stat().st_size
    if chosen.get("Size") and int(chosen["Size"]) != size:
        sys.exit(f"Size mismatch: catalog {chosen['Size']}, downloaded {size}")
    for field, algo in (("Sha256", "sha256"), ("Sha1", "sha1")):
        if chosen.get(field):
            got = file_digest(dest, algo)
            if got.lower() != chosen[field].lower():
                sys.exit(f"{field} mismatch for {dest.name}")
            print(f"{field} verified for {dest.name} ({size} bytes)", flush=True)
            break
    else:
        print(f"WARNING: catalog gave no checksum for {dest.name}", flush=True)
    print(f"ESD_PATH={dest}", flush=True)


if __name__ == "__main__":
    main()
