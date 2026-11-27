#!/usr/bin/env bash
# Builds GhosttyKit.xcframework into Vendor/ from Ghostty's latest release.
# Needs the Zig version that release names (v1.4.0: 0.17; Zig 0.15 can't link against the
# macOS 27 SDK) and Xcode's Metal Toolchain.
set -euo pipefail
GHOSTTY_TAG=v1.4.0
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$ROOT/scripts/local.env" ] && . "$ROOT/scripts/local.env"
# Ghostty's source goes in .deps/ (not committed) unless GHOSTTY_SRC says otherwise; ZIG is
# the zig to build it with (Zig 0.17 for v1.4.0), else `zig` on PATH.
SRC=${GHOSTTY_SRC:-$ROOT/.deps/ghostty}
ZIG=${ZIG:-zig}
if [ ! -d "$SRC/.git" ]; then git clone --filter=blob:none https://github.com/ghostty-org/ghostty "$SRC"; fi
git -C "$SRC" fetch --depth 1 origin tag "$GHOSTTY_TAG"
git -C "$SRC" checkout -q "$GHOSTTY_TAG"
(cd "$SRC" && "$ZIG" build -Doptimize=ReleaseFast -Demit-xcframework=true -Dxcframework-target=native -Demit-macos-app=false)
rm -rf "$ROOT/Vendor/GhosttyKit.xcframework"
mkdir -p "$ROOT/Vendor"
cp -R "$SRC/macos/GhosttyKit.xcframework" "$ROOT/Vendor/"
echo "GhosttyKit at $ROOT/Vendor/GhosttyKit.xcframework"
