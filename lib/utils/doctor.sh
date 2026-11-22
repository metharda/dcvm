#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

FIX=false
QUIET=false
FAST=false
SUMMARY=false
ONLY="host,network,vms,backups,storage,builds"
VM_FILTER=""
PROBLEMS=0
SECTION=""

section() {
  SECTION="$1${2:+|$2}"
}

report() {
  local kind="$1"
  shift
  case "$kind" in
  warn | fail) PROBLEMS=$((PROBLEMS + 1)) ;;
  fixed) kind=ok ;;
  *) $QUIET && return 0 ;;
  esac
  if [ -n "$SECTION" ]; then
    ui_section "${SECTION%%|*}" "$([[ $SECTION == *"|"* ]] && echo "${SECTION#*|}")"
    SECTION=""
  fi
  ui_step "$kind" "$@"
}

package_for() {
  local family
  family=$(distro_family)
  case "${family:-debian}:$1" in
  debian:qemu-img) echo qemu-utils ;;
  debian:virsh) echo libvirt-clients ;;
  debian:virt-install) echo virtinst ;;
  debian:dhcp_release) echo dnsmasq-utils ;;
  debian:aria2c) echo aria2 ;;
  debian:virt-customize) echo libguestfs-tools ;;
  debian:xz) echo xz-utils ;;
  debian:genisoimage) echo genisoimage ;;
  arch:qemu-img) echo qemu-img ;;
  arch:virsh) echo libvirt ;;
  arch:dhcp_release) echo dnsmasq ;;
  arch:aria2c) echo aria2 ;;
  arch:virt-customize) echo guestfs-tools ;;
  arch:genisoimage) echo cdrtools ;;
  arch:python3) echo python ;;
  fedora:virsh) echo libvirt-client ;;
  fedora:dhcp_release) echo dnsmasq-utils ;;
  fedora:aria2c) echo aria2 ;;
  fedora:guestfish) echo libguestfs ;;
  fedora:virt-customize) echo guestfs-tools ;;
  *) echo "$1" ;;
  esac
}

check_host() {
  section "Host"
  if [ -e /dev/kvm ] && virsh list >/dev/null 2>&1; then
    report ok "KVM" "/dev/kvm present, libvirt answering"
  elif [ ! -e /dev/kvm ]; then
    report fail "KVM" "/dev/kvm missing: enable virtualization in the firmware, or nested KVM on a VM host"
  else
    report fail "libvirt" "not answering: systemctl start libvirtd"
  fi

  local cmd missing=() pkgs=()
  for cmd in qemu-img virsh virt-install jq dhcp_release aria2c guestfish virt-customize xz curl python3; do
    command_exists "$cmd" || {
      missing+=("$cmd")
      pkgs+=("$(package_for "$cmd")")
    }
  done
  command_exists mkisofs || command_exists genisoimage || {
    missing+=(genisoimage)
    pkgs+=("$(package_for genisoimage)")
  }
  if [ ${#missing[@]} -eq 0 ]; then
    report ok "Tools" "all present"
  else
    local install="apt install"
    case "$(distro_family)" in
    arch) install="pacman -S" ;;
    fedora) install="dnf install" ;;
    esac
    report warn "Tools" "missing ${missing[*]}: $install $(printf '%s\n' "${pkgs[@]}" | sort -u | tr '\n' ' ')"
  fi

  local files
  files=$(shell_files_matching "$DCVM_ALIAS_LINE" | tr '\n' ' ')
  if [ -z "$files" ]; then
    report ok "Shell alias" "no old dcvm alias"
  elif $FIX; then
    remove_shell_lines "$DCVM_ALIAS_LINE" >/dev/null
    report fixed "Shell alias" "old dcvm alias removed from ${files% } (open a new shell)"
  else
    report warn "Shell alias" "old 'alias dcvm=' in ${files% } hides the dcvm command: --fix removes it"
  fi

  if dcvm_services_ok; then
    report ok "Services" "hourly storage check, boot service, socket for users without root, expiry of --ttl VMs"
  elif $FIX && install_dcvm_services; then
    report fixed "Services" "installed the storage check, boot service, socket and --ttl expiry"
  else
    report warn "Services" "the boot service, hourly check, socket for users without root or --ttl expiry is missing or old: --fix installs them"
  fi

  local lib=/usr/local/lib/dcvm bad="" p
  [ -d "$lib" ] && bad=$(find "$lib" /usr/local/bin/dcvm /etc/dcvm-install.conf \( ! -user root -o -perm /022 \) -print -quit 2>/dev/null)
  local parents=""
  p=$lib
  while [ "$p" != / ] && [ -d "$lib" ]; do
    p=$(dirname "$p")
    [ "$(stat -c %u "$p")" = 0 ] && [ $((0$(stat -c %a "$p") & 022)) -eq 0 ] || parents+="${parents:+, }$p"
  done
  if [ -n "$parents" ]; then
    report fail "Install" "$parents can be changed by non-root users, who could then run code as root through dcvm: make it root-owned and not group-writable"
  elif [ -z "$bad" ]; then
    report ok "Install" "dcvm's files are root-owned and not writable by others"
  elif $FIX && dcvm_tree_permissions /usr/local/bin/dcvm "$lib" && chown root:root /etc/dcvm-install.conf 2>/dev/null && chmod go-w /etc/dcvm-install.conf 2>/dev/null; then
    report fixed "Install" "dcvm's files made root-owned and not writable by others"
  else
    report fail "Install" "$bad can be changed by a non-root user, who could then run code as root through dcvm: --fix repairs it"
  fi

  local member members risky=""
  members=$(getent group "$DCVM_USER_GROUP" "$DCVM_ADMIN_GROUP" 2>/dev/null | cut -d: -f4 | tr ',' '\n' | grep . | sort -u)
  for member in $members; do
    id -nG "$member" 2>/dev/null | tr ' ' '\n' | grep -qx "$DCVM_ADMIN_GROUP" && continue
    id -nG "$member" 2>/dev/null | tr ' ' '\n' | grep -qxE 'libvirt|disk|docker' && risky+="${risky:+, }$member"
  done
  if [ -n "$risky" ]; then
    report warn "Users" "$risky also in libvirt, disk or docker: that is root on this host and bypasses dcvm's limits"
  elif [ -n "$members" ]; then
    report ok "Users" "$(plural "$(grep -c . <<<"$members")" user) without root (dcvm user list)"
  else
    report skip "Users" "only root uses dcvm (dcvm user add <user> lets others in)"
  fi

  local share="$DATACENTER_BASE/nfs-share"
  if ! awk -v p="$share" '$1 == p { f = 1 } END { exit !f }' /etc/exports 2>/dev/null; then
    report skip "NFS share" "not exported"
  elif nfs_share_secure "$share"; then
    report ok "NFS share" "VM users squashed, closed to host users"
  elif $FIX && secure_nfs_share "$share" "${NETWORK_SUBNET:-10.10.10}"; then
    report fixed "NFS share" "VM users squashed, share closed to host users$([ "${NFS_QUARANTINED:-0}" -gt 0 ] && echo "; moved $NFS_QUARANTINED setuid or device files to $NFS_QUARANTINE_DIR: a VM may have had root on this host")"
  else
    report fail "NFS share" "root in any VM can get root on this host: --fix squashes NFS users and closes the share"
  fi

  local vm_files vm_dirs backups_open=0
  vm_files=$(find "$DATACENTER_BASE/vms" -mindepth 2 -maxdepth 2 -type f \( -name '*.qcow2' -o -name '*.iso' \) -perm /044 -printf . 2>/dev/null | wc -c)
  vm_dirs=$(find "$DATACENTER_BASE/vms" -mindepth 1 -maxdepth 1 -type d -perm /044 -printf . 2>/dev/null | wc -c)
  [ -d "$DATACENTER_BASE/backups" ] && [ -n "$(find "$DATACENTER_BASE/backups" -maxdepth 0 -perm /077 2>/dev/null)" ] && backups_open=1
  if [ $((vm_files + vm_dirs + backups_open)) -eq 0 ]; then
    report ok "Permissions" "VM disks, seeds and backups closed to other users"
  elif $FIX; then
    find "$DATACENTER_BASE/vms" -mindepth 2 -maxdepth 2 -type f \( -name '*.qcow2' -o -name '*.iso' \) -perm /044 -exec chmod go-rwx {} + 2>/dev/null
    find "$DATACENTER_BASE/vms" -mindepth 1 -maxdepth 1 -type d -perm /044 -exec chmod 711 {} + 2>/dev/null
    [ "$backups_open" = 1 ] && chmod 700 "$DATACENTER_BASE/backups"
    report fixed "Permissions" "closed VM disks, seeds and backups to other users"
  else
    report warn "Permissions" "VM disks, cloud-init seeds (password hashes) or backups are readable by every local user: --fix closes them"
  fi

  $FAST && return 0
  local here latest tmp
  here=$(sed -n 's/.*Version: \([0-9][0-9.]*\).*/\1/p' "$(command -v dcvm 2>/dev/null || echo /usr/local/bin/dcvm)" 2>/dev/null | head -1)
  tmp=$(mktemp)
  if timeout 8 bash -c "$(declare -f fetch_repo_file command_exists); fetch_repo_file dcvm '$tmp'" 2>/dev/null; then
    latest=$(sed -n 's/.*Version: \([0-9][0-9.]*\).*/\1/p' "$tmp" | head -1)
  fi
  rm -f "$tmp"
  if [ -z "$latest" ]; then
    report skip "dcvm" "${here:-unknown}; could not check for a newer version"
  elif [ "$here" = "$latest" ]; then
    report ok "dcvm" "$here, the latest"
  elif [ "$(printf '%s\n%s\n' "$here" "$latest" | sort -V | tail -1)" = "$here" ]; then
    report ok "dcvm" "$here, newer than the latest release ($latest)"
  else
    report warn "dcvm" "$here installed, $latest available: dcvm self-update"
  fi
}

check_network() {
  section "Network" "$NETWORK_NAME"
  local info active autostart
  if ! info=$(virsh net-info "$NETWORK_NAME" 2>/dev/null); then
    report fail "$NETWORK_NAME" "does not exist: sudo bash $SCRIPT_DIR/../installation/install-dcvm.sh --network-only"
    return
  fi
  active=$(awk -F': *' '/^Active/ { print $2 }' <<<"$info")
  autostart=$(awk -F': *' '/^Autostart/ { print $2 }' <<<"$info")
  if [ "$active" != yes ] || [ "$autostart" != yes ]; then
    if $FIX && { [ "$active" = yes ] || virsh net-start "$NETWORK_NAME" >/dev/null 2>&1; } && virsh net-autostart "$NETWORK_NAME" >/dev/null 2>&1; then
      report fixed "$NETWORK_NAME" "started and set to autostart"
      active=yes
    else
      report fail "$NETWORK_NAME" "$([ "$active" = yes ] || echo "inactive")$([ "$active" != yes ] && [ "$autostart" != yes ] && echo ", ")$([ "$autostart" = yes ] || echo "no autostart"): --fix starts it"
    fi
  fi
  if [ "$active" = yes ]; then
    if ! ip link show "$BRIDGE_NAME" >/dev/null 2>&1; then
      report fail "Bridge" "$BRIDGE_NAME missing although the network is active: dcvm network restart"
    elif ! pgrep -f "dnsmasq.*/${NETWORK_NAME}.conf" >/dev/null; then
      report fail "DHCP" "dnsmasq not running for $NETWORK_NAME: dcvm network restart"
    elif [ "$autostart" = yes ]; then
      report ok "$NETWORK_NAME" "active, autostart, bridge $BRIDGE_NAME, DHCP running"
    fi
  fi

  local fwd
  fwd=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)
  if [ "$fwd" = 1 ] && ip_forwarding_persisted; then
    report ok "IP forwarding" "on, persisted"
  elif $FIX && enable_ip_forwarding; then
    report fixed "IP forwarding" "turned on and persisted in /etc/sysctl.d/90-dcvm.conf"
  else
    report warn "IP forwarding" "$([ "$fwd" = 1 ] && echo "on but not persisted (off after a reboot)" || echo "off: VMs have no internet"): --fix turns it on"
  fi

  local vm ip ssh_port http_port rules saved=0 lost=0 moved=""
  rules=$(iptables -t nat -S PREROUTING 2>/dev/null)
  while read -r vm ip ssh_port http_port; do
    [ -n "$vm" ] || continue
    saved=$((saved + 1))
    grep -q -- "--dport $ssh_port .*--to-destination $ip:22" <<<"$rules" || lost=$((lost + 1))
    if check_vm_exists "$vm" && [ "$(get_vm_state "$vm")" = running ]; then
      local now
      now=$(get_vm_ip "$vm" 2>/dev/null)
      [[ "$now" == *.* ]] && [ "$now" != "$ip" ] && moved+="${moved:+, }$vm"
    fi
  done < <(read_port_mappings 2>/dev/null)
  if [ "$saved" -eq 0 ]; then
    report skip "Port forwards" "none saved"
  elif [ -n "$moved" ]; then
    report warn "Port forwards" "VM address changed for $moved: dcvm network ports setup"
  elif [ "$lost" -eq 0 ]; then
    report ok "Port forwards" "$(plural "$saved" mapping) with live rules"
  elif $FIX && "$SCRIPT_DIR/../network/port-forward.sh" apply >/dev/null 2>&1; then
    report fixed "Port forwards" "rules restored for $(plural "$saved" mapping) (dcvm network ports apply)"
  else
    report warn "Port forwards" "$lost of $saved saved mappings have no rule (usually after a reboot): --fix runs ports apply"
  fi

  local status="${DNSMASQ_DIR:-/var/lib/libvirt/dnsmasq}/${BRIDGE_NAME}.status" stale=0
  if [ -s "$status" ] && command_exists jq; then
    stale=$(jq --argjson now "$(date +%s)" --arg vms "$(virsh list --all --name 2>/dev/null | tr '[:upper:]' '[:lower:]')" \
      '[.[] | select(((."expiry-time" // 0) < $now) or ((.hostname // "") != "" and ((.hostname | ascii_downcase) as $h | ($vms | split("\n") | index($h)) == null)))] | length' "$status" 2>/dev/null || echo 0)
  fi
  if [ "${stale:-0}" -eq 0 ]; then
    report ok "DHCP leases" "no stale leases"
  elif $FIX && "$SCRIPT_DIR/../network/dhcp.sh" cleanup >/dev/null 2>&1; then
    report fixed "DHCP leases" "$(plural "$stale" "stale lease") released"
  else
    report warn "DHCP leases" "$(plural "$stale" "stale lease") (expired or of deleted VMs): --fix releases them"
  fi
}

# The deleted base file a running VM still has open, if any: after a
# re-download replaced templates/<image>, its QEMU process keeps the old
# build alive until the VM stops.
open_deleted_base() {
  local pid fd
  pid=$(pgrep -f "[g]uest=$1," | head -1)
  [ -n "$pid" ] || return 1
  for fd in /proc/"$pid"/fd/*; do
    case "$(readlink "$fd")" in
    "$(templates_dir)"/*" (deleted)")
      echo "$fd"
      return 0
      ;;
    esac
  done
  return 1
}

base_status() {
  local vm="$1" disk="$2" base="$3" state="$4" img cur fd build pending
  pending="${DATACENTER_BASE}/vms/$vm/base.pending"
  case "$base" in
  "") echo "ok|standalone disk" ;;
  "$(builds_dir)"/*)
    img=$(build_image "$base")
    cur=$(current_build "$img" 2>/dev/null)
    if [ ! -f "$base" ]; then
      echo "fail|base build missing: restore a backup"
    elif [ -z "$cur" ] || [ "$cur" = "$base" ]; then
      echo "ok|current build"
    elif [ "$state" = running ]; then
      echo "skip|moves to the current build at its next start"
    elif $FIX && prepare_vm_disk "$vm" "$vm" >/dev/null; then
      echo "ok|moved to the current build"
    else
      echo "warn|on an older build: --fix moves it"
    fi
    ;;
  "$(templates_dir)"/*)
    img=${base##*/}
    if [ -f "$pending" ]; then
      echo "ok|pinned at its next start to $(sed 's#.*/##' "$pending")"
    elif [ "$(stat -c %W "$disk" 2>/dev/null || echo 0)" -gt "$(stat -c %Y "$base" 2>/dev/null || echo 0)" ]; then
      if ! $FIX; then
        echo "warn|from before 0.9.9: --fix pins it to its build"
      elif [ "$state" = running ]; then
        current_build "$img" >"$pending" && echo "ok|pinned at its next start" || echo "fail|could not register its build"
      else
        prepare_vm_disk "$vm" "$vm" >/dev/null && echo "ok|pinned and on the current build" || echo "fail|could not pin"
      fi
    elif [ "$state" = running ] && fd=$(open_deleted_base "$vm"); then
      if $FIX && build=$(register_build "$fd" "$img"); then
        echo "$build" >"$pending"
        echo "ok|original saved as ${build##*/}; pinned at its next start"
      else
        echo "warn|template replaced while it runs; the original is still open: --fix saves it"
      fi
    elif [ "$state" = running ]; then
      echo "fail|template replaced after creation, restarted since: likely broken; restore a backup"
    elif $FIX && prepare_vm_disk "$vm" "$vm" >/dev/null 2>&1; then
      echo "ok|pinned to the build its disk fits, then moved to the current build"
    elif $FIX; then
      echo "fail|template replaced after creation; no build fits its disk: restore a backup"
    else
      echo "warn|template replaced after creation: --fix looks for the build its disk fits"
    fi
    ;;
  *) echo "skip|not on a dcvm template" ;;
  esac
}

check_vms() {
  section "VMs"
  local vm disk base state ip st kind sym rows="" age pid cpu0 cpu1 noip=()
  local entry stale=()
  for entry in "${DCVM_STATE_DIR:-/var/lib/dcvm}"/vms/*; do
    [ -f "$entry" ] || continue
    vm=${entry##*/}
    [ "$(registry_get "$vm" state)" = creating ] && [ -n "$(find "$entry" -mmin -60)" ] && continue
    check_vm_exists "$vm" || stale+=("$vm")
  done
  if [ ${#stale[@]} -gt 0 ] && $FIX; then
    for vm in "${stale[@]}"; do registry_remove "$vm"; done
    report fixed "Owners" "removed owner records of deleted VMs: ${stale[*]}"
  elif [ ${#stale[@]} -gt 0 ]; then
    report warn "Owners" "owner records of VMs that no longer exist: ${stale[*]}: --fix removes them"
  fi
  while IFS=$'\t' read -r vm disk base; do
    is_vm_in_network "$vm" || continue
    [ -z "$VM_FILTER" ] || [ "$vm" = "$VM_FILTER" ] || continue
    state=$(get_vm_state "$vm")
    ip=""
    [ "$state" = running ] && ip=$(get_vm_ip "$vm" 2>/dev/null)
    [[ "$ip" == *.* ]] || ip=""
    st=$(base_status "$vm" "$disk" "$base" "$state")
    kind=${st%%|*}
    case "$kind" in ok) sym=$SYM_OK ;; skip) sym=$SYM_DOT ;; warn) sym=$SYM_WARN ;; *) sym=$SYM_FAIL ;; esac
    rows+="$vm"$'\t'"$state"$'\t'"${ip:--}"$'\t'"${base##*/}"$'\t'"$sym ${st#*|}"$'\n'
    if $QUIET; then
      $FIX && [ "$kind" = ok ] && [[ "${st#*|}" =~ ^(moved|pinned|original) ]] && kind=fixed
      report "$kind" "$vm" "base: ${st#*|}"
    else
      case "$kind" in warn | fail) PROBLEMS=$((PROBLEMS + 1)) ;; esac
    fi

    if [ "$state" = running ] && [ -z "$ip" ]; then
      pid=$(pgrep -f "[g]uest=$vm," | head -1)
      age=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
      [ "${age:-0}" -gt 180 ] && noip+=("$vm:$age")
    fi
    if [ "$(virsh dominfo "$vm" 2>/dev/null | awk -F': *' '/^Autostart:/ { print $2 }')" = disable ]; then
      if $FIX && virsh autostart "$vm" >/dev/null 2>&1; then
        report fixed "$vm" "autostart turned on (starts with the host)"
      else
        report warn "$vm" "does not start with the host: --fix turns autostart on"
      fi
    fi
    if [ "$state" = "shut off" ] && [ -f "$disk" ] && ! qemu-img info "$disk" >/dev/null 2>&1; then
      report fail "$vm" "its disk is locked although the VM is off: dcvm fix-lock $vm"
    fi
  done < <(vm_disks)
  if [ -z "$rows" ]; then
    $QUIET || echo -e "  ${DIM}no dcvm VMs${NC}"
  elif ! $QUIET; then
    SECTION=""
    ui_section "VMs"
    printf 'VM\tSTATE\tIP\tBASE\tSTATUS\n%s' "$rows" | ui_table
  fi
  local item
  for item in "${noip[@]}"; do
    vm=${item%%:*} age=${item#*:}
    if $FAST; then
      report warn "$vm" "running $((age / 60)) min without an address: likely stuck at boot; dcvm console $vm"
      continue
    fi
    cpu0=$(virsh domstats "$vm" --cpu-total 2>/dev/null | sed -n 's/.*cpu.time=//p')
    sleep 1
    cpu1=$(virsh domstats "$vm" --cpu-total 2>/dev/null | sed -n 's/.*cpu.time=//p')
    report warn "$vm" "running $((age / 60)) min without an address, CPU $(((cpu1 - cpu0) / 10000000))%: likely stuck at boot; dcvm console $vm"
  done
}

check_backups() {
  section "Backups" "${DATACENTER_BASE}/backups"
  local folder recorded=0 legacy=0 missing="" sha vm newest age none=""
  for folder in "${DATACENTER_BASE}"/backups/*-????????_??????; do
    [ -d "$folder" ] || continue
    if [ -f "$folder/base" ]; then
      recorded=$((recorded + 1))
      sha=$(sed -n 's/^sha256=//p' "$folder/base")
      [ -z "$sha" ] || find_build "$sha" >/dev/null || missing+="${missing:+, }${folder##*/}"
    else
      legacy=$((legacy + 1))
    fi
  done
  report ok "Records" "$recorded with a base record, $legacy from before 0.9.9 (matched by a file system check when restored)"
  [ -n "$missing" ] && report warn "Base builds" "not on this host for $missing (restore fetches them from the archive if they are there)"
  while read -r vm; do
    newest=$(ls -1d "${DATACENTER_BASE}/backups/$vm"-????????_?????? 2>/dev/null | sort | tail -1)
    if [ -z "$newest" ]; then
      none+="${none:+, }$vm"
    else
      age=$((($(date +%s) - $(stat -c %Y "$newest")) / 86400))
      [ "$age" -gt 30 ] && report skip "$vm" "newest backup is $age days old (dcvm backup create $vm)"
    fi
  done < <(list_datacenter_vm_names)
  [ -n "$none" ] && report skip "No backup" "$none (dcvm backup create <vm>)"
}

check_storage() {
  section "Storage" "$DATACENTER_BASE"
  local free largest=0 f size
  free=$(($(df -Pk "$DATACENTER_BASE" 2>/dev/null | awk 'NR == 2 { print $4 }') * 1024))
  for f in "$DATACENTER_BASE"/vms/*/*-disk.qcow2; do
    [ -f "$f" ] || continue
    size=$(file_bytes "$f")
    [ "$size" -gt "$largest" ] && largest=$size
  done
  if [ "$largest" -gt 0 ] && [ "$free" -lt "$largest" ]; then
    report fail "Free space" "$(format_bytes "$free") free; a backup of the largest VM disk needs $(format_bytes "$largest")"
  elif [ "$largest" -gt 0 ] && [ "$free" -lt $((largest * 2)) ]; then
    report warn "Free space" "$(format_bytes "$free") free; little room for a backup of the largest VM disk ($(format_bytes "$largest"))"
  else
    report ok "Free space" "$(format_bytes "$free") free"
  fi

  local orphans="" d
  for d in "$DATACENTER_BASE"/vms/*/; do
    [ -d "$d" ] || continue
    d=${d%/}
    check_vm_exists "${d##*/}" || orphans+="${orphans:+, }${d##*/}"
  done
  [ -n "$orphans" ] && report warn "VM folders" "no VM for $orphans in $DATACENTER_BASE/vms (remove them by hand if not needed)"

  local stale=(find "$DATACENTER_BASE/vms" "$DATACENTER_BASE/backups" "$(templates_dir)" -maxdepth 2 -type f
  \( -name '*.rebase' -o -name '.restore-*.qcow2' -o -name '*.tmp.*' -o -name '.fetch.*' -o -name '.rescue.tmp' \) -mmin +60)
  local count
  count=$("${stale[@]}" -printf . 2>/dev/null | wc -c)
  if [ "$count" -eq 0 ]; then
    report ok "Leftovers" "no files from interrupted operations"
  elif $FIX; then
    "${stale[@]}" -delete 2>/dev/null
    report fixed "Leftovers" "removed $(plural "$count" file) from interrupted operations"
  else
    report warn "Leftovers" "$(plural "$count" file) from interrupted downloads, restores or base moves: --fix removes them"
  fi

  $FAST && return 0
  local img corrupt=""
  for img in "$(templates_dir)"/*; do
    [ -f "$img" ] || continue
    qemu-img check -U "$img" >/dev/null 2>&1 || corrupt+="${corrupt:+, }${img##*/}"
  done
  if [ -n "$corrupt" ]; then
    report fail "Templates" "corrupt: $corrupt (dcvm template download <image> --force)"
  else
    report ok "Templates" "all pass qemu-img check"
  fi
}

check_builds() {
  section "Builds" "$(builds_dir)"
  local removed b users rows="" pending
  if $FIX; then
    removed=$(prune_builds)
    [ -n "$removed" ] && report fixed "Removed" "unused builds: $(echo $removed)"
  fi
  $QUIET && return 0
  pending=$(cat "${DATACENTER_BASE}"/vms/*/base.pending 2>/dev/null)
  for b in "$(builds_dir)"/*; do
    [ -f "$b" ] && [ "${b##*.}" != sums ] || continue
    users=$(vm_disks | awk -F'\t' -v b="$b" '$3 == b { printf "%s%s", s, $1; s = ", " }')
    [ "$b" -ef "$(templates_dir)/$(build_image "$b")" ] && users="current template${users:+, }$users"
    grep -qxF "$b" <<<"$pending" && users+="${users:+, }VMs at their next start"
    [ "$(backup_builds | grep -cxF "$b")" -gt 0 ] && users+="${users:+, }$(plural "$(backup_builds | grep -cxF "$b")" backup)"
    if [ -z "$users" ]; then
      legacy_references && users="kept: disks or backups from before 0.9.9 may need it" || users="nothing (--fix deletes it)"
    fi
    rows+="${b##*/}"$'\t'"$users"$'\n'
  done
  ui_section "Builds" "$(builds_dir)"
  SECTION=""
  if [ -n "$rows" ]; then
    printf 'BUILD\tUSED BY\n%s' "$rows" | ui_table
  else
    echo -e "  ${DIM}none yet; dcvm records builds as VMs are created or templates downloaded${NC}"
  fi
}

show_help() {
  ui_help <<EOF
dcvm doctor - check the host, network, VMs, base images, backups and storage

Usage: dcvm doctor [--fix] [--quiet] [--only <areas>] [--vm <name>]

Checks:
  host        KVM and libvirt, missing tools, services, old dcvm aliases, newer dcvm
  network     the dcvm network, IP forwarding, port forward rules, stale DHCP leases
  vms         base image of each VM, VMs stuck at boot, autostart, locked disks
  backups     base records, missing builds, VMs without a recent backup
  storage     free space for backups, orphan VM folders, leftovers, corrupt templates
  builds      the base builds kept in templates/builds/ and what uses them

Options:
  --fix              repair what is safe (network, IP forwarding, port forwards,
                     stale leases, aliases, services, autostart, base images,
                     unused builds, leftovers)
  --quiet            print only problems and fixes; exit 1 when problems remain
  --only <areas>     comma separated, e.g. --only network,vms
  --vm <name>        only this VM in the vms area
  --fast             skip the slow checks (newer version, template integrity)
  --summary          one line, and only when there are problems (for dcvm status)
EOF
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
    --fix) FIX=true ;;
    --quiet | -q) QUIET=true ;;
    --fast) FAST=true ;;
    --summary) SUMMARY=true QUIET=true FAST=true ;;
    --only)
      ONLY="${2:-}"
      shift
      ;;
    --vm)
      VM_FILTER="${2:-}"
      shift
      ;;
    -h | --help | help)
      show_help
      return 0
      ;;
    *)
      print_error "Unknown option: $1 (dcvm doctor --help)"
      return 1
      ;;
    esac
    shift
  done
  load_dcvm_config
  require_root

  local area
  if $SUMMARY; then
    for area in ${ONLY//,/ }; do declare -F "check_$area" >/dev/null && "check_$area"; done >/dev/null 2>&1
    [ "$PROBLEMS" -eq 0 ] || echo -e "${YELLOW}${SYM_WARN}${NC} $(plural "$PROBLEMS" problem) found  ${DIM}dcvm doctor shows them${NC}"
    [ "$PROBLEMS" -eq 0 ]
    return
  fi

  $QUIET || ui_title "Doctor" "${ONLY//,/, }$($FIX && echo " ${SYM_DOT} fixing")"
  for area in ${ONLY//,/ }; do
    if declare -F "check_$area" >/dev/null; then
      "check_$area"
    else
      print_error "Unknown area: $area (host, network, vms, backups, storage, builds)"
      return 1
    fi
  done

  if [ "$PROBLEMS" -eq 0 ]; then
    $QUIET || ui_done ok "No problems found"
  elif $FIX; then
    ui_done warn "$(plural "$PROBLEMS" problem) left" "see the lines marked ! and ✗"
  else
    ui_done warn "$(plural "$PROBLEMS" problem) found" "dcvm doctor --fix repairs what it safely can"
  fi
  $QUIET || echo ""
  [ "$PROBLEMS" -eq 0 ]
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
