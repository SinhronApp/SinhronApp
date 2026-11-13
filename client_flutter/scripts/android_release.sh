#!/usr/bin/env bash
# Signed release APKs for Android (ADR-040) — one per CPU type — plus the
# update manifest the app checks (ADR-058).
#
#   bash scripts/android_release.sh            # RELEASE_NOTES="…" optional
#
# Output: build/android-release/ — sinhron-<version>-<build>-<abi>.apk and
# android.json ({version, build, notes, apks: {abi: {url, sha256, size}}}).
# `scripts/publish_android.sh` uploads that folder to the server's
# /download/; the app finds android.json there and updates itself.
#
# The signing key lives OUTSIDE the repo: $SINHRON_ANDROID_KEY_DIR (default
# ~/Documents/Keys/sinhron) with android-release.jks + android-release.pass
# (the password, one line). Lose the key and installed apps can't update —
# keep a copy. android/key.properties exists only while this runs.
# Toolchain: JAVA_HOME = JDK 17, ANDROID_HOME = the SDK (docs/android-plan.md).
# Version: raise pubspec `version` and kAppVersion (settings_screen.dart)
# before every build the owner installs (CLAUDE.md § Versions); Settings →
# About shows "version (build)".
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/^version: *\([^+]*\).*/\1/p' pubspec.yaml)

KEY_DIR=${SINHRON_ANDROID_KEY_DIR:-$HOME/Documents/Keys/sinhron}
[[ -f $KEY_DIR/android-release.jks && -f $KEY_DIR/android-release.pass ]] || {
  echo "No signing key in $KEY_DIR (android-release.jks + android-release.pass)" >&2
  exit 1
}
export JAVA_HOME=${JAVA_HOME:-$HOME/opt/jdk-17/Contents/Home}
export ANDROID_HOME=${ANDROID_HOME:-$HOME/Library/Android/sdk}
BUILD_NUMBER=${BUILD_NUMBER:-$(date -u +%Y%m%d%H)}
# The build number is the hour (an Android versionCode must fit in an
# int), so two builds in one hour got the same one and the app saw no
# update (0.7.0 and 0.7.1, 2026-10-19). Never at or below the last build.
last=$(sed -n 's/.*"build": *\([0-9]*\).*/\1/p' build/android-release/android.json 2>/dev/null | head -1 || true) # no file on a clean machine (GitHub)
if [[ -n $last && $BUILD_NUMBER -le $last ]]; then
  echo "Build $BUILD_NUMBER is not above the last one ($last) — using $((last + 1))"
  BUILD_NUMBER=$((last + 1))
fi

pass=$(tr -d '\n' <"$KEY_DIR/android-release.pass")
props=android/key.properties
trap 'rm -f "$props"' EXIT
umask 077
printf 'storeFile=%s\nstorePassword=%s\nkeyAlias=sinhron\nkeyPassword=%s\n' "$KEY_DIR/android-release.jks" "$pass" "$pass" >"$props"

nice -n 19 flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64 --build-number "$BUILD_NUMBER" --dart-define=SINHRON_BUILD="$BUILD_NUMBER"

out=build/app/outputs/flutter-apk
apksigner=$(ls -d "$ANDROID_HOME"/build-tools/*/ | sort -V | tail -1)apksigner
# ADR-058 — the certificate the app trusts for updates (APP_CERT_SHA256 in
# lib/core/app_update.dart). A build signed with anything else gets no manifest.
OUR_CERT=6f048635c6991fe6bb3a4084e44af39fb31d63162aa75bdd5c8c8b8a6c6a6918
rel=build/android-release
rm -rf "$rel" && mkdir -p "$rel"
for apk in "$out"/app-*-release.apk; do
  "$apksigner" verify "$apk" >/dev/null
  cert=$("$apksigner" verify --print-certs "$apk" | sed -n 's/.*certificate SHA-256 digest: //p' | head -1)
  abi=$(basename "$apk" | sed 's/^app-\(.*\)-release\.apk$/\1/')
  name="sinhron-$VERSION-$BUILD_NUMBER-$abi.apk"
  cp "$apk" "$rel/$name"
  printf '%s  %s  %s  %s\n' "$(du -h "$apk" | cut -f1)" "$(shasum -a 256 "$apk" | cut -c1-16)" "$abi" "$name"
  [[ $cert == "$OUR_CERT" ]] || { echo "Not signed with the Sinhron release key ($cert) — no update manifest." >&2; NO_MANIFEST=1; }
done
if [[ -z ${NO_MANIFEST:-} ]]; then
  python3 -I - "$rel" "$VERSION" "$BUILD_NUMBER" "${RELEASE_NOTES:-}" <<'PY'
import hashlib, json, os, re, sys
rel, version, build, notes = sys.argv[1:5]
apks = {}
for name in sorted(os.listdir(rel)):
    m = re.fullmatch(rf"sinhron-{re.escape(version)}-{build}-(.+)\.apk", name)
    if not m:
        continue
    data = open(os.path.join(rel, name), "rb").read()
    apks[m.group(1)] = {"url": name, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
manifest = {"version": version, "build": int(build), "notes": notes, "apks": apks}
with open(os.path.join(rel, "android.json"), "w") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
  echo "Update manifest: $rel/android.json (publish: bash scripts/publish_android.sh --host <user@server>)"
fi
chmod 644 "$rel"/*  # the server's web server reads them (umask 077 above)
echo "Version $VERSION (build $BUILD_NUMBER)"
echo "Signed with: $("$JAVA_HOME"/bin/keytool -list -keystore "$KEY_DIR/android-release.jks" -storepass:file "$KEY_DIR/android-release.pass" 2>/dev/null | grep -o 'SHA-256.*' | head -1)"
