#!/usr/bin/env bash
# Put the Android build from a GitHub release on this server (no Mac needed).
#
#   sudo bash server/scripts/fetch_android.sh v0.12.0-2026111318
#
# The release is made by .github/workflows/release.yml (APKs + android.json).
# Same result as client_flutter/scripts/publish_android.sh from a Mac:
# server/download/ gets the APKs, sinhron.apk / sinhron-32bit.apk and,
# last, android.json — phones see the update from that moment.
set -euo pipefail
TAG=${1:?Usage: $0 <release tag, e.g. v0.12.0-2026111318>}
[[ $TAG =~ ^v[0-9.]+-[0-9]+$ ]] || { echo "Tag looks wrong: $TAG" >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DIR=${DIR:-$ROOT/server/download}
REPO=$(git -C "$ROOT" remote get-url origin)
REPO=${REPO%.git}
[[ $REPO == https://github.com/* ]] || { echo "origin is not a GitHub https address: $REPO" >&2; exit 1; }
BASE=$REPO/releases/download/$TAG
TMP=$(mktemp -d "$DIR/../.fetch-XXXXXX")
trap 'rm -rf "$TMP"' EXIT

curl -fsSL --retry 5 -o "$TMP/android.json" "$BASE/android.json"
# name sha256 per line; only plain file names (as android_release.sh writes them)
python3 -I - "$TMP/android.json" >"$TMP/list" <<'PY'
import json, re, sys
m = json.load(open(sys.argv[1]))
for abi, a in m["apks"].items():
    assert re.fullmatch(r"sinhron-[0-9.]+-[0-9]+-[a-z0-9_-]+\.apk", a["url"]), a["url"]
    print(abi, a["url"], a["sha256"])
PY
while read -r abi name sha; do
  echo "Downloading $name"
  curl -fsSL --retry 5 -o "$TMP/$name" "$BASE/$name"
  echo "$sha  $TMP/$name" | sha256sum -c --quiet - || { echo "Checksum mismatch: $name" >&2; exit 1; }
done <"$TMP/list"

chmod 644 "$TMP"/*
while read -r abi name sha; do
  mv -f "$TMP/$name" "$DIR/$name"
  case $abi in
    arm64-v8a) cp -f "$DIR/$name" "$DIR/sinhron.apk.new" && mv -f "$DIR/sinhron.apk.new" "$DIR/sinhron.apk" ;;
    armeabi-v7a) cp -f "$DIR/$name" "$DIR/sinhron-32bit.apk.new" && mv -f "$DIR/sinhron-32bit.apk.new" "$DIR/sinhron-32bit.apk" ;;
  esac
done <"$TMP/list"
mv -f "$TMP/android.json" "$DIR/android.json"
# keep the last three builds' APKs
cd "$DIR"
ls sinhron-*-*-*.apk 2>/dev/null | sed -n 's/^sinhron-[^-]*-\([0-9]*\)-.*/\1/p' | sort -un | head -n -3 |
  while read -r b; do rm -f sinhron-*-"$b"-*.apk; done
ls -l "$DIR"
echo "Done: $(python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m["version"], m["build"])' "$DIR/android.json") — phones see it within a few hours (or Settings → About → Check for updates)."
