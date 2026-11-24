#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

usage() {
  ui_help <<EOF
dcvm ssh | exec | cp - use a VM over SSH with your own key

Usage:
  dcvm ssh <vm> [-- <command>]      Log in, or run a command with a terminal
  dcvm exec <vm> -- <command>       Run a command without a terminal; exits with its status
  dcvm cp <src> <dst>               Copy files; write the VM side as <vm>:<path>

Examples:
  dcvm ssh web
  dcvm exec web -- 'cd app && make test'
  dcvm cp ./app web:/home/ubuntu/app
  dcvm cp web:/var/log/syslog .
EOF
}

VM_IP="" VM_USER="" VM_ALIAS="" VM_STATE=""
resolve_vm() {
  local info entry="$SCRIPT_DIR/../../dcvm"
  # Installed, ../../dcvm is the library directory itself; the command sits in /usr/local/bin.
  [ -f "$entry" ] || entry=/usr/local/bin/dcvm
  info=$("$entry" info "$1" --json) || exit
  read -r VM_IP VM_USER VM_ALIAS VM_STATE < <(python3 -I -S -c '
import json, sys
i = json.loads(sys.stdin.read())
print(i.get("ip") or "-", i.get("user") or "-", "dcvm-%s-%s" % (i.get("name"), i.get("created") or 0), (i.get("state") or "-").replace(" ", "_"))' <<<"$info")
  if [ "$VM_STATE" = shut_off ]; then
    print_error "$1 is shut off; start it first: dcvm start $1"
    exit 1
  elif [ "$VM_STATE" != running ]; then
    print_error "$1 is ${VM_STATE//_/ }, not running (dcvm info $1)"
    exit 1
  fi
  if [ "$VM_USER" = - ]; then
    print_error "dcvm doesn't know $1's login user (an ISO install, or a VM without its cloud-init files); use ssh yourself"
    exit 1
  fi
  if [ "$VM_IP" = - ]; then
    print_error "$1 has no address yet; wait for it to boot (dcvm info $1)"
    exit 1
  fi
}

ssh_opts() {
  mkdir -p -m 700 "$HOME/.ssh"
  printf '%s\n' -o "HostKeyAlias=$VM_ALIAS" -o "UserKnownHostsFile=$HOME/.ssh/dcvm_known_hosts" \
    -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=10
}

main() {
  local cmd="${1:-}" a
  shift || true
  # Help anywhere before "--"; after it, --help belongs to the remote command.
  for a in "$@"; do
    [ "$a" = -- ] && break
    case "$a" in -h | --help)
      usage
      return 0
      ;;
    esac
  done
  case "$cmd" in
  ssh | exec)
    local vm="${1:-}"
    case "$vm" in "" | -h | --help)
      usage
      [ -n "$vm" ]
      return
      ;;
    esac
    shift
    [ "${1:-}" = -- ] && shift
    if [ "$cmd" = exec ] && [ $# -eq 0 ]; then
      print_error "Usage: dcvm exec <vm> -- <command>"
      return 1
    fi
    resolve_vm "$vm"
    local opts
    mapfile -t opts < <(ssh_opts)
    if [ "$cmd" = exec ]; then
      exec ssh "${opts[@]}" -o BatchMode=yes -T "$VM_USER@$VM_IP" -- "$@"
    fi
    exec ssh "${opts[@]}" "$([ -t 0 ] && echo -t || echo -T)" "$VM_USER@$VM_IP" -- "$@"
    ;;
  cp)
    case "${1:-}" in -h | --help)
      usage
      return 0
      ;;
    esac
    [ $# -eq 2 ] || {
      usage
      return 1
    }
    local src="$1" dst="$2" vm="" opts
    if [[ "$src" == *:* && "$src" != /* && "$src" != .* ]]; then
      vm=${src%%:*}
      resolve_vm "$vm"
      src="$VM_USER@$VM_IP:${src#*:}"
    fi
    if [[ "$dst" == *:* && "$dst" != /* && "$dst" != .* ]]; then
      [ -n "$vm" ] && {
        print_error "dcvm cp copies between this machine and one VM, not from VM to VM"
        return 1
      }
      vm=${dst%%:*}
      resolve_vm "$vm"
      dst="$VM_USER@$VM_IP:${dst#*:}"
    fi
    [ -n "$vm" ] || {
      print_error "One side must be <vm>:<path>"
      return 1
    }
    mapfile -t opts < <(ssh_opts)
    exec scp -r -q "${opts[@]}" -o BatchMode=yes -- "$src" "$dst"
    ;;
  *) usage ;;
  esac
}

main "$@"
