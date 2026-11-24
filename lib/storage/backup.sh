#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

MIRROR_MANAGER="$SCRIPT_DIR/../utils/mirror-manager.sh"
if [ -f "$MIRROR_MANAGER" ]; then
  source "$MIRROR_MANAGER"
elif [ -f "/usr/local/lib/dcvm/utils/mirror-manager.sh" ]; then
  source "/usr/local/lib/dcvm/utils/mirror-manager.sh"
fi

BACKUP_SUBCOMMANDS="create, restore, list, delete, export, import, ssh-setup, troubleshoot"
# main reports an unknown subcommand, even where dcvm isn't installed.
[ "${1:-}" = help ] || wants_help "$@" ||
  [[ "${BASH_SOURCE[0]}" == "$0" && "${1:-}" != -* && ", $BACKUP_SUBCOMMANDS, " != *", ${1:-}, "* ]] || load_dcvm_config

FIX_LOCK_SCRIPT="${FIX_LOCK_SCRIPT:-$(get_fix_lock_script_path 2>/dev/null || echo "$SCRIPT_DIR/../utils/fix-lock.sh")}"
BACKUP_DIR="$DATACENTER_BASE/backups"
LOG_FILE="/var/log/dcvm-backup.log"
DATE=$(date +%Y%m%d_%H%M%S)
KEEP_BACKUPS=5
SHUTDOWN_TIMEOUT=60
BOOT_GRACE=90
COMPRESSION_ENABLED=true
ASSUME_YES=false

log() { log_to_file "$LOG_FILE" "[$1] ${*:2}"; }
get_backup_folder_path() { echo "$BACKUP_DIR/${1}-${2}"; }

backup_owner() { cat "$1/owner" 2>/dev/null || echo 0; }
backup_visible() {
  local owner
  owner=$(backup_owner "$1")
  if [ -n "${BACKUP_OWNER_FILTER:-}" ]; then
    [ "$owner" = "$BACKUP_OWNER_FILTER" ]
    return
  fi
  [ "$(caller_role)" != user ] || [ "$owner" = "$(caller_uid)" ]
}
list_backup_timestamps_desc() { collect_backup_timestamps "$1" "" "desc"; }
list_day_backup_timestamps_asc() { collect_backup_timestamps "$1" "$2" "asc"; }
collect_backup_timestamps() {
  local vm_name="$1"
  local day_filter="$2"
  local order="${3:-desc}"
  local -a ts_list=()
  local regex="^[0-9]{8}_[0-9]{6}$"

  if [ -n "$day_filter" ]; then
    regex="^${day_filter}_[0-9]{6}$"
  fi

  while IFS= read -r path; do
    [ -z "$path" ] && continue
    backup_visible "$path" || continue
    local base=$(basename "$path")
    local ts="${base#${vm_name}-}"
    [[ "$ts" =~ $regex ]] && ts_list+=("$ts")
  done < <(compgen -G "$BACKUP_DIR/${vm_name}-????????_??????" 2>/dev/null || printf '')

  while IFS= read -r path; do
    [ -z "$path" ] && continue
    [ "$(caller_role)" != user ] && [ "${BACKUP_OWNER_FILTER:-0}" = 0 ] || continue
    local base=$(basename "$path")
    local ts="${base#${vm_name}-disk-}"
    ts="${ts%.qcow2.gz}"
    ts="${ts%.qcow2}"
    [[ "$ts" =~ $regex ]] && ts_list+=("$ts")
  done < <(compgen -G "$BACKUP_DIR/${vm_name}-disk-*.qcow2*" 2>/dev/null || printf '')

  if [ ${#ts_list[@]} -eq 0 ]; then
    return 0
  fi

  if [ "$order" = "asc" ]; then
    printf "%s\n" "${ts_list[@]}" | sort -u
  else
    printf "%s\n" "${ts_list[@]}" | sort -u -r
  fi
}

get_backup_disk_path() {
  local vm_name="$1"
  local date_part="$2"
  local folder
  folder=$(get_backup_folder_path "$vm_name" "$date_part")
  backup_visible "$folder" || {
    echo ""
    return 1
  }
  if [ -d "$folder" ]; then
    if [ -f "$folder/${vm_name}-disk-${date_part}.qcow2.gz" ]; then
      echo "$folder/${vm_name}-disk-${date_part}.qcow2.gz"
      return 0
    fi
    if [ -f "$folder/${vm_name}-disk-${date_part}.qcow2" ]; then
      echo "$folder/${vm_name}-disk-${date_part}.qcow2"
      return 0
    fi
  fi
  if [ -f "$BACKUP_DIR/${vm_name}-disk-${date_part}.qcow2.gz" ]; then
    echo "$BACKUP_DIR/${vm_name}-disk-${date_part}.qcow2.gz"
    return 0
  fi
  if [ -f "$BACKUP_DIR/${vm_name}-disk-${date_part}.qcow2" ]; then
    echo "$BACKUP_DIR/${vm_name}-disk-${date_part}.qcow2"
    return 0
  fi
  echo ""
  return 1
}

get_backup_config_path() {
  local vm_name="$1"
  local date_part="$2"
  local folder
  folder=$(get_backup_folder_path "$vm_name" "$date_part")
  backup_visible "$folder" || {
    echo ""
    return 1
  }
  if [ -d "$folder" ] && [ -f "$folder/${vm_name}-config-${date_part}.xml" ]; then
    echo "$folder/${vm_name}-config-${date_part}.xml"
    return 0
  fi
  if [ -f "$BACKUP_DIR/${vm_name}-config-${date_part}.xml" ]; then
    echo "$BACKUP_DIR/${vm_name}-config-${date_part}.xml"
    return 0
  fi
  echo ""
  return 1
}

wait_for_vm_state() {
  local vm_name="$1"
  local desired_state="$2"
  local timeout="$3"
  local count=0

  while [ $count -lt $timeout ]; do
    local current_state=$(get_vm_state "$vm_name")
    if [ "$current_state" = "$desired_state" ]; then
      return 0
    fi
    sleep 1
    count=$((count + 1))
  done
  return 1
}

is_lock_error() {
  local error_message="$1"

  if echo "$error_message" | grep -qi "failed to get.*lock\|is another process using\|file is locked\|resource busy\|device or resource busy\|qemu unexpectedly closed\|failed to get shared.*lock\|block device is in use\|image is being used\|cannot lock\|already in use\|permission denied.*lock"; then
    return 0
  fi
  return 1
}

get_file_size() { format_bytes "$(file_bytes "$1")"; }

normalize_backing_chain() {
  local vm_disk_path="$1"
  if ! command -v qemu-img >/dev/null 2>&1; then
    return 0
  fi
  local info backing
  info=$(qemu-img info -U -f qcow2 "$vm_disk_path" 2>/dev/null) || return 0
  backing=$(echo "$info" | awk -F': ' '/backing file:/ {print $2; exit}')
  if [ -z "$backing" ]; then
    return 0
  fi
  if echo "$backing" | grep -q "/vms/"; then
    print_warning "Disk has VM-backed backing file ($backing). Flattening to standalone..."
    local tmp="${vm_disk_path}.tmp"
    if qemu-img convert -f qcow2 -O qcow2 "$vm_disk_path" "$tmp"; then
      mv -f "$tmp" "$vm_disk_path"
      print_success "Disk flattened to standalone image"
    else
      print_error "Failed to flatten disk image (qemu-img convert)"
      rm -f "$tmp" 2>/dev/null || true
      return 1
    fi
  fi
}

remove_backup_artifacts() {
  local vm_name="$1"
  local date_part="$2"
  local context="${3:-backup}"
  local removed=0

  local folder=$(get_backup_folder_path "$vm_name" "$date_part")
  if [ -d "$folder" ]; then
    if rm -rf "$folder"; then
      log "INFO" "Removed ${context} folder $folder"
      return 0
    fi
    return 1
  fi

  local disk=$(get_backup_disk_path "$vm_name" "$date_part")
  local cfg=$(get_backup_config_path "$vm_name" "$date_part")

  if [ -n "$disk" ] && rm -f "$disk"; then
    log "INFO" "Removed ${context} disk $disk"
    removed=1
  fi

  if [ -n "$cfg" ] && rm -f "$cfg"; then
    log "INFO" "Removed ${context} config $cfg"
    removed=1
  fi

  if [ $removed -gt 0 ]; then
    return 0
  fi

  return 1
}

cleanup_old_backups() {
  local vm_name="$1"

  mapfile -t all_ts < <(BACKUP_OWNER_FILTER=$(vm_owner_uid "$vm_name") list_backup_timestamps_desc "$vm_name")
  if [ ${#all_ts[@]} -gt $KEEP_BACKUPS ]; then
    local to_delete=("${all_ts[@]:$KEEP_BACKUPS}")
    for dp in "${to_delete[@]}"; do
      [ -z "$dp" ] && continue
      remove_backup_artifacts "$vm_name" "$dp" "old backup" || true
    done
    prune_builds >/dev/null
  fi
}

pretty_ts() { sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/' <<<"$1"; }

backup_age() {
  local s
  s=$(($(date +%s) - $(date -d "$(pretty_ts "$1")" +%s 2>/dev/null || date +%s)))
  if [ "$s" -lt 3600 ]; then
    echo "$((s / 60)) min"
  elif [ "$s" -lt 86400 ]; then
    plural "$((s / 3600))" hour
  else
    plural "$((s / 86400))" day
  fi
}

vm_state_label() {
  if check_vm_exists "$1"; then get_vm_state "$1"; else echo deleted; fi
}

backup_rows() {
  local vm_name="$1" dp dmy disk_path bytes note first=true
  local -A day_seq=() seq_for_dp=()
  mapfile -t backups_ts < <(list_backup_timestamps_desc "$vm_name")
  [ ${#backups_ts[@]} -gt 0 ] || return 1
  while read -r dp; do
    [ -n "$dp" ] || continue
    dmy=$(sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_.*/\3.\2.\1/' <<<"$dp")
    day_seq[$dmy]=$((${day_seq[$dmy]:-0} + 1))
    seq_for_dp[$dp]=${day_seq[$dmy]}
  done < <(printf '%s\n' "${backups_ts[@]}" | sort)
  for dp in "${backups_ts[@]}"; do
    [ -n "$dp" ] || continue
    disk_path=$(get_backup_disk_path "$vm_name" "$dp")
    bytes=$(file_bytes "$disk_path")
    note=""
    $first && [ ${#backups_ts[@]} -gt 1 ] && note="newest"
    first=false
    [[ "$disk_path" == *.gz ]] || note+="${note:+, }not compressed"
    [ -f "$(get_backup_config_path "$vm_name" "$dp")" ] || note="$SYM_WARN no config, cannot be restored${note:+, $note}"
    dmy=$(sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_.*/\3.\2.\1/' <<<"$dp")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${vm_name}-${dmy}-${seq_for_dp[$dp]:-?}" "$(pretty_ts "$dp" | cut -c1-16)" \
      "$(backup_age "$dp")" "$(format_bytes "$bytes")" "${note:- }" "$bytes"
  done
}

list_backups() {
  local vm_name="$1" with_index="$2" rows n total
  if ! rows=$(backup_rows "$vm_name"); then
    print_warning "No backups found for VM: $vm_name"
    return 1
  fi
  n=$(grep -c . <<<"$rows")
  total=$(awk -F'\t' '{ t += $6 } END { print t + 0 }' <<<"$rows")
  ui_title "Backups of $vm_name" "$n of $KEEP_BACKUPS kept ${SYM_DOT} $(format_bytes "$total") ${SYM_DOT} VM $(vm_state_label "$vm_name")"
  local cols=1-5 head=$'ID\tTAKEN\tAGE\tSIZE\tNOTE'
  awk -F'\t' '$5 != " "' <<<"$rows" | grep -q . || cols=1-4 head=${head%$'\t'NOTE}
  if [ "$with_index" = true ]; then
    printf '#\t%s\n%s\n' "$head" "$(cut -f"$cols" <<<"$rows" | awk '{ print NR "\t" $0 }')" | ui_table
    echo ""
  else
    printf '%s\n%s\n' "$head" "$(cut -f"$cols" <<<"$rows")" | ui_table
    ui_next "dcvm backup restore $vm_name" "put the newest backup back" \
      "dcvm backup restore $vm_name <id> <new-name>" "restore one as a new VM" \
      "dcvm backup delete $vm_name" "pick backups to delete"
  fi
  return 0
}

list_all_backups() {
  local -a vms=()
  local vm rows all="" n=0 total
  while IFS= read -r f; do vms+=("$(basename "$f" | awk -F"-disk-" '{print $1}')"); done < <(ls -1 "$BACKUP_DIR"/*-disk-*.qcow2* 2>/dev/null)
  while IFS= read -r d; do vms+=("$(basename "$d" | sed -E 's/-[0-9]{8}_[0-9]{6}$//')"); done < <(ls -1 -d "$BACKUP_DIR"/*-????????_?????? 2>/dev/null)
  if [ ${#vms[@]} -eq 0 ]; then
    print_warning "No backups found in: $BACKUP_DIR"
    return 1
  fi
  mapfile -t vms < <(printf "%s\n" "${vms[@]}" | sort -u)

  local shown=0
  for vm in "${vms[@]}"; do
    rows=$(backup_rows "$vm") || continue
    shown=$((shown + 1))
    all+=$(awk -F'\t' -v vm="$vm" -v st="$(vm_state_label "$vm")" 'BEGIN { OFS = "\t" } { print (NR == 1 ? vm : " "), (NR == 1 ? st : " "), $0 }' <<<"$rows")$'\n'
  done
  n=$(grep -c . <<<"$all")
  total=$(awk -F'\t' '{ t += $8 } END { print t + 0 }' <<<"$all")
  if [ "$shown" -eq 0 ]; then
    print_warning "No backups found"
    return 1
  fi
  ui_title "Backups" "$(plural "$n" backup) of $(plural "$shown" VM) ${SYM_DOT} $(format_bytes "$total") in $BACKUP_DIR"
  local cols=1-7 head=$'VM\tSTATE\tID\tTAKEN\tAGE\tSIZE\tNOTE'
  awk -F'\t' 'NF && $7 != " "' <<<"$all" | grep -q . || cols=1-6 head=${head%$'\t'NOTE}
  printf '%s\n%s\n' "$head" "$(grep . <<<"$all" | cut -f"$cols")" | ui_table
  ui_next "dcvm backup restore <vm>" "put a VM's newest backup back" \
    "dcvm backup restore <vm> <id> <new-name>" "restore one as a new VM" \
    "dcvm backup list <vm>" "one VM's backups"
  return 0
}

delete_backups() {
  local arg="$1"

  if [ -z "$arg" ]; then
    print_error "Usage: dcvm backup delete <vm> [id] | <vm>-<id> | --all"
    return 1
  fi

  if [ "$arg" = "--all" ]; then
    mapfile -t __folders < <(ls -1 -d "$BACKUP_DIR"/*-????????_?????? 2>/dev/null | grep -vE '/exports$')
    mapfile -t __legacy_disks < <(ls -1 "$BACKUP_DIR"/*-disk-*.qcow2* 2>/dev/null)

    local count_folders=${#__folders[@]}
    local count_legacy=${#__legacy_disks[@]}
    local total=$((count_folders + count_legacy))

    if [ "$total" -eq 0 ]; then
      print_warning "No backups found in: $BACKUP_DIR"
      return 0
    fi

    ui_title "Delete all backups" "$total in $BACKUP_DIR"
    [ "$count_folders" -gt 0 ] && ui_kv "Backups" "$count_folders"
    [ "$count_legacy" -gt 0 ] && ui_kv "Old format" "$count_legacy (single files from before 0.9)"
    echo ""
    [ "$ASSUME_YES" = true ] || confirm_action "Delete them permanently?" || return 0

    local removed=0
    for d in "${__folders[@]}"; do
      [ -z "$d" ] && continue
      rm -rf "$d" && removed=$((removed + 1))
    done
    for f in "${__legacy_disks[@]}"; do
      [ -z "$f" ] && continue
      rm -f "$f" && removed=$((removed + 1))
      local base=$(basename "$f")
      local vmname=$(echo "$base" | awk -F"-disk-" '{print $1}')
      local ts=$(echo "$base" | sed -E "s/${vmname}-disk-(.*)\.qcow2(\.gz)?/\1/")
      local legacy_cfg="$BACKUP_DIR/${vmname}-config-${ts}.xml"
      [ -f "$legacy_cfg" ] && rm -f "$legacy_cfg" || true
    done

    ui_done ok "$(plural "$removed" backup) deleted"
    echo ""
    return 0
  fi

  local vm_name="$arg" sel="${2:-}"
  if [ -z "$sel" ] && [[ "$arg" =~ ^(.+)-([0-9]{2}\.[0-9]{2}\.[0-9]{4}(-([0-9]{2}:[0-9]{2}:[0-9]{2}|[0-9]+))?)$ ]]; then
    vm_name="${BASH_REMATCH[1]}" sel="${BASH_REMATCH[2]}"
  fi
  sel="${sel#"$vm_name-"}"

  mapfile -t backup_dates < <(list_backup_timestamps_desc "$vm_name")
  if [ ${#backup_dates[@]} -eq 0 ]; then
    print_warning "No backups found for VM: $vm_name"
    return 1
  fi

  if [ -z "$sel" ]; then
    if ! list_backups "$vm_name" true; then
      print_warning "No backups to delete for VM: $vm_name"
      return 0
    fi
    read -r -p "  Number(s) to delete (e.g. 1 or 1,3): " selection || no_input
    selection=$(echo "$selection" | tr -d ' ')
    if [ -z "$selection" ]; then
      echo "  Cancelled."
      return 0
    fi

    IFS=',' read -r -a indices <<<"$selection"

    declare -a to_delete_dates
    for idx in "${indices[@]}"; do
      if ! [[ "$idx" =~ ^[0-9]+$ ]]; then
        print_error "Invalid number: $idx"
        return 1
      fi
      if [ "$idx" -lt 1 ] || [ "$idx" -gt ${#backup_dates[@]} ]; then
        print_error "Out of range: $idx"
        return 1
      fi
      local date_part="${backup_dates[$((idx - 1))]}"
      to_delete_dates+=("$date_part")
    done

    echo ""
    for d in "${to_delete_dates[@]}"; do
      [ -z "$d" ] && continue
      ui_step skip "$(pretty_ts "$d")" "$(get_file_size "$(get_backup_disk_path "$vm_name" "$d")")"
    done
    echo ""
    confirm_action "Delete $(plural "${#to_delete_dates[@]}" backup) of $vm_name?" || return 0

    local del_ok=0
    for date_part in "${to_delete_dates[@]}"; do
      [ -z "$date_part" ] && continue
      if remove_backup_artifacts "$vm_name" "$date_part" "backup"; then
        del_ok=$((del_ok + 1))
      fi
    done
    ui_done ok "$(plural "$del_ok" backup) of $vm_name deleted"
    echo ""
    return 0
  fi

  local resolved_ts=""
  if [ "$sel" = latest ]; then
    resolved_ts="${backup_dates[0]}"
  elif [[ "$sel" =~ ^([0-9]{2})\.([0-9]{2})\.([0-9]{4})-([0-9]{2}):([0-9]{2}):([0-9]{2})$ ]]; then
    resolved_ts="${BASH_REMATCH[3]}${BASH_REMATCH[2]}${BASH_REMATCH[1]}_${BASH_REMATCH[4]}${BASH_REMATCH[5]}${BASH_REMATCH[6]}"
  else
    resolved_ts=$(resolve_backup_selector "$vm_name" "$sel") || true
  fi
  if [ -z "$resolved_ts" ] || ! printf '%s\n' "${backup_dates[@]}" | grep -qxF -- "$resolved_ts"; then
    print_error "No matching backup found: $vm_name $sel (use dd.mm.yyyy[-N], dd.mm.yyyy-HH:MM:SS, YYYYMMDD_HHMMSS or latest)"
    return 1
  fi

  if remove_backup_artifacts "$vm_name" "$resolved_ts" "backup"; then
    ui_done ok "Backup $vm_name-$sel deleted" "taken $(pretty_ts "$resolved_ts")"
  else
    ui_done fail "Backup $vm_name-$sel could not be deleted" "check the permissions on $BACKUP_DIR"
    echo ""
    return 1
  fi
  echo ""
  return 0
}

troubleshoot_vm() {
  local vm_name="$1"

  if [ -z "$vm_name" ]; then
    print_error "VM name required for 'troubleshoot'"
    return 1
  fi

  if [ -x "$FIX_LOCK_SCRIPT" ]; then
    "$FIX_LOCK_SCRIPT" "$vm_name" --verbose
    return $?
  else
    print_error "fix-lock.sh script not found or not executable: $FIX_LOCK_SCRIPT"
    return 1
  fi
}
get_latest_backup() {
  local vm_name="$1"

  mapfile -t latest_list < <(collect_backup_timestamps "$vm_name" "" "desc")
  if [ ${#latest_list[@]} -gt 0 ]; then
    echo "${latest_list[0]}"
  fi
}

resolve_backup_selector() {
  local vm_name="$1"
  local selector="$2"

  if [ -z "$selector" ]; then
    echo ""
    return 0
  fi

  if [[ "$selector" =~ ^[0-9]{8}_[0-9]{6}$ ]]; then
    if [ -d "$(get_backup_folder_path "$vm_name" "$selector")" ] && ! backup_visible "$(get_backup_folder_path "$vm_name" "$selector")"; then
      echo ""
      return 1
    fi
    echo "$selector"
    return 0
  fi

  if [[ "$selector" =~ ^([0-9]{2})\.([0-9]{2})\.([0-9]{4})(-([0-9]+))?$ ]]; then
    local dd="${BASH_REMATCH[1]}"
    local mm="${BASH_REMATCH[2]}"
    local yyyy="${BASH_REMATCH[3]}"
    local n="${BASH_REMATCH[5]}"
    local yyyymmdd="${yyyy}${mm}${dd}"

    mapfile -t day_backups < <(list_day_backup_timestamps_asc "$vm_name" "$yyyymmdd")

    if [ ${#day_backups[@]} -eq 0 ]; then
      echo ""
      return 1
    fi

    if [ -z "$n" ]; then
      echo "${day_backups[-1]}"
      return 0
    else
      if ! [[ "$n" =~ ^[0-9]+$ ]]; then
        echo ""
        return 1
      fi
      if [ "$n" -lt 1 ] || [ "$n" -gt ${#day_backups[@]} ]; then
        echo ""
        return 1
      fi
      local idx=$((n - 1))
      echo "${day_backups[$idx]}"
      return 0
    fi
  fi
  echo ""
  return 1
}
export_backup() {
  local vm_name="$1"
  local backup_date="$2"
  local output_dir="$3"

  if [ -z "$vm_name" ]; then
    print_error "VM name required for 'export'"
    return 1
  fi

  if [ -n "$backup_date" ] && [ -z "$output_dir" ]; then
    if [ -d "$backup_date" ] || [[ "$backup_date" == */* ]] || [[ "$backup_date" == .* ]] || [[ "$backup_date" == ~* ]]; then
      output_dir="$backup_date"
      backup_date=""
    fi
  fi
  [ "$backup_date" = "latest" ] && backup_date=""
  [[ "$backup_date" == "$vm_name-"* ]] && backup_date="${backup_date#"$vm_name-"}"

  if [ -n "$backup_date" ] && [[ ! "$backup_date" =~ ^[0-9]{8}_[0-9]{6}$ ]]; then
    local _resolved
    _resolved=$(resolve_backup_selector "$vm_name" "$backup_date")
    if [ -z "$_resolved" ]; then
      print_error "Backup selector not found: $backup_date (use YYYYMMDD_HHMMSS, [<vm>-]dd.mm.yyyy[-N] or latest)"
      return 1
    fi
    backup_date="$_resolved"
  fi

  if [ -z "$backup_date" ]; then
    backup_date=$(get_latest_backup "$vm_name")
    if [ -z "$backup_date" ]; then
      print_error "No backups found for VM: $vm_name"
      return 1
    fi
    print_info "Using latest backup: $backup_date"
  fi

  local disk_backup=""
  local config_backup=""
  disk_backup=$(get_backup_disk_path "$vm_name" "$backup_date")
  config_backup=$(get_backup_config_path "$vm_name" "$backup_date")
  if [ -z "$disk_backup" ] || [ -z "$config_backup" ]; then
    print_error "Backup files not found for date: $backup_date"
    return 1
  fi
  ui_quiet
  ui_title "Exporting $vm_name" "backup $(pretty_ts "$backup_date") ${SYM_DOT} $(get_file_size "$disk_backup")"

  local export_base="$BACKUP_DIR/exports"
  [ -n "$output_dir" ] && export_base="$output_dir"
  export_base="${export_base/#\~/$HOME}"
  [[ "${DCVM_EXPORT_FD:-}" =~ ^[0-9]+$ ]] && export_base="$BACKUP_DIR/exports"
  if ! mkdir -p "$export_base"; then
    print_error "Cannot create export directory: $export_base"
    return 1
  fi

  local export_base_abs
  if ! export_base_abs=$(cd "$export_base" 2>/dev/null && pwd); then
    print_error "Cannot resolve export directory: $export_base"
    return 1
  fi
  export_base="$export_base_abs"

  local pkg_name="${vm_name}-${backup_date}.tar.gz"
  local pkg_path="$export_base/$pkg_name"

  local tmpdir
  tmpdir=$(mktemp -d) || return 1
  trap 'rm -rf "$tmpdir"' EXIT
  if [ "${EXPORT_FULL:-false}" = true ]; then
    local full_disk="$tmpdir/$(basename "${disk_backup%.gz}")"
    stage_backup_disk "$disk_backup" "$tmpdir/staged.qcow2" "$(dirname "$disk_backup")/base" || {
      rm -rf "$tmpdir"
      return 1
    }
    if ! ui_run "Flattening disk" qemu-img convert -f qcow2 -c -O qcow2 "$tmpdir/staged.qcow2" "$full_disk"; then
      rm -rf "$tmpdir"
      ui_step fail "Disk" "flattening failed"
      return 1
    fi
    rm -f "$tmpdir/staged.qcow2"
    disk_backup=$full_disk
    ui_step ok "Disk" "standalone, $(get_file_size "$full_disk") (${UI_RUN_SECS}s)"
  else
    ui_run "Copying disk" cp "$disk_backup" "$tmpdir/" || {
      rm -rf "$tmpdir"
      ui_step fail "Disk" "copy failed"
      print_error "Failed to copy disk backup"
      return 1
    }
    ui_step ok "Disk" "$(basename "$disk_backup") (${UI_RUN_SECS}s)"
    if [ -f "$(dirname "$disk_backup")/base" ]; then
      cp "$(dirname "$disk_backup")/base" "$tmpdir/base"
      ui_step ok "Base image" "recorded: $(sed -n 's/^build=//p' "$tmpdir/base" | sed 's#.*/##') (not included; --full makes the package standalone)"
    else
      ui_step warn "Base image" "not recorded (backup from before 0.9.9): the target needs the same build, or use --full"
    fi
  fi
  # The package leaves this host: no console password in it.
  sed "s/ passwd='[^']*'//g; s/ passwd=\"[^\"]*\"//g" "$config_backup" >"$tmpdir/$(basename "$config_backup")" || {
    rm -rf "$tmpdir"
    print_error "Failed to copy config backup"
    return 1
  }
  [ -f "$(dirname "$config_backup")/login" ] && cp "$(dirname "$config_backup")/login" "$tmpdir/login"

  local work_disk="$tmpdir/$(basename "$disk_backup")"
  local ssh_cleaned=false img
  if [ "$(caller_role)" = user ]; then
    # Root never opens a user's guest-controlled disk; the keys on it are the user's own.
    ui_step ok "SSH keys" "kept: the archive holds $vm_name's authorized_keys (your keys)"
  elif command -v guestfish >/dev/null 2>&1; then
    img=$work_disk
    if [[ "$work_disk" == *.gz ]]; then
      img="$tmpdir/.disk.qcow2"
      if ! gunzip -c "$work_disk" >"$img" 2>/dev/null; then
        rm -rf "$tmpdir"
        ui_step fail "Disk" "could not unpack $(basename "$work_disk") (corrupt, or no space in ${tmpdir%/*})"
        return 1
      fi
    fi
    guestfish --rw --format=qcow2 -a "$img" -i <<'GFSCMDS' 2>/dev/null && ssh_cleaned=true
-rm /root/.ssh/authorized_keys
-glob rm /home/*/.ssh/authorized_keys
GFSCMDS
    if [ "$img" != "$work_disk" ]; then
      # Recompressed to a new name: a failed gzip must not leave a truncated disk in the package.
      if [ "$ssh_cleaned" = true ] && ! { gzip -c "$img" >"$img.gz" && mv -f "$img.gz" "$work_disk"; }; then
        rm -rf "$tmpdir"
        ui_step fail "Disk" "could not compress it again (no space in ${tmpdir%/*}?)"
        return 1
      fi
      rm -f "$img"
    fi
    if [ "$ssh_cleaned" = true ]; then
      ui_step ok "SSH keys" "authorized_keys removed from the disk"
    else
      ui_step warn "SSH keys" "still on the disk (guestfish could not open it)"
    fi
  else
    ui_step warn "SSH keys" "still on the disk (install libguestfs-tools to remove them)"
  fi

  local vm_cloud_dir="${DATACENTER_BASE}/vms/${vm_name}/cloud-init"
  if [ -d "$vm_cloud_dir" ]; then
    mkdir -p "$tmpdir/cloud-init"
    [ -f "$vm_cloud_dir/meta-data" ] && cp "$vm_cloud_dir/meta-data" "$tmpdir/cloud-init/" || true
    [ -f "$vm_cloud_dir/network-config" ] && cp "$vm_cloud_dir/network-config" "$tmpdir/cloud-init/" || true
    rm -f "$tmpdir/cloud-init"/*authorized_keys 2>/dev/null || true
  fi

  cat >"$tmpdir/manifest.txt" <<EOF
vm_name=$vm_name
backup_date=$backup_date
disk_file=$(basename "$disk_backup")
disk=$([ "${EXPORT_FULL:-false}" = true ] && echo full || echo thin)
config_file=$(basename "$config_backup")
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
dcvm_version=portable
EOF

  [ -d "$tmpdir/cloud-init" ] && ui_step ok "cloud-init" "meta-data and network-config (user-data holds secrets and stays here)"

  if [[ "${DCVM_EXPORT_FD:-}" =~ ^[0-9]+$ ]]; then
    # /dev/fd/N would be reopened by path as root; write through the caller's descriptor.
    ui_run "Packing" bash -c 'tar -czf - -C "$1" . >&"$2"' _ "$tmpdir" "$DCVM_EXPORT_FD"
  else
    ui_run "Packing" tar -czf "$pkg_path" -C "$tmpdir" .
  fi || {
    rm -rf "$tmpdir"
    ui_step fail "Archive" "tar failed"
    print_error "Failed to create export archive"
    return 1
  }
  rm -rf "$tmpdir"
  trap - EXIT
  if [[ "${DCVM_EXPORT_FD:-}" =~ ^[0-9]+$ ]]; then
    ui_step ok "Archive" "written to your file (${UI_RUN_SECS}s)"
    return 0
  fi
  ui_step ok "Archive" "$(get_file_size "$pkg_path") (${UI_RUN_SECS}s)"

  ui_done ok "Exported to $pkg_path"
  ui_next "dcvm backup import $pkg_name" "on the other host: restore it there" \
    "dcvm backup ssh-setup $vm_name" "then put that host's SSH key on it"
  return 0
}

import_backup() {
  local pkg_path="$1"
  local rename_to="$2"
  if [ -z "$pkg_path" ]; then
    print_error "Package path required for 'import'"
    return 1
  fi
  if [ -n "$rename_to" ]; then
    validate_vm_name "$rename_to" || return 1
  fi
  pkg_path="${pkg_path/#\~/$HOME}"

  if [ ! -f "$pkg_path" ] && [ ! -d "$pkg_path" ]; then
    print_error "Package not found: $pkg_path"
    return 1
  fi

  local workdir
  workdir=$(mktemp -d)

  if [ -f "$pkg_path" ]; then
    if ! tar --no-same-owner --no-same-permissions -xzf "$pkg_path" -C "$workdir" 2>/dev/null; then
      rm -rf "$workdir"
      print_error "Unsupported or corrupt archive: $pkg_path"
      return 1
    fi
  else
    cp -r "$pkg_path"/* "$workdir"/ 2>/dev/null || true
  fi
  if [ -n "$(find "$workdir" -mindepth 1 ! -type f ! -type d -print -quit)" ]; then
    rm -rf "$workdir"
    print_error "The archive contains links or special files: $pkg_path"
    return 1
  fi

  local disk_file
  local config_file
  disk_file=$(ls "$workdir"/*-disk-*.qcow2* 2>/dev/null | head -1)
  config_file=$(ls "$workdir"/*-config-*.xml 2>/dev/null | head -1)

  if [ -z "$disk_file" ] || [ -z "$config_file" ]; then
    rm -rf "$workdir"
    print_error "Archive must contain *-disk-*.qcow2[.gz] and *-config-*.xml"
    return 1
  fi

  local base_disk vm_from date_part
  base_disk=$(basename "$disk_file")
  vm_from=${base_disk%%-disk-*}
  date_part=${base_disk#*-disk-}
  date_part=${date_part%.gz}
  date_part=${date_part%.qcow2}
  if ! validate_vm_name "$vm_from" || [[ ! "$date_part" =~ ^[0-9]{8}_[0-9]{6}$ ]]; then
    rm -rf "$workdir"
    print_error "Unexpected file names in the archive: $base_disk"
    return 1
  fi

  local vm_target="$vm_from"
  [ -n "$rename_to" ] && vm_target="$rename_to"

  mkdir -p -m 700 "$BACKUP_DIR" || {
    rm -rf "$workdir"
    print_error "Cannot create $BACKUP_DIR"
    return 1
  }
  local backup_folder="$(get_backup_folder_path "$vm_target" "$date_part")"
  if [ -e "$backup_folder" ]; then
    rm -rf "$workdir"
    print_error "A backup of $vm_target from $(pretty_ts "$date_part") already exists: $backup_folder"
    return 1
  fi
  mkdir -m 700 "$backup_folder" || {
    rm -rf "$workdir"
    print_error "Cannot create backup folder: $backup_folder"
    return 1
  }
  local tgt_disk="$backup_folder/${vm_target}-disk-${date_part}.qcow2"
  local tgt_cfg="$backup_folder/${vm_target}-config-${date_part}.xml"

  if [[ "$base_disk" == *.gz ]]; then
    tgt_disk+=".gz"
  fi

  ui_quiet
  ui_title "Importing $vm_target" "$(basename "$pkg_path")"
  cp "$disk_file" "$tgt_disk" || {
    rm -rf "$workdir" "$backup_folder"
    print_error "Failed to import disk file"
    return 1
  }
  cp "$config_file" "$tgt_cfg" || {
    rm -rf "$workdir" "$backup_folder"
    print_error "Failed to import config file"
    return 1
  }
  caller_uid >"$backup_folder/owner"
  local login
  [ -f "$workdir/login" ] && login=$(grep -Em1 '^[a-zA-Z_][a-zA-Z0-9_-]{0,31}$' "$workdir/login") && echo "$login" >"$backup_folder/login"
  if [ -f "$workdir/base" ]; then
    grep -E '^(image=[A-Za-z0-9][A-Za-z0-9._+-]*|sha256=[0-9a-f]{64}|sha512=[0-9a-f]{128}|added=[0-9T:+-]+)$' "$workdir/base" >"$backup_folder/base"
    # The archive's build= is a path on the other host; prune_builds keeps the build this one names after image and sha256.
    local img sha
    img=$(sed -n 's/^image=//p' "$backup_folder/base" | head -1) sha=$(sed -n 's/^sha256=//p' "$backup_folder/base" | head -1)
    valid_image_name "$img" && valid_sha256 "$sha" && echo "build=$(build_file "$img" "$sha")" >>"$backup_folder/base"
  fi
  chmod 600 "$backup_folder"/*

  rm -rf "$workdir"
  ui_step ok "Imported" "backup $(pretty_ts "$date_part") into $backup_folder"

  if ! restore_vm "$vm_target" "$date_part" "" "from_import"; then
    rm -rf "$backup_folder"
    return 1
  fi
}

# Writes a stopped VM's disk, base record, owner, login and config into a new <folder>.
write_backup_files() {
  local vm_name="$1" vm_disk_path="$2" folder="$3" how=uncompressed disk config
  disk="$folder/${vm_name}-disk-$DATE.qcow2" config="$folder/${vm_name}-config-$DATE.xml"
  if ! mkdir -m 700 "$folder"; then
    ui_step fail "Save disk" "cannot create $folder"
    return 1
  fi
  [ "$COMPRESSION_ENABLED" = true ] && disk+=".gz" && how=$(command -v pigz || echo gzip)
  if [ "$how" = uncompressed ]; then
    ui_run "Copying disk" cp --sparse=always "$vm_disk_path" "$disk"
  else
    ui_run "Compressing disk" sh -c '"$1" -c "$2" >"$3"' _ "$how" "$vm_disk_path" "$disk"
  fi || {
    ui_step fail "Save disk" "failed"
    cat "$UI_RUN_LOG"
    return 1
  }
  ui_step ok "Saved disk" "$(get_file_size "$disk") (${how##*/}) in ${UI_RUN_SECS}s"
  log "INFO" "Disk backup completed for $vm_name: $(get_file_size "$disk")"
  if ! write_base_record "$vm_disk_path" "$folder" || ! vm_owner_uid "$vm_name" >"$folder/owner" ||
    ! vm_login "$vm_name" >"$folder/login"; then
    ui_step fail "Save backup" "could not write the base, owner or login record"
    return 1
  fi
  # --security-info keeps the VNC/SPICE password; without it a restore opens the console to every local user.
  if ! (umask 077 && virsh dumpxml --security-info "$vm_name" >"$config") 2>/dev/null || [ ! -s "$config" ]; then
    ui_step fail "Save config" "virsh dumpxml failed"
    return 1
  fi
  chmod 600 "$folder"/*
  ui_step ok "Saved config" "$(basename "$config")"
}

backup_vm() {
  local vm_name="$1"
  local was_running=false

  ui_quiet
  log "INFO" "Starting backup for VM: $vm_name"

  if ! check_vm_exists "$vm_name"; then
    print_error "VM '$vm_name' does not exist"
    log "ERROR" "VM '$vm_name' does not exist"
    return 1
  fi

  local vm_disk_path=$(get_vm_disk_path "$vm_name")
  if [ -z "$vm_disk_path" ]; then
    print_error "Could not find disk path for VM '$vm_name'"
    log "ERROR" "Could not find disk path for VM '$vm_name'"
    return 1
  fi

  ui_title "Backing up $vm_name" "$(get_file_size "$vm_disk_path") disk ${SYM_DOT} $BACKUP_DIR"

  if ! mkdir -p -m 700 "$BACKUP_DIR"; then
    print_error "Failed to create backup directory: $BACKUP_DIR"
    return 1
  fi
  # The disk streams into the backup file, so it never needs more than the disk's allocated blocks.
  local need
  need=$(du -B1 "$vm_disk_path" 2>/dev/null | cut -f1)
  if [ "$(free_bytes "$BACKUP_DIR")" -lt "${need:-0}" ]; then
    ui_step fail "Free space" "$(format_bytes "$(free_bytes "$BACKUP_DIR")") free in $BACKUP_DIR; the backup needs up to $(format_bytes "$need")"
    echo -e "      ${DIM}$vm_name was not stopped. Free some space (dcvm backup delete <vm>), then try again.${NC}"
    return 1
  fi

  if [ "$(get_vm_state "$vm_name")" = "running" ]; then
    was_running=true
    # A VM that is still booting ignores the shutdown request; let it boot.
    local age
    age=$(ps -o etimes= -p "$(pgrep -f "[g]uest=$vm_name," | head -1)" 2>/dev/null | tr -d ' ')
    if [ "${age:-999}" -lt "$BOOT_GRACE" ]; then
      ui_run "Waiting for boot" sleep $((BOOT_GRACE - age))
      ui_step ok "Booted" "$vm_name started ${age}s ago; waited until it finished booting"
    fi
    if ! virsh shutdown "$vm_name" >/dev/null 2>&1; then
      print_error "Failed to send shutdown command"
      log "ERROR" "Failed to send shutdown command to VM $vm_name"
      return 1
    fi
    if ui_run "Shutting down" wait_for_vm_state "$vm_name" "shut off" "$SHUTDOWN_TIMEOUT"; then
      ui_step ok "Shut down" "cleanly in ${UI_RUN_SECS}s"
      log "INFO" "VM $vm_name shut down gracefully"
    else
      if [ -t 0 ] && ! confirm_action "$vm_name did not shut down in ${SHUTDOWN_TIMEOUT}s. Force it off (like pulling the plug)?"; then
        log "INFO" "Backup of $vm_name cancelled: it did not shut down"
        return 1
      fi
      virsh destroy "$vm_name" >/dev/null 2>&1
      sleep 5
      ui_step warn "Shut down" "forced after ${SHUTDOWN_TIMEOUT}s"
      log "WARNING" "Forced shutdown of VM $vm_name"
    fi
  fi

  local backup_folder_path="$BACKUP_DIR/${vm_name}-$DATE" rc=0
  # Built under a hidden name and renamed once complete, so a failed or interrupted backup never lists as one.
  local tmp="$BACKUP_DIR/.${vm_name}-$DATE.part"
  trap 'rm -rf "$tmp"; [ "$was_running" = true ] && virsh start "$vm_name" >/dev/null 2>&1' EXIT
  if ! prepare_vm_disk "$vm_name"; then
    log "ERROR" "Backup of $vm_name stopped: its base image could not be identified"
    rc=1
  elif ! write_backup_files "$vm_name" "$vm_disk_path" "$tmp" || ! mv -T "$tmp" "$backup_folder_path"; then
    log "ERROR" "Backup of $vm_name failed"
    rc=1
  fi
  trap - EXIT
  rm -rf "$tmp"

  if [ "$was_running" = true ]; then
    if virsh start "$vm_name" >/dev/null 2>&1; then
      ui_step ok "Started VM" "running again"
      log "INFO" "VM $vm_name restarted successfully"
    else
      ui_step fail "Start VM" "failed; run: dcvm start $vm_name"
      log "ERROR" "Failed to restart VM $vm_name"
    fi
  fi
  [ "$rc" = 0 ] || return 1

  local before after
  before=$(list_backup_timestamps_desc "$vm_name" | grep -c . || true)
  cleanup_old_backups "$vm_name"
  after=$(list_backup_timestamps_desc "$vm_name" | grep -c . || true)
  if [ "$after" -lt "$before" ]; then
    ui_step ok "Old backups" "removed $((before - after)), keeping the $KEEP_BACKUPS newest"
  fi

  echo ""
  echo -e "${GREEN}${SYM_OK}${NC} ${BOLD}Backup saved${NC}  ${DIM}$backup_folder_path${NC}"
  ui_next "dcvm backup restore $vm_name" "put $vm_name back to this point" \
    "dcvm backup list $vm_name" "all backups of $vm_name"

  log "SUCCESS" "Backup completed successfully for VM: $vm_name"
  return 0
}

hosts_rename_sed_expr() {
  # sed -E expression that renames host name $1 to $2 in /etc/hosts. Callers
  # apply it twice: one pass cannot rename adjacent matches ("vm1 vm1") that
  # share a separator.
  printf 's/([[:space:]])%s([.[:space:]]|$)/\\1%s\\2/g' "$1" "$2"
}

# A user's disk is guest-controlled, so root never opens it with libguestfs: the copy gets a
# new cloud-init instance instead, which regenerates SSH host keys and sets the hostname.
reseed_restored_guest() {
  local vm="$1" dir="$DATACENTER_BASE/vms/$1" tool=genisoimage
  command -v mkisofs >/dev/null 2>&1 && tool=mkisofs
  command -v "$tool" >/dev/null 2>&1 || return 1
  mkdir -p -m 700 "$dir/cloud-init" &&
    (umask 077 && printf 'instance-id: %s-%s\nlocal-hostname: %s\n' "$vm" "$(date +%s)" "$vm" >"$dir/cloud-init/meta-data" &&
      printf '%s\n' '#cloud-config' 'users: []' 'bootcmd:' \
        '  - [cloud-init-per, instance, dcvm-machine-id, sh, -c, "rm -f /etc/machine-id /var/lib/dbus/machine-id; systemd-machine-id-setup"]' \
        >"$dir/cloud-init/user-data" &&
      "$tool" -output "$dir/cloud-init.iso" -volid cidata -joliet -rock "$dir/cloud-init/" >/dev/null 2>&1) || return 1
  chmod 600 "$dir/cloud-init.iso"
}

customize_restored_guest() {
  local disk_path="$1"
  local new_name="$2"
  local old_name="$3"

  if ! validate_vm_name "$new_name" >/dev/null 2>&1; then
    print_warning "Not customizing guest: invalid name '$new_name'"
    return 1
  fi
  if ! command -v virt-customize >/dev/null 2>&1; then
    print_warning "virt-customize not found (install libguestfs-tools); the copy keeps the hostname, machine-id and SSH host keys of '$old_name'"
    print_info "Inside the VM run: sudo hostnamectl set-hostname $new_name"
    print_info "  and reset its identity: sudo truncate -s 0 /etc/machine-id; sudo rm -f /etc/ssh/ssh_host_*; sudo ssh-keygen -A; then reboot"
    return 1
  fi

  local -a args=(-q --format qcow2 -a "$disk_path" --hostname "$new_name")
  if [ -n "$old_name" ] && validate_vm_name "$old_name" >/dev/null 2>&1; then
    local hosts_expr
    hosts_expr=$(hosts_rename_sed_expr "$old_name" "$new_name")
    args+=(--run-command "if [ -f /etc/hosts ]; then sed -i -E -e '$hosts_expr' -e '$hosts_expr' /etc/hosts; fi")
  fi
  # An empty /etc/machine-id makes systemd generate a new one on the next boot
  # (what virt-sysprep does). The D-Bus copy is removed unless it is a symlink.
  args+=(--run-command 'truncate -s 0 /etc/machine-id; [ -L /var/lib/dbus/machine-id ] || rm -f /var/lib/dbus/machine-id')
  # New SSH host keys are generated on the first boot, before sshd is reloaded.
  args+=(--firstboot-command 'rm -f /etc/ssh/ssh_host_*; ssh-keygen -A; systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true')

  print_info "Customizing guest: hostname '$new_name', new machine-id, new SSH host keys on first boot..."
  if virt-customize "${args[@]}" >/dev/null 2>&1; then
    print_success "Guest hostname set to '$new_name'; machine-id and SSH host keys will be regenerated on first boot"
    return 0
  fi
  print_warning "Could not customize guest; inside the VM run: sudo hostnamectl set-hostname $new_name"
  print_info "  and reset its identity: sudo truncate -s 0 /etc/machine-id; sudo rm -f /etc/ssh/ssh_host_*; sudo ssh-keygen -A; then reboot"
  return 1
}

restore_disk_base() {
  local disk="$1" record="$2" backing img="" build="" how="" sha256 sha512 cur
  backing=$(disk_backing "$disk")
  if [ -z "$backing" ]; then
    ui_step ok "Base image" "none needed (standalone disk)"
    return 0
  fi
  [ -f "$record" ] && img=$(sed -n 's/^image=//p' "$record" | head -1)
  valid_image_name "$img" || img=""
  if [ -z "$img" ]; then
    case "$backing" in
    "$(builds_dir)"/*) img=$(build_image "$backing") ;;
    *) img=${backing##*/} ;;
    esac
  fi
  if ! valid_image_name "$img"; then
    ui_step fail "Base image" "the backup names an invalid base image"
    return 1
  fi
  if [ -n "${RESTORE_BASE:-}" ]; then
    if [ ! -f "$RESTORE_BASE" ]; then
      print_error "--base: no such file: $RESTORE_BASE"
      return 1
    fi
    build=$(register_build "$RESTORE_BASE" "$img") && how="given with --base"
  elif [ -f "$record" ]; then
    sha256=$(sed -n 's/^sha256=//p' "$record")
    sha512=$(sed -n 's/^sha512=//p' "$record")
    if build=$(find_build "$sha256"); then
      how="on this host"
    elif cur=$(current_build "$img" 2>/dev/null) && [ "$(build_sum "$cur" sha256)" = "$sha256" ]; then
      build=$cur how="the current template"
    elif build=$(fetch_archived_build "$img" "$sha256" "$sha512"); then
      how="fetched from the archive"
    fi
  elif registered_build "$backing"; then
    build=$(realpath -e -- "$backing") how="on this host"
  elif ! inside_dir "$backing" "$(templates_dir)"; then
    ui_step fail "Base image" "the disk's base is outside dcvm's templates: $backing"
    return 1
  else
    if ui_run "Checking base" legacy_disk_build "$disk" "$img" && [ -n "$(tail -1 "$UI_RUN_LOG")" ]; then
      build=$(tail -1 "$UI_RUN_LOG")
      how="matched by a file system check (backup from before 0.9.9)"
    fi
  fi
  if [ -z "$build" ]; then
    ui_step fail "Base image" "the $(image_label "$img") build this disk was made on is not on this host or in the archive"
    echo -e "      ${DIM}Restore on the host it came from, or copy that build here and use --base <file>.${NC}"
    return 1
  fi
  qemu-img rebase -u -f qcow2 -b "$build" -F qcow2 "$disk" || return 1
  ui_step ok "Base image" "${build##*/}, $how"

  if ! cur=$(current_build "$img" 2>/dev/null); then
    if download_image_ui "$img" "$(templates_dir)/$img" 100000000; then
      cur=$(current_build "$img")
    else
      ui_step warn "Base image" "stays on ${build##*/}: no $(image_label "$img") template could be downloaded"
      return 0
    fi
  fi
  if [ "$cur" != "$build" ]; then
    if ui_run "Base image" rebase_disk "$disk" "$cur"; then
      ui_step ok "Base image" "moved to the current build ${cur##*/} (${UI_RUN_SECS}s)"
    else
      ui_step warn "Base image" "could not move to ${cur##*/}; stays on ${build##*/}"
    fi
  fi
  return 0
}

stage_backup_disk() {
  local disk="$1" staged="$2" record="$3"
  rm -f "$staged"
  if [[ "$disk" == *.gz ]]; then
    if ! gunzip -t "$disk" >/dev/null 2>&1; then
      print_error "Compressed backup file is corrupted: $disk"
      return 1
    fi
    ui_run "Unpacking disk" sh -c 'gunzip -c "$1" >"$2"' _ "$disk" "$staged"
  else
    ui_run "Copying disk" cp --sparse=always "$disk" "$staged"
  fi || {
    rm -f "$staged"
    print_error "Could not unpack the backup disk"
    return 1
  }
  ui_step ok "Unpacked disk" "$(get_file_size "$staged") in ${UI_RUN_SECS}s"
  if ! check_disk_image "$staged"; then
    rm -f "$staged"
    ui_step fail "Disk" "not a plain qcow2 image (external data file, other format or backing protocol)"
    return 1
  fi
  restore_disk_base "$staged" "$record" || {
    rm -f "$staged"
    return 1
  }
}

# A restore that fails after replacing a VM puts the old definition and disk back.
undo_restore() {
  local vm_name="$1" prev_xml="$2" prev_disk="$3" disk="$4"
  quota_release "$vm_name"
  [ -n "$prev_disk" ] && mv -f "$prev_disk" "$disk"
  if [ -s "$prev_xml" ] && virsh define "$prev_xml" >/dev/null 2>&1; then
    print_warning "Restore failed: the previous $vm_name is back"
  fi
  rm -f "$prev_xml"
}

restore_vm() {
  ui_quiet
  local source_name="$1"
  local vm_name="${5:-$1}"
  local backup_date="$2"
  local opt_third="$3"
  local opt_fourth="$4"
  local force_restore=""
  local from_import=""
  if [ "$opt_third" = "true" ]; then force_restore="true"; fi
  if [ "$opt_fourth" = "from_import" ]; then from_import="true"; fi
  local final_state="shut off"
  local skip_auto_start=false
  local start_error=""

  if [ "$vm_name" != "$source_name" ] && ! validate_vm_name "$vm_name"; then
    return 1
  fi

  if [ "$vm_name" != "$source_name" ]; then
    print_info "Starting restore of '$source_name' backup as new VM: $vm_name"
    log "INFO" "Starting restore of $source_name backup as VM: $vm_name"
  else
    print_info "Starting restore for VM: $vm_name"
    log "INFO" "Starting restore for VM: $vm_name"
  fi

  [ "$backup_date" = "latest" ] && backup_date=""
  [[ "$backup_date" == "$source_name-"* ]] && backup_date="${backup_date#"$source_name-"}"

  if [ -n "$backup_date" ] && [[ ! "$backup_date" =~ ^[0-9]{8}_[0-9]{6}$ ]]; then
    local _resolved
    _resolved=$(resolve_backup_selector "$source_name" "$backup_date")
    if [ -z "$_resolved" ]; then
      print_error "Backup selector not found: $backup_date (use YYYYMMDD_HHMMSS, [<vm>-]dd.mm.yyyy[-N] or latest)"
      return 1
    fi
    backup_date="$_resolved"
  fi

  if [ -z "$backup_date" ]; then
    backup_date=$(get_latest_backup "$source_name")
    if [ -z "$backup_date" ]; then
      print_error "No backups found for VM: $source_name"
      log "ERROR" "No backups found for VM: $source_name"
      return 1
    fi
    print_info "Using latest backup: $backup_date"
  fi

  local disk_backup=""
  local config_backup=""
  disk_backup=$(get_backup_disk_path "$source_name" "$backup_date")
  config_backup=$(get_backup_config_path "$source_name" "$backup_date")
  local is_compressed=false
  if [ -z "$disk_backup" ] || [ -z "$config_backup" ]; then
    print_error "Backup not found for date: $backup_date"
    print_info "Available backups:"
    list_backups "$source_name"
    return 1
  fi
  [[ "$disk_backup" == *.gz ]] && is_compressed=true
  print_info "Found $([ "$is_compressed" = true ] && echo compressed || echo uncompressed) backup: $(basename "$disk_backup")"

  print_info "Found backup files:"
  print_info "  Disk: $(basename "$disk_backup") ($(get_file_size "$disk_backup"))"
  print_info "  Config: $(basename "$config_backup")"
  ui_quiet
  if [ "$source_name" != "$vm_name" ]; then
    ui_title "Restoring $source_name as $vm_name" "backup $backup_date ${SYM_DOT} $(get_file_size "$disk_backup")"
  else
    ui_title "Restoring $vm_name" "backup $backup_date ${SYM_DOT} $(get_file_size "$disk_backup")"
  fi

  local staged="$BACKUP_DIR/.restore-${vm_name}.qcow2"
  local vm_exists=false vm_state=""
  if check_vm_exists "$vm_name"; then
    vm_exists=true
    if [ "$(registry_get "$vm_name" protected)" = 1 ]; then
      print_error "$vm_name is protected: dcvm unprotect $vm_name first"
      return 1
    fi
    vm_state=$(get_vm_state "$vm_name")
    print_warning "VM '$vm_name' already exists (state: $vm_state)"

    if [ "$force_restore" != "true" ]; then
      print_warning "This will COMPLETELY REPLACE the existing VM!"
      print_warning "All current data in the VM will be LOST!"
      read -p "Are you sure you want to continue? (type 'yes' to confirm): " confirm || no_input
      echo ""

      if [ "$confirm" != "yes" ]; then
        print_info "Restore cancelled by user"
        return 0
      fi
    fi
  fi

  stage_backup_disk "$disk_backup" "$staged" "$(dirname "$disk_backup")/base" || return 1

  local vm_dir="$DATACENTER_BASE/vms/$vm_name"
  local vm_disk_path="$vm_dir/${vm_name}-disk.qcow2"

  local backup_vm_name renamed=false static_ip_copy=""
  backup_vm_name=$(sed -n 's|^[[:space:]]*<name>\([^<]*\)</name>.*|\1|p' "$config_backup" | head -1)
  if [[ ! "$backup_vm_name" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_-]*$ ]]; then
    backup_vm_name="" renamed=true
  elif [ "$backup_vm_name" != "$vm_name" ]; then
    renamed=true
    local source_net_conf="${DATACENTER_BASE:-/srv/datacenter}/config/network/${backup_vm_name}.conf"
    if [ -f "$source_net_conf" ]; then
      static_ip_copy=$(grep '^IP=' "$source_net_conf" | head -1 | cut -d'=' -f2- | sed 's/^"//;s/"$//')
      [ -n "$static_ip_copy" ] || static_ip_copy="unknown"
      print_warning "The copy keeps static IP $static_ip_copy from $backup_vm_name (set inside the guest); change it before starting $vm_name"
      print_info "'$vm_name' will not be started or set to autostart"
    fi
  fi

  print_info "Restoring VM configuration..."

  local temp_config=$(mktemp)

  if ! cp "$config_backup" "$temp_config"; then
    print_error "Failed to prepare temporary config file"
    rm -f "$temp_config" "$staged"
    return 1
  fi

  if ! sanitize_domain_xml "$temp_config" "$vm_name" "$vm_disk_path" "$renamed" 2>/dev/null; then
    print_error "The backup's VM configuration could not be read"
    rm -f "$temp_config" "$staged"
    return 1
  fi

  local cpus mem_kib disk_bytes mem_mb disk_gb
  cpus=$(sed -n 's/.*<vcpu[^>]*>\([0-9]*\)<\/vcpu>.*/\1/p' "$temp_config" | head -1)
  mem_kib=$(sed -n 's/.*<memory[^>]*>\([0-9]*\)<\/memory>.*/\1/p' "$temp_config" | head -1)
  disk_bytes=$(qemu-img info -U --output=json "$staged" 2>/dev/null | python3 -I -S -c 'import json, sys; print(json.load(sys.stdin)["virtual-size"])' 2>/dev/null)
  mem_mb=$((${mem_kib:-0} / 1024)) disk_gb=$(((${disk_bytes:-0} + 1073741823) / 1073741824))
  if [ -n "${DCVM_QUOTA_LIMITS:-}" ] && { [ -z "$cpus" ] || [ -z "$mem_kib" ] || [ -z "$disk_bytes" ]; }; then
    print_error "Could not read the backup's size to check your quota"
    rm -f "$temp_config" "$staged"
    return 1
  fi
  if ! within_quota "${cpus:-1}" "$mem_mb" "$disk_gb" "$vm_name"; then
    rm -f "$temp_config" "$staged"
    return 1
  fi

  print_info "Preparing VM directory..."
  if ! mkdir -p "$vm_dir" || ! chmod 711 "$vm_dir"; then
    print_error "Failed to create VM directory: $vm_dir"
    quota_release "$vm_name"
    rm -f "$temp_config" "$staged"
    return 1
  fi

  local prev_xml="" prev_disk=""
  if [ "$vm_exists" = true ]; then
    vm_state=$(get_vm_state "$vm_name")
    if [ "$vm_state" = "running" ]; then
      print_info "Stopping existing VM..."
      virsh shutdown "$vm_name" >/dev/null 2>&1

      if ui_run "Stopping VM" wait_for_vm_state "$vm_name" "shut off" "$SHUTDOWN_TIMEOUT"; then
        ui_step ok "Stopped VM" "cleanly in ${UI_RUN_SECS}s"
      else
        virsh destroy "$vm_name" >/dev/null 2>&1
        sleep 5
        ui_step warn "Stopped VM" "forced after ${SHUTDOWN_TIMEOUT}s"
      fi
    elif [ "$vm_state" != "shut off" ]; then
      virsh destroy "$vm_name" >/dev/null 2>&1
      ui_step ok "Stopped VM" "was $vm_state"
    fi
    if [ "$(get_vm_state "$vm_name")" != "shut off" ]; then
      print_error "Could not stop $vm_name; it was left as it is"
      quota_release "$vm_name"
      rm -f "$temp_config" "$staged"
      return 1
    fi

    prev_xml=$(mktemp)
    virsh dumpxml --inactive --security-info "$vm_name" >"$prev_xml" 2>/dev/null
    print_info "Removing existing VM definition (keeping storage)..."
    # Keep a UEFI VM's variables: a rollback redefines it with the same NVRAM file.
    virsh undefine "$vm_name" --keep-nvram >/dev/null 2>&1 || virsh undefine "$vm_name" >/dev/null 2>&1 || true

    print_info "Running fix-lock.sh for comprehensive cleanup..."
    if [ -x "$FIX_LOCK_SCRIPT" ]; then
      "$FIX_LOCK_SCRIPT" "$vm_name" >/dev/null 2>&1 || true
    else
      print_warning "fix-lock.sh not found, doing basic cleanup..."
      virsh destroy "$vm_name" >/dev/null 2>&1 || true
      sleep 2
    fi
  fi

  if [ -f "$vm_disk_path" ]; then
    print_info "Setting the existing disk aside until the restored VM is defined..."
    lsof "$vm_disk_path" 2>/dev/null && sleep 3
    prev_disk="$vm_disk_path.pre-restore"
    mv -f "$vm_disk_path" "$prev_disk" || {
      print_error "Failed to move the existing disk file aside: $vm_disk_path"
      undo_restore "$vm_name" "$prev_xml" "" "$vm_disk_path"
      rm -f "$temp_config" "$staged"
      return 1
    }
  fi

  if mv -f "$staged" "$vm_disk_path"; then
    ui_step ok "Restored disk" "$(get_file_size "$vm_disk_path")"
  else
    rm -f "$staged"
    print_error "Could not move the restored disk into place: $vm_disk_path"
    undo_restore "$vm_name" "$prev_xml" "$prev_disk" "$vm_disk_path"
    rm -f "$temp_config"
    return 1
  fi

  if [ ! -f "$vm_disk_path" ] || [ ! -s "$vm_disk_path" ]; then
    print_error "Restored disk file is missing or empty: $vm_disk_path"
    undo_restore "$vm_name" "$prev_xml" "$prev_disk" "$vm_disk_path"
    rm -f "$temp_config"
    return 1
  fi

  normalize_backing_chain "$vm_disk_path" || true

  print_info "Setting correct permissions and ownership..."

  if id -u libvirt-qemu >/dev/null 2>&1; then
    chown libvirt-qemu:kvm "$vm_disk_path" 2>/dev/null || chown root:root "$vm_disk_path"
  elif id -u qemu >/dev/null 2>&1; then
    chown qemu:qemu "$vm_disk_path" 2>/dev/null || chown root:root "$vm_disk_path"
  else
    chown root:root "$vm_disk_path"
  fi

  chmod 600 "$vm_disk_path"

  if command -v restorecon >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
    restorecon "$vm_disk_path" 2>/dev/null || true
  fi

  print_success "File permissions and ownership set"

  local reseeded=false
  if [ "$renamed" = true ] && [ "$(caller_role)" = user ]; then
    reseed_restored_guest "$vm_name" && reseeded=true ||
      print_warning "Could not give $vm_name a new identity; inside the VM: sudo hostnamectl set-hostname $vm_name, then reset /etc/machine-id and the SSH host keys"
  elif [ "$renamed" = true ]; then
    customize_restored_guest "$vm_disk_path" "$vm_name" "$backup_vm_name" || true
  fi

  local define_output attempt=1 max_attempts=3 defined=false
  while [ $attempt -le $max_attempts ]; do
    define_output=$(virsh define "$temp_config" 2>&1)
    if [ $? -eq 0 ]; then
      ui_step ok "Defined VM" "libvirt config restored$([ "$attempt" -gt 1 ] && echo " (attempt $attempt)")"
      [ -f "$(registry_file "$vm_name")" ] || register_vm "$vm_name"
      local login_file login
      login_file="$(dirname "$config_backup")/login"
      if [ "$(dirname "$config_backup")" != "$BACKUP_DIR" ] && [ -f "$login_file" ]; then
        login=$(grep -Em1 '^[a-zA-Z_][a-zA-Z0-9_-]{0,31}$' "$login_file")
      else
        login=$(vm_login "$vm_name")
      fi
      registry_set "$vm_name" "cpus=${cpus:-1}" "memory_mb=$mem_mb" "disk_gb=$disk_gb" "user=$login"
      if [ "$reseeded" = true ]; then
        virsh attach-disk "$vm_name" "$DATACENTER_BASE/vms/$vm_name/cloud-init.iso" sdc --type cdrom --mode readonly --targetbus sata --config >/dev/null 2>&1 &&
          ui_step ok "Identity" "new hostname, SSH host keys and machine-id on first boot" ||
          print_warning "Could not attach $vm_name's new cloud-init seed; it keeps the source's identity"
      fi
      log "INFO" "VM configuration restored for $vm_name on attempt $attempt"
      defined=true
      break
    fi
    if echo "$define_output" | grep -q "must be model='pci-root'"; then
      print_warning "Adjusting root PCI controller to pci-root"
      if command -v xmlstarlet >/dev/null 2>&1; then
        xmlstarlet ed -P -L -u "/domain/devices/controller[@type='pci' and @index='0']/@model" -v "pci-root" "$temp_config" 2>/dev/null || true
      else
        sed -i "/<controller[^>]*type=['\"]pci['\"][^>]*index=['\"]0['\"][^>]*>/s/model=['\"][^'\"]*['\"]/model='pci-root'/" "$temp_config"
        sed -i "/<controller[^>]*type=['\"]pci['\"][^>]*index=['\"]0['\"][^>]*>/s/model=\"[^\"]*\"/model=\"pci-root\"/" "$temp_config"
      fi
    elif echo "$define_output" | grep -q "requires a controller that accepts a pcie-root-port"; then
      print_warning "Switching to q35 + pcie-root + pcie-root-port"
      if command -v xmlstarlet >/dev/null 2>&1; then
        curmach=$(xmlstarlet sel -t -v "/domain/os/type/@machine" "$temp_config" 2>/dev/null)
        if [ "$curmach" != "q35" ]; then
          xmlstarlet ed -P -L -i "/domain/os/type[not(@machine)]" -t attr -n machine -v "q35" "$temp_config" 2>/dev/null || true
          xmlstarlet ed -P -L -u "/domain/os/type/@machine" -v "q35" "$temp_config" 2>/dev/null || true
        fi
        xmlstarlet ed -P -L -u "/domain/devices/controller[@type='pci' and @index='0']/@model" -v "pcie-root" "$temp_config" 2>/dev/null || true
        if ! xmlstarlet sel -t -v "count(/domain/devices/controller[@type='pci' and @model='pcie-root-port'])" "$temp_config" 2>/dev/null | grep -q '[1-9]'; then
          xmlstarlet ed -P -L -s "/domain/devices" -t elem -n controllerTMP -v "" "$temp_config" 2>/dev/null || true
          xmlstarlet ed -P -L -i "/domain/devices/controllerTMP" -t attr -n type -v "pci" "$temp_config" 2>/dev/null || true
          xmlstarlet ed -P -L -i "/domain/devices/controllerTMP" -t attr -n model -v "pcie-root-port" "$temp_config" 2>/dev/null || true
          xmlstarlet ed -P -L -i "/domain/devices/controllerTMP" -t attr -n index -v "1" "$temp_config" 2>/dev/null || true
          sed -i "s/controllerTMP/controller/" "$temp_config"
        fi
      else
        grep -q "machine='q35'\|machine=\"q35\"" "$temp_config" || sed -i "s|<type arch='x86_64'\(.*\)>hvm</type>|<type arch='x86_64' machine='q35'\1>hvm</type>|" "$temp_config"
        sed -i "/<controller[^>]*type=['\"]pci['\"][^>]*index=['\"]0['\"][^>]*>/s/model=['\"][^'\"]*['\"]/model='pcie-root'/" "$temp_config"
        sed -i "/<controller[^>]*type=['\"]pci['\"][^>]*index=['\"]0['\"][^>]*>/s/model=\"[^\"]*\"/model=\"pcie-root\"/" "$temp_config"
        if ! grep -q "pcie-root-port" "$temp_config"; then
          sed -i "/<devices>/a \\t<controller type='pci' model='pcie-root-port' index='1'/>" "$temp_config"
        fi
      fi
    else
      print_error "Define failed (attempt $attempt): $define_output"
    fi
    attempt=$((attempt + 1))
    [ $attempt -le $max_attempts ] && print_info "Retrying define (attempt $attempt)..." && sleep 1
  done
  if [ "$defined" != true ]; then
    print_error "Giving up after $max_attempts attempts"
    sed -n '1,30p' "$temp_config"
    rm -f "$temp_config"
    undo_restore "$vm_name" "$prev_xml" "$prev_disk" "$vm_disk_path"
    return 1
  fi
  rm -f "$prev_disk" "$prev_xml"

  rm -f "$temp_config"

  if [ -n "$static_ip_copy" ]; then
    print_warning "Autostart not enabled: '$vm_name' keeps static IP $static_ip_copy from '$backup_vm_name'"
  elif virsh autostart "$vm_name" >/dev/null 2>&1; then
    print_success "VM autostart enabled"
  else
    print_warning "Failed to enable VM autostart (VM may still work)"
  fi

  if check_vm_exists "$vm_name"; then
    print_success "VM successfully restored and defined in libvirt"
  else
    print_error "VM restore completed but VM not found in libvirt"
    return 1
  fi

  print_info "Waiting for libvirt to register the restored VM..."
  sleep 3

  print_info "Performing post-restore verification and cleanup..."
  sleep 3

  print_info "Checking for other VMs referencing the restored disk..."
  conflicting_vms=$(virsh list --all --name 2>/dev/null | grep -v "^$" | while read -r other; do
    [ "$other" = "$vm_name" ] && continue
    virsh domblklist "$other" --details 2>/dev/null | awk '{print $4}' | grep -Fxq "$vm_disk_path" && echo "$other"
  done)

  if [ -n "$conflicting_vms" ]; then
    print_error "The disk is referenced by other VM(s): $(echo $conflicting_vms | tr '\n' ' ')"
    echo "This will cause shared write lock failures."
    echo "Resolve by detaching/changing disk on those VMs or undefining them before start."
    echo "You can run: sudo $FIX_LOCK_SCRIPT $vm_name --verbose (for cleanup), but conflicts must be fixed manually."
    final_state="shut off (conflicting domains detected)"
    skip_auto_start=true
    start_error="Disk referenced by other VM(s): $(echo "$conflicting_vms" | tr '\n' ' ')"
  fi

  local start_attempts=0
  local max_attempts=2

  if [ -n "$static_ip_copy" ] && [ "$skip_auto_start" = false ]; then
    skip_auto_start=true
    final_state="shut off (static IP $static_ip_copy copied from $backup_vm_name)"
    print_warning "Not starting '$vm_name': change the static IP $static_ip_copy inside the guest first (it belongs to '$backup_vm_name')"
  elif [ "$skip_auto_start" = true ]; then
    print_warning "Skipping auto-start due to conflicting VM references"
  else
    print_info "Attempting to start VM..."
    while [ $start_attempts -lt $max_attempts ]; do
      local attempt=$((start_attempts + 1))
      print_info "Start attempt ${attempt}/$max_attempts"
      start_error=$(virsh start "$vm_name" 2>&1)
      if [ $? -eq 0 ]; then
        print_success "VM restore completed and VM is now starting!"
        if wait_for_vm_state "$vm_name" "running" 30; then
          ui_step ok "Started VM" "running"
          final_state="running"
        else
          ui_step warn "Started VM" "still booting"
          final_state="starting"
        fi
        break
      fi

      print_error "Start attempt ${attempt} failed: $start_error"

      if is_lock_error "$start_error" && [ $start_attempts -eq 0 ]; then
        print_warning "Detected lock-related error, running fix-lock.sh..."
        if [ -x "$FIX_LOCK_SCRIPT" ]; then
          if "$FIX_LOCK_SCRIPT" "$vm_name"; then
            print_success "fix-lock.sh completed successfully"
            start_attempts=$((start_attempts + 1))
            print_info "Waiting before retry..."
            sleep 3
            continue
          else
            print_error "fix-lock.sh failed"
            break
          fi
        else
          print_error "fix-lock.sh script not found or not executable: $FIX_LOCK_SCRIPT"
          break
        fi
      fi

      print_error "Cannot recover from error: $start_error"
      break
    done
  fi

  local need_manual_help=false
  if [ "$final_state" != "running" ]; then
    if [ "$skip_auto_start" = false ]; then
      if wait_for_vm_state "$vm_name" "running" 5; then
        final_state="running"
      else
        need_manual_help=true
        final_state="shut off (manual start needed)"
      fi
    elif [ -z "$static_ip_copy" ] || [ -n "$conflicting_vms" ]; then
      need_manual_help=true
    fi
  fi

  if [ "$need_manual_help" = true ] && [ "$final_state" != "running" ]; then
    print_warning "VM restored but failed to start automatically after $max_attempts attempts"
    "$SCRIPT_DIR/../utils/doctor.sh" --quiet --fast --only host,network,vms --vm "$vm_name" || true
    [ -z "$start_error" ] && start_error="Auto-start skipped."
    echo "Last error was: $start_error"
  fi

  if [ "$from_import" = "true" ] && [ -n "$static_ip_copy" ]; then
    echo "SSH key setup skipped (it starts the VM). After changing the IP: dcvm backup ssh-setup $vm_name"
  elif [ "$from_import" = "true" ]; then
    read -r -p "Configure SSH keys for this VM? (recommended after import) (Y/n): " setup_ssh || setup_ssh=n
    setup_ssh=${setup_ssh:-y}
    if [[ "$setup_ssh" =~ ^[Yy]$ ]]; then
      ssh_setup_vm "$vm_name"
    fi
  fi

  echo ""
  if [ "$final_state" = "running" ]; then
    echo -e "${GREEN}${SYM_OK}${NC} ${BOLD}$vm_name restored${NC}  ${DIM}from backup $backup_date, $(get_file_size "$vm_disk_path") disk${NC}"
    echo ""
  else
    print_warning "$vm_name restored from backup $backup_date but not running: $final_state"
    ui_next "dcvm start $vm_name" "start it" "$FIX_LOCK_SCRIPT $vm_name" "clear stale locks if it won't start"
  fi
  log "SUCCESS" "Restore completed successfully for VM: $vm_name from backup: $backup_date"
  return 0
}

ssh_setup_vm() {
  local vm_name="$1"
  local ssh_wait_total=120
  local ssh_wait_interval=5
  local ssh_waited=0
  local ip_wait_total=120

  if [ -z "$vm_name" ]; then
    print_error "VM name required for 'ssh-setup'"
    return 1
  fi

  if ! check_vm_exists "$vm_name"; then
    print_error "VM '$vm_name' does not exist"
    return 1
  fi

  ui_title "SSH key for $vm_name" "copies this host's public key with ssh-copy-id"
  read -r -p "  User on the VM (e.g. ubuntu, debian, root): " target_user || no_input
  target_user=${target_user:-root}

  if [[ ! "$target_user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    print_error "Invalid username: $target_user"
    return 1
  fi

  local vm_state
  vm_state=$(get_vm_state "$vm_name")
  if [ "$vm_state" != "running" ]; then
    print_info "Starting VM '$vm_name'..."
    virsh start "$vm_name" >/dev/null 2>&1 || {
      print_error "Failed to start VM"
      return 1
    }
    print_info "Waiting for VM to boot (30s)..."
    sleep 30
  fi

  local vm_ip=""
  local ip_deadline=$((SECONDS + ip_wait_total))
  print_info "Waiting up to ${ip_wait_total}s for the VM IP address (checked every 2s)..."
  while :; do
    vm_ip=$(get_vm_ip "$vm_name" 1 2>/dev/null)
    if [ -n "$vm_ip" ] && [ "$vm_ip" != "N/A" ]; then
      break
    fi
    vm_ip=""
    [ "$SECONDS" -ge "$ip_deadline" ] && break
    sleep 2
  done
  if [ -z "$vm_ip" ]; then
    print_error "Could not determine VM IP address"
    print_info "Try waiting longer for VM to boot and get DHCP lease, then run: dcvm backup ssh-setup $vm_name"
    return 1
  fi

  print_info "Waiting for SSH on $vm_ip (timeout ${ssh_wait_total}s)..."
  while ! bash -c "</dev/tcp/$vm_ip/22" 2>/dev/null; do
    if [ "$ssh_waited" -ge "$ssh_wait_total" ]; then
      print_warning "SSH port not open after ${ssh_wait_total}s; will continue attempts anyway"
      break
    fi
    sleep "$ssh_wait_interval"
    ssh_waited=$((ssh_waited + ssh_wait_interval))
    echo -n "."
  done
  echo ""

  local ssh_pubkey=""
  for keyfile in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
    if [ -f "$keyfile" ]; then
      ssh_pubkey="$keyfile"
      break
    fi
  done

  if [ -z "$ssh_pubkey" ]; then
    print_error "No SSH public key found in ~/.ssh/"
    print_info "Generate one with: ssh-keygen -t ed25519"
    return 1
  fi

  print_info "VM IP: $vm_ip"
  print_info "Target user: $target_user"
  print_info "SSH public key: $ssh_pubkey"
  echo ""
  print_info "Using ssh-copy-id to securely copy your public key..."
  print_warning "You will be prompted for the password of '$target_user' on the VM"
  echo ""

  local tmp_out
  tmp_out=$(mktemp)
  local tmp_fifo fifo_dir
  fifo_dir=$(mktemp -d)
  tmp_fifo="$fifo_dir/out"
  mkfifo "$tmp_fifo"

  (ssh-copy-id -o StrictHostKeyChecking=no -i "$ssh_pubkey" "${target_user}@${vm_ip}" >"$tmp_fifo" 2>&1) &
  local scp_pid=$!
  while IFS= read -r line; do
    echo "$line" >>"$tmp_out"

    local normalized="$line"
    normalized=${normalized#/usr/bin/ssh-copy-id: }
    normalized=${normalized#ssh-copy-id: }

    if [ -z "$normalized" ]; then
      continue
    fi

    case "$normalized" in
    *": INFO: "*)
      msg="${normalized#*: INFO: }"
      case "$msg" in
      Now\ try\ logging\ into\ the\ machine,* | and\ check\ to\ make\ sure*) ;;
      *)
        print_info "$msg"
        ;;
      esac
      ;;
    *": WARNING: "*)
      print_warning "${normalized#*: WARNING: }"
      ;;
    *"'s password:"* | *" password:"* | *Password:*)
      printf "%s\n" "$normalized"
      ;;
    *)
      if echo "$normalized" | grep -qi "permission denied"; then
        print_warning "$normalized"
      else
        print_info "$normalized"
      fi
      ;;
    esac
  done <"$tmp_fifo"

  wait "$scp_pid"
  local scp_rc=$?
  local scp_output
  scp_output=$(cat "$tmp_out") || scp_output=""
  rm -rf "$tmp_out" "$fifo_dir"

  if echo "$scp_output" | grep -qi "All keys were skipped"; then
    print_warning "All keys were skipped because they already exist on the remote system. Use -f to force installation if appropriate."
  fi

  if echo "$scp_output" | grep -qi "permission denied"; then
    echo ""
    while IFS= read -r p; do
      print_warning "$p"
    done <<<"$(echo "$scp_output" | grep -i "permission denied")"
  fi

  if [ $scp_rc -eq 0 ]; then
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "${target_user}@${vm_ip}" true 2>/dev/null; then
      ui_done ok "SSH key installed for $target_user" "key login tested"
    else
      ui_done warn "SSH key copied for $target_user" "but a key login did not work yet"
    fi
    ui_next "ssh $target_user@$vm_ip" "log in with the key"
  else
    ui_done fail "SSH key not copied" "ssh-copy-id exited with $scp_rc"
    echo "  Check that '$target_user' exists on the VM with a password, and that"
    echo "  sshd allows password logins (dcvm console $vm_name), then retry:"
    ui_next "ssh-copy-id $target_user@$vm_ip" "copy the key by hand"
    return 1
  fi

  return 0
}

show_help() {
  ui_help <<EOF
dcvm backup - back up, restore and move VMs

Usage: dcvm backup <command> [args]

Commands:
  create <vm>                         Back up a VM (shuts it down meanwhile, then starts it again)
  list [vm]                           Backups of every VM, or of one
  restore <vm> [id] [new-name]        Put a backup back (newest by default) and start it, or restore it as a new VM
                                      (replacing a VM asks first; --yes without a terminal)
  delete <vm>                         Pick backups to delete from a numbered list
  delete <vm> <id> | <vm>-<id>        Delete one backup, without asking
  delete --all                        Delete every backup (asks first; --yes without a terminal)
  export <vm> [id] [dir]              Pack a backup as a .tar.gz for another host (default dir: $BACKUP_DIR/exports)
  import <file|dir> [new-name]        Unpack an exported backup and restore it
  ssh-setup <vm>                      Put this host's SSH key on an imported VM
  troubleshoot <vm>                   Fix a VM that does not start (runs dcvm fix-lock)

Backup IDs:
  As backup list shows them: <vm>-dd.mm.yyyy-N (the Nth backup of that day),
  dd.mm.yyyy[-N], YYYYMMDD_HHMMSS, or latest.

Settings:
  Location    $BACKUP_DIR
  Kept        last $KEEP_BACKUPS per VM, older ones are deleted
  Compressed  $([ "$COMPRESSION_ENABLED" = true ] && echo "yes (gzip)" || echo "no")
  Shutdown    waits up to ${SHUTDOWN_TIMEOUT}s, then forces it

Examples:
  dcvm backup create web
  dcvm backup list web
  dcvm backup restore web
  dcvm backup restore web web-21.11.2026-1 web-copy
  dcvm backup export web /tmp
EOF
}

main() {
  if [ $# -lt 1 ]; then
    show_help
    exit 0
  fi

  if [[ "$1" == "help" ]] || wants_help "$@"; then
    show_help
    exit 0
  fi

  local -a args=()
  while [ $# -gt 0 ]; do
    case "$1" in
    --base)
      RESTORE_BASE="${2:-}"
      shift 2 || shift
      ;;
    --base=*)
      RESTORE_BASE="${1#*=}"
      shift
      ;;
    --full)
      EXPORT_FULL=true
      shift
      ;;
    -y | --yes)
      ASSUME_YES=true
      shift
      ;;
    *)
      args+=("$1")
      shift
      ;;
    esac
  done
  set -- "${args[@]}"

  local SUBCOMMAND="$1"
  local VM_NAME="$2"
  local BACKUP_DATE="$3"
  if [[ ", $BACKUP_SUBCOMMANDS, " != *", $SUBCOMMAND, "* ]]; then
    print_error "Unknown subcommand: $SUBCOMMAND"
    echo "Valid subcommands: $BACKUP_SUBCOMMANDS"
    exit 1
  fi

  for cmd in virsh cp gzip gunzip wget qemu-img; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      print_error "Required command not found: $cmd"
      exit 1
    fi
  done

  local LOG_DIR
  LOG_DIR=$(dirname "$LOG_FILE")
  if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR" 2>/dev/null || {
      print_warning "Cannot create log directory, logging to stdout only"
      LOG_FILE="/dev/null"
    }
  fi

  case "$SUBCOMMAND" in
  "create")
    if [ -z "$VM_NAME" ]; then
      print_error "VM name required for 'create'"
      exit 1
    fi
    backup_vm "$VM_NAME"
    exit $?
    ;;
  "restore")
    if [ -z "$VM_NAME" ]; then
      print_error "VM name required for 'restore'"
      exit 1
    fi
    restore_vm "$VM_NAME" "$BACKUP_DATE" "$ASSUME_YES" "" "$4"
    exit $?
    ;;
  "list")
    if [ -n "$VM_NAME" ]; then
      list_backups "$VM_NAME"
      exit $?
    else
      list_all_backups
      exit $?
    fi
    ;;
  "delete")
    if [ -z "$VM_NAME" ]; then
      print_error "Argument required. Use: dcvm backup delete <vm> [id] | <vm>-<id> | --all"
      exit 1
    fi
    delete_backups "$VM_NAME" "$BACKUP_DATE"
    local rc=$?
    prune_builds >/dev/null
    exit $rc
    ;;
  "export")
    if [ -z "$VM_NAME" ]; then
      print_error "VM name required for 'export'"
      exit 1
    fi
    export_backup "$VM_NAME" "$BACKUP_DATE" "$4"
    exit $?
    ;;
  "import")
    if [ -z "$VM_NAME" ]; then
      print_error "Package path or directory required for 'import'"
      exit 1
    fi
    import_backup "$VM_NAME" "$BACKUP_DATE"
    exit $?
    ;;
  "ssh-setup")
    if [ -z "$VM_NAME" ]; then
      print_error "VM name required for 'ssh-setup'"
      exit 1
    fi
    ssh_setup_vm "$VM_NAME"
    exit $?
    ;;
  "troubleshoot")
    if [ -z "$VM_NAME" ]; then
      print_error "VM name required for 'troubleshoot'"
      exit 1
    fi
    troubleshoot_vm "$VM_NAME"
    exit $?
    ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
