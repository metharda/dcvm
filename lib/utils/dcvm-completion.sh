# DCVM tab-completion for Bash and Zsh
_dcvm_commands() {
  echo "create delete list status start stop restart console network backup storage uninstall version help"
}

_dcvm_vm_list() {
  command -v virsh >/dev/null 2>&1 || return 0
  virsh list --all --name 2>/dev/null | grep -v '^$'
}

_dcvm_dhcp_subs() {
  echo "show clear-mac clear-vm clear-all cleanup renew files help"
}


_dcvm_backup_subs() {
  echo "create restore list delete export import troubleshoot help"
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
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  if [[ ${COMP_CWORD} -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "$(_dcvm_commands)" -- "$cur") )
    return 0
  fi

  local cmd="${COMP_WORDS[1]}"

  case "$cmd" in
    delete|start|stop|restart|console|status)
      COMPREPLY=( $(compgen -W "$(_dcvm_vm_list)" -- "$cur") )
      ;;

    create)
      COMPREPLY=( $(compgen -W "$(_dcvm_vm_list)" -- "$cur") )
      ;;

    backup)
      if [[ ${COMP_CWORD} -eq 2 ]]; then
        COMPREPLY=( $(compgen -W "$(_dcvm_backup_subs)" -- "$cur") )
      else
        local sub="${COMP_WORDS[2]}"
        case "$sub" in
          create|restore|delete|export|troubleshoot)
            if [[ ${COMP_CWORD} -eq 3 ]]; then
              COMPREPLY=( $(compgen -W "$(_dcvm_vm_list)" -- "$cur") )
            fi
            ;;
          list)
            if [[ ${COMP_CWORD} -eq 3 ]]; then
              COMPREPLY=( $(compgen -W "$(_dcvm_vm_list)" -- "$cur") )
            fi
            ;;
        esac
      fi
      ;;

    dhcp)
      if [[ ${COMP_CWORD} -eq 2 ]]; then
        COMPREPLY=( $(compgen -W "$(_dcvm_dhcp_subs)" -- "$cur") )
      else
        local sub="${COMP_WORDS[2]}"
        case "$sub" in
          clear-vm)
            if [[ ${COMP_CWORD} -eq 3 ]]; then
              COMPREPLY=( $(compgen -W "$(_dcvm_vm_list)" -- "$cur") )
            fi
            ;;
          clear-mac)
            if [[ ${COMP_CWORD} -eq 3 ]]; then
              COMPREPLY=( $(compgen -W "$(_dcvm_lease_macs)" -- "$cur") )
            fi
            ;;
        esac
      fi
      ;;

    *)
      ;;
  esac
}

if [ -n "$BASH_VERSION" ]; then
  complete -F _dcvm_completion dcvm
fi

if [ -n "$ZSH_VERSION" ]; then
  autoload -Uz bashcompinit 2>/dev/null && bashcompinit
  if typeset -f complete >/dev/null 2>&1; then
    complete -F _dcvm_completion dcvm
  fi
fi
