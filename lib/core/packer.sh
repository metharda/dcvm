#!/bin/bash

set -euo pipefail
if [[ "${PACKER_DEBUG:-}" == "1" ]]; then
  set -x
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

if [[ -f "/etc/dcvm-install.conf" ]]; then
  load_dcvm_config
else
  DATACENTER_BASE="${DATACENTER_BASE:-/srv/datacenter}"
  NETWORK_NAME="${NETWORK_NAME:-datacenter-net}"
  BRIDGE_NAME="${BRIDGE_NAME:-virbr-dc}"
fi

ensure_packer() {
  if command -v packer >/dev/null 2>&1; then
    return 0
  fi

  local os arch arch_id ver
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) arch_id="amd64" ;;
    aarch64|arm64) arch_id="arm64" ;;
    *) arch_id="" ;;
  esac
  ver="${PACKER_VERSION:-1.11.2}"

  # Choose installation target directory (user-local if not root)
  local target_dir
  if [[ ${EUID:-1000} -eq 0 ]]; then
    target_dir="/usr/local/bin"
  else
    target_dir="$HOME/.dcvm/bin"
    mkdir -p "$target_dir" >/dev/null 2>&1 || true
    # Prepend to PATH for current process so we can use it immediately
    export PATH="$target_dir:$PATH"
  fi

  if [[ "$os" == "darwin" ]]; then
    if command -v packer >/dev/null 2>&1; then return 0; fi
    if command -v brew >/dev/null 2>&1; then
      print_info "Installing Packer via Homebrew..."
      if brew install packer >/dev/null 2>&1 || brew install hashicorp/tap/packer >/dev/null 2>&1; then
        command -v packer >/dev/null 2>&1 && { print_success "Packer installed via Homebrew"; return 0; }
      fi
    fi
    if [[ -n "$arch_id" ]]; then
      local url="https://releases.hashicorp.com/packer/${ver}/packer_${ver}_darwin_${arch_id}.zip"
      local tmpd
      tmpd=$(mktemp -d)
      print_info "Downloading Packer ${ver} for macOS (${arch_id})"
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$tmpd/packer.zip" "$url" || true
      else
        wget -q -O "$tmpd/packer.zip" "$url" || true
      fi
      if [[ -s "$tmpd/packer.zip" ]]; then
        if command -v unzip >/dev/null 2>&1; then
          unzip -o "$tmpd/packer.zip" -d "$target_dir" >/dev/null 2>&1 || true
        elif command -v bsdtar >/dev/null 2>&1; then
          bsdtar -xf "$tmpd/packer.zip" -C "$target_dir" || true
        fi
        chmod +x "$target_dir/packer" 2>/dev/null || true
        rm -rf "$tmpd" || true
        if command -v packer >/dev/null 2>&1 || [[ -x "$target_dir/packer" ]]; then
          print_success "Packer installed to $target_dir/packer"
          return 0
        fi
      fi
    fi
    print_error "Could not install Packer automatically on macOS. Please install Homebrew and run: brew install packer"
    return 1
  fi

  if [[ "$os" == "linux" ]]; then
    if command -v packer >/dev/null 2>&1; then return 0; fi
    if [[ -f /etc/os-release ]]; then
      . /etc/os-release
      if [[ "$ID" == "debian" || "$ID" == "ubuntu" ]]; then
        if command -v apt >/dev/null 2>&1; then
          print_info "Installing Packer via apt..."
          if [[ ${EUID:-1000} -eq 0 ]]; then
            export DEBIAN_FRONTEND=noninteractive
            if apt update -y && apt install -y packer; then
              command -v packer >/dev/null 2>&1 && { print_success "Packer installed via apt"; return 0; }
            fi
          else
            print_warning "Not running as root; skipping apt install. Falling back to user-local install."
          fi
        fi
      fi
    fi
    if [[ -n "$arch_id" ]]; then
      local url="https://releases.hashicorp.com/packer/${ver}/packer_${ver}_linux_${arch_id}.zip"
      local tmpd
      tmpd=$(mktemp -d)
      print_info "Downloading Packer ${ver} for Linux (${arch_id})"
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$tmpd/packer.zip" "$url" || true
      else
        wget -q -O "$tmpd/packer.zip" "$url" || true
      fi
      if [[ -s "$tmpd/packer.zip" ]]; then
        if ! command -v unzip >/dev/null 2>&1 && ! command -v bsdtar >/dev/null 2>&1; then
          if [[ -f /etc/os-release && ( "$ID" == "debian" || "$ID" == "ubuntu" ) ]] && command -v apt >/dev/null 2>&1 && [[ ${EUID:-1000} -eq 0 ]]; then
            apt update -y && apt install -y unzip || true
          fi
        fi
        if command -v unzip >/dev/null 2>&1; then
          unzip -o "$tmpd/packer.zip" -d "$target_dir" >/dev/null 2>&1 || true
        elif command -v bsdtar >/dev/null 2>&1; then
          bsdtar -xf "$tmpd/packer.zip" -C "$target_dir" || true
        fi
        chmod +x "$target_dir/packer" 2>/dev/null || true
        rm -rf "$tmpd" || true
        if command -v packer >/dev/null 2>&1 || [[ -x "$target_dir/packer" ]]; then
          print_success "Packer installed to $target_dir/packer"
          return 0
        fi
      fi
    fi
  fi

  print_error "Automatic installation of Packer failed. Please install it manually and retry."
  return 1
}

show_usage() {
  cat <<'EOF'
Packer integration
Usage:
  dcvm packer build <vm_name> --template <path> [options]
  dcvm packer validate --template <path> [options]
  dcvm packer init --template <path>
  dcvm packer inspect --template <path>

Build options:
  --template <path>          Required. Packer HCL file (e.g., build.ubuntu-22_04.pkr.hcl)
  --only <target>            Run only the specified builder (e.g., qemu.ubuntu-22_04)
  --var-file <file>          Add var file (repeatable)
  --var key=value            Add var (repeatable)
  --artifact <path>          Explicit artifact path (qcow2/raw[.gz])
  --os-variant <name>        libosinfo variant (e.g., ubuntu22.04)
  -m, --memory <MB>          VM RAM (default: 4096)
  -c, --cpus <N>             VM CPU (default: 4)
  --attach-cidata            Attach an empty cloud-init ISO
  -h, --help                 Show this help

Notes:
  - build locates the newest qcow2/raw artifact after completion and imports it via 'dcvm import-image'.
  - If auto-detection fails, provide the path using --artifact.
EOF
}

CMD=""
VM_NAME=""
TEMPLATE_PATH=""
ONLY_TARGET=""
declare -a VAR_FILES=()
declare -a VAR_KVS=()
ARTIFACT_PATH=""
OS_VARIANT=""
MEMORY=4096
CPUS=4
ATTACH_CIDATA=false

parse_args() {
  [[ $# -lt 1 ]] && { show_usage; exit 1; }
  CMD="$1"; shift || true
  case "$CMD" in
    build)
      [[ $# -lt 1 ]] && { show_usage; exit 1; }
      VM_NAME="$1"; shift
      ;;
    validate|init|inspect|help|-h|--help)
      ;;
    *)
      echo "Unknown subcommand: $CMD"; show_usage; exit 1 ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
  -h|--help) show_usage; exit 0 ;;
      --template) TEMPLATE_PATH="$2"; shift 2 ;;
      --only) ONLY_TARGET="$2"; shift 2 ;;
      --var-file) VAR_FILES+=("$2"); shift 2 ;;
      --var) VAR_KVS+=("$2"); shift 2 ;;
      --artifact) ARTIFACT_PATH="$2"; shift 2 ;;
      --os-variant) OS_VARIANT="$2"; shift 2 ;;
      -m|--memory) MEMORY="$2"; shift 2 ;;
      -c|--cpus) CPUS="$2"; shift 2 ;;
      --attach-cidata) ATTACH_CIDATA=true; shift ;;
  *) echo "Unknown option: $1"; show_usage; exit 1 ;;
    esac
  done

  if [[ "$CMD" != "help" && "$CMD" != "-h" && "$CMD" != "--help" ]]; then
  [[ -z "$TEMPLATE_PATH" ]] && { echo "--template is required"; show_usage; exit 1; }
  [[ ! -f "$TEMPLATE_PATH" ]] && { print_error "Template not found: $TEMPLATE_PATH"; exit 1; }
  fi
}

run_packer() {
  local subcmd="$1"; shift
  local tpl_dir tpl_file
  tpl_dir="$(cd "$(dirname "$TEMPLATE_PATH")" && pwd)"
  tpl_file="$(basename "$TEMPLATE_PATH")"

  local -a base=(packer "$subcmd")

  case "$subcmd" in
    build)
      local -a args=()
      [[ -n "$ONLY_TARGET" ]] && args+=("-only" "$ONLY_TARGET")
      for vf in "${VAR_FILES[@]}"; do args+=("-var-file" "$vf"); done
  for kv in "${VAR_KVS[@]}"; do args+=("-var" "$kv"); done
      print_info "Executing: (cd $tpl_dir && ${base[*]} ${args[*]} $tpl_file)"
      ( cd "$tpl_dir" && "${base[@]}" "${args[@]}" "$tpl_file" )
      ;;
    validate|inspect|init)
      local -a args=()
      [[ "$subcmd" == "validate" || "$subcmd" == "inspect" ]] && {
        for vf in "${VAR_FILES[@]}"; do args+=("-var-file" "$vf"); done
        for kv in "${VAR_KVS[@]}"; do args+=("-var" "$kv"); done
      }
      print_info "Executing: (cd $tpl_dir && ${base[*]} ${args[*]} $tpl_file)"
      ( cd "$tpl_dir" && "${base[@]}" "${args[@]}" "$tpl_file" )
      ;;
  esac
}

find_artifact() {
  if [[ -n "$ARTIFACT_PATH" ]]; then
    echo "$ARTIFACT_PATH"
    return 0
  fi

  local stamp="$1"
  local search_dir
  search_dir="$(cd "$(dirname "$TEMPLATE_PATH")" && pwd)"

  local -a candidates=()
  while IFS= read -r f; do
    candidates+=("$f")
  done < <(find "$search_dir" -type f \( -name "*.qcow2" -o -name "*.qcow2.gz" -o -name "*.img" -o -name "*.raw" \) -newer "$stamp" 2>/dev/null | sort)

  if [[ ${#candidates[@]} -eq 0 ]]; then
    while IFS= read -r f; do
      candidates+=("$f")
    done < <(find "$search_dir" -type f -path "*/output-*/*" \( -name "*.qcow2" -o -name "*.qcow2.gz" -o -name "*.img" -o -name "*.raw" \) -newer "$stamp" 2>/dev/null | sort)
  fi

  if [[ ${#candidates[@]} -eq 0 ]]; then
    return 1
  fi

  local latest=""
  local latest_mtime=0
  for f in "${candidates[@]}"; do
    local mt
    mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    if (( mt > latest_mtime )); then
      latest_mtime=$mt
      latest="$f"
    fi
  done
  [[ -n "$latest" ]] && echo "$latest" || return 1
}

auto_import() {
  local vm="$1" artifact="$2"
  local fmt=""
  case "$artifact" in
    *.qcow2|*.qcow2.gz) fmt="qcow2" ;;
    *.img|*.raw) fmt="raw" ;;
    *) fmt="qcow2" ;;
  esac

  local extra=( )
  [[ -n "$OS_VARIANT" ]] && extra+=(--os-variant "$OS_VARIANT")
  [[ "$ATTACH_CIDATA" == true ]] && extra+=(--attach-cidata)

  print_info "Importing image: $artifact (fmt=$fmt)"
  "$SCRIPT_DIR/import-image.sh" "$vm" --image "$artifact" --format "$fmt" -m "$MEMORY" -c "$CPUS" ${extra[@]+${extra[@]}}
}

main() {
  parse_args "$@"

  case "$CMD" in
    help|-h|--help)
      show_usage; exit 0 ;;
    validate|inspect|init)
      ensure_packer || exit 1
      run_packer "$CMD"; exit 0 ;;
    build)
      ensure_packer || exit 1
      local stamp
      stamp=$(mktemp)
      touch "$stamp"
      run_packer build
      local artifact
      if ! artifact=$(find_artifact "$stamp"); then
        print_warning "Could not detect an artifact from Packer output. Please provide --artifact <path>."
        rm -f "$stamp" || true
        exit 1
      fi
      rm -f "$stamp" || true
      local host_os
      host_os=$(uname -s | tr '[:upper:]' '[:lower:]')
      if [[ "${DCVM_SKIP_IMPORT:-0}" == "1" ]]; then
        print_info "Skipping auto-import (DCVM_SKIP_IMPORT=1). Artifact ready at: $artifact"
        exit 0
      fi
      if [[ "$host_os" == "linux" ]] && command -v virsh >/dev/null 2>&1; then
        auto_import "$VM_NAME" "$artifact"
      else
        print_info "Auto-import is only supported on Linux with libvirt (virsh)."
        print_info "Built artifact: $artifact"
        print_info "To import later on a Linux host, copy the artifact and run: dcvm import-image $VM_NAME --image <path>"
      fi
      ;;
  esac
}

main "$@"
