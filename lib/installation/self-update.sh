#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

DCVM_REPO_SLUG="${DCVM_REPO_SLUG:-metharda/dcvm}"
DCVM_REPO_BRANCH="${DCVM_REPO_BRANCH:-main}"
INSTALL_BIN="/usr/local/bin"
INSTALL_LIB="/usr/local/lib/dcvm"
BACKUP_DIR="/var/lib/dcvm/backups"
LOG_FILE="/var/log/dcvm-update.log"
KEEP_UPDATE_BACKUPS=3

require_root

create_backup_dir() {
  if [[ ! -d "$BACKUP_DIR" ]]; then
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    chown root:root "$BACKUP_DIR"
  fi
}

validate_backup() {
  local backup_path="$1"
  local resolved_path
  if command -v realpath >/dev/null 2>&1; then
    resolved_path="$(realpath -e -- "$backup_path" 2>/dev/null)" || return 1
  elif command -v readlink >/dev/null 2>&1; then
    resolved_path="$(readlink -f -- "$backup_path" 2>/dev/null)" || return 1
  else
    if [[ -d "$backup_path" ]]; then
      resolved_path="$(cd "$backup_path" 2>/dev/null && pwd -P)" || return 1
    else
      [[ -L "$backup_path" ]] && return 1
      resolved_path="$backup_path"
    fi
  fi

  [[ "$resolved_path" != "$BACKUP_DIR"/* ]] && return 1
  [[ -e "$resolved_path" ]] || return 1
  [[ "$(stat -c '%u' "$resolved_path" 2>/dev/null)" != "0" ]] && return 1

  local mode world_perms
  mode="$(stat -c '%a' "$resolved_path" 2>/dev/null)" || return 1
  world_perms="${mode: -1}"
  [[ "$world_perms" != "0" ]] && return 1
  return 0
}

show_usage() {
  ui_help <<EOF
dcvm self-update - update dcvm from GitHub

Usage: dcvm self-update [option]

Options:
  --check      Compare the installed version with the latest one
  --force      Reinstall even if the version is the same
  --revert     Go back to a version saved before an update
  -h, --help   Show this help

Self-update keeps the previous version in $BACKUP_DIR
(the last $KEEP_UPDATE_BACKUPS updates). VMs, backups and settings are not touched.
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
  local tmp version
  tmp=$(mktemp)
  if fetch_repo_file dcvm "$tmp"; then
    version=$(sed -n 's/.*Version: \([0-9][0-9.]*\).*/\1/p' "$tmp" | head -1)
  fi
  rm -f "$tmp"
  echo "${version:-error}"
}

install_files() {
  local files="$1" result="$2" ok=true updated_count=0 file_path dest tmp_dest dest_root tmp_abs root_abs
  while IFS= read -r file_path; do
    [[ -z "$file_path" ]] && continue
    if [[ "$file_path" == /* ]] || [[ "$file_path" == *".."* ]]; then
      print_warning "Skipping unsafe path from repository: $file_path"
      ok=false
      continue
    fi
    if [[ "$file_path" == "dcvm" ]]; then
      dest="$INSTALL_BIN/dcvm" dest_root="$INSTALL_BIN"
    elif [[ "$file_path" == lib/* ]]; then
      dest="$INSTALL_LIB/${file_path#lib/}" dest_root="$INSTALL_LIB"
    else
      print_warning "Skipping unexpected repository path: $file_path"
      ok=false
      continue
    fi
    tmp_dest="${dest}.tmp.$$"
    mkdir -p "$(dirname "$tmp_dest")" 2>/dev/null || true
    if ! fetch_repo_file "$file_path" "$tmp_dest"; then
      print_warning "Could not download $file_path"
      rm -f "$tmp_dest" 2>/dev/null || true
      ok=false
      continue
    fi
    if command -v readlink >/dev/null 2>&1; then
      tmp_abs=$(readlink -f "$tmp_dest" 2>/dev/null || true)
      root_abs=$(readlink -f "$dest_root" 2>/dev/null || true)
      case "$tmp_abs" in
      "$root_abs"/*) ;;
      *)
        print_error "Refusing to install $file_path outside $dest_root"
        rm -f "$tmp_dest"
        ok=false
        continue
        ;;
      esac
    fi
    mv -f "$tmp_dest" "$dest"
    [[ "$dest" == *.sh || "$file_path" == dcvm ]] && chmod +x "$dest" 2>/dev/null
    updated_count=$((updated_count + 1))
  done <<<"$files"
  echo "$updated_count $ok" >"$result"
}

prune_update_backups() {
  find "$BACKUP_DIR" -maxdepth 1 -type d -name 'dcvm-backup-*' 2>/dev/null | sort -r |
    tail -n +$((KEEP_UPDATE_BACKUPS + 1)) | while IFS= read -r old; do rm -rf "$old"; done
}

do_update() {
  local force="${1:-false}"
  local current_version remote_version
  current_version=$(get_current_version)
  remote_version=$(get_remote_version)

  if [[ "$remote_version" == "error" ]] || [[ -z "$remote_version" ]] || [[ "$remote_version" == "unknown" ]]; then
    print_error "Could not fetch the latest version from GitHub. Check the network connection."
    exit 1
  fi

  if [[ "$current_version" == "$remote_version" ]] && [[ "$force" != "true" ]]; then
    ui_done ok "dcvm is up to date" "$current_version"
    echo ""
    exit 0
  fi

  ui_title "Updating dcvm" "$current_version $SYM_ARROW $remote_version"

  create_backup_dir
  local backup_dir="$BACKUP_DIR/dcvm-backup-$(date +%Y%m%d%H%M%S)"
  mkdir -p "$backup_dir"
  chmod 700 "$backup_dir"
  [[ -f "$INSTALL_BIN/dcvm" ]] && cp "$INSTALL_BIN/dcvm" "$backup_dir/dcvm"
  [[ -d "$INSTALL_LIB" ]] && cp -r "$INSTALL_LIB" "$backup_dir/lib"
  ui_step ok "Backup" "$current_version saved in $backup_dir"

  local files
  files=$(list_repo_files)
  if [[ -z "$files" ]]; then
    ui_step fail "Files" "could not list the repository files"
    print_error "Could not discover repository files; nothing was changed"
    exit 1
  fi

  local result updated_count ok
  result=$(mktemp)
  ui_run "Downloading" install_files "$files" "$result" || true
  read -r updated_count ok <"$result"
  rm -f "$result"

  if [[ "$ok" == "true" ]]; then
    ui_step ok "Files" "$updated_count installed (${UI_RUN_SECS}s)"
    prune_update_backups
    ui_done ok "dcvm updated to $remote_version" "dcvm self-update --revert goes back to $current_version"
    echo ""
    "$INSTALL_LIB/utils/doctor.sh" --quiet --fast --only host,vms || true
  else
    ui_step fail "Files" "${updated_count:-0} installed, some failed"
    sed 's/^/  /' "$UI_RUN_LOG"
    print_error "Some files failed to update; the previous version is in $backup_dir (dcvm self-update --revert)"
    exit 1
  fi
}

check_update() {
  local current_version remote_version
  current_version=$(get_current_version)
  remote_version=$(get_remote_version)

  echo ""
  ui_kv "Installed" "$current_version" "Latest" "${remote_version:-unknown}"

  if [[ "$remote_version" == "error" ]] || [[ -z "$remote_version" ]] || [[ "$remote_version" == "unknown" ]]; then
    ui_done warn "Could not determine the latest version" "check the network connection"
    echo ""
    exit 1
  fi

  if [[ "$current_version" == "$remote_version" ]]; then
    ui_done ok "dcvm is up to date"
    echo ""
  else
    ui_done ok "Update available" "$current_version $SYM_ARROW $remote_version"
    ui_next "dcvm self-update" "install it"
  fi
}

do_revert() {
  create_backup_dir
  local backups backup
  local -a backup_array=()
  backups=$(find "$BACKUP_DIR" -maxdepth 1 -type d -name 'dcvm-backup-*' 2>/dev/null | sort -r)
  while IFS= read -r backup; do
    [[ -z "$backup" ]] && continue
    if ! validate_backup "$backup"; then
      print_warning "Skipping untrusted backup: $backup"
      continue
    fi
    backup_array+=("$backup")
  done <<<"$backups"

  if [[ ${#backup_array[@]} -eq 0 ]]; then
    print_error "No saved versions in $BACKUP_DIR (each update saves the version it replaces)"
    exit 1
  fi

  ui_title "Revert dcvm" "installed: $(get_current_version)"
  local i ts
  {
    printf '#\tSAVED\tVERSION\n'
    for i in "${!backup_array[@]}"; do
      ts=$(basename "${backup_array[i]}" | sed 's/dcvm-backup-//')
      printf '%s\t%s\t%s\n' "$((i + 1))" \
        "$(date -d "${ts:0:8} ${ts:8:2}:${ts:10:2}:${ts:12:2}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$ts")" \
        "$(sed -n 's/.*Version: \([0-9][0-9.]*\).*/\1/p' "${backup_array[i]}/dcvm" 2>/dev/null | head -1)"
    done
  } | ui_table
  echo ""

  local choice
  read -r -p "  Version to go back to (1-${#backup_array[@]}, q to cancel): " choice
  if [[ "$choice" == "q" || "$choice" == "Q" || -z "$choice" ]]; then
    echo "  Cancelled."
    exit 0
  fi
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#backup_array[@]} ]]; then
    print_error "Invalid selection"
    exit 1
  fi

  local selected_backup="${backup_array[$((choice - 1))]}"
  echo ""
  if [[ -f "$selected_backup/dcvm" ]]; then
    cp "$selected_backup/dcvm" "$INSTALL_BIN/dcvm"
    chmod +x "$INSTALL_BIN/dcvm"
    ui_step ok "dcvm" "$INSTALL_BIN/dcvm"
  else
    ui_step warn "dcvm" "not in this backup, left as is"
  fi
  if [[ -d "$selected_backup/lib" ]]; then
    cp -r "$selected_backup/lib/"* "$INSTALL_LIB/"
    ui_step ok "Libraries" "$INSTALL_LIB"
  else
    ui_step warn "Libraries" "not in this backup, left as is"
  fi

  ui_done ok "Reverted to $(get_current_version)" "dcvm self-update installs the latest again"
  echo ""
}

main() {
  local CHECK_ONLY=false
  local FORCE=false
  local REVERT=false

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
    --revert)
      REVERT=true
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

  if [[ "$REVERT" == "true" ]]; then
    do_revert
  elif [[ "$CHECK_ONLY" == "true" ]]; then
    check_update
  else
    do_update "$FORCE"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
