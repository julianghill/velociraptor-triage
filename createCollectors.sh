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
BUILD_AGENTS=0
AGENTS_ONLY=0
AGENT_OUTPUT_DIR="${AGENT_OUTPUT_DIR:-}"
AGENT_ORG="${AGENT_ORG:-root}"
AGENT_LINUX_BINARY="${AGENT_LINUX_BINARY:-}"
AGENT_WINDOWS_BINARY="${AGENT_WINDOWS_BINARY:-}"
SERVER_CONFIG="${SERVER_CONFIG:-}"
SFTP_HOST=""
SFTP_USER=""
SFTP_KEY_PATH=""
SFTP_REMOTE_DIR=""
velociraptor_version=""
release_response=""

WINDOWS_TARGETS_URL="https://triage.velocidex.com/docs/windows.triage.targets/Windows.Triage.Targets.zip"
LINUX_UAC_URL="https://triage.velocidex.com/docs/linux.triage.uac/Linux.Triage.UAC.zip"
LINUX_AVML_URL="https://raw.githubusercontent.com/Velocidex/velociraptor-docs/master/content/exchange/artifacts/Linux.Memory.AVML.yaml"
SPEC_FILES=()

log() {
  echo "$@" >&2
}

resolve_path() {
  local path="$1"
  if [ -z "$path" ]; then
    return
  fi
  if [ ! -e "$path" ]; then
    echo "$path"
    return
  fi
  if command -v realpath >/dev/null 2>&1; then
    realpath "$path"
  else
    (cd "$(dirname "$path")" && printf "%s/%s\n" "$(pwd)" "$(basename "$path")")
  fi
}

usage() {
  cat >&2 <<'EOF'
Usage: createCollectors.sh [flags]
  --spec-only                   Render spec(s) with overrides and exit (no collector build)
  --build-agents                Build Velociraptor client agents (Linux + Windows)
  --agents-only                 Build agents only (skip collectors/specs)
  --sftp-host <host[:port]>     SFTP host (optional port; defaults to :22 if omitted)
  --sftp-user <user>            SFTP username
  --sftp-key-path <path>        Path to private key file to embed/reference
  --sftp-remote-dir <dir>       Remote directory for uploads
  --workdir <path>              Working directory (default: repo directory)
  --output-dir <path>           Where to write collectors (default: <workdir>/collectors)
  --spec-output <path>          Where to write rendered spec in --spec-only mode (default: <workdir>/spec.yaml)
  --velo-binary <path>          Path to Velociraptor CLI binary to use
  --server-config <path>        Path to server.config.yaml for agent repacking
  --agent-output-dir <path>     Where to write repacked agents (default: <workdir>/agents)
  --agent-org <name>            Org name for client config (default: root)
  --agent-linux-binary <path>   Linux Velociraptor binary to repack (default: --velo-binary)
  --agent-windows-binary <path> Windows Velociraptor binary to repack (downloaded if missing)
  -h | --help                   Show this help
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec-only)
      SPEC_ONLY=1
      ;;
    --build-agents)
      BUILD_AGENTS=1
      ;;
    --agents-only)
      AGENTS_ONLY=1
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
    --velo-binary)
      VELO_BINARY="${2:-}"; shift
      [ -n "$VELO_BINARY" ] || usage
      ;;
    --server-config)
      SERVER_CONFIG="${2:-}"; shift
      [ -n "$SERVER_CONFIG" ] || usage
      ;;
    --agent-output-dir)
      AGENT_OUTPUT_DIR="${2:-}"; shift
      [ -n "$AGENT_OUTPUT_DIR" ] || usage
      ;;
    --agent-org)
      AGENT_ORG="${2:-}"; shift
      [ -n "$AGENT_ORG" ] || usage
      ;;
    --agent-linux-binary)
      AGENT_LINUX_BINARY="${2:-}"; shift
      [ -n "$AGENT_LINUX_BINARY" ] || usage
      ;;
    --agent-windows-binary)
      AGENT_WINDOWS_BINARY="${2:-}"; shift
      [ -n "$AGENT_WINDOWS_BINARY" ] || usage
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

WORKDIR=$(resolve_path "$WORKDIR")

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
AGENT_OUTPUT_DIR="${AGENT_OUTPUT_DIR:-$WORKDIR/agents}"
RENDERED_SPEC_DIR="$WORKDIR/rendered_specs"

SERVER_CONFIG=$(resolve_path "$SERVER_CONFIG")
if [ -n "$AGENT_LINUX_BINARY" ]; then
  AGENT_LINUX_BINARY=$(resolve_path "$AGENT_LINUX_BINARY")
fi
if [ -n "$AGENT_WINDOWS_BINARY" ]; then
  AGENT_WINDOWS_BINARY=$(resolve_path "$AGENT_WINDOWS_BINARY")
fi

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

detect_velo_version() {
  local bin="$1"
  local version=""
  if [ -x "$bin" ]; then
    version=$("$bin" version 2>/dev/null | awk -F': ' '/^version:/ {print $2; exit}')
  fi
  if [ -z "$version" ]; then
    version=$(basename "$bin" | sed -n 's/.*velociraptor-v\([0-9.]*\).*/\1/p')
  fi
  echo "$version"
}

fetch_release_info() {
  if [ -n "$release_response" ]; then
    return 0
  fi
  release_response=$(fetch_with_retry "https://api.github.com/repos/Velocidex/velociraptor/releases/latest") || exit 1
}

get_asset_url_by_name() {
  local name="$1"
  echo "$release_response" | jq -r --arg name "$name" '.assets[] | select(.name==$name) | .browser_download_url' | head -n1
}

ensure_velo_binary() {
  local have_binary=0
  if [ -n "$VELO_BINARY" ] && [ -f "$VELO_BINARY" ]; then
    VELO_BINARY=$(resolve_path "$VELO_BINARY")
    have_binary=1
    chmod +x "$VELO_BINARY" 2>/dev/null || true
    velociraptor_version=$(detect_velo_version "$VELO_BINARY")
    if [ -n "$velociraptor_version" ]; then
      log "Using provided Velociraptor binary ($VELO_BINARY) version $velociraptor_version"
    fi
  fi

  if [ -z "$velociraptor_version" ]; then
    fetch_release_info
    if [ -z "$release_response" ]; then
      log "Error: Empty response from GitHub API"
      exit 1
    fi

    asset_info=$(echo "$release_response" | jq -r '[.assets[] | select((.name | test("velociraptor-.*-linux-amd64$")) and (.name | contains("musl") | not)) | {name: .name, url: .browser_download_url}] | sort_by(.name) | last')
    download_url=$(echo "$asset_info" | jq -r '.url')
    asset_name=$(echo "$asset_info" | jq -r '.name')

    if [ -z "$download_url" ] || [ "$download_url" == "null" ]; then
      log "Error: Could not find a Linux AMD64 binary in the latest release"
      log "Debug - Available assets:"
      echo "$release_response" | jq -r '.assets[].name' >&2
      exit 1
    fi

    binary_version=$(echo "$asset_name" | sed -n 's/.*velociraptor-v\([0-9.]*\)-linux-amd64$/\1/p')
    velociraptor_version=${binary_version:-$(echo "$release_response" | jq -r '.tag_name' | sed 's/^v//')}
  fi

  if [ -z "$velociraptor_version" ] || [ "$velociraptor_version" == "null" ]; then
    log "Error: Unable to determine Velociraptor version"
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

  if [ $have_binary -eq 1 ]; then
    return 0
  fi

  fetch_release_info
  download_url=$(echo "$release_response" | jq -r --arg version "$velociraptor_version" '.assets[] | select(.name == ("velociraptor-v" + $version + "-linux-amd64")) | .browser_download_url' | head -n1)

  if [ -z "$download_url" ] || [ "$download_url" == "null" ]; then
    log "Error: Could not find Linux AMD64 binary for version $velociraptor_version"
    exit 1
  fi

  log "Downloading Velociraptor binary from: $download_url"
  download_with_retry "$download_url" "$VELO_BINARY" || exit 1
  chmod +x "$VELO_BINARY"
}

ensure_agent_windows_binary() {
  if [ -n "$AGENT_WINDOWS_BINARY" ] && [ -f "$AGENT_WINDOWS_BINARY" ]; then
    return 0
  fi

  fetch_release_info
  if [ -z "$velociraptor_version" ]; then
    log "Error: Velociraptor version not set; cannot download Windows agent binary."
    exit 1
  fi

  windows_name="velociraptor-v${velociraptor_version}-windows-amd64.exe"
  windows_url=$(get_asset_url_by_name "$windows_name")
  if [ -z "$windows_url" ] || [ "$windows_url" == "null" ]; then
    log "Error: Could not find Windows binary $windows_name in release assets. Provide --agent-windows-binary."
    exit 1
  fi

  AGENT_WINDOWS_BINARY="$WORKDIR/$windows_name"
  log "Downloading Windows agent binary from: $windows_url"
  download_with_retry "$windows_url" "$AGENT_WINDOWS_BINARY" || exit 1
}

build_agents() {
  if [ ! -f "$SERVER_CONFIG" ]; then
    log "Error: server.config.yaml not found at $SERVER_CONFIG"
    exit 1
  fi

  if [ ! -f "$VELO_BINARY" ]; then
    log "Error: Velociraptor binary not found at $VELO_BINARY"
    exit 1
  fi

  if [ -z "$AGENT_LINUX_BINARY" ]; then
    AGENT_LINUX_BINARY="$VELO_BINARY"
  fi

  if [ ! -f "$AGENT_LINUX_BINARY" ]; then
    log "Error: Linux agent binary not found at $AGENT_LINUX_BINARY"
    exit 1
  fi

  ensure_agent_windows_binary

  mkdir -p "$AGENT_OUTPUT_DIR"
  client_config="$AGENT_OUTPUT_DIR/client.${AGENT_ORG}.config.yaml"
  log "Generating client config for org '$AGENT_ORG'"
  "$VELO_BINARY" config client --org "$AGENT_ORG" --config "$SERVER_CONFIG" > "$client_config"

  linux_out="$AGENT_OUTPUT_DIR/velociraptor-client-linux-amd64"
  windows_out="$AGENT_OUTPUT_DIR/velociraptor-client-windows-amd64.exe"

  log "Repacking Linux client binary -> $linux_out"
  "$VELO_BINARY" config repack --exe "$AGENT_LINUX_BINARY" "$client_config" "$linux_out"

  log "Repacking Windows client binary -> $windows_out"
  "$VELO_BINARY" config repack --exe "$AGENT_WINDOWS_BINARY" "$client_config" "$windows_out"

  log "Agents written to $AGENT_OUTPUT_DIR"
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

DO_COLLECTORS=1
DO_AGENTS=0
if [ $AGENTS_ONLY -eq 1 ]; then
  DO_COLLECTORS=0
  DO_AGENTS=1
fi
if [ $BUILD_AGENTS -eq 1 ]; then
  DO_AGENTS=1
fi

if [ $SPEC_ONLY -eq 1 ] && [ $DO_COLLECTORS -eq 0 ]; then
  log "Error: --spec-only is only valid when building collectors."
  exit 1
fi

mkdir -p "$DATA_DIR" "$DATASTORE_DIR" "$RENDERED_SPEC_DIR"
if [ $DO_COLLECTORS -eq 1 ]; then
  mkdir -p "$COLLECTOR_OUTPUT_DIR"
fi
if [ $DO_AGENTS -eq 1 ]; then
  mkdir -p "$AGENT_OUTPUT_DIR"
fi

if [ $DO_COLLECTORS -eq 1 ]; then
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
fi

if [ $DO_COLLECTORS -eq 1 ] || [ $DO_AGENTS -eq 1 ]; then
  ensure_velo_binary
fi

if [ $DO_COLLECTORS -eq 1 ]; then
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
fi

if [ $DO_AGENTS -eq 1 ]; then
  build_agents
fi
