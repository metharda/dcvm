#!/usr/bin/env bash
# DCVM tab-completion for Bash and Zsh

_dcvm_commands() {
  echo "create create-iso delete list status start stop restart console network backup storage uninstall version help"
}

_dcvm_vm_list() {
  command -v virsh >/dev/null 2>&1 || return 0
  virsh list --all --name 2>/dev/null | grep -v '^$'
}

_dcvm_dhcp_subs() { echo "show clear-mac clear-vm clear-all cleanup renew files help"; }
_dcvm_ports_subs() { echo "setup show rules apply clear test help"; }

_dcvm_backup_subs() {
  echo "create restore list delete export import ssh-setup troubleshoot help"
}

_dcvm_backup_dir() {
  local cfg="/etc/dcvm-install.conf"
  local base="/srv/datacenter"
  if [ -r "$cfg" ]; then
    local val
    val=$(grep -E '^DATACENTER_BASE=' "$cfg" | tail -1 | cut -d= -f2-)
    val="${val%\"}"
    val="${val#\"}"
    val="${val%\'}"
    val="${val#\'}"
    [ -n "$val" ] && base="$val"
  fi
  echo "$base/backups"
}

_dcvm_backup_dates_for_vm() {
  local vm_name="$1"
  [ -z "$vm_name" ] && return 0
  local dir
  dir="$(_dcvm_backup_dir)"
  [ -d "$dir" ] || return 0

  local -a ts_list=()

  while IFS= read -r path; do
    [ -z "$path" ] && continue
    local base=$(basename "$path")
    local ts="${base#${vm_name}-}"
    [[ "$ts" =~ ^[0-9]{8}_[0-9]{6}$ ]] && ts_list+=("$ts")
  done < <(compgen -G "$dir/${vm_name}-????????_??????" 2>/dev/null || printf '')

  while IFS= read -r path; do
    [ -z "$path" ] && continue
    local base=$(basename "$path")
    local ts="${base#${vm_name}-disk-}"
    ts="${ts%.qcow2.gz}"
    ts="${ts%.qcow2}"
    [[ "$ts" =~ ^[0-9]{8}_[0-9]{6}$ ]] && ts_list+=("$ts")
  done < <(compgen -G "$dir/${vm_name}-disk-*.qcow2*" 2>/dev/null || printf '')

  [ ${#ts_list[@]} -eq 0 ] && return 0

  declare -A day_count
  local sorted_ts
  sorted_ts=$(printf "%s\n" "${ts_list[@]}" | sort -u)
  local result=""
  while IFS= read -r ts; do
    [ -z "$ts" ] && continue
    local yyyy="${ts:0:4}"
    local mm="${ts:4:2}"
    local dd="${ts:6:2}"
    local dmy="${dd}.${mm}.${yyyy}"
    local n="${day_count[$dmy]:-0}"
    n=$((n + 1))
    day_count[$dmy]=$n
    result+="${dmy}-${n} "
  done <<<"$sorted_ts"
  echo "$result"
}

_dcvm_lease_macs() {
  local bridge="${BRIDGE_NAME:-virbr-dc}"
  local lease_file="/var/lib/libvirt/dnsmasq/${bridge}.leases"
  [ -r "$lease_file" ] || return 0
  awk '{print $2}' "$lease_file" | grep -E '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' 2>/dev/null | sort -u
}

_dcvm_completion() {
  local cur prev words cword
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD - 1]}"

  if [[ ${COMP_CWORD} -eq 1 ]]; then
    COMPREPLY=($(compgen -W "$(_dcvm_commands)" -- "$cur"))
    return 0
  fi

  local cmd="${COMP_WORDS[1]}"

  case "$cmd" in
  delete | start | stop | restart | console | status)
    if [[ ${COMP_CWORD} -ge 2 ]]; then
      local already_selected=""
      local i
      for ((i = 2; i < COMP_CWORD; i++)); do
        already_selected+=" ${COMP_WORDS[i]}"
      done
      local available_vms=""
      local vm
      for vm in $(_dcvm_vm_list); do
        if [[ ! " $already_selected " =~ " $vm " ]]; then
          available_vms+="$vm "
        fi
      done
      COMPREPLY=($(compgen -W "$available_vms" -- "$cur"))
    fi
    ;;

  create)
    COMPREPLY=()
    ;;

  backup)
    if [[ ${COMP_CWORD} -eq 2 ]]; then
      COMPREPLY=($(compgen -W "$(_dcvm_backup_subs)" -- "$cur"))
    else
      local sub="${COMP_WORDS[2]}"
      case "$sub" in
      create | delete | export | troubleshoot | ssh-setup)
        if [[ ${COMP_CWORD} -eq 3 ]]; then
          COMPREPLY=($(compgen -W "$(_dcvm_vm_list)" -- "$cur"))
        else
          COMPREPLY=()
        fi
        ;;
      restore)
        if [[ ${COMP_CWORD} -eq 3 ]]; then
          COMPREPLY=($(compgen -W "$(_dcvm_vm_list)" -- "$cur"))
        elif [[ ${COMP_CWORD} -eq 4 ]]; then
          local vm_name="${COMP_WORDS[3]}"
          local _dates
          _dates=$(_dcvm_backup_dates_for_vm "$vm_name")
          COMPREPLY=($(compgen -W "$_dates" -- "$cur"))
        else
          COMPREPLY=()
        fi
        ;;
      list)
        if [[ ${COMP_CWORD} -eq 3 ]]; then
          COMPREPLY=($(compgen -W "$(_dcvm_vm_list)" -- "$cur"))
        fi
        ;;
      esac
    fi
    ;;

  network)
    if [[ ${COMP_CWORD} -eq 2 ]]; then
      COMPREPLY=($(compgen -W "show info status start stop restart leases bridge ip-forwarding config ports dhcp help" -- "$cur"))
    else
      local sub1="${COMP_WORDS[2]}"
      case "$sub1" in
      status | start | stop | restart | leases | bridge | config)
        COMPREPLY=()
        ;;
      ip-forwarding)
        if [[ ${COMP_CWORD} -eq 3 ]]; then
          COMPREPLY=($(compgen -W "on off show" -- "$cur"))
        fi
        ;;
      ports)
        if [[ ${COMP_CWORD} -eq 3 ]]; then
          COMPREPLY=($(compgen -W "$(_dcvm_ports_subs)" -- "$cur"))
        fi
        ;;
      dhcp)
        if [[ ${COMP_CWORD} -eq 3 ]]; then
          COMPREPLY=($(compgen -W "$(_dcvm_dhcp_subs)" -- "$cur"))
        else
          local sub2="${COMP_WORDS[3]}"
          case "$sub2" in
          clear-vm)
            if [[ ${COMP_CWORD} -eq 4 ]]; then
              COMPREPLY=($(compgen -W "$(_dcvm_vm_list)" -- "$cur"))
            fi
            ;;
          clear-mac)
            if [[ ${COMP_CWORD} -eq 4 ]]; then
              COMPREPLY=($(compgen -W "$(_dcvm_lease_macs)" -- "$cur"))
            fi
            ;;
          esac
        fi
        ;;
      show | info | help)
        COMPREPLY=()
        ;;
      esac
    fi
    ;;

  *) ;;
  esac
}

if [ -n "${BASH_VERSION-}" ]; then
  complete -F _dcvm_completion dcvm
fi

if [ -n "${ZSH_VERSION-}" ]; then
  autoload -Uz bashcompinit 2>/dev/null && bashcompinit
  if typeset -f complete >/dev/null 2>&1; then
    complete -F _dcvm_completion dcvm
  fi
fi
