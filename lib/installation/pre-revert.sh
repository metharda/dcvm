#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

# An older version's modules would run behind this version's socket.
remove_units() {
  # disable fails when the units were never installed, so what is left decides.
  systemctl disable --now dcvm.socket dcvm-reaper.timer >/dev/null 2>&1
  rm -f /etc/systemd/system/dcvm.socket /etc/systemd/system/dcvm@.service \
    /etc/systemd/system/dcvm-reaper.service /etc/systemd/system/dcvm-reaper.timer &&
    systemctl daemon-reload >/dev/null 2>&1 && ! systemctl is-active --quiet dcvm.socket dcvm-reaper.timer
}

require_root

remove_units
