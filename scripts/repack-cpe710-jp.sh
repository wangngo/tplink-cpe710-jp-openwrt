#!/usr/bin/env bash
# Byte-identical round-trip verifier & JP support-list repacker for TP-Link CPE710 v2
#
# Given an official (or ASU-built) OpenWrt factory.bin for `tplink_cpe710-v2`:
# 1. Compiles both unpatched (`safeloader-orig`) and JP-patched (`safeloader-jp`) from
#    OpenWrt `firmware-utils` if not already built.
# 2. Extracts `os-image`, `file-system`, and `soft-version` from the input factory.bin.
# 3. Parses the exact BCD build date (`SOURCE_DATE_EPOCH`) and revision (`-V r<rev>`)
#    from `soft-version`, strips the 4-byte `deadc0de` JFFS2 EOF marker from `file-system`,
#    and repacks with `safeloader-orig`.
# 4. Verifies that the unpatched repack is 100% BYTE-IDENTICAL (`cmp -s`) to the input
#    factory.bin (safety gate).
# 5. Repacks with `safeloader-jp` to produce `<output-jp.bin>` containing:
#      CPE710(TP-LINK|JP|AC866-5|4A500000):2.0
#
# Usage:
#   ./scripts/repack-cpe710-jp.sh <input-openwrt-factory.bin> [output-factory-jp.bin]

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <input-openwrt-factory.bin> [output-factory-jp.bin]" >&2
  exit 1
fi

INPUT_BIN="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
OUTPUT_BIN="${2:-${INPUT_BIN%.bin}-jp.bin}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH_FILE="$REPO_ROOT/patches/safeloader-cpe710v2-jp.patch"
BUILD_DIR="${BUILD_DIR:-$(mktemp -d)}"
trap '[[ "${KEEP_BUILD_DIR:-0}" == "1" ]] || rm -rf "$BUILD_DIR"' EXIT

if [[ ! -f "$INPUT_BIN" ]]; then
  echo "[!] Input file not found: $INPUT_BIN" >&2
  exit 1
fi

SAFELOADER_ORIG="${SAFELOADER_ORIG:-$BUILD_DIR/safeloader-orig}"
SAFELOADER_JP="${SAFELOADER_JP:-$BUILD_DIR/safeloader-jp}"

if [[ ! -x "$SAFELOADER_ORIG" || ! -x "$SAFELOADER_JP" ]]; then
  echo "[*] Cloning OpenWrt firmware-utils and building safeloader-orig + safeloader-jp..."
  git clone --depth 1 https://git.openwrt.org/project/firmware-utils.git "$BUILD_DIR/firmware-utils" >/dev/null 2>&1
  cc -O2 "$BUILD_DIR/firmware-utils/src/tplink-safeloader.c" "$BUILD_DIR/firmware-utils/src/md5.c" -o "$SAFELOADER_ORIG"
  patch -d "$BUILD_DIR/firmware-utils" -p1 < "$PATCH_FILE" >/dev/null
  cc -O2 "$BUILD_DIR/firmware-utils/src/tplink-safeloader.c" "$BUILD_DIR/firmware-utils/src/md5.c" -o "$SAFELOADER_JP"
fi

mkdir -p "$BUILD_DIR/extracted"
echo "[*] Extracting partitions from $(basename "$INPUT_BIN")..."
(cd "$BUILD_DIR/extracted" && "$SAFELOADER_ORIG" -x "$INPUT_BIN" -d "$BUILD_DIR/extracted" >/dev/null)

read -r SOURCE_DATE_EPOCH REV_STR < <(python3 - "$BUILD_DIR/extracted/soft-version" "$BUILD_DIR/extracted/file-system" "$BUILD_DIR/rootfs.noeof" << 'PY'
import datetime, struct, sys

sv_path, fs_path, noeof_path = sys.argv[1], sys.argv[2], sys.argv[3]
sv = open(sv_path, "rb").read()
if len(sv) < 20:
    raise SystemExit(f"[!] Unexpected soft-version length: {len(sv)}")

bcd_date = sv[12:16].hex()
rev_num = struct.unpack(">I", sv[16:20])[0]
dt = datetime.datetime.strptime(bcd_date, "%Y%m%d").replace(tzinfo=datetime.timezone.utc)
epoch = int(dt.timestamp())

fs = open(fs_path, "rb").read()
if fs[-4:] != b"\xde\xad\xc0\xde":
    raise SystemExit(f"[!] Expected deadc0de trailer at end of file-system, found {fs[-4:].hex()}")
open(noeof_path, "wb").write(fs[:-4])
print(f"{epoch} r{rev_num}")
PY
)

export SOURCE_DATE_EPOCH
echo "[*] Parsed metadata from soft-version: SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH, revision=$REV_STR"

echo "[*] Safety gate: verifying byte-identical round-trip with unpatched tplink-safeloader..."
"$SAFELOADER_ORIG" -B CPE710V2 \
  -k "$BUILD_DIR/extracted/os-image" \
  -r "$BUILD_DIR/rootfs.noeof" \
  -V "$REV_STR" -j \
  -o "$BUILD_DIR/rebuilt-orig.bin" >/dev/null

if ! cmp -s "$INPUT_BIN" "$BUILD_DIR/rebuilt-orig.bin"; then
  echo "[!] ERROR: Unpatched round-trip image differs from input! Aborting." >&2
  exit 1
fi
echo "[+] Round-trip verification PASSED (100% byte-identical to original)."

echo "[*] Building JP-compatible factory image..."
"$SAFELOADER_JP" -B CPE710V2 \
  -k "$BUILD_DIR/extracted/os-image" \
  -r "$BUILD_DIR/rootfs.noeof" \
  -V "$REV_STR" -j \
  -o "$OUTPUT_BIN" >/dev/null

mkdir -p "$BUILD_DIR/verify-jp"
"$SAFELOADER_JP" -x "$OUTPUT_BIN" -d "$BUILD_DIR/verify-jp" >/dev/null
echo "[+] Created: $OUTPUT_BIN"
echo "[+] Verified support-list inside $(basename "$OUTPUT_BIN"):"
cat "$BUILD_DIR/verify-jp/support-list"
