#!/usr/bin/env bash
# Risk #5 — guard against flutter_rust_bridge generated-code drift.
#
# When a developer edits `rust/src/api/*.rs` without re-running
# `flutter_rust_bridge_codegen generate`, the Dart bindings in
# `lib/src/rust/` go out of sync with the Rust surface. The project
# still compiles (Dart side uses the old shape) but the first FFI call
# crashes at runtime with arity / type mismatches — a class of bug
# that already bit us twice during the WU C5/C6/B3 cycle.
#
# This script runs the codegen fresh, then verifies `git status` is
# clean for the generated directory. Non-zero exit if dirty — meaning
# "run codegen before committing".
#
# Usage:
#   bash client_flutter/scripts/check_frb_drift.sh
#
# Wire as:
#   • pre-commit hook (`.git/hooks/pre-commit` or via husky/lefthook)
#   • CI step
#
# Requires:
#   • `flutter_rust_bridge_codegen` 2.11.x in PATH
#   • `git` for diff detection

set -euo pipefail

# Resolve script-relative client_flutter dir so the script works from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${CLIENT_DIR}"

GENERATED_DIR="lib/src/rust"
RUST_API_DIR="rust/src/api"

if [[ ! -d "${GENERATED_DIR}" ]]; then
    echo "ERROR: ${GENERATED_DIR} not found — wrong cwd?" >&2
    exit 2
fi

# Snapshot current state of the generated dir so we can diff post-codegen.
# Using `git diff-index` against HEAD would also work; using a temp copy
# avoids any interaction with the working tree's other changes.
TMP_BEFORE="$(mktemp -d)"
trap 'rm -rf "${TMP_BEFORE}"' EXIT
cp -R "${GENERATED_DIR}" "${TMP_BEFORE}/before"

# Regenerate. frb prints to stdout; failures bubble via `set -e`.
echo "→ running flutter_rust_bridge_codegen generate"
flutter_rust_bridge_codegen generate >/dev/null

# Compare. `diff -r` exits non-zero on any difference. We capture the
# output so we can print a useful error message.
if ! diff -r "${TMP_BEFORE}/before" "${GENERATED_DIR}" >/dev/null; then
    echo "" >&2
    echo "❌ FRB drift detected — Dart bindings in ${GENERATED_DIR}" >&2
    echo "   are out of sync with Rust surface in ${RUST_API_DIR}." >&2
    echo "" >&2
    echo "   Fix:" >&2
    echo "     cd ${CLIENT_DIR}" >&2
    echo "     flutter_rust_bridge_codegen generate" >&2
    echo "     git add lib/src/rust" >&2
    echo "     git commit --amend  # or as a new commit" >&2
    echo "" >&2
    echo "   See Risk #5 in docs/status.md." >&2
    exit 1
fi

echo "✓ FRB bindings in sync with Rust API surface"
