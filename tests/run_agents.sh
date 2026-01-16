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

VELO_BINARY="${VELO_BINARY:-$ROOT_DIR/velociraptor}"
SERVER_CONFIG="${SERVER_CONFIG:-$ROOT_DIR/server.config.yaml}"

if [ ! -f "$VELO_BINARY" ] || [ ! -f "$SERVER_CONFIG" ]; then
  log "Skipping agents test: expected $VELO_BINARY and $SERVER_CONFIG (override with VELO_BINARY/SERVER_CONFIG)."
  exit 0
fi

log "Running agents test in $ROOT_DIR"

AGENT_OUTPUT_DIR="$TMP_DIR/agents"
mkdir -p "$AGENT_OUTPUT_DIR"

(cd "$ROOT_DIR" && bash createCollectors.sh \
  --agents-only \
  --velo-binary "$VELO_BINARY" \
  --server-config "$SERVER_CONFIG" \
  --agent-output-dir "$AGENT_OUTPUT_DIR")

if [ ! -f "$AGENT_OUTPUT_DIR/velociraptor-client-linux-amd64" ]; then
  log "Error: missing Linux agent at $AGENT_OUTPUT_DIR/velociraptor-client-linux-amd64"
  exit 1
fi

if [ ! -f "$AGENT_OUTPUT_DIR/velociraptor-client-windows-amd64.exe" ]; then
  log "Error: missing Windows agent at $AGENT_OUTPUT_DIR/velociraptor-client-windows-amd64.exe"
  exit 1
fi

log "Agents test completed"
