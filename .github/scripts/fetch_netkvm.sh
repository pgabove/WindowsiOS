#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Puts the virtio-win NetKVM network driver for Windows 11 on Arm into work/drivers/NetKVM.
#
# Windows on Arm loads only kernel drivers that Microsoft signed (WHQL or attestation) unless
# test signing is turned on. The stable virtio-win ISO carries drivers signed by Red Hat, so the
# attestation-signed upstream build is tried first and the ISO is the fallback. The signer of the
# chosen driver's catalog is printed, and written to work/netkvm_source.txt.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
OUT=work/drivers/NetKVM
T="${RUNNER_TEMP:-/tmp}/netkvm"
UPSTREAM=https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/upstream-virtio/
STABLE_ISO=https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso
rm -rf "$T" "$OUT" work/netkvm_source.txt
mkdir -p "$T" "$OUT"

signers() { # certificate subjects in a catalog's signature
  openssl pkcs7 -inform DER -in "$1" -print_certs -noout 2>/dev/null | grep -i '^subject' | sed -E 's/^subject= *//'
}
microsoft_signed() {
  local cat
  for cat in "$1"/*.cat; do
    [ -f "$cat" ] && signers "$cat" | grep -q "Microsoft Windows Hardware Compatibility Publisher" && return 0
  done
  return 1
}
arm64_netkvm_dir() { # the folder holding the Windows 11 Arm64 netkvm.inf under $1
  local inf
  inf="$(find "$1" -iname netkvm.inf 2>/dev/null | grep -i arm64 | grep -iE '/(w11|win11)/' | head -n 1)"
  [ -n "$inf" ] || inf="$(find "$1" -iname netkvm.inf 2>/dev/null | grep -i arm64 | head -n 1)"
  [ -n "$inf" ] && dirname "$inf"
}
take() { # DIR LABEL   (only NetKVM's own files: some builds keep every driver in one folder)
  find "$1" -maxdepth 1 -type f -iname 'netkvm*' -exec cp {} "$OUT"/ \; || return 1
  ls "$OUT"/*.inf >/dev/null 2>&1 || return 1
  chmod u+w "$OUT"/*
  {
    echo "NetKVM: $2 ($(grep -i -m1 '^DriverVer' "$OUT"/netkvm.inf | tr -d '\r'))"
    for cat in "$OUT"/*.cat; do echo "  $(basename "$cat") signed by:"; signers "$cat" | sed 's/^/    /'; done
  } | tee work/netkvm_source.txt
  ls -l "$OUT"
}

# 1. The attestation-signed upstream build (newest).
zip="$(curl -fsSL --retry 3 "$UPSTREAM" | grep -oE 'attestation-virtio-win-prewhql-0\.1-[0-9]+\.zip' | sort -u | sort -t- -k6,6n | tail -n 1)"
if [ -n "$zip" ]; then
  echo "Newest attestation-signed upstream build: $zip"
  if curl -fL --retry 3 -sS -o "$T/$zip" "$UPSTREAM$zip" && mkdir -p "$T/att" && unzip -q "$T/$zip" -d "$T/att"; then
    dir="$(arm64_netkvm_dir "$T/att")"
    if [ -n "$dir" ] && microsoft_signed "$dir"; then
      take "$dir" "$zip, ${dir#"$T"/att/}"
      exit 0
    fi
    echo "::warning::$zip has no Microsoft-signed Arm64 NetKVM (found: ${dir:-none})"
    [ -n "$dir" ] && for cat in "$dir"/*.cat; do signers "$cat"; done
  else
    echo "::warning::could not download or unpack $zip"
  fi
else
  echo "::warning::no attestation-signed build listed at $UPSTREAM"
fi

# 2. Fallback: the stable ISO.
curl -fL --retry 3 -sS -o "$T/virtio-win.iso" "$STABLE_ISO" || { echo "::error::could not download the virtio-win ISO"; exit 1; }
mkdir -p "$T/iso"
hdiutil attach -nobrowse -readonly -mountpoint "$T/iso" "$T/virtio-win.iso" >/dev/null || { echo "::error::could not mount the ISO"; exit 1; }
dir="$(arm64_netkvm_dir "$T/iso")"
if [ -n "$dir" ]; then
  take "$dir" "virtio-win stable ISO, ${dir#"$T"/iso/}"
  microsoft_signed "$OUT" || echo "::warning::the stable ISO's NetKVM is not Microsoft-signed; Windows on Arm may refuse to load it"
fi
hdiutil detach "$T/iso" >/dev/null 2>&1 || true
[ -n "$dir" ] || { echo "::error::no Arm64 NetKVM on the ISO"; exit 1; }
exit 0
