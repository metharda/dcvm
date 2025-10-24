#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

load_dcvm_config
check_dependencies packer

show_usage() {
  cat <<'EOF'
Packer entegrasyonu
Kullanım:
  dcvm packer build <vm_name> --template <path> [opsiyonlar]
  dcvm packer validate --template <path> [opsiyonlar]
  dcvm packer init --template <path>
  dcvm packer inspect --template <path>

Build opsiyonları:
  --template <path>          Zorunlu. Packer HCL dosyası (örn: build.ubuntu-22_04.pkr.hcl)
  --only <target>            Sadece belirtilen builder'ı çalıştır (örn: qemu.ubuntu-22_04)
  --var-file <file>          Var dosyası ekle (çoklu kullanılabilir)
  --var key=value            Var ekle (çoklu kullanılabilir)
  --artifact <path>          Çıktı imaj yolunu elle belirt (qcow2/raw[.gz])
  --os-variant <name>        libosinfo varyantı (örn: ubuntu22.04)
  -m, --memory <MB>          VM RAM (varsayılan: 4096)
  -c, --cpus <N>             VM CPU (varsayılan: 4)
  --attach-cidata            Boş bir cloud-init ISO ekle
  -h, --help                 Yardım

Notlar:
  - build komutu packer çıktısını tamamladıktan sonra üretilen qcow2/raw imajını otomatik bulup
    'dcvm import-image' ile belirtilen <vm_name> adına içe aktarır.
  - Otomatik tespit başarısız olursa --artifact ile dosya yolunu verin.
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
      echo "Bilinmeyen alt komut: $CMD"; show_usage; exit 1 ;;
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
      *) echo "Bilinmeyen seçenek: $1"; show_usage; exit 1 ;;
    esac
  done

  if [[ "$CMD" != "help" && "$CMD" != "-h" && "$CMD" != "--help" ]]; then
    [[ -z "$TEMPLATE_PATH" ]] && { echo "--template gerekli"; show_usage; exit 1; }
    [[ ! -f "$TEMPLATE_PATH" ]] && { print_error "Template bulunamadı: $TEMPLATE_PATH"; exit 1; }
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
      for kv in "${VAR_KVS[@]}"; do args+=("-var" "$kv"); endone=false; done
      # Not: yukarıdaki endone sadece shellcheck uyarısını bastırmak için; etkisi yok.
      ( cd "$tpl_dir" && "${base[@]}" "${args[@]}" "$tpl_file" )
      ;;
    validate|inspect|init)
      local -a args=()
      [[ "$subcmd" == "validate" || "$subcmd" == "inspect" ]] && {
        for vf in "${VAR_FILES[@]}"; do args+=("-var-file" "$vf"); done
        for kv in "${VAR_KVS[@]}"; do args+=("-var" "$kv"); done
      }
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
  end

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

  print_info "İmaj içe aktarılıyor: $artifact (fmt=$fmt)"
  "$SCRIPT_DIR/import-image.sh" "$vm" --image "$artifact" --format "$fmt" -m "$MEMORY" -c "$CPUS" ${extra[@]+${extra[@]}}
}

main() {
  parse_args "$@"

  case "$CMD" in
    help|-h|--help)
      show_usage; exit 0 ;;
    validate|inspect|init)
      run_packer "$CMD"; exit 0 ;;
    build)
      require_root
      check_dependencies virsh qemu-img
      local stamp
      stamp=$(mktemp)
      touch "$stamp"
      run_packer build
      local artifact
      if ! artifact=$(find_artifact "$stamp"); then
        print_warning "Packer çıktısından imaj tespit edilemedi. Lütfen --artifact ile dosya yolunu belirtin."
        rm -f "$stamp" || true
        exit 1
      fi
      rm -f "$stamp" || true
      auto_import "$VM_NAME" "$artifact"
      ;;
  esac
}

main "$@"
