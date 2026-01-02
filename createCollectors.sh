#!/bin/bash
# Based on the triage.zip collector workflow by Digital-Defense-Institute (https://github.com/Digital-Defense-Institute/triage.zip)
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

WORKDIR="${WORKDIR:-}"
DATA_DIR="${DATA_DIR:-}"
DATASTORE_DIR="${DATASTORE_DIR:-}"
SPEC_DIR="${SPEC_DIR:-}"
SPEC_FILE="${SPEC_FILE:-}"
VERSION_FILE=""
SPEC_SOURCE_REPO="${SPEC_SOURCE_REPO:-julianghill/velociraptor-triage}"
SPEC_SOURCE_REF="${SPEC_SOURCE_REF:-main}"
COLLECTOR_OUTPUT_DIR="${COLLECTOR_OUTPUT_DIR:-}"
SPEC_OUTPUT="${SPEC_OUTPUT:-}"
SPEC_ONLY=0
SFTP_HOST=""
SFTP_USER=""
SFTP_KEY_PATH=""
SFTP_REMOTE_DIR=""

WINDOWS_TARGETS_URL="https://triage.velocidex.com/docs/windows.triage.targets/Windows.Triage.Targets.zip"
LINUX_UAC_URL="https://triage.velocidex.com/docs/linux.triage.uac/Linux.Triage.UAC.zip"
LINUX_AVML_URL="https://raw.githubusercontent.com/Velocidex/velociraptor-docs/master/content/exchange/artifacts/Linux.Memory.AVML.yaml"
SPEC_FILES=()

log() {
  echo "$@" >&2
}

usage() {
  cat >&2 <<'EOF'
Usage: createCollectors.sh [flags]
  --spec-only                   Render spec(s) with overrides and exit (no collector build)
  --sftp-host <host[:port]>     SFTP host (optional port; defaults to :22 if omitted)
  --sftp-user <user>            SFTP username
  --sftp-key-path <path>        Path to private key file to embed/reference
  --sftp-remote-dir <dir>       Remote directory for uploads
  --workdir <path>              Working directory (default: mktemp)
  --output-dir <path>           Where to write collectors (default: <workdir>/dist)
  --spec-output <path>          Where to write rendered spec in --spec-only mode (default: <workdir>/spec.yaml)
  -h | --help                   Show this help
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec-only)
      SPEC_ONLY=1
      ;;
    --sftp-host)
      SFTP_HOST="${2:-}"; shift
      [ -n "$SFTP_HOST" ] || usage
      ;;
    --sftp-user)
      SFTP_USER="${2:-}"; shift
      [ -n "$SFTP_USER" ] || usage
      ;;
    --sftp-key-path)
      SFTP_KEY_PATH="${2:-}"; shift
      [ -n "$SFTP_KEY_PATH" ] || usage
      ;;
    --sftp-remote-dir)
      SFTP_REMOTE_DIR="${2:-}"; shift
      [ -n "$SFTP_REMOTE_DIR" ] || usage
      ;;
    --workdir)
      WORKDIR="${2:-}"; shift
      [ -n "$WORKDIR" ] || usage
      ;;
    --output-dir)
      COLLECTOR_OUTPUT_DIR="${2:-}"; shift
      [ -n "$COLLECTOR_OUTPUT_DIR" ] || usage
      ;;
    --spec-output)
      SPEC_OUTPUT="${2:-}"; shift
      [ -n "$SPEC_OUTPUT" ] || usage
      ;;
    -h|--help)
      usage
      ;;
    *)
      log "Unknown argument: $1"
      usage
      ;;
  esac
  shift
done

if [ -z "$WORKDIR" ]; then
  WORKDIR="$SCRIPT_DIR"
else
  mkdir -p "$WORKDIR"
fi

DATA_DIR="${DATA_DIR:-$WORKDIR/data}"
DATASTORE_DIR="${DATASTORE_DIR:-$WORKDIR/datastore}"
SPEC_DIR="${SPEC_DIR:-$SCRIPT_DIR/spec}"
VERSION_FILE="$DATA_DIR/velociraptor-version.json"
COLLECTOR_OUTPUT_DIR="${COLLECTOR_OUTPUT_DIR:-$WORKDIR/collectors}"
SPEC_OUTPUT="${SPEC_OUTPUT:-$WORKDIR/spec.yaml}"
VELO_BINARY="${VELO_BINARY:-$WORKDIR/velociraptor}"
WINDOWS_TARGETS_ZIP="${WINDOWS_TARGETS_ZIP:-$WORKDIR/Windows.Triage.Targets.zip}"
WINDOWS_TARGETS_DIR="${WINDOWS_TARGETS_DIR:-$DATASTORE_DIR/artifact_definitions/Windows/Triage}"
LINUX_UAC_ZIP="${LINUX_UAC_ZIP:-$WORKDIR/Linux.Triage.UAC.zip}"
LINUX_UAC_DIR="${LINUX_UAC_DIR:-$DATASTORE_DIR/artifact_definitions/Linux/Triage}"
LINUX_UAC_FILE="${LINUX_UAC_FILE:-$LINUX_UAC_DIR/Linux.Triage.UAC.yaml}"
LINUX_AVML_DIR="${LINUX_AVML_DIR:-$DATASTORE_DIR/artifact_definitions/Linux/Memory}"
LINUX_AVML_FILE="${LINUX_AVML_FILE:-$LINUX_AVML_DIR/Linux.Memory.AVML.yaml}"
SERVER_CONFIG="${SERVER_CONFIG:-$WORKDIR/server.config.yaml}"
RENDERED_SPEC_DIR="$WORKDIR/rendered_specs"

SFTP_ENDPOINT="$SFTP_HOST"
DO_SFTP_INJECT=0

fetch_with_retry() {
  local url="$1"
  local max_retries=3
  local retry_delay=2
  local attempt=1
  
  while [ $attempt -le $max_retries ]; do
    if [ $attempt -gt 1 ]; then
      log "Fetching from GitHub API (attempt $attempt/$max_retries)..."
    fi
    response=$(curl -s -L "$url" || true)
    
    if echo "$response" | jq -e . >/dev/null 2>&1; then
      echo "$response"
      return 0
    fi
    
    if [ $attempt -lt $max_retries ]; then
      log "Request failed, retrying in ${retry_delay}s..."
      sleep $retry_delay
      retry_delay=$((retry_delay * 2))
    fi
    
    attempt=$((attempt + 1))
  done
  
  log "Error: Failed to fetch valid JSON from GitHub API after $max_retries attempts"
  log "Debug - Last response received: ${response:0:200}..."
  return 1
}

download_with_retry() {
  local url="$1"
  local output="$2"
  local max_retries=3
  local retry_delay=2
  local attempt=1
  
  while [ $attempt -le $max_retries ]; do
    if [ $attempt -gt 1 ]; then
      log "Downloading binary (attempt $attempt/$max_retries)..."
    fi
    if curl -L "$url" -o "$output" --fail --silent --show-error; then
      log "Download successful"
      return 0
    fi
    
    if [ $attempt -lt $max_retries ]; then
      log "Download failed, retrying in ${retry_delay}s..."
      rm -f "$output"
      sleep $retry_delay
      retry_delay=$((retry_delay * 2))
    fi
    
    attempt=$((attempt + 1))
  done
  
  log "Error: Failed to download binary after $max_retries attempts"
  return 1
}

validate_sftp_flags() {
  local set_count=0
  for v in "$SFTP_HOST" "$SFTP_USER" "$SFTP_KEY_PATH" "$SFTP_REMOTE_DIR"; do
    [ -n "$v" ] && set_count=$((set_count + 1))
  done

  if [ $set_count -gt 0 ] && [ $set_count -lt 4 ]; then
    log "Error: SFTP flags are partially provided. Need --sftp-host, --sftp-user, --sftp-key-path, --sftp-remote-dir together."
    exit 1
  fi

  if [ $set_count -eq 4 ]; then
    DO_SFTP_INJECT=1
    if [ ! -f "$SFTP_KEY_PATH" ]; then
      log "Error: SFTP key file not found at $SFTP_KEY_PATH"
      exit 1
    fi
    if [[ "$SFTP_ENDPOINT" != *:* ]]; then
      SFTP_ENDPOINT="${SFTP_ENDPOINT}:22"
    fi
  fi
}

ensure_local_specs() {
  if [ -n "$SPEC_FILE" ]; then
    if [ -f "$SPEC_FILE" ]; then
      SPEC_FILES=("$SPEC_FILE")
      log "Using SPEC_FILE override at $SPEC_FILE"
      return 0
    fi
    log "Error: SPEC_FILE is set but not found at $SPEC_FILE"
    exit 1
  fi

  if [ ! -d "$SPEC_DIR" ]; then
    log "Spec directory not found at $SPEC_DIR; creating it."
    mkdir -p "$SPEC_DIR"
  fi

  mapfile -t SPEC_FILES < <(find "$SPEC_DIR" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)

  if [ ${#SPEC_FILES[@]} -eq 0 ]; then
    log "No local spec files found under $SPEC_DIR; attempting to fetch from GitHub ($SPEC_SOURCE_REPO @ $SPEC_SOURCE_REF)"
    fetch_specs_from_github || log "Warning: Unable to fetch specs from GitHub."
    mapfile -t SPEC_FILES < <(find "$SPEC_DIR" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
  fi

  if [ ${#SPEC_FILES[@]} -eq 0 ]; then
    log "Error: No spec files (*.yaml/ *.yml) available. Check SPEC_DIR or SPEC_FILE settings."
    exit 1
  fi

  log "Discovered ${#SPEC_FILES[@]} spec file(s) under $SPEC_DIR"
}

ensure_windows_targets() {
  mkdir -p "$WINDOWS_TARGETS_DIR"
  if [ -f "$WINDOWS_TARGETS_DIR/Windows.Triage.Targets.yaml" ]; then
    log "Windows triage targets already present."
    return 0
  fi
  log "Downloading Windows triage targets..."
  download_with_retry "$WINDOWS_TARGETS_URL" "$WINDOWS_TARGETS_ZIP"
  unzip -o "$WINDOWS_TARGETS_ZIP" -d "$WINDOWS_TARGETS_DIR"
  rm "$WINDOWS_TARGETS_ZIP"
}

ensure_linux_uac() {
  mkdir -p "$LINUX_UAC_DIR"
  if [ -f "$LINUX_UAC_FILE" ]; then
    log "Linux UAC triage artifact already present."
    return 0
  fi
  log "Downloading Linux UAC triage artifact..."
  download_with_retry "$LINUX_UAC_URL" "$LINUX_UAC_ZIP"
  unzip -o "$LINUX_UAC_ZIP" -d "$LINUX_UAC_DIR"
  rm "$LINUX_UAC_ZIP"
}

ensure_linux_avml() {
  mkdir -p "$LINUX_AVML_DIR"
  if [ -f "$LINUX_AVML_FILE" ]; then
    log "Linux AVML artifact already present."
    return 0
  fi
  log "Downloading Linux AVML artifact..."
  download_with_retry "$LINUX_AVML_URL" "$LINUX_AVML_FILE"
}

fetch_specs_from_github() {
  local api_url="https://api.github.com/repos/$SPEC_SOURCE_REPO/contents/spec?ref=$SPEC_SOURCE_REF"
  mkdir -p "$SPEC_DIR"

  local listing
  listing=$(fetch_with_retry "$api_url") || return 1

  mapfile -t remote_specs < <(echo "$listing" | jq -r '.[] | select(.type=="file") | select(.name | test("\\.(yaml|yml)$")) | .download_url')

  if [ ${#remote_specs[@]} -eq 0 ]; then
    log "No remote spec files found in $SPEC_SOURCE_REPO at ref $SPEC_SOURCE_REF"
    return 1
  fi

  for url in "${remote_specs[@]}"; do
    local fname="${url##*/}"
    log "Downloading spec $fname from GitHub"
    if ! curl -L "$url" -o "$SPEC_DIR/$fname" --fail --silent --show-error; then
      log "Warning: failed to download $fname"
    fi
  done
}

render_spec_with_overrides() {
  local src="$1"
  local dst="$2"

  mkdir -p "$(dirname "$dst")"
  if [ $DO_SFTP_INJECT -ne 1 ]; then
    cp "$src" "$dst"
    return
  fi

  local injected=0
  local skip_block=0
  : > "$dst"

  while IFS= read -r line || [ -n "$line" ]; do
    if [ $skip_block -eq 1 ]; then
      if [[ "$line" =~ ^[[:space:]]*$ ]]; then
        continue
      fi
      if [[ "$line" =~ ^[[:space:]] ]]; then
        continue
      fi
      skip_block=0
    fi

    if [[ "$line" =~ ^Target:[[:space:]] ]]; then
      echo "Target: SFTP" >> "$dst"
      continue
    fi

    if [[ "$line" =~ ^TargetArgs:[[:space:]]*$ ]]; then
      echo "TargetArgs:" >> "$dst"
      echo "  user: \"$SFTP_USER\"" >> "$dst"
      echo "  endpoint: \"$SFTP_ENDPOINT\"" >> "$dst"
      echo "  path: \"$SFTP_REMOTE_DIR\"" >> "$dst"
      echo "  hostkey: \"\"" >> "$dst"
      echo "  privatekey: |" >> "$dst"
      while IFS= read -r key_line || [ -n "$key_line" ]; do
        echo "    $key_line" >> "$dst"
      done < "$SFTP_KEY_PATH"
      injected=1
      skip_block=1
      continue
    fi

    echo "$line" >> "$dst"
  done < "$src"

  if [ $DO_SFTP_INJECT -eq 1 ] && [ $injected -eq 0 ]; then
    {
      echo ""
      echo "Target: SFTP"
      echo "TargetArgs:"
      echo "  user: \"$SFTP_USER\""
      echo "  endpoint: \"$SFTP_ENDPOINT\""
      echo "  path: \"$SFTP_REMOTE_DIR\""
      echo "  hostkey: \"\""
      echo "  privatekey: |"
      while IFS= read -r key_line || [ -n "$key_line" ]; do
        echo "    $key_line"
      done < "$SFTP_KEY_PATH"
    } >> "$dst"
  fi
}

write_server_config() {
  local version="$1"
  cat > "$SERVER_CONFIG" <<EOF
Client:
  use_self_signed_ssl: true
  server_urls: []
  nonce: ""
EOF
}

log "Starting createCollectors.sh (spec directory mode) in $WORKDIR"

mkdir -p "$DATA_DIR" "$DATASTORE_DIR" "$COLLECTOR_OUTPUT_DIR" "$RENDERED_SPEC_DIR"

validate_sftp_flags
ensure_local_specs
log "Collectors will be written to $COLLECTOR_OUTPUT_DIR"

rendered_specs=()
if [ $SPEC_ONLY -eq 1 ]; then
  for spec_path in "${SPEC_FILES[@]}"; do
    rendered_path="$RENDERED_SPEC_DIR/$(basename "$spec_path")"
    log "Rendering spec with overrides (spec-only): $spec_path -> $rendered_path"
    render_spec_with_overrides "$spec_path" "$rendered_path"
    rendered_specs+=("$rendered_path")
  done

  if [ -n "$SPEC_OUTPUT" ]; then
    if [ ${#rendered_specs[@]} -eq 1 ]; then
      mkdir -p "$(dirname "$SPEC_OUTPUT")"
      cp "${rendered_specs[0]}" "$SPEC_OUTPUT"
      log "Rendered spec written to $SPEC_OUTPUT"
    else
      mkdir -p "$SPEC_OUTPUT"
      for r in "${rendered_specs[@]}"; do
        cp "$r" "$SPEC_OUTPUT/"
      done
      log "Rendered specs written to directory $SPEC_OUTPUT"
    fi
  else
    log "Rendered specs available under $RENDERED_SPEC_DIR"
  fi
  exit 0
fi

response=$(fetch_with_retry "https://api.github.com/repos/Velocidex/velociraptor/releases/latest") || exit 1

if [ -z "$response" ]; then
  log "Error: Empty response from GitHub API"
  exit 1
fi

asset_info=$(echo "$response" | jq -r '[.assets[] | select((.name | test("velociraptor-.*-linux-amd64$")) and (.name | contains("musl") | not)) | {name: .name, url: .browser_download_url}] | sort_by(.name) | last')
download_url=$(echo "$asset_info" | jq -r '.url')
asset_name=$(echo "$asset_info" | jq -r '.name')

if [ -z "$download_url" ] || [ "$download_url" == "null" ]; then
  log "Error: Could not find a Linux AMD64 binary in the latest release"
  log "Debug - Available assets:"
  echo "$response" | jq -r '.assets[].name' >&2
  exit 1
fi

binary_version=$(echo "$asset_name" | sed -n 's/.*velociraptor-v\([0-9.]*\)-linux-amd64$/\1/p')
velociraptor_version=${binary_version:-$(echo "$response" | jq -r '.tag_name' | sed 's/^v//')}

if [ -z "$velociraptor_version" ] || [ "$velociraptor_version" == "null" ]; then
  log "Error: Unable to determine Velociraptor version from asset metadata"
  exit 1
fi

log "Velociraptor release version: $velociraptor_version"

stored_version="unknown"
if [ -f "$VERSION_FILE" ]; then
  stored_version=$(jq -r '.velociraptor_version // "unknown"' "$VERSION_FILE" 2>/dev/null || echo "unknown")
fi

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "VELO_VERSION=$velociraptor_version" >> "$GITHUB_ENV"
fi

if [ "$stored_version" = "$velociraptor_version" ] && [ -n "${SKIP_IF_VERSION_UNCHANGED:-}" ]; then
  echo "Velociraptor version unchanged ($velociraptor_version); skipping build."
  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "VELO_VERSION_CHANGED=false" >> "$GITHUB_ENV"
  fi
  exit 0
fi

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "VELO_VERSION_CHANGED=true" >> "$GITHUB_ENV"
fi

mkdir -p "$DATA_DIR"
cat <<EOF > "$VERSION_FILE"
{
  "velociraptor_version": "$velociraptor_version"
}
EOF

log "Downloading Velociraptor binary from: $download_url"

download_with_retry "$download_url" "$VELO_BINARY" || exit 1
chmod +x "$VELO_BINARY"

need_linux=0
need_windows=0
need_unknown=0

for spec_path in "${SPEC_FILES[@]}"; do
  spec_os=$(awk -F':' '/^OS[[:space:]]*:/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}' "$spec_path")
  spec_os_lower=$(echo "${spec_os:-}" | tr '[:upper:]' '[:lower:]')
  log "Spec OS detected for $spec_path: ${spec_os:-unknown}"
  case "$spec_os_lower" in
    linux)
      need_linux=1
      ;;
    windows*)
      need_windows=1
      ;;
    *)
      need_unknown=1
      ;;
  esac
done

if [ $need_unknown -eq 1 ]; then
  log "Unknown OS detected; fetching both Linux and Windows triage artifacts."
  ensure_windows_targets
  ensure_linux_uac
  ensure_linux_avml
else
  if [ $need_windows -eq 1 ]; then
    ensure_windows_targets
  fi
  if [ $need_linux -eq 1 ]; then
    ensure_linux_uac
    ensure_linux_avml
  fi
fi

rendered_specs=()
for spec_path in "${SPEC_FILES[@]}"; do
  rendered_path="$RENDERED_SPEC_DIR/$(basename "$spec_path")"
  log "Rendering spec with overrides: $spec_path -> $rendered_path"
  render_spec_with_overrides "$spec_path" "$rendered_path"
  rendered_specs+=("$rendered_path")
done

for spec_path in "${rendered_specs[@]}"; do
  log "Building collector for $spec_path"
  build_output=$("$VELO_BINARY" collector --datastore "$DATASTORE_DIR/" "$spec_path" 2>&1 | tee /dev/stderr)
  collector_path=$(echo "$build_output" | jq -r '.[].Repacked.Path? // empty' 2>/dev/null || true)
  if [ -n "$collector_path" ] && [ -f "$collector_path" ]; then
    mkdir -p "$COLLECTOR_OUTPUT_DIR"
    mv "$collector_path" "$COLLECTOR_OUTPUT_DIR/"
    log "Moved collector to $COLLECTOR_OUTPUT_DIR/$(basename "$collector_path")"
  else
    log "Warning: Could not detect collector path in output; leaving files in $DATASTORE_DIR"
  fi
done

log "Collectors written to $COLLECTOR_OUTPUT_DIR"
