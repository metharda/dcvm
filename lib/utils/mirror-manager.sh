#!/usr/bin/env bash

MIRROR_debian_13="
https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2
https://cdimage.debian.org/cdimage/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2
https://mirrors.kernel.org/debian-cdimage/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2
https://mirror.rackspace.com/debian-cdimage/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2
https://mirror.leaseweb.net/debian-cdimage/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2
"

MIRROR_debian_12="
https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2
https://cdimage.debian.org/cdimage/cloud/bookworm/latest/debian-12-generic-amd64.qcow2
https://mirrors.kernel.org/debian-cdimage/cloud/bookworm/latest/debian-12-generic-amd64.qcow2
https://mirror.rackspace.com/debian-cdimage/cloud/bookworm/latest/debian-12-generic-amd64.qcow2
https://mirror.leaseweb.net/debian-cdimage/cloud/bookworm/latest/debian-12-generic-amd64.qcow2
"

MIRROR_debian_11="
https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2
https://cdimage.debian.org/cdimage/cloud/bullseye/latest/debian-11-generic-amd64.qcow2
https://mirrors.kernel.org/debian-cdimage/cloud/bullseye/latest/debian-11-generic-amd64.qcow2
https://mirror.rackspace.com/debian-cdimage/cloud/bullseye/latest/debian-11-generic-amd64.qcow2
https://mirror.leaseweb.net/debian-cdimage/cloud/bullseye/latest/debian-11-generic-amd64.qcow2
"

MIRROR_ubuntu_2404="
https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img
https://mirror.rackspace.com/ubuntu-cloud-images/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img
https://mirror.leaseweb.net/ubuntu-cloud-images/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img
https://mirrors.edge.kernel.org/ubuntu/cloud-images/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img
https://mirror.hetzner.de/ubuntu/cloud-images/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img
"

MIRROR_ubuntu_2204="
https://cloud-images.ubuntu.com/releases/jammy/release/ubuntu-22.04-server-cloudimg-amd64.img
https://releases.ubuntu.com/jammy/ubuntu-22.04-server-cloudimg-amd64.img
https://mirror.rackspace.com/ubuntu-cloud-images/releases/jammy/release/ubuntu-22.04-server-cloudimg-amd64.img
https://mirror.leaseweb.net/ubuntu-cloud-images/releases/jammy/release/ubuntu-22.04-server-cloudimg-amd64.img
https://mirrors.edge.kernel.org/ubuntu/cloud-images/releases/jammy/release/ubuntu-22.04-server-cloudimg-amd64.img
https://mirror.hetzner.de/ubuntu/cloud-images/releases/jammy/release/ubuntu-22.04-server-cloudimg-amd64.img
https://mirror.sjc01.us.leaseweb.net/ubuntu-cloud-images/releases/jammy/release/ubuntu-22.04-server-cloudimg-amd64.img
https://mirror.frankfurt.linode.com/ubuntu/cloud-images/releases/jammy/release/ubuntu-22.04-server-cloudimg-amd64.img
"

MIRROR_ubuntu_2004="
https://cloud-images.ubuntu.com/releases/focal/release/ubuntu-20.04-server-cloudimg-amd64.img
https://releases.ubuntu.com/focal/ubuntu-20.04-server-cloudimg-amd64.img
https://mirrors.edge.kernel.org/ubuntu/cloud-images/releases/focal/release/ubuntu-20.04-server-cloudimg-amd64.img
https://mirror.hetzner.de/ubuntu/cloud-images/releases/focal/release/ubuntu-20.04-server-cloudimg-amd64.img
https://mirror.frankfurt.linode.com/ubuntu/cloud-images/releases/focal/release/ubuntu-20.04-server-cloudimg-amd64.img
"

MIRROR_arch="
https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
https://mirror.rackspace.com/archlinux/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
https://mirrors.kernel.org/archlinux/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
https://mirror.leaseweb.net/archlinux/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
https://mirror.alpix.eu/archlinux/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
https://mirror.netcologne.de/archlinux/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
https://cloud-images.archlinux.org/Arch-Linux-x86_64-cloudimg.qcow2
https://mirror.archlinux.org/archlinux/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
https://mirrors.ocf.berkeley.edu/archlinux/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
https://mirror.hetzner.de/archlinux/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
https://mirror.sjc01.us.leaseweb.net/archlinux/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
https://mirror.frankfurt.linode.com/archlinux/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
https://mirror.digitalocean.com/archlinux/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
https://mirrors.tuna.tsinghua.edu.cn/archlinux/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
"

KALI_VERSION="2025.4" #update kali version when a new update.
MIRROR_kali="
https://kali.download/cloud-images/current/kali-linux-${KALI_VERSION}-cloud-genericcloud-amd64.tar.xz
https://cdimage.kali.org/cloud-images/current/kali-linux-${KALI_VERSION}-cloud-genericcloud-amd64.tar.xz
"
SUPPORTED_IMAGES="debian-13-genericcloud-amd64.qcow2 debian-12-generic-amd64.qcow2 debian-11-generic-amd64.qcow2 ubuntu-24.04-server-cloudimg-amd64.img ubuntu-22.04-server-cloudimg-amd64.img ubuntu-20.04-server-cloudimg-amd64.img Arch-Linux-x86_64-cloudimg.qcow2 kali-linux-cloud-genericcloud-amd64.qcow2"

get_mirror_varname() {
  local filename="$1"
  case "$filename" in
  debian-13-genericcloud-amd64.qcow2) echo "MIRROR_debian_13" ;;
  debian-12-generic-amd64.qcow2) echo "MIRROR_debian_12" ;;
  debian-11-generic-amd64.qcow2) echo "MIRROR_debian_11" ;;
  ubuntu-24.04-server-cloudimg-amd64.img) echo "MIRROR_ubuntu_2404" ;;
  ubuntu-22.04-server-cloudimg-amd64.img) echo "MIRROR_ubuntu_2204" ;;
  ubuntu-20.04-server-cloudimg-amd64.img) echo "MIRROR_ubuntu_2004" ;;
  Arch-Linux-x86_64-cloudimg.qcow2) echo "MIRROR_arch" ;;
  kali-linux-cloud-genericcloud-amd64.qcow2) echo "MIRROR_kali" ;;
  *) echo "" ;;
  esac
}

get_mirrors() {
  local filename="${1:-}"
  if [ -z "$filename" ]; then
    return 1
  fi
  local varname
  varname=$(get_mirror_varname "$filename")

  if [ -z "$varname" ]; then
    return 1
  fi
  local mirrors="${!varname:-}"

  if [ -z "$mirrors" ]; then
    return 1
  fi
  echo "$mirrors" | grep -v '^$' | sed 's/^[[:space:]]*//'
}

test_url() {
  local url="$1"
  local timeout="${2:-10}"

  if command -v curl >/dev/null 2>&1; then
    local err
    err=$(curl -sS -o /dev/null --connect-timeout "$timeout" --max-time "$timeout" -I "$url" 2>&1)
    local status=$?
    if [ $status -ne 0 ]; then
      echo "Error: curl failed to access $url: $err" >&2
    fi
    return $status
  elif command -v wget >/dev/null 2>&1; then
    local err
    err=$(wget --spider --timeout="$timeout" -q "$url" 2>&1)
    local status=$?
    if [ $status -ne 0 ]; then
      echo "Error: wget failed to access $url: $err" >&2
    fi
    return $status
  fi
  return 1
}

check_mirrors() {
  local filename="${1:-}"

  if [ -z "$filename" ]; then
    echo "ERROR: filename required. Usage: $0 check <filename>"
    echo "Available images:"
    for img in $SUPPORTED_IMAGES; do
      echo "  $img"
    done
    return 1
  fi

  local mirrors
  mirrors=$(get_mirrors "$filename")
  if [ -z "$mirrors" ]; then
    echo "Unknown image: $filename"
    return 1
  fi

  echo "Checking mirrors for $filename (parallel speed test)..."

  local tmp_dir
  tmp_dir=$(mktemp -d)
  local pids=()
  local idx=0

  while IFS= read -r url; do
    [ -z "$url" ] && continue
    test_mirror_speed "$url" "$tmp_dir" "$idx" &
    pids+=($!)
    idx=$((idx + 1))
  done <<<"$mirrors"

  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  local count_ok=0
  local count_fail=0

  echo ""
  echo "Results (sorted by speed):"

  for f in "$tmp_dir"/result_*; do
    [ -f "$f" ] || continue
    cat "$f"
  done | sort -t' ' -k3 -rn | while read -r line; do
    local r_speed r_time r_url
    r_time=$(awk '{print $2}' <<<"$line")
    r_speed=$(awk '{print $3}' <<<"$line")
    r_url=$(awk '{$1=$2=$3=""; print $0}' <<<"$line" | sed 's/^[[:space:]]*//')
    printf "  [OK] %-65s %6.2f MB/s  (latency: %ss)\n" "$r_url" "$r_speed" "$r_time"
  done

  local total_mirrors
  total_mirrors=$(echo "$mirrors" | grep -c .)
  local ok_count
  ok_count=$(ls -1 "$tmp_dir"/result_* 2>/dev/null | wc -l)
  local fail_count=$((total_mirrors - ok_count))

  if [ "$fail_count" -gt 0 ]; then
    echo ""
    echo "  $fail_count mirror(s) failed or timed out"
  fi

  rm -rf "$tmp_dir"
  echo ""
  echo "Summary: $ok_count/$total_mirrors mirrors OK"
}

ensure_aria2c() {
  if command -v aria2c >/dev/null 2>&1; then
    return 0
  fi
  echo "NOTICE: aria2c not found. aria2c enables faster parallel downloads." >&2
  if [[ "${DCVM_AUTO_INSTALL_ARIA2:-false}" == "true" ]] && [[ $(id -u) -eq 0 ]]; then
    echo "INFO: Attempting to install aria2c automatically (DCVM_AUTO_INSTALL_ARIA2=true)" >&2
    if command -v apt-get >/dev/null 2>&1; then
      if apt-get update -y && apt-get install -y aria2; then
        return 0
      else
        return 1
      fi
    elif command -v yum >/dev/null 2>&1; then
      if yum install -y aria2; then
        return 0
      else
        return 1
      fi
    elif command -v pacman >/dev/null 2>&1; then
      if pacman -Sy --noconfirm aria2; then
        return 0
      else
        return 1
      fi
    else
      echo "No supported package manager found to install aria2c automatically." >&2
      return 1
    fi
  fi
  echo "Hint: install aria2 (e.g. 'sudo apt-get install aria2') for faster downloads." >&2
  return 1
}

test_mirror_speed() {
  local url="$1"
  local tmp_dir="$2"
  local idx="$3"
  local result
  result=$(curl -sS -L --max-redirs 3 -o /dev/null -w '%{http_code} %{time_total} %{speed_download}' \
    --connect-timeout 3 --max-time 5 -r 0-1048575 "$url" 2>/dev/null) || return 1
  local http_code time_s speed_bps
  http_code=$(awk '{print $1}' <<<"$result")
  time_s=$(awk '{print $2}' <<<"$result")
  speed_bps=$(awk '{print $3}' <<<"$result")
  case "$http_code" in
  2* | 416) ;;
  *) return 1 ;;
  esac
  local speed_mbs
  speed_mbs=$(awk "BEGIN{printf \"%.2f\", $speed_bps/1048576}")
  echo "$idx $time_s $speed_mbs $url" >"$tmp_dir/result_$idx"
}
export -f test_mirror_speed

select_best_mirror() {
  local filename="${1:-}"

  if [ -z "$filename" ]; then
    echo "ERROR: filename required" >&2
    return 1
  fi

  local mirrors
  mirrors=$(get_mirrors "$filename") || {
    echo "ERROR: No mirrors for $filename" >&2
    return 1
  }

  echo "Testing mirrors (parallel)..." >&2

  local tmp_dir
  tmp_dir=$(mktemp -d)
  local pids=()
  local idx=0

  while IFS= read -r url; do
    [ -z "$url" ] && continue
    (
      result=$(curl -4 --http1.1 -sSL -o /dev/null -w '%{http_code} %{time_total} %{speed_download}' \
        --connect-timeout 5 --max-time 10 -r 0-1048575 "$url" 2>/dev/null) || exit 1
      http_code=$(awk '{print $1}' <<<"$result")
      time_s=$(awk '{print $2}' <<<"$result")
      speed_bps=$(awk '{print $3}' <<<"$result")
      case "$http_code" in
      2* | 416) ;;
      *) exit 1 ;;
      esac
      speed_mbs=$(awk "BEGIN{printf \"%.2f\", $speed_bps/1048576}")
      echo "$idx $time_s $speed_mbs $url" >"$tmp_dir/result_$idx"
    ) &
    pids+=($!)
    idx=$((idx + 1))
  done <<<"$mirrors"

  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  local best_url=""
  local best_speed=0
  local best_latency=9999

  for f in "$tmp_dir"/result_*; do
    [ -f "$f" ] || continue
    local line
    line=$(cat "$f")
    local r_idx r_time r_speed r_url
    r_idx=$(awk '{print $1}' <<<"$line")
    r_time=$(awk '{print $2}' <<<"$line")
    r_speed=$(awk '{print $3}' <<<"$line")
    r_url=$(awk '{$1=$2=$3=""; print $0}' <<<"$line" | sed 's/^[[:space:]]*//')

    printf "  Mirror: %s -> %.2f MB/s (latency: %ss)\n" "$r_url" "$r_speed" "$r_time" >&2
    if awk -v s="$r_speed" -v bs="$best_speed" 'BEGIN{exit !(s>bs)}'; then
      best_speed="$r_speed"
      best_latency="$r_time"
      best_url="$r_url"
    elif awk -v s="$r_speed" -v bs="$best_speed" -v t="$r_time" -v bt="$best_latency" 'BEGIN{exit !(s==bs && t<bt)}'; then
      best_latency="$r_time"
      best_url="$r_url"
    fi
  done

  rm -rf "$tmp_dir"

  if [ -n "$best_url" ]; then
    printf "\n★ Best mirror: %s (%.2f MB/s, latency: %ss)\n" "$best_url" "$best_speed" "$best_latency" >&2
    echo "$best_url"
    return 0
  fi
  echo "ERROR: No working mirrors found" >&2
  return 1
}


download_with_mirrors() {
  local filename="${1:-}"
  local target_path="${2:-}"
  local min_size="${3:-104857600}"
  local expected_sha256="${4:-}"

  if [ -z "$filename" ]; then
    echo "ERROR: filename required" >&2
    return 1
  fi

  if [ -z "$target_path" ]; then
    echo "ERROR: target_path required" >&2
    return 1
  fi

  local mirrors
  mirrors=$(get_mirrors "$filename")
  if [ -z "$mirrors" ]; then
    echo "ERROR: No mirrors configured for $filename" >&2
    return 1
  fi

  mkdir -p "$(dirname "$target_path")" 2>/dev/null
  local tmp_file="${target_path}.tmp.$$"
  echo "INFO: Finding best mirror for $filename..." >&2
  local best
  best=$(select_best_mirror "$filename") || best=""

  local url_list=()
  if [ -n "$best" ]; then
    url_list+=("$best")
  fi
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    [ "$url" = "$best" ] && continue
    url_list+=("$url")
  done <<<"$mirrors"

  if command -v aria2c >/dev/null 2>&1 && [ -n "$best" ]; then
    echo "INFO: Using aria2c with best mirror for fast download" >&2
    echo "INFO: Downloading from: $best" >&2
    local ARIA2_CONN=${DCVM_ARIA2_CONN:-16}
    local ARIA2_SPLIT=${DCVM_ARIA2_SPLIT:-16}
    local ARIA2_MIN_SPLIT_SIZE=${DCVM_ARIA2_MIN_SPLIT_SIZE:-1M}

    local aria_args=(-c -x "$ARIA2_CONN" -s "$ARIA2_SPLIT" -k "$ARIA2_MIN_SPLIT_SIZE" --allow-overwrite=true --auto-file-renaming=false --summary-interval=1 --dir="$(dirname "$tmp_file")" --out="$(basename "$tmp_file")")
    local start_time end_time elapsed_time
    start_time=$(date +%s)
    aria2c "${aria_args[@]}" "$best"
    local rc=$?
    end_time=$(date +%s)
    elapsed_time=$((end_time - start_time))

    if [ "$rc" -eq 0 ]; then
      local file_size
      file_size=$(stat -c%s "$tmp_file" 2>/dev/null || echo 0)
      if [ "$file_size" -ge "$min_size" ]; then
        if [ -n "$expected_sha256" ]; then
          local actual_sha256=""
          if command -v sha256sum >/dev/null 2>&1; then
            actual_sha256=$(sha256sum "$tmp_file" | awk '{print $1}')
          elif command -v shasum >/dev/null 2>&1; then
            actual_sha256=$(shasum -a 256 "$tmp_file" | awk '{print $1}')
          fi
          if [ -n "$actual_sha256" ] && [ "$actual_sha256" != "$expected_sha256" ]; then
            echo "WARNING: Checksum mismatch (expected $expected_sha256, got $actual_sha256)" >&2
            rm -f "$tmp_file" 2>/dev/null
            rc=2
          fi
        fi
      else
        echo "WARNING: aria2c produced small file (${file_size} bytes)" >&2
        rm -f "$tmp_file" 2>/dev/null
        rc=3
      fi
      if [ "$rc" -eq 0 ]; then
        if is_kali_image "$filename"; then
          if ! extract_kali_image "$tmp_file" "$target_path"; then
            rm -f "$tmp_file" 2>/dev/null
            echo "WARNING: Kali image extraction failed, trying next mirror" >&2
            rc=4
          else
            rm -f "$tmp_file" 2>/dev/null
          fi
        else
          mv "$tmp_file" "$target_path"
        fi
      fi
      if [ "$rc" -eq 0 ]; then
        local avg_speed_mbs
        if [ "$elapsed_time" -gt 0 ]; then
          avg_speed_mbs=$(awk "BEGIN{printf \"%.2f\", $file_size/1048576/$elapsed_time}")
        else
          avg_speed_mbs="N/A"
        fi
        local size_mb
        size_mb=$(awk "BEGIN{printf \"%.1f\", $file_size/1048576}")
        echo "SUCCESS: Downloaded ${size_mb}MB in ${elapsed_time}s (avg: ${avg_speed_mbs} MB/s) via aria2c" >&2
        echo "${url_list[0]}"
        return 0
      fi
    else
      echo "WARNING: aria2c download failed (rc=$rc)" >&2
      rm -f "$tmp_file" 2>/dev/null
    fi
  fi

  for url in "${url_list[@]}"; do
    echo "INFO: Trying mirror: $url" >&2
    local rc=1
    local start_time end_time
    start_time=$(date +%s)
    if command -v curl >/dev/null 2>&1; then
      curl -4 --http1.1 -L --fail --progress-bar -o "$tmp_file" "$url"
      rc=$?
    else
      wget --progress=bar:force -O "$tmp_file" "$url"
      rc=$?
    fi
    end_time=$(date +%s)
    local elapsed_time=$((end_time - start_time))

    if [ "$rc" -eq 0 ]; then
      local file_size
      file_size=$(stat -c%s "$tmp_file" 2>/dev/null || echo 0)
      if [ "$file_size" -ge "$min_size" ]; then
        if [ -n "$expected_sha256" ]; then
          local actual_sha256=""
          if command -v sha256sum >/dev/null 2>&1; then
            actual_sha256=$(sha256sum "$tmp_file" | awk '{print $1}')
          elif command -v shasum >/dev/null 2>&1; then
            actual_sha256=$(shasum -a 256 "$tmp_file" | awk '{print $1}')
          fi
          if [ -n "$actual_sha256" ] && [ "$actual_sha256" != "$expected_sha256" ]; then
            echo "WARNING: Checksum mismatch (expected $expected_sha256, got $actual_sha256)" >&2
            rm -f "$tmp_file" 2>/dev/null
            continue
          fi
        fi
        if is_kali_image "$filename"; then
          if ! extract_kali_image "$tmp_file" "$target_path"; then
            rm -f "$tmp_file" 2>/dev/null
            echo "WARNING: Kali image extraction failed, trying next mirror" >&2
            continue
          fi
          rm -f "$tmp_file" 2>/dev/null
        else
          mv "$tmp_file" "$target_path"
        fi
        local avg_speed_mbs size_mb
        if [ "$elapsed_time" -gt 0 ]; then
          avg_speed_mbs=$(awk "BEGIN{printf \"%.2f\", $file_size/1048576/$elapsed_time}")
        else
          avg_speed_mbs="N/A"
        fi
        size_mb=$(awk "BEGIN{printf \"%.1f\", $file_size/1048576}")
        echo "SUCCESS: Downloaded ${size_mb}MB in ${elapsed_time}s (avg: ${avg_speed_mbs} MB/s) from $url" >&2
        echo "$url"
        return 0
      else
        echo "WARNING: File too small (${file_size} bytes) from $url" >&2
        rm -f "$tmp_file" 2>/dev/null
      fi
    else
      echo "WARNING: Download failed from $url" >&2
      rm -f "$tmp_file" 2>/dev/null
    fi
  done

  rm -f "$tmp_file" 2>/dev/null
  echo "ERROR: All mirrors failed for $filename" >&2
  return 1
}

list_mirrors() {
  local filename="${1:-}"
  if [ -z "$filename" ]; then
    echo "Available images:"
    for img in $SUPPORTED_IMAGES; do
      echo "  $img"
    done
    return 0
  fi

  local mirrors
  mirrors=$(get_mirrors "$filename")
  if [ -z "$mirrors" ]; then
    echo "No mirrors found for: $filename"
    return 1
  fi

  echo "Mirrors for $filename:"
  local i=1
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    echo "  $i) $url"
    i=$((i + 1))
  done <<<"$mirrors"
}

is_kali_image() {
  local filename="$1"
  [[ "$filename" == "kali-linux-cloud-genericcloud-amd64.qcow2" ]]
}

extract_kali_image() {
  local tarxz_path="$1"
  local target_qcow2="$2"
  local extract_dir=""
  
  cleanup_extract() {
    [ -n "$extract_dir" ] && [ -d "$extract_dir" ] && rm -rf "$extract_dir" 2>/dev/null
  }
  trap cleanup_extract EXIT

  echo "INFO: Extracting Kali Linux image from tar.xz archive..." >&2

  if ! command -v tar >/dev/null 2>&1; then
    echo "ERROR: 'tar' command required to extract Kali image" >&2
    return 1
  fi

  if ! command -v xz >/dev/null 2>&1; then
    echo "ERROR: 'xz' command required to extract Kali image. Install xz-utils." >&2
    return 1
  fi

  if ! command -v qemu-img >/dev/null 2>&1; then
    echo "ERROR: 'qemu-img' command required to convert Kali image" >&2
    return 1
  fi

  extract_dir=$(mktemp -d 2>/dev/null)
  if [ -z "$extract_dir" ] || [ ! -d "$extract_dir" ]; then
    echo "ERROR: Failed to create temporary directory for extraction" >&2
    return 1
  fi

  if ! tar -xJf "$tarxz_path" -C "$extract_dir"; then
    echo "ERROR: Failed to extract tar.xz archive" >&2
    return 1
  fi

  local raw_file
  raw_file=$(find "$extract_dir" -name "*.raw" -type f | head -1)
  if [ -z "$raw_file" ]; then
    raw_file=$(find "$extract_dir" -name "disk*" -type f | head -1)
  fi

  if [ -z "$raw_file" ]; then
    echo "ERROR: No raw disk image found in tar.xz archive" >&2
    echo "Archive contents:" >&2
    find "$extract_dir" -type f >&2
    return 1
  fi

  echo "INFO: Found raw image: $(basename "$raw_file")" >&2
  local raw_size
  raw_size=$(du -h "$raw_file" 2>/dev/null | cut -f1)
  echo "INFO: Raw image size: $raw_size (this will be compressed)" >&2
  echo "INFO: Converting raw image to qcow2 format (this may take a few minutes)..." >&2
  if ! qemu-img convert -f raw -O qcow2 -c -p "$raw_file" "$target_qcow2"; then
    echo "ERROR: Failed to convert raw image to qcow2" >&2
    rm -f "$target_qcow2" 2>/dev/null
    return 1
  fi

  trap - EXIT
  cleanup_extract

  local final_size
  final_size=$(du -h "$target_qcow2" 2>/dev/null | cut -f1)
  echo "SUCCESS: Kali Linux image converted to qcow2 (${raw_size} -> ${final_size})" >&2
  return 0
}

main() {
  if [ -f /etc/dcvm-install.conf ]; then
    source /etc/dcvm-install.conf
  fi
  DATACENTER_BASE="${DATACENTER_BASE:-/srv/datacenter}"
  TEMPLATE_DIR="$DATACENTER_BASE/storage/templates"

  case "${1:-}" in
  list)
    list_mirrors "${2:-}"
    ;;
  check)
    local target="${2:-}"
    if [ "$target" = "-a" ] || [ "$target" = "--all" ]; then
      echo "Checking mirrors for all templates..."
      echo ""
      for img in $SUPPORTED_IMAGES; do
        echo "=== $img ==="
        check_mirrors "$img"
        echo ""
      done
    elif [ -z "$target" ]; then
      echo "ERROR: filename required. Usage: dcvm template check <filename>"
      echo "       dcvm template check -a, --all  (check all templates)"
      echo ""
      list_mirrors ""
      exit 1
    else
      check_mirrors "$target"
    fi
    ;;
  best)
    local target="${2:-}"
    if [ "$target" = "-a" ] || [ "$target" = "--all" ]; then
      echo "Finding best mirrors for all templates..."
      echo ""
      printf "%-50s %s\n" "Template" "Best Mirror"
      printf "%-50s %s\n" "--------" "-----------"
      for img in $SUPPORTED_IMAGES; do
        local best=$(select_best_mirror "$img" 2>/dev/null)
        if [ -n "$best" ]; then
          printf "%-50s %s\n" "$img" "$best"
        else
          printf "%-50s %s\n" "$img" "(no working mirror)"
        fi
      done
    elif [ -z "$target" ]; then
      echo "ERROR: filename required. Usage: dcvm template best <filename>"
      echo "       dcvm template best -a, --all  (find best for all)"
      echo ""
      list_mirrors ""
      exit 1
    else
      select_best_mirror "$target"
    fi
    ;;
  download)
    local target="${2:-}"
    local force="${3:-}"
    
    if [ "$target" = "-a" ] || [ "$target" = "--all" ]; then
      echo "Downloading all templates..."
      echo ""
      local success=0
      local failed=0
      for img in $SUPPORTED_IMAGES; do
        local target_path="$TEMPLATE_DIR/$img"
        if [ -f "$target_path" ] && [ "$force" != "--force" ] && [ "$force" != "-f" ]; then
          echo "✓ $img (already exists)"
          ((success++))
        else
          echo "Downloading: $img"
          if download_with_mirrors "$img" "$target_path" 100000000; then
            echo "✓ $img downloaded"
            ((success++))
          else
            echo "✗ $img FAILED"
            ((failed++))
          fi
        fi
      done
      echo ""
      echo "Summary: $success successful, $failed failed"
      exit 0
    fi
    
    if [ -z "$target" ]; then
      echo "DCVM Template Download"
      echo ""
      echo "Usage: dcvm template download <filename> [--force]"
      echo "       dcvm template download -a, --all [-f]  (download all)"
      echo ""
      echo "Options:"
      echo "  --force, -f    Force redownload even if template exists"
      echo ""
      echo "Available templates:"
      for img in $SUPPORTED_IMAGES; do
        local tpath="$TEMPLATE_DIR/$img"
        if [ -f "$tpath" ]; then
          local size=$(du -h "$tpath" 2>/dev/null | cut -f1)
          echo "  $img  [installed: $size]"
        else
          echo "  $img"
        fi
      done
      exit 0
    fi
    
    local target_path="$TEMPLATE_DIR/$target"
    
    if [ -f "$target_path" ] && [ "$force" != "--force" ] && [ "$force" != "-f" ]; then
      echo "Template already exists: $target_path"
      echo "Use --force to redownload: dcvm template download $target --force"
      exit 0
    fi
    
    if [ -f "$target_path" ] && { [ "$force" = "--force" ] || [ "$force" = "-f" ]; }; then
      echo "Removing existing template for redownload..."
      rm -f "$target_path"
    fi
    
    mkdir -p "$TEMPLATE_DIR"
    echo "Downloading template: $target"
    echo "Target: $target_path"
    echo ""
    
    if download_with_mirrors "$target" "$target_path" 100000000; then
      echo ""
      echo "SUCCESS: Template downloaded successfully"
      ls -lh "$target_path"
    else
      echo ""
      echo "FAILED: Could not download template"
      exit 1
    fi
    ;;
  status)
    echo "DCVM Template Status"
    echo ""
    echo "Template directory: $TEMPLATE_DIR"
    echo ""
    if [ -d "$TEMPLATE_DIR" ]; then
      echo "Installed templates:"
      local count=0
      local corrupt=0
      for img in $SUPPORTED_IMAGES; do
        local target="$TEMPLATE_DIR/$img"
        if [ -f "$target" ]; then
          local size=$(du -h "$target" 2>/dev/null | cut -f1)
          local vsize=$(qemu-img info "$target" 2>/dev/null | grep "virtual size" | awk -F': ' '{print $2}' | cut -d' ' -f1-2)
          local integrity="OK"
          if command -v qemu-img >/dev/null 2>&1; then
            if ! qemu-img check "$target" >/dev/null 2>&1; then
              integrity="CORRUPT"
              ((corrupt++))
            fi
          fi
          
          if [ "$integrity" = "OK" ]; then
            echo "  ✓ $img ($size, virtual: ${vsize:-unknown})"
          else
            echo "  ✗ $img ($size) - CORRUPT! Use: dcvm template download $img --force"
          fi
          ((count++))
        fi
      done
      if [ $count -eq 0 ]; then
        echo "  (none)"
      fi
      if [ $corrupt -gt 0 ]; then
        echo ""
        echo "WARNING: $corrupt template(s) are corrupted and should be redownloaded"
      fi
      echo ""
      echo "Available for download:"
      for img in $SUPPORTED_IMAGES; do
        local target="$TEMPLATE_DIR/$img"
        if [ ! -f "$target" ]; then
          echo "  • $img"
        fi
      done
    else
      echo "Template directory does not exist yet."
      echo "Templates will be downloaded on first VM creation."
    fi
    ;;
  verify)
    local target="${2:-}"
    echo "DCVM Template Verification"
    echo ""
    if [ "$target" = "-a" ] || [ "$target" = "--all" ] || [ -z "$target" ]; then
      echo "Verifying all installed templates..."
      echo ""
      local ok=0
      local bad=0
      for img in $SUPPORTED_IMAGES; do
        local tpath="$TEMPLATE_DIR/$img"
        if [ -f "$tpath" ]; then
          printf "  Checking %-50s " "$img"
          if qemu-img check "$tpath" >/dev/null 2>&1; then
            echo "[OK]"
            ((ok++))
          else
            echo "[CORRUPT]"
            ((bad++))
          fi
        fi
      done
      echo ""
      echo "Summary: $ok OK, $bad corrupted"
      [ $bad -gt 0 ] && echo "Redownload corrupted templates with: dcvm template download <name> --force"
    else
      local tpath="$TEMPLATE_DIR/$target"
      if [ ! -f "$tpath" ]; then
        echo "Template not found: $target"
        exit 1
      fi
      echo "Verifying: $target"
      if qemu-img check "$tpath" 2>&1; then
        echo ""
        echo "Template is OK"
      else
        echo ""
        echo "Template is CORRUPTED"
        echo "Redownload with: dcvm template download $target --force"
        exit 1
      fi
    fi
    ;;
  help | --help | -h | "")
    echo "DCVM Template Management"
    echo ""
    echo "Usage: dcvm template <command> [args]"
    echo ""
    echo "Commands:"
    echo "  list [filename]              List available images or mirrors for an image"
    echo "  status                       Show installed templates with integrity check"
    echo "  verify [filename|-a]         Verify template integrity"
    echo "  download <filename> [-f]     Download or redownload a template"
    echo "  download -a [--force]        Download all templates"
    echo "  check <filename>             Check mirror availability for an image"
    echo "  check -a, --all              Check mirrors for all images"
    echo "  best <filename>              Find fastest mirror for an image"
    echo "  best -a, --all               Find best mirrors for all images"
    echo ""
    echo "Available templates:"
    for img in $SUPPORTED_IMAGES; do
      echo "  $img"
    done
    echo ""
    echo "Examples:"
    echo "  dcvm template status"
    echo "  dcvm template verify -a"
    echo "  dcvm template download debian-12-generic-amd64.qcow2"
    echo "  dcvm template download -a --force"
    echo "  dcvm template check -a"
    ;;
  *)
    echo "Unknown command: ${1:-}"
    echo "Use: dcvm template help"
    exit 1
    ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi