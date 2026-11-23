#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

require_root

# An older version's modules would run behind this version's socket.
systemctl disable --now dcvm.socket dcvm-reaper.timer >/dev/null 2>&1
rm -f /etc/systemd/system/dcvm.socket /etc/systemd/system/dcvm@.service \
  /etc/systemd/system/dcvm-reaper.service /etc/systemd/system/dcvm-reaper.timer
systemctl daemon-reload >/dev/null 2>&1
exit 0
