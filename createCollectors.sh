#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

DATA_DIR="${DATA_DIR:-$SCRIPT_DIR/data}"
DATASTORE_DIR="${DATASTORE_DIR:-$SCRIPT_DIR/datastore}"
SPEC_DIR="${SPEC_DIR:-$SCRIPT_DIR/spec}"
SPEC_FILE="${SPEC_FILE:-}"
VERSION_FILE="$DATA_DIR/velociraptor-version.json"

WINDOWS_TARGETS_URL="https://triage.velocidex.com/docs/windows.triage.targets/Windows.Triage.Targets.zip"
WINDOWS_TARGETS_ZIP="$SCRIPT_DIR/Windows.Triage.Targets.zip"
WINDOWS_TARGETS_DIR="$DATASTORE_DIR/artifact_definitions/Windows/Triage"

LINUX_UAC_URL="https://triage.velocidex.com/docs/linux.triage.uac/Linux.Triage.UAC.zip"
LINUX_UAC_ZIP="$SCRIPT_DIR/Linux.Triage.UAC.zip"
LINUX_UAC_DIR="$DATASTORE_DIR/artifact_definitions/Linux/Triage"
LINUX_UAC_FILE="$LINUX_UAC_DIR/Linux.Triage.UAC.yaml"

LINUX_AVML_URL="https://raw.githubusercontent.com/Velocidex/velociraptor-docs/master/content/exchange/artifacts/Linux.Memory.AVML.yaml"
LINUX_AVML_DIR="$DATASTORE_DIR/artifact_definitions/Linux/Memory"
LINUX_AVML_FILE="$LINUX_AVML_DIR/Linux.Memory.AVML.yaml"

VELO_BINARY="$SCRIPT_DIR/velociraptor"
SPEC_FILES=()

log() {
  echo "$@" >&2
}

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
    log "Error: spec directory not found at $SPEC_DIR"
    exit 1
  fi

  mapfile -t SPEC_FILES < <(find "$SPEC_DIR" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)

  if [ ${#SPEC_FILES[@]} -eq 0 ]; then
    log "Error: No spec files (*.yaml/ *.yml) found under $SPEC_DIR"
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

log "Starting createCollectors.sh (spec directory mode)..."

mkdir -p "$DATA_DIR" "$DATASTORE_DIR"

ensure_local_specs

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

for spec_path in "${SPEC_FILES[@]}"; do
  log "Building collector for $spec_path"
  "$VELO_BINARY" collector --datastore "$DATASTORE_DIR/" "$spec_path"
done
