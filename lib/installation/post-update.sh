#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

require_root

# Only the services must match the new files; everything else is the doctor's report to act on.
dcvm_services_ok || install_dcvm_services
