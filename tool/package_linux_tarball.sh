#!/usr/bin/env bash
# Package a `flutter build linux --release` bundle into a portable .tar.gz for
# distributions that do not install the .deb (Fedora, Arch, ...).
#
# Usage:
#   tool/package_linux_tarball.sh --label v0.13 [--bundle build/linux/x64/release/bundle] \
#     [--output dist]
#
# The bundled executable is expected at <bundle>/flutify (see linux/CMakeLists.txt
# BINARY_NAME). The archive unpacks into Flutify-<label>-linux-x64/ with the
# bundle, LICENSE and THIRD_PARTY_NOTICES.md; GTK3 and libmpv (media_kit audio
# backend) must be present on the target system.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
label=""
bundle="$repo/build/linux/x64/release/bundle"
output="$repo/dist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) label="$2"; shift 2 ;;
    --bundle) bundle="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    -h|--help) grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$label" ]]; then
  echo "missing --label" >&2
  exit 2
fi
label_safe="$(printf '%s' "$label" | tr -c 'a-zA-Z0-9._-' '-')"

if [[ ! -x "$bundle/flutify" ]]; then
  echo "missing release build executable: $bundle/flutify" >&2
  exit 1
fi
for required in lib data; do
  if [[ ! -d "$bundle/$required" ]]; then
    echo "missing bundle directory: $bundle/$required" >&2
    exit 1
  fi
done

artifact="Flutify-${label_safe}-linux-x64"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
stage="$(mktemp -d "${TMPDIR:-/tmp}/flutify-tar.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

install_root="$stage/$artifact"
mkdir -p "$install_root"
cp -a "$bundle/." "$install_root/"

# Do not ship a debug kernel if a debug build lingered in the shared assets dir.
for name in kernel_blob.bin vm_snapshot_data isolate_snapshot_data; do
  rm -f "$install_root/data/flutter_assets/$name"
done

cp -f "$repo/LICENSE" "$install_root/LICENSE"
cp -f "$repo/THIRD_PARTY_NOTICES.md" "$install_root/THIRD_PARTY_NOTICES.md"

tarball="$output/${artifact}.tar.gz"
rm -f "$tarball"
tar -czf "$tarball" -C "$stage" "$artifact"
echo "Built $tarball"
