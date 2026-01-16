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

SPEC_FILE="${SPEC_FILE:-}"

log "Running collectors test in $ROOT_DIR"

COLLECTOR_OUTPUT_DIR="$TMP_DIR/collectors"
mkdir -p "$COLLECTOR_OUTPUT_DIR"

cmd=(bash createCollectors.sh --output-dir "$COLLECTOR_OUTPUT_DIR")
if [ -n "$SPEC_FILE" ]; then
  cmd=(SPEC_FILE="$SPEC_FILE" "${cmd[@]}")
fi

(cd "$ROOT_DIR" && "${cmd[@]}")

if ! ls "$COLLECTOR_OUTPUT_DIR"/* >/dev/null 2>&1; then
  log "Error: no collectors found under $COLLECTOR_OUTPUT_DIR"
  exit 1
fi

log "Collectors test completed"
