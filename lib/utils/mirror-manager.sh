#!/usr/bin/env bash

MIRROR_debian_12="
https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2
https://cdimage.debian.org/cdimage/cloud/bookworm/latest/debian-12-generic-amd64.qcow2
https://mirrors.kernel.org/debian-cdimage/cloud/bookworm/latest/debian-12-generic-amd64.qcow2
https://mirror.rackspace.com/debian-cdimage/cloud/bookworm/latest/debian-12-generic-amd64.qcow2
https://mirror.leaseweb.net/debian-cdimage/cloud/bookworm/latest/debian-12-generic-amd64.qcow2
"

MIRROR_debian_12_arm64="
https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-arm64.qcow2
https://cdimage.debian.org/cdimage/cloud/bookworm/latest/debian-12-generic-arm64.qcow2
https://mirrors.kernel.org/debian-cdimage/cloud/bookworm/latest/debian-12-generic-arm64.qcow2
https://mirror.rackspace.com/debian-cdimage/cloud/bookworm/latest/debian-12-generic-arm64.qcow2
https://mirror.leaseweb.net/debian-cdimage/cloud/bookworm/latest/debian-12-generic-arm64.qcow2
"

MIRROR_debian_11="
https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2
https://cdimage.debian.org/cdimage/cloud/bullseye/latest/debian-11-generic-amd64.qcow2
https://mirrors.kernel.org/debian-cdimage/cloud/bullseye/latest/debian-11-generic-amd64.qcow2
https://mirror.rackspace.com/debian-cdimage/cloud/bullseye/latest/debian-11-generic-amd64.qcow2
https://mirror.leaseweb.net/debian-cdimage/cloud/bullseye/latest/debian-11-generic-amd64.qcow2
"

MIRROR_debian_11_arm64="
https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-arm64.qcow2
https://cdimage.debian.org/cdimage/cloud/bullseye/latest/debian-11-generic-arm64.qcow2
https://mirrors.kernel.org/debian-cdimage/cloud/bullseye/latest/debian-11-generic-arm64.qcow2
https://mirror.rackspace.com/debian-cdimage/cloud/bullseye/latest/debian-11-generic-arm64.qcow2
https://mirror.leaseweb.net/debian-cdimage/cloud/bullseye/latest/debian-11-generic-arm64.qcow2
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

MIRROR_ubuntu_2204_arm64="
https://cloud-images.ubuntu.com/releases/jammy/release/ubuntu-22.04-server-cloudimg-arm64.img
https://mirror.rackspace.com/ubuntu-cloud-images/releases/jammy/release/ubuntu-22.04-server-cloudimg-arm64.img
https://mirror.leaseweb.net/ubuntu-cloud-images/releases/jammy/release/ubuntu-22.04-server-cloudimg-arm64.img
https://mirrors.edge.kernel.org/ubuntu/cloud-images/releases/jammy/release/ubuntu-22.04-server-cloudimg-arm64.img
https://mirror.hetzner.de/ubuntu/cloud-images/releases/jammy/release/ubuntu-22.04-server-cloudimg-arm64.img
https://mirror.sjc01.us.leaseweb.net/ubuntu-cloud-images/releases/jammy/release/ubuntu-22.04-server-cloudimg-arm64.img
https://mirror.frankfurt.linode.com/ubuntu/cloud-images/releases/jammy/release/ubuntu-22.04-server-cloudimg-arm64.img
"
MIRROR_ubuntu_2004="
https://cloud-images.ubuntu.com/releases/focal/release/ubuntu-20.04-server-cloudimg-amd64.img
https://releases.ubuntu.com/focal/ubuntu-20.04-server-cloudimg-amd64.img
https://mirrors.edge.kernel.org/ubuntu/cloud-images/releases/focal/release/ubuntu-20.04-server-cloudimg-amd64.img
https://mirror.hetzner.de/ubuntu/cloud-images/releases/focal/release/ubuntu-20.04-server-cloudimg-amd64.img
https://mirror.frankfurt.linode.com/ubuntu/cloud-images/releases/focal/release/ubuntu-20.04-server-cloudimg-amd64.img
"

MIRROR_ubuntu_2004_arm64="
https://cloud-images.ubuntu.com/releases/focal/release/ubuntu-20.04-server-cloudimg-arm64.img
https://mirrors.edge.kernel.org/ubuntu/cloud-images/releases/focal/release/ubuntu-20.04-server-cloudimg-arm64.img
https://mirror.hetzner.de/ubuntu/cloud-images/releases/focal/release/ubuntu-20.04-server-cloudimg-arm64.img
https://mirror.frankfurt.linode.com/ubuntu/cloud-images/releases/focal/release/ubuntu-20.04-server-cloudimg-arm64.img
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
SUPPORTED_IMAGES="debian-12-generic-amd64.qcow2 debian-12-generic-arm64.qcow2 debian-11-generic-amd64.qcow2 debian-11-generic-arm64.qcow2 ubuntu-22.04-server-cloudimg-amd64.img ubuntu-22.04-server-cloudimg-arm64.img ubuntu-20.04-server-cloudimg-amd64.img ubuntu-20.04-server-cloudimg-arm64.img Arch-Linux-x86_64-cloudimg.qcow2"

get_mirror_varname() {
  local filename="$1"
  case "$filename" in
  debian-12-generic-amd64.qcow2) echo "MIRROR_debian_12" ;;
  debian-12-generic-arm64.qcow2) echo "MIRROR_debian_12_arm64" ;;
  debian-11-generic-amd64.qcow2) echo "MIRROR_debian_11" ;;
  debian-11-generic-arm64.qcow2) echo "MIRROR_debian_11_arm64" ;;
  ubuntu-22.04-server-cloudimg-amd64.img) echo "MIRROR_ubuntu_2204" ;;
  ubuntu-22.04-server-cloudimg-arm64.img) echo "MIRROR_ubuntu_2204_arm64" ;;
  ubuntu-20.04-server-cloudimg-amd64.img) echo "MIRROR_ubuntu_2004" ;;
  ubuntu-20.04-server-cloudimg-arm64.img) echo "MIRROR_ubuntu_2004_arm64" ;;
  Arch-Linux-x86_64-cloudimg.qcow2) echo "MIRROR_arch" ;;
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
  result=$(curl -sS -o /dev/null -w '%{http_code} %{time_total} %{speed_download}' \
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
        mv "$tmp_file" "$target_path"
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
        mv "$tmp_file" "$target_path"
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

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
  list)
    list_mirrors "${2:-}"
    ;;
  check)
    if [ -z "${2:-}" ]; then
      echo "ERROR: filename required. Usage: $0 check <filename>"
      echo ""
      list_mirrors ""
      exit 1
    fi
    check_mirrors "$2"
    ;;
  best)
    if [ -z "${2:-}" ]; then
      echo "ERROR: filename required. Usage: $0 best <filename>"
      echo ""
      list_mirrors ""
      exit 1
    fi
    select_best_mirror "$2"
    ;;
  download)
    if [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
      echo "ERROR: filename and target required. Usage: $0 download <filename> <target> [min_size]"
      echo ""
      list_mirrors ""
      exit 1
    fi
    download_with_mirrors "$2" "$3" "${4:-}"
    ;;
  *)
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  list [filename]                         - List available images or mirrors for an image"
    echo "  check <filename>                        - Check mirror availability for an image"
    echo "  best <filename>                         - Find fastest mirror for an image"
    echo "  download <filename> <target> [min_size] - Download image with mirror fallback"
    echo ""
    echo "Available images:"
    for img in $SUPPORTED_IMAGES; do
      echo "  $img"
    done
    ;;
  esac
fi
