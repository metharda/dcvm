#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

json_str() { printf '"%s"' "$(sed 's/\\/\\\\/g; s/"/\\"/g' <<<"$1")"; }

show_whoami() {
  if [ "${1:-}" = --json ]; then
    printf '{"user":%s,"uid":%s,"role":%s}\n' "$(json_str "$(caller_user)")" "$(caller_uid)" "$(json_str "$(caller_role)")"
    return 0
  fi
  echo ""
  ui_kv "User" "$(caller_user)" "Role" "$(caller_role)"
  echo ""
}

show_info() {
  local vm="$1" json="${2:-}" state ip cpus mem owner expires protected created
  if ! check_vm_exists "$vm" || ! is_vm_in_network "$vm"; then
    print_error "No VM named $vm"
    return 1
  fi
  state=$(get_vm_state "$vm")
  ip=$(get_vm_ip "$vm")
  [ "$ip" = N/A ] && ip=""
  cpus=$(virsh dominfo -- "$vm" 2>/dev/null | awk '/^CPU\(s\)/ { print $2 }')
  mem=$(virsh dominfo -- "$vm" 2>/dev/null | awk '/^Max memory/ { print int($3 / 1024) }')
  owner=$(registry_get "$vm" owner)
  expires=$(registry_get "$vm" expires)
  protected=$(registry_get "$vm" protected)
  created=$(registry_get "$vm" created)
  if [ "$json" = --json ]; then
    printf '{"name":%s,"state":%s,"ip":%s,"user":%s,"owner":%s,"vcpus":%s,"memory_mb":%s,"protected":%s,"expires":%s,"created":%s}\n' \
      "$(json_str "$vm")" "$(json_str "$state")" "$([ -n "$ip" ] && json_str "$ip" || echo null)" \
      "$(login=$(vm_login "$vm") && [ -n "$login" ] && json_str "$login" || echo null)" "$(json_str "${owner:-root}")" "${cpus:-null}" "${mem:-null}" \
      "$([ "$protected" = 1 ] && echo true || echo false)" "${expires:-null}" "${created:-null}"
    return 0
  fi
  echo ""
  ui_kv "VM" "$vm" "State" "$state" "IP" "${ip:-none yet}" "Login" "$(vm_login "$vm" | grep . || echo "not known to dcvm (an ISO install, or a VM without its cloud-init files)")" \
    "Owner" "${owner:-root}" "Resources" "${cpus:-?} vCPU, ${mem:-?} MB" \
    "Protected" "$([ "$protected" = 1 ] && echo yes || echo no)" \
    "Expires" "$([ -n "$expires" ] && date -d "@$expires" '+%Y-%m-%d %H:%M' || echo never)"
  echo ""
}

set_protected() {
  local vm="$1" value="$2"
  if ! check_vm_exists "$vm" || ! is_vm_in_network "$vm"; then
    print_error "No VM named $vm"
    return 1
  fi
  [ -f "$(registry_file "$vm")" ] || registry_set "$vm" "owner_uid=0" "owner=root"
  registry_set "$vm" "protected=$value"
  if [ "$value" = 1 ]; then
    ui_done ok "$vm is protected" "delete and restore refuse it until: dcvm unprotect $vm"
  else
    ui_done ok "$vm is no longer protected"
  fi
}

reap_expired() {
  local f vm expires now names count=0
  # One listing, not a lookup per VM: without libvirt every VM looks gone, and its record would be lost.
  names=$(virsh list --all --name 2>/dev/null) || {
    echo "dcvm reap: libvirt is not answering; trying again next run" >&2
    return 1
  }
  now=$(date +%s)
  for f in "${DCVM_STATE_DIR:-/var/lib/dcvm}"/vms/*; do
    [ -f "$f" ] || continue
    vm=${f##*/}
    expires=$(registry_get "$vm" expires)
    [[ "$expires" =~ ^[0-9]+$ ]] && [ "$expires" -le "$now" ] || continue
    if [ "$(registry_get "$vm" protected)" = 1 ]; then
      continue
    fi
    if grep -qxF -- "$vm" <<<"$names"; then
      # The server holds this lock while a user works on the VM; a busy VM waits for the next run.
      mkdir -p -m 700 /run/dcvm/locks
      if flock -n "/run/dcvm/locks/vm-$vm" "$SCRIPT_DIR/delete-vm.sh" "$vm" >/dev/null 2>&1; then
        count=$((count + 1))
        log_to_file "/var/log/dcvm-reaper.log" "deleted $vm (ttl ended $(date -d "@$expires" -Is))" 2>/dev/null
      fi
    else
      registry_remove "$vm"
    fi
  done
  [ "$count" -gt 0 ] && echo "dcvm reap: deleted $(plural "$count" VM) whose time ran out"
  return 0
}

require_admin() {
  case "$(caller_role)" in
  root | admin) return 0 ;;
  esac
  print_error "This needs a dcvm admin"
  exit 1
}

manage_users() {
  require_admin
  local action="${1:-list}" name="${2:-}" member
  case "$action" in
  add)
    [ -n "$name" ] && id -u "$name" >/dev/null 2>&1 || {
      print_error "No such user: ${name:-<user>}"
      return 1
    }
    ensure_dcvm_groups || return 1
    usermod -aG "$DCVM_USER_GROUP" "$name" || return 1
    if [ "${3:-}" = --admin ]; then
      usermod -aG "$DCVM_ADMIN_GROUP" "$name" || return 1
      ui_done ok "$name is a dcvm admin" "admins can do everything root can; it takes effect at their next login"
    else
      ui_done ok "$name can use dcvm" "their own VMs only; it takes effect at their next login"
    fi
    ;;
  remove)
    [ -n "$name" ] || {
      print_error "Usage: dcvm user remove <user>"
      return 1
    }
    member=false
    gpasswd -d "$name" "$DCVM_ADMIN_GROUP" >/dev/null 2>&1 && member=true
    gpasswd -d "$name" "$DCVM_USER_GROUP" >/dev/null 2>&1 && member=true
    if [ "$member" = false ]; then
      print_error "$name is not a dcvm user"
      return 1
    fi
    ui_done ok "$name can no longer use dcvm" "their VMs stay; dcvm owner <vm> <user> hands them to someone else"
    ;;
  list)
    {
      printf 'USER\tROLE\tVMS\n'
      for member in $(getent group "$DCVM_USER_GROUP" "$DCVM_ADMIN_GROUP" | cut -d: -f4 | tr ',' '\n' | sort -u); do
        [ -n "$member" ] || continue
        printf '%s\t%s\t%s\n' "$member" \
          "$(id -nG "$member" 2>/dev/null | tr ' ' '\n' | grep -qx "$DCVM_ADMIN_GROUP" && echo admin || echo user)" \
          "$(grep -l "^owner_uid=$(id -u "$member" 2>/dev/null)$" "${DCVM_STATE_DIR:-/var/lib/dcvm}"/vms/* 2>/dev/null | wc -l)"
      done
    } | ui_table
    ;;
  *)
    print_error "Usage: dcvm user add <user> [--admin] | remove <user> | list"
    return 1
    ;;
  esac
}

set_owner() {
  require_admin
  local vm="$1" name="$2" uid
  if ! check_vm_exists "$vm" || ! is_vm_in_network "$vm"; then
    print_error "No VM named $vm"
    return 1
  fi
  uid=$(id -u "$name" 2>/dev/null) || {
    print_error "No such user: $name"
    return 1
  }
  registry_set "$vm" "owner_uid=$uid" "owner=$name"
  ui_done ok "$vm now belongs to $name" "its existing backups stay with their owner"
  echo -e "      ${DIM}The VM still holds only the previous owner's SSH key: $name logs in with the VM's password (dcvm console $vm) and adds their key to ~/.ssh/authorized_keys.${NC}"
}

usage() {
  case "$1" in
  info) echo "Usage: dcvm info <vm> [--json]     State, IP, login user, owner, resources, expiry" ;;
  whoami) echo "Usage: dcvm whoami [--json]        Your dcvm user and role (root, admin or user)" ;;
  protect | unprotect) echo "Usage: dcvm protect <vm> | dcvm unprotect <vm>    A protected VM refuses delete and restore" ;;
  reap) echo "Usage: dcvm reap                  Delete VMs whose --ttl has passed (admins; the timer runs it every 5 minutes)" ;;
  user) echo "Usage: dcvm user add <user> [--admin] | remove <user> | list    Who may use dcvm without root (admins)" ;;
  owner) echo "Usage: dcvm owner <vm> <user>     Hand a VM to another user (admins)" ;;
  esac
}

main() {
  local cmd="$1"
  shift
  if [ "${1:-}" = --help ]; then
    usage "$cmd"
    exit 0
  fi
  load_dcvm_config
  case "$cmd" in
  whoami) show_whoami "$@" ;;
  info)
    [ -n "${1:-}" ] || {
      print_error "Usage: dcvm info <vm> [--json]"
      return 1
    }
    show_info "$@"
    ;;
  protect) set_protected "${1:?Usage: dcvm protect <vm>}" 1 ;;
  unprotect) set_protected "${1:?Usage: dcvm unprotect <vm>}" 0 ;;
  reap)
    require_admin
    reap_expired
    ;;
  user) manage_users "$@" ;;
  owner) set_owner "${1:?Usage: dcvm owner <vm> <user>}" "${2:?Usage: dcvm owner <vm> <user>}" ;;
  esac
}

main "$@"
