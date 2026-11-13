#!/usr/bin/env bash
# Build a release IPA and upload it to App Store Connect (TestFlight).
#
#   bash scripts/testflight.sh              build + upload
#   bash scripts/testflight.sh --no-upload  build the IPA only
#
# Signing: automatic, team CBJTTRBDF3 (ios/ExportOptions*.plist); Xcode's
# Apple ID on this Mac does the signing and the upload (no API key).
# On GitHub (.github/workflows/release.yml) there is no Apple ID: with
# ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID set (App Store Connect API key,
# Admin role) Xcode signs and uploads with that key instead.
# Build number = UTC time (YYYYMMDDHHMM): always higher than the last one.
# Version: raise pubspec `version` and kAppVersion (settings_screen.dart)
# before every build the owner installs (CLAUDE.md § Versions); Settings →
# About shows "version (build)".
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/^version: *\([^+]*\).*/\1/p' pubspec.yaml)

BUILD_NUMBER=${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}

# A device build after a simulator build in the same folder can ship the
# simulator's objective_c.framework (stale native assets) — start clean.
rm -rf .dart_tool/flutter_build build/native_assets/ios

AUTH=()
if [[ -n ${ASC_KEY_PATH:-} ]]; then
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  # `flutter build ipa` can't pass the key to Xcode: Flutter writes its
  # settings, xcodebuild archives with the key.
  flutter build ios --config-only --release --build-number "$BUILD_NUMBER" --dart-define=SINHRON_BUILD="$BUILD_NUMBER"
  (cd ios && pod install)
  xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release \
    -destination 'generic/platform=iOS' -archivePath build/ios/archive/Runner.xcarchive \
    archive -allowProvisioningUpdates "${AUTH[@]}"
else
  nice -n 19 flutter build ipa --release --build-number "$BUILD_NUMBER" --dart-define=SINHRON_BUILD="$BUILD_NUMBER" \
    --export-options-plist ios/ExportOptions.plist
fi

if [[ ${1:-} != --no-upload ]]; then
  xcodebuild -exportArchive \
    -archivePath build/ios/archive/Runner.xcarchive \
    -exportOptionsPlist ios/ExportOptionsUpload.plist \
    -exportPath build/ios/upload \
    -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"}
  echo "Uploaded $VERSION (build $BUILD_NUMBER) — App Store Connect processes it in 10–30 min."
fi
