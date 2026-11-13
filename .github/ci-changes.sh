#!/usr/bin/env bash
# Which CI jobs a push needs — writes `<job>=true|false` to $GITHUB_OUTPUT.
# Everything runs on a manual start, a new branch, or a change under .github/.
# 2026-10-16: a full run is ~47 billed minutes (Android ~23); most pushes
# touch one area.
set -euo pipefail
all=false
if [[ ${ALL:-false} == true || -z ${BEFORE:-} || $BEFORE =~ ^0+$ ]] || ! git cat-file -e "$BEFORE^{commit}" 2>/dev/null; then
  all=true
fi
files=""
[[ $all == true ]] || files=$(git diff --name-only "$BEFORE" "${AFTER:-HEAD}")
grep -q '^\.github/' <<<"$files" && all=true
# A version bump (`version:` in pubspec.yaml — every build for the owner)
# is not a dependency change: it doesn't call for the 23-min Android build.
deps=$(grep -Ev '^client_flutter/pubspec\.yaml$' <<<"$files" || true)
if grep -q '^client_flutter/pubspec\.yaml$' <<<"$files" &&
  git diff "$BEFORE" "${AFTER:-HEAD}" -- client_flutter/pubspec.yaml | grep -E '^[-+][^-+]' | grep -Evq '^[-+]version:'; then
  deps+=$'\nclient_flutter/pubspec.yaml'
fi
echo "changed files:"; sed 's/^/  /' <<<"$files"
out() {
  local v=false list=${3:-$files}
  if [[ $all == true ]] || grep -Eq "$2" <<<"$list"; then v=true; fi
  echo "$1=$v" >>"$GITHUB_OUTPUT"
  echo "$1: $v"
}
out server '^server/(src|migrations|proto|tests|Cargo\.|build\.rs)'
# install_test.sh also checks compose, the Caddyfile and the APK upload script.
out installer '^(server/(install\.sh|scripts/|docker-compose|Caddyfile)|client_flutter/scripts/publish_android\.sh)'
# The image job checks the Dockerfile / compose / healthcheck; the code itself
# is compiled and tested by the server job.
out image '^server/(Dockerfile|docker-compose|Caddyfile|scripts/caddy_sites_check\.sh|scripts/db-init/|livekit\.yaml|turnserver\.conf|\.dockerignore|Cargo\.(toml|lock)|migrations/)'
out client_rust '^client_flutter/rust/'
out flutter '^client_flutter/(lib|test|integration_test|pubspec|l10n\.yaml|analysis_options)'
out frb '^client_flutter/(rust/src/api|rust/Cargo|lib/src/rust|flutter_rust_bridge)'
# Android: Gradle / Kotlin / manifest, native dependencies (Cargo, pubspec
# dependencies — not a version bump), the Rust build glue. Rust code alone is
# tested by client_rust; a manual run builds the APK any time.
out android '^client_flutter/(android/|rust/Cargo\.(toml|lock)|rust/.*/Cargo\.toml|rust_builder/|pubspec\.(yaml|lock))' "$deps"
