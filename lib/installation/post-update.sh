#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

# The installer copies the completion once: each update must refresh the copies a shell sources.
refresh_completion() {
  local f
  for f in "$@"; do
    [ ! -f "$f" ] || cp "$SCRIPT_DIR/../utils/dcvm-completion.sh" "$f" || print_warning "Could not refresh $f"
  done
}

require_root

refresh_completion /usr/local/share/dcvm/dcvm-completion.sh /etc/bash_completion.d/dcvm
# Only the services must match the new files; everything else is the doctor's report to act on.
dcvm_services_ok || install_dcvm_services
