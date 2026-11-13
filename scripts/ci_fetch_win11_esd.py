#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Find, and optionally download, Microsoft's retail Windows 11 Arm64 ESD.

Reads the catalog (products.cab) that Microsoft's own Media Creation Tool reads, so the ESD
comes straight from Microsoft's servers and is checked against the catalog's checksum. Since
25H2 the tool asks Microsoft's update metadata service where the current catalog is; the older
fixed link still serves the 24H2 catalog. Both are read here.

  --list                 Print the Arm64 entries for the language. Metadata only: nothing is
                         downloaded besides the small catalog itself.
  --download DIR         Download the matching consumer ESD into DIR and verify it.
  --build-prefix 26300   Require this build family (26300 = 26H2). Exit code 3 when the catalog
                         offers no such ESD.
  --lang en-us           Language code (default en-us).

Needs: curl, and cabextract or bsdtar (macOS tar).
"""

import argparse
import base64
import hashlib
import json
import shutil
import ssl
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

CATALOG_URL = "https://go.microsoft.com/fwlink/?LinkId=2156292"
# What Media Creation Tool 10.0.26100.7019 asks: "which products.cab is current?"
FE3_SEARCH = "https://fe3.delivery.mp.microsoft.com/UpdateMetadataService/updates/search/v1/bydeviceinfo"
FE3_QUERY = {"Products": "PN=Windows.Products.Cab.amd64&V=0.0.0.0",
             "DeviceAttributes": "DUScan=1;OSVersion=10.0.26100.1"}
# Microsoft's update servers use certificates from Microsoft's own root, which Windows trusts and
# public CA bundles do not. The root and the issuing CA are published on www.microsoft.com, whose
# own certificate comes from a public CA, so they can be fetched and then trusted for this lookup.
MS_CA_URLS = (
    ("https://www.microsoft.com/pkiops/certs/MicRooCerAut2011_2011_03_22.crt",
     "https://www.microsoft.com/pki/certs/MicRooCerAut2011_2011_03_22.crt"),
    ("https://www.microsoft.com/pkiops/certs/Microsoft%20Update%20Secure%20Server%20CA%202.1.crt",),
)


def microsoft_ca_bundle(tmp: Path) -> Path:
    bundle = tmp / "microsoft_ca.pem"
    count = 0
    with open(bundle, "w", encoding="ascii") as out:
        for urls in MS_CA_URLS:
            for url in urls:
                raw = tmp / "ca.crt"
                if subprocess.run(["curl", "-fsSL", "--retry", "2", "-o", str(raw), url]).returncode != 0:
                    continue
                data = raw.read_bytes()
                pem = data.decode("ascii") if b"BEGIN CERTIFICATE" in data else ssl.DER_cert_to_PEM_cert(data)
                out.write(pem if pem.endswith("\n") else pem + "\n")
                print(f"Microsoft CA certificate: {url.rsplit('/', 1)[-1]} "
                      f"(sha256 {hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem)).hexdigest()})", flush=True)
                count += 1
                break
    if not count:
        raise RuntimeError("could not fetch Microsoft's CA certificates from www.microsoft.com")
    return bundle


def curl_microsoft(args, tmp: Path, **kwargs):
    """curl with the system's trusted CAs first, then with Microsoft's own CA. Never unverified."""
    first = subprocess.run(["curl", *args], **kwargs)
    if first.returncode not in (35, 51, 58, 59, 60, 77, 83, 90, 91):  # anything but a certificate problem
        return first
    bundle = tmp / "microsoft_ca.pem"
    if not bundle.exists():
        microsoft_ca_bundle(tmp)
    return subprocess.run(["curl", "--cacert", str(bundle), *args], **kwargs)


def extract_catalog(cab: Path, tmp: Path) -> Path:
    tmp.mkdir(parents=True, exist_ok=True)
    if shutil.which("cabextract"):
        subprocess.run(["cabextract", "-q", "-d", str(tmp), str(cab)], check=True)
    else:
        subprocess.run(["tar", "-xf", str(cab), "-C", str(tmp)], check=True)  # bsdtar (macOS) reads .cab
    xmls = sorted(tmp.glob("*.xml"))
    if not xmls:
        raise RuntimeError("products.cab held no XML catalog")
    return xmls[0]


def fetch_catalog(tmp: Path) -> Path:
    """The catalog behind the fixed link (24H2 and older media)."""
    cab = tmp / "products.cab"
    subprocess.run(["curl", "-fsSL", "--retry", "3", "-o", str(cab), CATALOG_URL], check=True)
    return extract_catalog(cab, tmp / "x")


def digest_matches(path: Path, digest: str):
    """True/False when the digest is a SHA-256 or SHA-1 in base64 or hex; None when it is neither."""
    forms = []
    try:
        forms.append(base64.b64decode(digest, validate=True))
    except Exception:
        pass
    try:
        forms.append(bytes.fromhex(digest))
    except ValueError:
        pass
    for raw in forms:
        algo = {32: "sha256", 20: "sha1"}.get(len(raw))
        if algo:
            return hashlib.new(algo, path.read_bytes()).digest() == raw
    return None


def fetch_catalog_fe3(tmp: Path) -> Path:
    """The current catalog, located through Microsoft's update metadata service."""
    done = curl_microsoft(
        ["-sS", "--retry", "3", "-X", "POST", "-H", "Content-Type: application/json",
         "-H", "Accept: application/json", "--data", json.dumps(FE3_QUERY), FE3_SEARCH],
        tmp, capture_output=True, text=True)
    if done.returncode != 0:
        raise RuntimeError(f"metadata service request failed (curl {done.returncode}): {done.stderr.strip()[:300]}")
    reply = done.stdout
    try:
        data = json.loads(reply)
    except ValueError:
        raise RuntimeError(f"metadata service did not answer with JSON: {reply[:600]!r}")
    found = None
    for entry in data if isinstance(data, list) else [data]:
        if not isinstance(entry, dict):
            continue
        files = entry.get("FileLocations") or []
        for f in files if isinstance(files, list) else [files]:
            if isinstance(f, dict) and str(f.get("FileName", "")).lower().endswith(".cab") and f.get("Url"):
                found = found or (entry, f)
    if not found:
        raise RuntimeError(f"metadata service listed no products.cab: {reply[:600]!r}")
    entry, f = found
    host = f["Url"].split("/")[2] if "//" in f["Url"] else "?"
    print(f"Metadata service: update {entry.get('UpdateIds')}, {f.get('FileName')} {f.get('Size')} bytes"
          f" from {host}", flush=True)
    if not host.endswith(".microsoft.com"):
        raise RuntimeError(f"unexpected catalog host {host}")
    cab = tmp / "products_fe3.cab"
    got = curl_microsoft(["-fsSL", "--retry", "3", "-o", str(cab), f["Url"]], tmp, capture_output=True, text=True)
    if got.returncode != 0:
        raise RuntimeError(f"products.cab download failed (curl {got.returncode}): {got.stderr.strip()[:300]}")
    ok = digest_matches(cab, str(f.get("Digest") or ""))
    if ok is False:
        raise RuntimeError("products.cab does not match the digest the metadata service gave")
    print(f"products.cab: {cab.stat().st_size} bytes, digest "
          f"{'verified' if ok else 'not checked (format ' + repr(str(f.get('Digest'))[:12]) + ')'}", flush=True)
    return extract_catalog(cab, tmp / "x_fe3")


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

    entries = []
    with tempfile.TemporaryDirectory() as t:
        for name, fetch in (("metadata service", fetch_catalog_fe3), ("fixed link", fetch_catalog)):
            try:
                got = catalog_files(fetch(Path(t)))
                print(f"Catalog via {name}: {len(got)} file entries", flush=True)
                entries += got
            except Exception as exc:
                print(f"Catalog via {name}: failed ({exc})", flush=True)
    if not entries:
        sys.exit("No catalog could be read")
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
