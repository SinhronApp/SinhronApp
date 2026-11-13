#!/usr/bin/env bash
# ADR-058 — put a new Android build on our server, where the installed apps
# find it and update themselves (Settings → About, the banner over Chats).
#
#   bash scripts/android_release.sh                     # builds build/android-release/
#   bash scripts/publish_android.sh --host root@<server> [--dir /opt/sinhron/server/download] [--dry-run]
#
# Order matters — a phone that reads android.json mid-upload must never see
# a manifest pointing at a file that isn't there yet:
#   1. the versioned APKs (sinhron-<version>-<build>-<abi>.apk) go up;
#   2. the stable names the /join page and the install guide link to are
#      refreshed from them (sinhron.apk = arm64-v8a, sinhron-32bit.apk =
#      armeabi-v7a);
#   3. android.json goes up last (written to a temp name, then renamed);
#   4. older versioned APKs are deleted, the newest three builds stay.
# Needs only ssh/scp to the server; the folder is served by Caddy at
# https://<host>/download/ (server/Caddyfile).
set -euo pipefail
cd "$(dirname "$0")/.."

HOST=""
DIR=/opt/sinhron/server/download
DRY=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --host) HOST=$2; shift 2 ;;
    --dir) DIR=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n $HOST ]] || { echo "Usage: $0 --host user@server [--dir $DIR] [--dry-run]" >&2; exit 2; }

rel=build/android-release
[[ -f $rel/android.json ]] || { echo "No $rel/android.json — run scripts/android_release.sh first." >&2; exit 1; }
shopt -s nullglob
apks=("$rel"/sinhron-*.apk)
[[ ${#apks[@]} -gt 0 ]] || { echo "No APKs in $rel" >&2; exit 1; }
version=$(python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m["version"], m["build"])' "$rel/android.json")
echo "Publishing Sinhron $version to $HOST:$DIR"

run() {
  if [[ -n $DRY ]]; then echo "[dry-run] $(printf '%q ' "$@")"; else "$@"; fi
}

# Status 183 — a flaky link dropped a 175 MB scp halfway ("lost
# connection") and a second one hung. rsync resumes a broken file
# and gives up on a stalled link (--timeout); five tries. The broken part
# waits next to the folder, not in it (security review 2026-11,
# deploy-deps:18): with plain --partial a cut-off APK sat under its final
# name at /download/ until the next try.
[[ $DIR == /* ]] || { echo "--dir must be an absolute path" >&2; exit 2; }
upload() {
  local i
  for i in 1 2 3 4 5; do
    if run rsync --partial-dir="$(dirname "$DIR")/.download-partial" --timeout=60 "$@" "$HOST:$DIR/"; then return 0; fi
    echo "Upload broke off (try $i) — resuming…" >&2
    sleep 10
  done
  echo "Upload failed after 5 tries" >&2
  return 1
}
upload "${apks[@]}"
run scp -q "$rel/android.json" "$HOST:$DIR/android.json.new"
# Remote part: stable copies, the manifest swap, cleanup. Names come from
# the files we just built, so nothing here depends on what else is there.
arm64="" arm32=""
for f in "$rel"/sinhron-*-arm64-v8a.apk; do arm64=$(basename "$f"); done
for f in "$rel"/sinhron-*-armeabi-v7a.apk; do arm32=$(basename "$f"); done
remote=$(cat <<EOF
set -eu
cd $(printf '%q' "$DIR")
chmod 644 sinhron-*.apk android.json.new
[ -n $(printf '%q' "$arm64") ] && cp -f $(printf '%q' "$arm64") sinhron.apk.new && mv -f sinhron.apk.new sinhron.apk
[ -n $(printf '%q' "$arm32") ] && cp -f $(printf '%q' "$arm32") sinhron-32bit.apk.new && mv -f sinhron-32bit.apk.new sinhron-32bit.apk
mv -f android.json.new android.json
# Keep the newest three builds' versioned files (a phone mid-download keeps its file).
ls sinhron-*-*-*.apk 2>/dev/null | sed -n 's/^sinhron-[^-]*-\([0-9]*\)-.*/\1/p' | sort -un | head -n -3 | while read -r b; do rm -f sinhron-*-"\$b"-*.apk; done
ls -l
EOF
)
run ssh "$HOST" "$remote"
echo "Done. Phones see it at https://<host>/download/android.json within a few hours (or Settings → About → Check for updates)."
