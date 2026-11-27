#!/usr/bin/env bash
# Publishes a release to a synced folder people update from (a OneDrive folder named
# herdr-mac, shared with them):
#   HERDR_MAC_RELEASES=~/Library/CloudStorage/OneDrive-<org>/herdr-mac scripts/publish.sh "release notes"
# (or set HERDR_MAC_RELEASES in scripts/local.env, which isn't committed).
# Writes HerdrMac.zip first and version.json last, with the zip's size and SHA-256, so an
# app never offers a zip that hasn't finished syncing.
set -euo pipefail
NOTES=${1:?usage: scripts/publish.sh "release notes"}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$ROOT/scripts/local.env" ] && . "$ROOT/scripts/local.env"
DEST=${HERDR_MAC_RELEASES:?set HERDR_MAC_RELEASES to the synced release folder (see scripts/local.env.example)}
cd "$ROOT"
BUILD=$(date +%Y%m%d%H%M)
BUILD=$BUILD scripts/bundle.sh release >/dev/null
TMP=$(mktemp -d -t herdr-mac-publish.XXXXXX)
ditto -c -k --sequesterRsrc --keepParent build/HerdrMac.app "$TMP/HerdrMac.zip"
SIZE=$(stat -f %z "$TMP/HerdrMac.zip")
SHA=$(shasum -a 256 "$TMP/HerdrMac.zip" | cut -d' ' -f1)
mkdir -p "$DEST"
cp "$TMP/HerdrMac.zip" "$DEST/HerdrMac.zip.part" && mv -f "$DEST/HerdrMac.zip.part" "$DEST/HerdrMac.zip"
python3 -I -c 'import json,sys; print(json.dumps({"version": sys.argv[1], "build": int(sys.argv[2]), "size": int(sys.argv[3]), "sha256": sys.argv[4], "notes": sys.argv[5]}, indent=2))' \
  "$(cat VERSION)" "$BUILD" "$SIZE" "$SHA" "$NOTES" > "$TMP/version.json"
cp "$TMP/version.json" "$DEST/version.json.part" && mv -f "$DEST/version.json.part" "$DEST/version.json"
echo "published $(cat VERSION) ($BUILD) to $DEST"
