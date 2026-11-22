#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

require_root

"$SCRIPT_DIR/../utils/doctor.sh" --fix --quiet --only host || true
