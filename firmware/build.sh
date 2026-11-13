#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Builds the AArch64 UEFI firmware (EDK2 ArmVirtQemu) for the WindowsiOS engine.
#
# It is the firmware QEMU ships as edk2-aarch64-code.fd ("edk2-stable202408-prebuilt.qemu.org":
# same EDK2 release, DEBUG target, GCC5 toolchain, the -D options and PCDs of QEMU 9.2's
# roms/edk2-build.config for build.armvirt.aa64), plus one change:
# firmware/edk2-ramfb-host-resolution.patch, which lets the host choose the screen resolution.
# Without that request the firmware behaves like QEMU's (800x600), so it also fits existing setups.
#
#   firmware/build.sh OUT_DIR       Ubuntu with sudo; installs the cross compiler it needs.
#                                   Writes OUT_DIR/code.fd (64 MiB) and OUT_DIR/code.fd.sha256.
set -euo pipefail
OUT="$(mkdir -p "$1" && cd "$1" && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
TAG=edk2-stable202408

sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  gcc-aarch64-linux-gnu acpica-tools uuid-dev nasm build-essential git >/dev/null
aarch64-linux-gnu-gcc --version | head -n 1
python3 --version

W="$(mktemp -d)"
git clone -q --depth 1 --branch "$TAG" https://github.com/tianocore/edk2.git "$W/edk2"
cd "$W/edk2"
# Everything the firmware build uses (the unit-test-only submodules are left out).
git submodule update -q --init --depth 1 \
  CryptoPkg/Library/OpensslLib/openssl \
  CryptoPkg/Library/MbedTlsLib/mbedtls \
  ArmPkg/Library/ArmSoftFloatLib/berkeley-softfloat-3 \
  MdeModulePkg/Universal/RegularExpressionDxe/oniguruma \
  MdeModulePkg/Library/BrotliCustomDecompressLib/brotli \
  BaseTools/Source/C/BrotliCompress/brotli \
  RedfishPkg/Library/JsonLib/jansson \
  MdePkg/Library/BaseFdtLib/libfdt \
  MdePkg/Library/MipiSysTLib/mipisyst \
  SecurityPkg/DeviceSecurity/SpdmLib/libspdm
git apply --verbose "$HERE/edk2-ramfb-host-resolution.patch"

export GCC5_AARCH64_PREFIX=aarch64-linux-gnu-
export PYTHON_COMMAND=python3
make -s -C BaseTools -j"$(nproc)" >/dev/null
# edksetup.sh is not written for "set -eu", and it parses the caller's arguments: clear them.
set --
set +eu
# shellcheck disable=SC1091
source ./edksetup.sh >/dev/null
set -eu
command -v build

build -q -a AARCH64 -t GCC5 -b DEBUG -p ArmVirtPkg/ArmVirtQemu.dsc -n "$(nproc)" \
  -D NETWORK_HTTP_BOOT_ENABLE=TRUE -D NETWORK_IP6_ENABLE=TRUE -D NETWORK_TLS_ENABLE=TRUE \
  -D NETWORK_ISCSI_ENABLE=TRUE -D NETWORK_ALLOW_HTTP_CONNECTIONS=TRUE \
  -D TPM2_ENABLE=TRUE -D TPM2_CONFIG_ENABLE=TRUE -D TPM1_ENABLE=TRUE \
  -D CAVIUM_ERRATUM_27456=TRUE -D DEBUG_PRINT_ERROR_LEVEL=0x80000000 \
  --pcd PcdDxeNxMemoryProtectionPolicy=0xC000000000007FD1 \
  --pcd PcdUninstallMemAttrProtocol=TRUE \
  --pcd 'PcdFirmwareVersionString=Ledk2-stable202408-winios-ramfb\0'

cp Build/ArmVirtQemu-AARCH64/DEBUG_GCC5/FV/QEMU_EFI.fd "$OUT/code.fd"
truncate -s 64M "$OUT/code.fd"
( cd "$OUT" && sha256sum code.fd | tee code.fd.sha256 )
ls -l "$OUT"
