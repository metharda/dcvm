#!/bin/bash

CONFIG_FILE="/etc/dcvm-install.conf"
if [[ -f "$CONFIG_FILE" ]]; then
	source "$CONFIG_FILE"
else
	DATACENTER_BASE="/srv/datacenter"
fi
BACKUP_DIR="$DATACENTER_BASE/backups"
LOG_FILE="/var/log/dcvm-backup.log"
DATE=$(date +%Y%m%d_%H%M%S)
KEEP_BACKUPS=5
SHUTDOWN_TIMEOUT=60
COMPRESSION_ENABLED=true
FIX_LOCK_SCRIPT="$DATACENTER_BASE/scripts/fix-lock.sh"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] ${*:2}" >>"$LOG_FILE"; }

generate_random_mac() { printf "52:54:00:%02x:%02x:%02x\n" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)); }
get_backup_folder_path() { echo "$BACKUP_DIR/${1}-${2}"; }
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
		local base=$(basename "$path")
		local ts="${base#${vm_name}-}"
		[[ "$ts" =~ $regex ]] && ts_list+=("$ts")
	done < <(compgen -G "$BACKUP_DIR/${vm_name}-????????_??????" 2>/dev/null || printf '')

	while IFS= read -r path; do
		[ -z "$path" ] && continue
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
	local vm_name="$1"; local date_part="$2"
	local folder
	folder=$(get_backup_folder_path "$vm_name" "$date_part")
	if [ -d "$folder" ]; then
		if [ -f "$folder/${vm_name}-disk-${date_part}.qcow2.gz" ]; then
			echo "$folder/${vm_name}-disk-${date_part}.qcow2.gz"; return 0
		fi
		if [ -f "$folder/${vm_name}-disk-${date_part}.qcow2" ]; then
			echo "$folder/${vm_name}-disk-${date_part}.qcow2"; return 0
		fi
	fi
	if [ -f "$BACKUP_DIR/${vm_name}-disk-${date_part}.qcow2.gz" ]; then
		echo "$BACKUP_DIR/${vm_name}-disk-${date_part}.qcow2.gz"; return 0
	fi
	if [ -f "$BACKUP_DIR/${vm_name}-disk-${date_part}.qcow2" ]; then
		echo "$BACKUP_DIR/${vm_name}-disk-${date_part}.qcow2"; return 0
	fi
	echo ""
	return 1
}

get_backup_config_path() {
	local vm_name="$1"; local date_part="$2"
	local folder
	folder=$(get_backup_folder_path "$vm_name" "$date_part")
	if [ -d "$folder" ] && [ -f "$folder/${vm_name}-config-${date_part}.xml" ]; then
		echo "$folder/${vm_name}-config-${date_part}.xml"; return 0
	fi
	if [ -f "$BACKUP_DIR/${vm_name}-config-${date_part}.xml" ]; then
		echo "$BACKUP_DIR/${vm_name}-config-${date_part}.xml"; return 0
	fi
	echo ""
	return 1
}

download_cloud_image() {
	local filename="$1"; local target_path="$2"
	local url=""
	case "$filename" in
		ubuntu-22.04-server-cloudimg-amd64.img)
			url="https://cloud-images.ubuntu.com/releases/jammy/release/ubuntu-22.04-server-cloudimg-amd64.img";;
		ubuntu-20.04-server-cloudimg-amd64.img)
			url="https://cloud-images.ubuntu.com/releases/focal/release/ubuntu-20.04-server-cloudimg-amd64.img";;
		debian-12-generic-amd64.qcow2)
			url="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2";;
		debian-11-generic-amd64.qcow2)
			url="https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2";;
	esac
	if [ -z "$url" ]; then
		print_warning "Unknown backing image '$filename'. Please place it at: $target_path"
		return 1
	fi
	mkdir -p "$(dirname "$target_path")" || { print_error "Cannot create directory for backing image"; return 1; }
	print_info "Downloading cloud image $filename ..."
	if wget -q -O "$target_path" "$url"; then
		print_success "Downloaded backing image: $filename"
		return 0
	else
		print_error "Failed to download backing image from $url"
		return 1
	fi
}

ensure_backing_image() {
	local vm_disk_path="$1"
	if ! command -v qemu-img >/dev/null 2>&1; then
		print_warning "qemu-img not found; skipping backing file check"
		return 0
	fi
	local info
	info=$(qemu-img info "$vm_disk_path" 2>/dev/null) || return 0
	local backing_file
	backing_file=$(echo "$info" | awk -F': ' '/backing file:/ {print $2; exit}')
	if [ -z "$backing_file" ]; then
		return 0
	fi
	if [[ "$backing_file" != /* ]]; then
		local base_dir="$(dirname "$vm_disk_path")"
		backing_file="${base_dir}/${backing_file}"
	fi
	if [ -f "$backing_file" ]; then
		return 0
	fi
	print_warning "Backing file missing: $backing_file"
	local filename="$(basename "$backing_file")"
	local canonical_path="$DATACENTER_BASE/storage/templates/$filename"
	if [ "$backing_file" = "$canonical_path" ]; then
		if download_cloud_image "$filename" "$canonical_path"; then
			return 0
		else
			return 1
		fi
	else
		if download_cloud_image "$filename" "$canonical_path"; then
			print_info "Rebasing restored disk to use canonical backing file path"
			if qemu-img rebase -u -b "$canonical_path" "$vm_disk_path"; then
				print_success "Rebase completed"
				return 0
			else
				print_error "Failed to rebase disk backing file"
				return 1
			fi
		else
			return 1
		fi
	fi
}

check_vm_exists() { virsh list --all 2>/dev/null | grep -q " $1 "; }

get_vm_state() { virsh domstate "$1" 2>/dev/null; }

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

get_vm_disk_path() {
	local vm_name="$1"
	virsh domblklist "$vm_name" --details 2>/dev/null | grep "disk" | grep "file" | awk '{print $4}' | head -1
}

is_lock_error() {
	local error_message="$1"
	
	if echo "$error_message" | grep -qi "failed to get.*lock\|is another process using\|file is locked\|resource busy\|device or resource busy\|qemu unexpectedly closed\|failed to get shared.*lock\|block device is in use\|image is being used\|cannot lock\|already in use\|permission denied.*lock"; then
		return 0
	fi
	return 1
}

get_file_size() { [ -f "$1" ] && du -h "$1" | cut -f1 || echo "0"; }

normalize_backing_chain() {
	local vm_disk_path="$1"
	if ! command -v qemu-img >/dev/null 2>&1; then
		return 0
	fi
	local info backing
	info=$(qemu-img info "$vm_disk_path" 2>/dev/null) || return 0
	backing=$(echo "$info" | awk -F': ' '/backing file:/ {print $2; exit}')
	if [ -z "$backing" ]; then
		return 0
	fi
	if echo "$backing" | grep -q "/vms/"; then
		print_warning "Disk has VM-backed backing file ($backing). Flattening to standalone..."
		local tmp="${vm_disk_path}.tmp"
		if qemu-img convert -O qcow2 "$vm_disk_path" "$tmp"; then
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

	print_info "Cleaning up old backups (keeping $KEEP_BACKUPS most recent)..."
	mapfile -t all_ts < <(list_backup_timestamps_desc "$vm_name")
	if [ ${#all_ts[@]} -gt $KEEP_BACKUPS ]; then
		local to_delete=("${all_ts[@]:$KEEP_BACKUPS}")
		for dp in "${to_delete[@]}"; do
			[ -z "$dp" ] && continue
			remove_backup_artifacts "$vm_name" "$dp" "old backup" || true
		done
	fi

	print_success "Cleanup completed"
}

list_backups() {
	local vm_name="$1"
	local with_index="$2" 

	print_info "Backups for VM: $vm_name"
	echo ""

	mapfile -t backups_ts < <(list_backup_timestamps_desc "$vm_name")

	if [ ${#backups_ts[@]} -eq 0 ]; then
		print_warning "No backups found for VM: $vm_name"
		return 1
	fi

	declare -A __day_seq
	declare -A __seq_for_dp
	mapfile -t __chrono_dps < <(printf "%s\n" "${backups_ts[@]}" | sort)
	for __dp in "${__chrono_dps[@]}"; do
		[ -z "$__dp" ] && continue
		__dmy=$(echo "$__dp" | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_.*/\3.\2.\1/')
		[ -z "$__dmy" ] && continue
		local __cur=${__day_seq[$__dmy]:-0}
		local __n=$((__cur+1))
		__day_seq[$__dmy]=$__n
		__seq_for_dp[$__dp]=$__n
	done

	if [ "$with_index" = "true" ]; then
		printf "%-3s %-24s %-19s %-9s %-10s %s\n" "#" "ID" "Date/Time" "Size" "Type" "Status"
		printf "%-3s %-24s %-19s %-9s %-10s %s\n" "---" "------------------------" "-------------------" "---------" "----------" "--------"
	else
		printf "%-24s %-19s %-9s %-10s %s\n" "ID" "Date/Time" "Size" "Type" "Status"
		printf "%-24s %-19s %-9s %-10s %s\n" "------------------------" "-------------------" "---------" "----------" "--------"
	fi

	local idx=0
	for date_part in "${backups_ts[@]}"; do
		[ -z "$date_part" ] && continue
		local disk_path; disk_path=$(get_backup_disk_path "$vm_name" "$date_part")
		local cfg_path;  cfg_path=$(get_backup_config_path "$vm_name" "$date_part")
		local size=$(get_file_size "$disk_path")
		local type="qcow2"; [[ "$disk_path" == *.gz ]] && type="qcow2+gz"
		local status="✓"; [ ! -f "$cfg_path" ] && status="⚠ No config"

		local pretty_dt=$(echo "$date_part" | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/')
		local dmy=$(echo "$date_part" | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_.*/\3.\2.\1/')
		local seq=${__seq_for_dp[$date_part]:-?}
		local date_id="${vm_name}-${dmy}-${seq}"

		if [ "$with_index" = "true" ]; then
			idx=$((idx+1))
			printf "%-3s %-24s %-19s %-9s %-10s %s\n" "$idx" "$date_id" "$pretty_dt" "$size" "$type" "$status"
		else
			printf "%-24s %-19s %-9s %-10s %s\n" "$date_id" "$pretty_dt" "$size" "$type" "$status"
		fi
	done

	echo ""
	return 0
}

list_all_backups() {
	print_info "Available backups (grouped by VM)"
	echo ""

	local -a vms=()
	while IFS= read -r f; do vms+=("$(basename "$f" | awk -F"-disk-" '{print $1}')"); done < <(ls -1 "$BACKUP_DIR"/*-disk-*.qcow2* 2>/dev/null)
	while IFS= read -r d; do vms+=("$(basename "$d" | sed -E 's/-[0-9]{8}_[0-9]{6}$//')"); done < <(ls -1 -d "$BACKUP_DIR"/*-????????_?????? 2>/dev/null)
	if [ ${#vms[@]} -eq 0 ]; then
		print_warning "No backups found in: $BACKUP_DIR"
		return 1
	fi
	mapfile -t vms < <(printf "%s\n" "${vms[@]}" | sort -u)

	for vm in "${vms[@]}"; do
		echo "VM: $vm"
		list_backups "$vm" false || true
	done

	return 0
}

delete_backups() {
	local arg="$1"

	if [ -z "$arg" ]; then
		print_error "Usage: dcvm backup delete <vm>|<vm-dd.mm.yyyy>|<vm-dd.mm.yyyy-N>|<vm-dd.mm.yyyy-HH:MM:SS>"
		return 1
	fi

	if [ "$arg" = "--all" ] || [ "$arg" = "all" ]; then
		mapfile -t __folders < <(ls -1 -d "$BACKUP_DIR"/*-????????_?????? 2>/dev/null | grep -vE '/exports$')
		mapfile -t __legacy_disks < <(ls -1 "$BACKUP_DIR"/*-disk-*.qcow2* 2>/dev/null)

		local count_folders=${#__folders[@]}
		local count_legacy=${#__legacy_disks[@]}
		local total=$((count_folders + count_legacy))

		if [ "$total" -eq 0 ]; then
			print_warning "No backups found in: $BACKUP_DIR"
			return 0
		fi

		echo "This will permanently delete $total backup(s):"
		[ "$count_folders" -gt 0 ] && echo "  - $count_folders folder backup(s)"
		[ "$count_legacy" -gt 0 ] && echo "  - $count_legacy legacy file backup(s)"
		read -p "Proceed? (y/N): " yn
		if [[ ! "$yn" =~ ^[Yy]$ ]]; then
			print_info "Cancelled."
			return 0
		fi

		local removed=0
		for d in "${__folders[@]}"; do
			[ -z "$d" ] && continue
			rm -rf "$d" && removed=$((removed+1))
		done
		for f in "${__legacy_disks[@]}"; do
			[ -z "$f" ] && continue
			rm -f "$f" && removed=$((removed+1))
			local base=$(basename "$f")
			local vmname=$(echo "$base" | awk -F"-disk-" '{print $1}')
			local ts=$(echo "$base" | sed -E "s/${vmname}-disk-(.*)\.qcow2(\.gz)?/\1/")
			local legacy_cfg="$BACKUP_DIR/${vmname}-config-${ts}.xml"
			[ -f "$legacy_cfg" ] && rm -f "$legacy_cfg" || true
		done

		print_success "$removed backup artifact(s) deleted."
		return 0
	fi

	local vm_name=""
	local dmy=""
	local hms=""
	local indexN=""

	if [[ "$arg" =~ ^(.+)-([0-9]{2}\.[0-9]{2}\.[0-9]{4})(-([0-9]{2}:[0-9]{2}:[0-9]{2}|[0-9]+))?$ ]]; then
		vm_name="${BASH_REMATCH[1]}"
		dmy="${BASH_REMATCH[2]}"
		local tail="${BASH_REMATCH[4]}"
		if [[ "$tail" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
			hms="$tail"
		elif [[ "$tail" =~ ^[0-9]+$ ]]; then
			indexN="$tail"
		fi
	else
		vm_name="$arg"
	fi

	mapfile -t backup_dates < <(list_backup_timestamps_desc "$vm_name")
	if [ ${#backup_dates[@]} -eq 0 ]; then
		print_warning "No backups found for VM: $vm_name"
		return 0
	fi

	if [ -z "$dmy" ]; then
		if ! list_backups "$vm_name" true; then
			print_warning "No backups to delete for VM: $vm_name"
			return 0
		fi
		read -p "Enter number(s) to delete (e.g., 1 or 1,2,3): " selection
		selection=$(echo "$selection" | tr -d ' ')
		if [ -z "$selection" ]; then
			print_info "Cancelled."
			return 0
		fi

		IFS=',' read -r -a indices <<< "$selection"

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
			local date_part="${backup_dates[$((idx-1))]}"
			to_delete_dates+=("$date_part")
		done

		echo "Backups to delete:"
		for d in "${to_delete_dates[@]}"; do
			[ -z "$d" ] && continue
			echo "  ${vm_name}-${d}"
		done
		read -p "Proceed? (y/N): " yn
		if [[ ! "$yn" =~ ^[Yy]$ ]]; then
			print_info "Cancelled."
			return 0
		fi

		local del_ok=0
		for date_part in "${to_delete_dates[@]}"; do
			[ -z "$date_part" ] && continue
			if remove_backup_artifacts "$vm_name" "$date_part" "backup"; then
				del_ok=$((del_ok+1))
			fi
		done
		print_success "$del_ok backup(s) deleted."
		return 0
	fi

	local dd=$(echo "$dmy" | cut -d'.' -f1)
	local mm=$(echo "$dmy" | cut -d'.' -f2)
	local yyyy=$(echo "$dmy" | cut -d'.' -f3)
	local yyyymmdd="${yyyy}${mm}${dd}"

	local resolved_ts=""
	if [ -n "$hms" ]; then
		local HH=$(echo "$hms" | cut -d':' -f1)
		local MM=$(echo "$hms" | cut -d':' -f2)
		local SS=$(echo "$hms" | cut -d':' -f3)
		resolved_ts="${yyyymmdd}_${HH}${MM}${SS}"
	elif [ -n "$indexN" ]; then
		local selector="${dd}.${mm}.${yyyy}-${indexN}"
		resolved_ts=$(resolve_backup_selector "$vm_name" "$selector") || true
	else
		resolved_ts=$(resolve_backup_selector "$vm_name" "${dd}.${mm}.${yyyy}") || true
	fi

	if [ -z "$resolved_ts" ]; then
		print_error "No matching backup found: ${vm_name}-${dmy}${hms:+-$hms}${indexN:+-$indexN}"
		return 1
	fi

	local removed=0
	if remove_backup_artifacts "$vm_name" "$resolved_ts" "backup"; then
		removed=1
	fi
	print_success "$removed backup(s) deleted."
	return 0
}

troubleshoot_vm() {
	local vm_name="$1"

	if [ -z "$vm_name" ]; then
		print_error "VM name required for 'troubleshoot'"
		return 1
	fi

	print_info "Troubleshooting VM (delegated to fix-lock.sh): $vm_name"
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
		echo "$selector"; return 0
	fi

	if [[ "$selector" =~ ^([0-9]{2})\.([0-9]{2})\.([0-9]{4})(-([0-9]+))?$ ]]; then
		local dd="${BASH_REMATCH[1]}"; local mm="${BASH_REMATCH[2]}"; local yyyy="${BASH_REMATCH[3]}"; local n="${BASH_REMATCH[5]}"
		local yyyymmdd="${yyyy}${mm}${dd}"

		mapfile -t day_backups < <(list_day_backup_timestamps_asc "$vm_name" "$yyyymmdd")

		if [ ${#day_backups[@]} -eq 0 ]; then
			echo ""; return 1
		fi

		if [ -z "$n" ]; then
			echo "${day_backups[-1]}"; return 0
		else
			if ! [[ "$n" =~ ^[0-9]+$ ]]; then
				echo ""; return 1
			fi
			if [ "$n" -lt 1 ] || [ "$n" -gt ${#day_backups[@]} ]; then
				echo ""; return 1
			fi
			local idx=$((n-1))
			echo "${day_backups[$idx]}"; return 0
		fi
	fi
	echo ""; return 1
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

	if [ -n "$backup_date" ] && [[ ! "$backup_date" =~ ^[0-9]{8}_[0-9]{6}$ ]]; then
		local _resolved
		_resolved=$(resolve_backup_selector "$vm_name" "$backup_date")
		if [ -z "$_resolved" ]; then
			print_error "Backup selector not found: $backup_date (use YYYYMMDD_HHMMSS or dd.mm.yyyy[-N])"
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
	local is_compressed=false
	if [ -z "$disk_backup" ] || [ -z "$config_backup" ]; then
		print_error "Backup files not found for date: $backup_date"
		return 1
	fi
	[[ "$disk_backup" == *.gz ]] && is_compressed=true

	local export_base="$BACKUP_DIR/exports"
	[ -n "$output_dir" ] && export_base="$output_dir"
	export_base="${export_base/#\~/$HOME}"
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

	print_info "Creating export package: $pkg_path"
	local tmpdir
	tmpdir=$(mktemp -d)
	cp "$disk_backup" "$tmpdir/" || { rm -rf "$tmpdir"; print_error "Failed to copy disk backup"; return 1; }
	cp "$config_backup" "$tmpdir/" || { rm -rf "$tmpdir"; print_error "Failed to copy config backup"; return 1; }

	cat >"$tmpdir/manifest.txt" <<EOF
vm_name=$vm_name
backup_date=$backup_date
disk_file=$(basename "$disk_backup")
config_file=$(basename "$config_backup")
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
dcvm_version=portable
EOF

	(cd "$tmpdir" && tar -czf "$pkg_path" .) || { rm -rf "$tmpdir"; print_error "Failed to create export archive"; return 1; }
	rm -rf "$tmpdir"

	print_success "Export created: $pkg_path"
	echo "$pkg_path"
	return 0
}

import_backup() {
	local pkg_path="$1"
	local rename_to="$2"  
	if [ -z "$pkg_path" ]; then
		print_error "Package path required for 'import'"
		return 1
	fi
	pkg_path="${pkg_path/#\~/$HOME}"

	if [ ! -f "$pkg_path" ] && [ ! -d "$pkg_path" ]; then
		print_error "Package not found: $pkg_path"
		return 1
	fi

	local workdir
	workdir=$(mktemp -d)

	if [ -f "$pkg_path" ]; then
		if ! tar -xzf "$pkg_path" -C "$workdir" 2>/dev/null; then
			rm -rf "$workdir"
			print_error "Unsupported or corrupt archive: $pkg_path"
			return 1
		fi
	else
		cp -r "$pkg_path"/* "$workdir"/ 2>/dev/null || true
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

	local base_disk
	base_disk=$(basename "$disk_file")
	local vm_from
	vm_from=$(echo "$base_disk" | awk -F"-disk-" '{print $1}')
	local date_part
	date_part=$(echo "$base_disk" | sed -E "s/${vm_from}-disk-(.*)\.qcow2(\.gz)?/\1/")

	local vm_target="$vm_from"
	[ -n "$rename_to" ] && vm_target="$rename_to"

	mkdir -p "$BACKUP_DIR" || { rm -rf "$workdir"; print_error "Cannot create $BACKUP_DIR"; return 1; }
	local backup_folder="$(get_backup_folder_path "$vm_target" "$date_part")"
	mkdir -p "$backup_folder" || { rm -rf "$workdir"; print_error "Cannot create backup folder: $backup_folder"; return 1; }
	local tgt_disk="$backup_folder/${vm_target}-disk-${date_part}.qcow2"
	local tgt_cfg="$backup_folder/${vm_target}-config-${date_part}.xml"

	if [[ "$base_disk" == *.gz ]]; then
		tgt_disk+=".gz"
	fi

	print_info "Importing to: $tgt_disk and $tgt_cfg"
	cp "$disk_file" "$tgt_disk" || { rm -rf "$workdir"; print_error "Failed to import disk file"; return 1; }
	cp "$config_file" "$tgt_cfg" || { rm -rf "$workdir"; print_error "Failed to import config file"; return 1; }

	rm -rf "$workdir"

	print_success "Import completed. Proceeding to restore..."
	restore_vm "$vm_target" "$date_part"
	return $?
}

restore_vm() {
	local vm_name="$1"
	local backup_date="$2"
	local opt_third="$3"
	local force_restore=""
	if [ "$opt_third" = "true" ]; then force_restore="true"; fi
	local final_state="shut off"
	local skip_auto_start=false
	local start_error=""

	print_info "Starting restore for VM: $vm_name"
	log "INFO" "Starting restore for VM: $vm_name"

	if [ -z "$backup_date" ]; then
		backup_date=$(get_latest_backup "$vm_name")
		if [ -z "$backup_date" ]; then
			print_error "No backups found for VM: $vm_name"
			log "ERROR" "No backups found for VM: $vm_name"
			return 1
		fi
		print_info "Using latest backup: $backup_date"
	fi

	local disk_backup=""
	local config_backup=""
	disk_backup=$(get_backup_disk_path "$vm_name" "$backup_date")
	config_backup=$(get_backup_config_path "$vm_name" "$backup_date")
	local is_compressed=false
	if [ -z "$disk_backup" ] || [ -z "$config_backup" ]; then
		print_error "Backup not found for date: $backup_date"
		print_info "Available backups:"
		list_backups "$vm_name"
		return 1
	fi
	[[ "$disk_backup" == *.gz ]] && is_compressed=true
	print_info "Found $( [ "$is_compressed" = true ] && echo compressed || echo uncompressed ) backup: $(basename "$disk_backup")"

	print_info "Found backup files:"
	print_info "  Disk: $(basename "$disk_backup") ($(get_file_size "$disk_backup"))"
	print_info "  Config: $(basename "$config_backup")"

	if check_vm_exists "$vm_name"; then
		local vm_state=$(get_vm_state "$vm_name")
		print_warning "VM '$vm_name' already exists (state: $vm_state)"

		if [ "$force_restore" != "true" ]; then
			echo ""
			print_warning "This will COMPLETELY REPLACE the existing VM!"
			print_warning "All current data in the VM will be LOST!"
			echo ""
			read -p "Are you sure you want to continue? (type 'yes' to confirm): " confirm

			if [ "$confirm" != "yes" ]; then
				print_info "Restore cancelled by user"
				return 0
			fi
		fi

		if [ "$vm_state" = "running" ]; then
			print_info "Stopping existing VM..."
			virsh shutdown "$vm_name" >/dev/null 2>&1

			if ! wait_for_vm_state "$vm_name" "shut off" "$SHUTDOWN_TIMEOUT"; then
				print_warning "Graceful shutdown failed, forcing stop..."
				virsh destroy "$vm_name" >/dev/null 2>&1
				sleep 5
			fi
		fi

		print_info "Removing existing VM definition (keeping storage)..."
		virsh undefine "$vm_name" >/dev/null 2>&1 || true
		
		print_info "Running fix-lock.sh for comprehensive cleanup..."
		if [ -x "$FIX_LOCK_SCRIPT" ]; then
			"$FIX_LOCK_SCRIPT" "$vm_name" >/dev/null 2>&1 || true
		else
			print_warning "fix-lock.sh not found, doing basic cleanup..."
			virsh destroy "$vm_name" >/dev/null 2>&1 || true
			sleep 2
		fi
	fi

	local vm_dir="$DATACENTER_BASE/vms/$vm_name"
	local vm_disk_path="$vm_dir/${vm_name}-disk.qcow2"

	print_info "Preparing VM directory..."
	if ! mkdir -p "$vm_dir"; then
		print_error "Failed to create VM directory: $vm_dir"
		return 1
	fi

	if [ -f "$vm_disk_path" ]; then
		print_info "Removing existing disk file..."
		lsof "$vm_disk_path" 2>/dev/null && sleep 3
		rm -f "$vm_disk_path" || {
			print_error "Failed to remove existing disk file: $vm_disk_path"
			return 1
		}
	fi

	if [ "$is_compressed" = true ]; then
		print_info "Decompressing backup directly to destination..."

		if ! gunzip -t "$disk_backup" >/dev/null 2>&1; then
			print_error "Compressed backup file is corrupted: $disk_backup"
			return 1
		fi

		local original_size=$(stat -f%z "$disk_backup" 2>/dev/null || stat -c%s "$disk_backup" 2>/dev/null || echo "unknown")
		print_info "Decompressing $original_size bytes..."

		if gunzip -c "$disk_backup" >"$vm_disk_path" 2>/dev/null; then
			if [ -f "$vm_disk_path" ] && [ -s "$vm_disk_path" ]; then
				local restored_size=$(get_file_size "$vm_disk_path")
				print_success "Backup decompressed and restored ($restored_size)"
			else
				print_error "Decompressed file is empty or missing"
				rm -f "$vm_disk_path"
				return 1
			fi
		else
			print_error "Failed to decompress backup"
			rm -f "$vm_disk_path"
			return 1
		fi
	else
		print_info "Copying uncompressed backup..."

		if cp "$disk_backup" "$vm_disk_path"; then
			local restored_size=$(get_file_size "$vm_disk_path")
			print_success "Backup copied successfully ($restored_size)"
		else
			print_error "Failed to copy backup file"
			return 1
		fi
	fi

	if [ ! -f "$vm_disk_path" ] || [ ! -s "$vm_disk_path" ]; then
		print_error "Restored disk file is missing or empty: $vm_disk_path"
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

	chmod 660 "$vm_disk_path"

	if command -v restorecon >/dev/null 2>&1 && [ -f /selinux/enforce ]; then
		restorecon "$vm_disk_path" 2>/dev/null || true
	fi

	print_success "File permissions and ownership set"

	print_info "Restoring VM configuration..."

	local temp_config=$(mktemp)

	if ! cp "$config_backup" "$temp_config"; then
		print_error "Failed to prepare temporary config file"
		rm -f "$temp_config"
		return 1
	fi

	local original_main_file=""
	if command -v xmlstarlet >/dev/null 2>&1; then
		original_main_file=$(xmlstarlet sel -t -v "(/domain/devices/disk[@device='disk']/source/@file)[1]" "$temp_config" 2>/dev/null)
		if [ -z "$original_main_file" ]; then
			original_main_file=$(xmlstarlet sel -t -v "(/domain/devices/disk[not(@device='cdrom')]/source/@file)[1]" "$temp_config" 2>/dev/null)
		fi
	else
		original_main_file=$(grep -oE "source (file|dev)=['\"][^'\"]+['\"]" "$temp_config" | head -1 | sed -E "s/.*=['\"]([^'\"]+)['\"]/\1/")
	fi

	if command -v xmlstarlet >/dev/null 2>&1; then
		if ! xmlstarlet ed -P -L -u "/domain/devices/disk[@device='disk']/source/@file" -v "$vm_disk_path" "$temp_config"; then
			print_error "Failed to update disk source with xmlstarlet"
			rm -f "$temp_config"
			return 1
		fi
		xmlstarlet ed -P -L -u "/domain/name" -v "$vm_name" "$temp_config" 2>/dev/null || true
		xmlstarlet ed -P -L -d "/domain/uuid" "$temp_config" 2>/dev/null || true
		xmlstarlet ed -P -L -d "/domain/devices/disk[@device='cdrom']" "$temp_config" 2>/dev/null || true
		xmlstarlet ed -P -L -d "/domain/devices/disk[contains(source/@file, '.iso')]" "$temp_config" 2>/dev/null || true
		xmlstarlet ed -P -L -d "/domain/devices/controller[@type='ide']" "$temp_config" 2>/dev/null || true
		xmlstarlet ed -P -L -N qemu='http://libvirt.org/schemas/domain/qemu/1.0' -d "/domain/qemu:commandline[qemu:arg/@value[contains(., '.iso')]]" "$temp_config" 2>/dev/null || true
		xmlstarlet ed -P -L -d "/domain/metadata" "$temp_config" 2>/dev/null || true
		current_machine=$(xmlstarlet sel -t -v "/domain/os/type/@machine" "$temp_config" 2>/dev/null)
		if [ -n "$current_machine" ] && [ "$current_machine" != "q35" ]; then
			xmlstarlet ed -P -L -d "/domain/os/type/@machine" "$temp_config" 2>/dev/null || true
		fi
		xmlstarlet ed -P -L -N libosinfo='http://libosinfo.org/xmlns/libvirt/domain/1.0' -d "/domain/@xmlns:libosinfo" "$temp_config" 2>/dev/null || true
		print_info "Removed cdrom/iso/ide/qemu:commandline entries from config (if any)"
		print_info "Normalized domain metadata and machine attribute for compatibility"
	else
		sed -i "/<disk[^>]*device=\"disk\"[^>]*>/,/<\/disk>/{s|<source file='[^']*'/>|<source file='$vm_disk_path'/>|g}" "$temp_config"
		sed -i "s|<name>[^<]*</name>|<name>$vm_name</name>|" "$temp_config" 2>/dev/null || true
		sed -i "/<uuid>.*<\/uuid>/d" "$temp_config" 2>/dev/null || true
		sed -i "/<disk[^>]*device=['\"]cdrom['\"][^>]*>/,/<\\/disk>/d" "$temp_config"
		sed -i "/<disk[^>]*>[^<]*<source[^>]*file=['\"][^'\"]*\.iso['\"][^>]*>[^<]*<[^>]*>/,/<\\/disk>/d" "$temp_config"
		sed -i "/<controller[^>]*type=['\"]ide['\"][^>]*>/,/<\\/controller>/d" "$temp_config"
		sed -i "/<qemu:commandline[\s\S]*\.iso[\s\S]*<\\/qemu:commandline>/d" "$temp_config"
		sed -i "/<metadata[ >\t]/,/<\\/metadata>/d" "$temp_config"
		if grep -q "machine=\"q35\"" "$temp_config" || grep -q "machine='q35'" "$temp_config"; then
			:
		else
			sed -i "s/ machine='[^']*'//" "$temp_config"
			sed -i 's/ machine=\"[^\"]*\"//' "$temp_config"
		fi
		sed -i "s/ xmlns:libosinfo='[^']*'//" "$temp_config"
		sed -i 's/ xmlns:libosinfo="[^"]*"//' "$temp_config"
		print_info "Removed cdrom/iso/ide/qemu:commandline entries and normalized metadata/machine attributes"
	fi

	if [ -n "$original_main_file" ] && [ "$original_main_file" != "$vm_disk_path" ]; then
		sed -i "s|file='$original_main_file'|file='$vm_disk_path'|g" "$temp_config" 2>/dev/null || true
		sed -i "s|file=\"$original_main_file\"|file=\"$vm_disk_path\"|g" "$temp_config" 2>/dev/null || true
	fi

	sed -i "/<disk[^>]*>/,/<\\/disk>/{ \
	/<source[^>]*file='[^']*\\/vms\\/[^']*'[^>]*>/ { \
		/<source[^>]*file='[^']*\\/vms\\\/$vm_name\\/[^']*'[^>]*>/! d \
	} \
}" "$temp_config" 2>/dev/null || true
	sed -i "/<disk[^>]*>/,/<\\/disk>/{ \
	/<source[^>]*file=\"[^\"]*\\/vms\\/[^\"]*\"[^>]*>/ { \
		/<source[^>]*file=\"[^\"]*\\/vms\\\/$vm_name\\/[^\"]*\"[^>]*>/! d \
	} \
}" "$temp_config" 2>/dev/null || true
		if command -v xmlstarlet >/dev/null 2>&1; then
			local __ifcnt
			__ifcnt=$(xmlstarlet sel -t -v "count(/domain/devices/interface/mac/@address)" "$temp_config" 2>/dev/null | tr -d '\n')
			if [[ "$__ifcnt" =~ ^[0-9]+$ ]] && [ "$__ifcnt" -gt 0 ]; then
				for ((i=1; i<=__ifcnt; i++)); do
					local newmac
					newmac=$(generate_random_mac)
					xmlstarlet ed -P -L -u "(/domain/devices/interface/mac/@address)[$i]" -v "$newmac" "$temp_config" 2>/dev/null || true
				done
				print_info "Randomized $__ifcnt MAC address(es) to avoid DHCP lease reuse"
			fi
		else
			local __tmp_mac_cfg
			__tmp_mac_cfg=$(mktemp)
			while IFS= read -r __line; do
				if echo "$__line" | grep -q "<mac address=\\\"\|<mac address='"; then
					local mac
					mac=$(generate_random_mac)
					__line=$(echo "$__line" | sed -E "s/address='[^']*'/address='$mac'/g; s/address=\\\"[^\\\"]*\\\"/address=\\\"$mac\\\"/g")
				fi
				echo "$__line" >> "$__tmp_mac_cfg"
			done < "$temp_config"
			mv "$__tmp_mac_cfg" "$temp_config"
			print_info "Randomized MAC addresses (sed fallback)"
		fi

	ensure_backing_image "$vm_disk_path" || true

	local define_output attempt=1 max_attempts=3
	while [ $attempt -le $max_attempts ]; do
		define_output=$(virsh define "$temp_config" 2>&1)
		if [ $? -eq 0 ]; then
			print_success "VM configuration restored (attempt $attempt)"
			log "INFO" "VM configuration restored for $vm_name on attempt $attempt"
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
			if [ $attempt -eq $max_attempts ]; then
				print_error "Giving up after $max_attempts attempts"
				sed -n '1,30p' "$temp_config"
				rm -f "$temp_config"
				return 1
			fi
		fi
		attempt=$((attempt+1))
		[ $attempt -le $max_attempts ] && print_info "Retrying define (attempt $attempt)..." && sleep 1
	done

	rm -f "$temp_config"

	if virsh autostart "$vm_name" >/dev/null 2>&1; then
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
		print_info "This will cause shared write lock failures."
		print_info "Resolve by detaching/changing disk on those VMs or undefining them before start."
		print_info "You can run: sudo $FIX_LOCK_SCRIPT $vm_name --verbose (for cleanup), but conflicts must be fixed manually."
		final_state="shut off (conflicting domains detected)"
		skip_auto_start=true
		start_error="Disk referenced by other VM(s): $(echo "$conflicting_vms" | tr '\n' ' ')"
	fi
	
	print_info "Attempting to start VM..."
	local start_attempts=0
	local max_attempts=2

	if [ "$skip_auto_start" = true ]; then
		print_warning "Skipping auto-start due to conflicting VM references"
	else
		while [ $start_attempts -lt $max_attempts ]; do
			local attempt=$((start_attempts + 1))
			print_info "Start attempt ${attempt}/$max_attempts"
			start_error=$(virsh start "$vm_name" 2>&1)
			if [ $? -eq 0 ]; then
				print_success "VM restore completed and VM is now starting!"
				if wait_for_vm_state "$vm_name" "running" 30; then
					print_success "VM is now running successfully!"
					final_state="running"
				else
					print_warning "VM started but may still be booting"
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
		else
			need_manual_help=true
		fi
	fi

	if [ "$need_manual_help" = true ] && [ "$final_state" != "running" ]; then
		print_warning "VM restored but failed to start automatically after $max_attempts attempts"
		print_info ""
		print_info "Manual troubleshooting steps:"
		print_info "  1. Check for conflicting domains using the same disk:"
		print_info "     virsh list --all --name | while read n; do [ \"$vm_name\" = \"$n\" ] || virsh domblklist \"$n\" --details | awk '{print $4}' | grep -Fxq \"$vm_disk_path\" && echo \"$n\"; done"
		print_info "     If any are listed, detach/change their disk or undefine them."
		print_info ""
		print_info "  2. Run fix-lock.sh with verbose:"
		print_info "     sudo $FIX_LOCK_SCRIPT $vm_name --verbose"
		print_info ""
		print_info "  3. Ensure no cdrom/ide remains in XML:"
		print_info "     sudo grep -iE 'cdrom|controller type=\"ide\"' /etc/libvirt/qemu/$vm_name.xml || echo OK"
		print_info ""
		print_info "  4. Manual start:"
		print_info "     virsh start $vm_name"
		print_info ""
		print_info "  5. Check detailed logs:"
		print_info "     tail -f /var/log/libvirt/qemu/$vm_name.log"
		print_info ""
		[ -z "$start_error" ] && start_error="Auto-start skipped."
		print_info "Last error was: $start_error"
	fi

	echo ""
	echo "=================================================="
	print_success "Restore completed for VM: $vm_name"
	echo "=================================================="
	echo "Restored from backup:"
	echo "  Date: $backup_date"
	echo "  Source: $(basename "$disk_backup")"
	echo "  Compression: $([ "$is_compressed" = true ] && echo "Yes" || echo "No")"
	echo "  VM Directory: $vm_dir"
	echo "  Disk Size: $(get_file_size "$vm_disk_path")"
	echo ""
	echo "VM Status: $final_state"
	echo ""
	if [ "$final_state" = "running" ]; then
		echo "VM is ready to use!"
		echo "  SSH access: dcvm setup-forwarding  (to configure ports)"
		echo "  Console:    virsh console $vm_name"
	else
		echo "Manual startup required:"
		echo "  Try: dcvm start $vm_name"
		echo "  Or:  virsh start $vm_name"
		echo "  Fix locks: $FIX_LOCK_SCRIPT $vm_name"
	fi
	echo ""

	log "SUCCESS" "Restore completed successfully for VM: $vm_name from backup: $backup_date"
	return 0
}

compress_backup() {
	local file_path="$1"
	local vm_name="$2"

	if [ "$COMPRESSION_ENABLED" = true ]; then
		print_info "Compressing backup..."
		local compressed_file="${file_path}.gz"

		if gzip "$file_path"; then
			local original_size=$(get_file_size "$file_path")
			local compressed_size=$(get_file_size "$compressed_file")
			print_success "Compression completed (${compressed_size})"
			log "INFO" "Compressed backup for $vm_name: $original_size -> $compressed_size"
			echo "$compressed_file"
		else
			print_error "Compression failed, keeping uncompressed backup"
			log "ERROR" "Failed to compress backup for $vm_name"
			echo "$file_path"
		fi
	else
		echo "$file_path"
	fi
}

backup_vm() {
	local vm_name="$1"
	local was_running=false

	print_info "Starting backup for VM: $vm_name"
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

	print_info "VM disk path: $vm_disk_path"
	print_info "Disk size: $(get_file_size "$vm_disk_path")"

	local vm_state=$(get_vm_state "$vm_name")
	print_info "VM current state: $vm_state"

	if [ "$vm_state" = "running" ]; then
		was_running=true
		print_info "Shutting down VM for consistent backup..."

		if virsh shutdown "$vm_name" >/dev/null 2>&1; then
			print_info "Shutdown command sent, waiting up to ${SHUTDOWN_TIMEOUT}s..."

			if wait_for_vm_state "$vm_name" "shut off" "$SHUTDOWN_TIMEOUT"; then
				print_success "VM shut down gracefully"
				log "INFO" "VM $vm_name shut down gracefully"
			else
				print_warning "Graceful shutdown timeout, forcing shutdown..."
				virsh destroy "$vm_name" >/dev/null 2>&1
				sleep 5
				log "WARNING" "Forced shutdown of VM $vm_name"
			fi
		else
			print_error "Failed to send shutdown command"
			log "ERROR" "Failed to send shutdown command to VM $vm_name"
			return 1
		fi
	fi

	if ! mkdir -p "$BACKUP_DIR"; then
		print_error "Failed to create backup directory: $BACKUP_DIR"
		log "ERROR" "Failed to create backup directory: $BACKUP_DIR"
		return 1
	fi

	local backup_folder_name="${vm_name}-$DATE"
	local backup_folder_path="$BACKUP_DIR/$backup_folder_name"
	mkdir -p "$backup_folder_path" || { print_error "Failed to create folder: $backup_folder_path"; return 1; }

	local disk_backup="$backup_folder_path/${vm_name}-disk-$DATE.qcow2"
	local config_backup="$backup_folder_path/${vm_name}-config-$DATE.xml"

	print_info "Backing up VM disk..."
	if cp "$vm_disk_path" "$disk_backup"; then
		local disk_size=$(get_file_size "$disk_backup")
		print_success "Disk backup completed ($disk_size)"
		log "INFO" "Disk backup completed for $vm_name: $disk_size"

		disk_backup=$(compress_backup "$disk_backup" "$vm_name")
	else
		print_error "Failed to backup VM disk"
		log "ERROR" "Failed to backup VM disk for $vm_name"

		if [ "$was_running" = true ]; then
			print_info "Restarting VM..."
			virsh start "$vm_name" >/dev/null 2>&1
		fi
		return 1
	fi

	print_info "Backing up VM configuration..."
	if virsh dumpxml "$vm_name" >"$config_backup" 2>/dev/null; then
		print_success "Configuration backup completed"
		log "INFO" "Configuration backup completed for $vm_name"
	else
		print_error "Failed to backup VM configuration"
		log "ERROR" "Failed to backup VM configuration for $vm_name"
	fi

	if [ "$was_running" = true ]; then
		print_info "Restarting VM..."
		if virsh start "$vm_name" >/dev/null 2>&1; then
			print_success "VM restarted successfully"
			log "INFO" "VM $vm_name restarted successfully"
		else
			print_error "Failed to restart VM"
			log "ERROR" "Failed to restart VM $vm_name"
		fi
	fi

	cleanup_old_backups "$vm_name"

	echo ""
	echo "=================================================="
	print_success "Backup completed for VM: $vm_name"
	echo "=================================================="
	echo "Backup files created:"
	echo "  Disk: $(basename "$disk_backup")"
	echo "  Config: $(basename "$config_backup")"
	echo "  Location: $backup_folder_path"
	echo "  Timestamp: $DATE"
	if [ "$COMPRESSION_ENABLED" = true ]; then
		echo "  Compression: Enabled"
	fi
	echo ""

	log "SUCCESS" "Backup completed successfully for VM: $vm_name"
	return 0
}

if [ $# -lt 1 ]; then
	echo "VM Backup & Restore Script"
	echo "Usage: dcvm backup create <vm_name>"
	echo "       dcvm backup restore <vm_name> [backup_date]"
	echo "       dcvm backup list [vm_name]"
	echo "       dcvm backup delete <vm_name>|<vm_name-dd.mm.yyyy>|<vm_name-dd.mm.yyyy-N>|<vm_name-dd.mm.yyyy-HH:MM:SS>|--all|all"
	echo "       dcvm backup export <vm_name> [backup_date] [output_dir]"
	echo "       dcvm backup import <package_path|directory> [new_vm_name]"
	echo "       dcvm backup troubleshoot <vm_name>"
	echo ""
	echo "Examples:"
	echo "  dcvm backup create datacenter-vm1             			# Create backup"
	echo "  dcvm backup restore datacenter-vm1            			# Restore from latest backup"
	echo "  dcvm backup restore datacenter-vm1 20250722_143052  	# Restore from specific backup"
	echo "  dcvm backup list                                		# List all backups"
	echo "  dcvm backup list datacenter-vm1               			# List backups of a VM"
	echo "  dcvm backup delete vm1                         			# Interactive delete (numbered)"
	echo "  dcvm backup delete vm1-10.01.2025            			# Delete by date-id (day, latest of day)"
	echo "  dcvm backup delete vm1-10.01.2025-2          			# Delete Nth backup of the day"
	echo "  dcvm backup delete vm1-10.01.2025-14:30:00   			# Delete precise backup"
	echo "  dcvm backup delete --all                      			# Delete ALL backups across ALL VMs"
	echo "  dcvm backup export vm1 /tmp                 			# Export latest backup to custom dir"
	echo "  dcvm backup export vm1 20250722_143052 /tmp   			# Export specific backup by timestamp"
	echo "  dcvm backup export vm1 28.09.2025-1 /tmp     			# Export using day+index selector"
	echo "  dcvm backup import /tmp/vm1-20250722_143052.tar.gz 		# Import and restore on this host"
	echo "  dcvm backup troubleshoot vm1                  			# Fix VM startup issues"
	echo ""
	echo "Options:"
	echo "  Backups are stored in: $BACKUP_DIR"
	echo "  Retention: $KEEP_BACKUPS backups per VM"
	echo "  Compression: $([ "$COMPRESSION_ENABLED" = true ] && echo "Enabled" || echo "Disabled")"
	echo ""
	echo "WARNING: Restore will COMPLETELY REPLACE the existing VM!"
	exit 1
fi

SUBCOMMAND="$1"
VM_NAME="$2"
BACKUP_DATE="$3"

for cmd in virsh cp gzip gunzip wget qemu-img; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		print_error "Required command not found: $cmd"
		exit 1
	fi
done

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
	backup_vm "$VM_NAME"; exit $?
	;;
"restore")
	if [ -z "$VM_NAME" ]; then
		print_error "VM name required for 'restore'"
		exit 1
	fi
	restore_vm "$VM_NAME" "$BACKUP_DATE"; exit $?
	;;
"list")
	if [ -n "$VM_NAME" ]; then
		list_backups "$VM_NAME"; exit $?
	else
		list_all_backups; exit $?
	fi
	;;
"delete")
	if [ -z "$VM_NAME" ]; then
		print_error "Argument required. Use: dcvm backup delete <vm>|<vm-dd.mm.yyyy>|<vm-dd.mm.yyyy-N>|<vm-dd.mm.yyyy-HH:MM:SS>|--all|all"
		exit 1
	fi
	delete_backups "$VM_NAME"; exit $?
	;;
"export")
	if [ -z "$VM_NAME" ]; then
		print_error "VM name required for 'export'"
		exit 1
	fi
	export_backup "$VM_NAME" "$BACKUP_DATE" "$4"; exit $?
	;;
"import")
	if [ -z "$VM_NAME" ]; then
		print_error "Package path or directory required for 'import'"
		exit 1
	fi
	import_backup "$VM_NAME" "$BACKUP_DATE"; exit $?
	;;
"troubleshoot")
	if [ -z "$VM_NAME" ]; then
		print_error "VM name required for 'troubleshoot'"
		exit 1
	fi
	troubleshoot_vm "$VM_NAME"; exit $?
	;;
*)
	print_error "Unknown subcommand: $SUBCOMMAND"
	echo "Valid subcommands: create, restore, list, delete, export, import, troubleshoot"
	exit 1
	;;
esac
