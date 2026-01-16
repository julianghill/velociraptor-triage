#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

log() {
  echo "$@" >&2
}

log "Running smoke tests in $ROOT_DIR"

# Spec-only render should work without requiring a Velociraptor binary.
log "Test: spec-only render"
SPEC_OUTPUT="$TMP_DIR/spec_output"
mkdir -p "$SPEC_OUTPUT"
(cd "$ROOT_DIR" && bash createCollectors.sh --spec-only --spec-output "$SPEC_OUTPUT")

if ! ls "$SPEC_OUTPUT"/*.yaml >/dev/null 2>&1; then
  log "Error: spec-only render did not produce any YAML files in $SPEC_OUTPUT"
  exit 1
fi

log "Smoke tests completed"
