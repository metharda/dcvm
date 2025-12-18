#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

DCVM_REPO_SLUG="${DCVM_REPO_SLUG:-metharda/dcvm}"
DCVM_REPO_BRANCH="${DCVM_REPO_BRANCH:-main}"
INSTALL_BIN="/usr/local/bin"
INSTALL_LIB="/usr/local/lib/dcvm"
LOG_FILE="/var/log/dcvm-update.log"

require_root

show_usage() {
  cat <<EOF
DCVM Self-Update

Usage: dcvm self-update [options]

Options:
  --check        Check for updates without installing
  --force        Force update even if already up to date
  -h, --help     Show this help

Examples:
  dcvm self-update           # Update to latest version
  dcvm self-update --check   # Check for available updates
EOF
}

get_current_version() {
  if [[ -f "$INSTALL_BIN/dcvm" ]]; then
    sed -n 's/.*Version: \([0-9][0-9.]*\).*/\1/p' "$INSTALL_BIN/dcvm" 2>/dev/null | head -1 || echo "unknown"
  else
    echo "not-installed"
  fi
}

get_remote_version() {
  local url="https://raw.githubusercontent.com/${DCVM_REPO_SLUG}/${DCVM_REPO_BRANCH}/dcvm"
  local content

  if command -v curl >/dev/null 2>&1; then
    content=$(curl -fsSL "$url" 2>/dev/null)
  elif command -v wget >/dev/null 2>&1; then
    content=$(wget -qO- "$url" 2>/dev/null)
  else
    echo "error"
    return 1
  fi

  echo "$content" | sed -n 's/.*Version: \([0-9][0-9.]*\).*/\1/p' | head -1 || echo "unknown"
}

fetch_file() {
  local rel_path="$1"
  local dest_path="$2"
  local base_url="https://raw.githubusercontent.com/${DCVM_REPO_SLUG}/${DCVM_REPO_BRANCH}"

  mkdir -p "$(dirname "$dest_path")" 2>/dev/null || true

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$dest_path" "$base_url/$rel_path" 2>>"$LOG_FILE"
  else
    wget -q -O "$dest_path" "$base_url/$rel_path" 2>>"$LOG_FILE"
  fi
}

discover_repo_files() {
  local api_url="https://api.github.com/repos/${DCVM_REPO_SLUG}/git/trees/${DCVM_REPO_BRANCH}?recursive=1"
  local response

  if command -v curl >/dev/null 2>&1; then
    response=$(curl -fsSL -H "Accept: application/vnd.github.v3+json" "$api_url" 2>>"$LOG_FILE")
  elif command -v wget >/dev/null 2>&1; then
    response=$(wget -q -O - --header="Accept: application/vnd.github.v3+json" "$api_url" 2>>"$LOG_FILE")
  else
    return 1
  fi

  [[ -z "$response" ]] && return 1

  local files
  if command -v python3 >/dev/null 2>&1; then
    files=$(echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if 'tree' in data:
        for item in data['tree']:
            path = item.get('path', '')
            if path == 'dcvm' or (path.startswith('lib/') and path.endswith('.sh')):
                print(path)
except:
    pass
" 2>/dev/null)
  elif command -v jq >/dev/null 2>&1; then
    files=$(echo "$response" | jq -r '.tree[]? | select(.path == "dcvm" or (.path | startswith("lib/") and endswith(".sh"))) | .path' 2>/dev/null)
  else
    files=$(echo "$response" | grep -o '"path":"[^"]*"' | sed 's/"path":"//;s/"$//' | grep -E '^(dcvm$|lib/.+\.sh$)')
  fi

  echo "$files"
}

do_update() {
  local force="${1:-false}"

  print_info "Checking for updates..."

  local current_version=$(get_current_version)
  local remote_version=$(get_remote_version)

  print_info "Current version: $current_version"
  print_info "Latest version: $remote_version"

  if [[ "$remote_version" == "error" ]] || [[ "$remote_version" == "unknown" ]]; then
    print_error "Could not fetch remote version. Check your network connection."
    exit 1
  fi

  if [[ "$current_version" == "$remote_version" ]] && [[ "$force" != "true" ]]; then
    print_success "DCVM is already up to date (v$current_version)"
    exit 0
  fi

  print_info "Updating DCVM from v$current_version to v$remote_version..."

  local backup_dir="/tmp/dcvm-backup-$(date +%Y%m%d%H%M%S)"
  mkdir -p "$backup_dir"
  [[ -f "$INSTALL_BIN/dcvm" ]] && cp "$INSTALL_BIN/dcvm" "$backup_dir/"
  [[ -d "$INSTALL_LIB" ]] && cp -r "$INSTALL_LIB" "$backup_dir/"
  print_info "Backup created at $backup_dir"

  local files
  files=$(discover_repo_files)

  if [[ -z "$files" ]]; then
    print_error "Could not discover repository files"
    print_info "Restoring backup..."
    [[ -f "$backup_dir/dcvm" ]] && cp "$backup_dir/dcvm" "$INSTALL_BIN/"
    [[ -d "$backup_dir/dcvm" ]] && cp -r "$backup_dir/dcvm/"* "$INSTALL_LIB/"
    exit 1
  fi

  local file_count=$(echo "$files" | grep -c '^.' || echo 0)
  print_info "Updating $file_count files..."

  local ok=true
  local updated_count=0

  while IFS= read -r file_path; do
    [[ -z "$file_path" ]] && continue
    if [[ "$file_path" == /* ]] || [[ "$file_path" == *".."* ]]; then
      print_warning "Skipping unsafe path from repository: $file_path"
      ok=false
      continue
    fi

    if [[ "$file_path" == "dcvm" ]]; then
      local dest="$INSTALL_BIN/dcvm"
      local tmp_dest="${dest}.tmp.$$"
      mkdir -p "$(dirname "$tmp_dest")" 2>/dev/null || true

      if fetch_file "$file_path" "$tmp_dest"; then
        if command -v readlink >/dev/null 2>&1; then
          local tmp_abs
          tmp_abs=$(readlink -f "$tmp_dest" 2>/dev/null || true)
          local bin_abs
          bin_abs=$(readlink -f "$INSTALL_BIN" 2>/dev/null || true)
          case "$tmp_abs" in
          "$bin_abs"/*) ;;
          *)
            print_error "Refusing to install $file_path outside $INSTALL_BIN"
            rm -f "$tmp_dest"
            ok=false
            continue
            ;;
          esac
        fi
        mv -f "$tmp_dest" "$dest"
        chmod +x "$dest" 2>/dev/null || true
        ((updated_count++))
      else
        rm -f "$tmp_dest" 2>/dev/null || true
        ok=false
      fi

    elif [[ "$file_path" == lib/* ]]; then
      local rel_no_lib="${file_path#lib/}"
      if [[ "$rel_no_lib" == *".."* || "$rel_no_lib" == /* ]]; then
        print_warning "Skipping unsafe lib path: $file_path"
        ok=false
        continue
      fi
      local dest="$INSTALL_LIB/$rel_no_lib"
      local tmp_dest="${dest}.tmp.$$"
      mkdir -p "$(dirname "$tmp_dest")" 2>/dev/null || true

      if fetch_file "$file_path" "$tmp_dest"; then
        if command -v readlink >/dev/null 2>&1; then
          local tmp_abs
          tmp_abs=$(readlink -f "$tmp_dest" 2>/dev/null || true)
          local lib_abs
          lib_abs=$(readlink -f "$INSTALL_LIB" 2>/dev/null || true)
          case "$tmp_abs" in
          "$lib_abs"/*) ;;
          *)
            print_error "Refusing to install $file_path outside $INSTALL_LIB"
            rm -f "$tmp_dest"
            ok=false
            continue
            ;;
          esac
        fi
        mv -f "$tmp_dest" "$dest"
        [[ "$dest" == *.sh ]] && chmod +x "$dest" 2>/dev/null || true
        ((updated_count++))
      else
        rm -f "$tmp_dest" 2>/dev/null || true
        ok=false
      fi

    else
      print_warning "Skipping unexpected repository path: $file_path"
      ok=false
      continue
    fi
  done <<<"$files"

  if [[ "$ok" == "true" ]]; then
    print_success "Successfully updated $updated_count files"
    print_success "DCVM updated to v$remote_version"
    rm -rf "$backup_dir"
  else
    print_error "Some files failed to update"
    print_info "Backup available at $backup_dir"
    exit 1
  fi
}

check_update() {
  print_info "Checking for updates..."

  local current_version=$(get_current_version)
  local remote_version=$(get_remote_version)

  echo "Current version: $current_version"
  echo "Latest version:  $remote_version"
  echo ""

  if [[ "$remote_version" == "error" ]] || [[ "$remote_version" == "unknown" ]]; then
    print_warning "Could not determine latest version"
    exit 1
  fi

  if [[ "$current_version" == "$remote_version" ]]; then
    print_success "DCVM is up to date"
  else
    print_info "Update available: v$current_version -> v$remote_version"
    print_info "Run 'dcvm self-update' to update"
  fi
}

main() {
  local CHECK_ONLY=false
  local FORCE=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --check)
      CHECK_ONLY=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    -h | --help)
      show_usage
      exit 0
      ;;
    *)
      print_error "Unknown option: $1"
      show_usage
      exit 1
      ;;
    esac
  done

  if [[ "$CHECK_ONLY" == "true" ]]; then
    check_update
  else
    do_update "$FORCE"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
