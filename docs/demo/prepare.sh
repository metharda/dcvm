#!/usr/bin/env bash
# Puts the recording host into the starting state of a tape (see the table in
# docs/development.md). Runs as root on the host, before the tape, off camera.
#   prepare.sh hero|backup|daily|screens
set -euo pipefail

src=${DCVM_SRC:-/root/dcvm-src}
password=$(cat /root/.demo-pass)

install_dcvm() {
  command -v dcvm >/dev/null && return 0
  # No terminal: the installer takes its defaults and skips the NFS share.
  bash "$src/lib/installation/install-dcvm.sh" </dev/null >/dev/null
}

wait_for() {
  local _
  for _ in $(seq 120); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 5
  done
  echo "timed out waiting for: $*" >&2
  return 1
}

vm_exists() { virsh dominfo "$1" >/dev/null 2>&1; }

case "${1:?tape}" in
screens) ;;
hero)
  install_dcvm
  dcvm template download ubuntu-24.04-server-cloudimg-amd64.img >/dev/null
  ;;
backup)
  vm_exists web || dcvm create web -f -p "$password" -k nginx --ip 10.10.10.50 >/dev/null
  wait_for curl -sf -o /dev/null 10.10.10.50
  wait_for ssh -o ConnectTimeout=3 ubuntu@10.10.10.50 true
  ;;
daily)
  wait_for curl -sf -o /dev/null 10.10.10.50
  dcvm template download debian-13-genericcloud-amd64.qcow2 >/dev/null
  vm_exists ctf || dcvm create ctf -f -p "$password" -o 1 >/dev/null
  wait_for sh -c 'ip=$(virsh domifaddr ctf --source lease | awk "/ipv4/ {print \$4}" | cut -d/ -f1); [ -n "$ip" ] && ssh -o ConnectTimeout=3 debian@"$ip" true'
  ;;
*)
  echo "unknown tape: $1" >&2
  exit 1
  ;;
esac
