#!/usr/bin/env bash

# Mirrors per image, spread over Europe, the Americas and Asia: dcvm
# speed-tests them from wherever it runs and downloads from the fastest, so
# the nearest one wins. Each entry served the same file as the official
# server when checked (2026-11-21; dcvm template check -a shows which still
# answer). Mirrors that lag behind (another file size) are left out, and
# aria2c only combines mirrors serving the same file anyway.
MIRROR_debian_13="
https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2
https://cdimage.debian.org/cdimage/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2
https://ftp.acc.umu.se/cdimage/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2
https://ftp.gwdg.de/pub/debian/debian-cloud-image/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2
https://mirror.nju.edu.cn/debian-cdimage/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2
https://mirrors.cernet.edu.cn/debian-cdimage/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2
"

MIRROR_debian_12="
https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2
https://cdimage.debian.org/cdimage/cloud/bookworm/latest/debian-12-generic-amd64.qcow2
https://ftp.acc.umu.se/cdimage/cloud/bookworm/latest/debian-12-generic-amd64.qcow2
https://ftp.gwdg.de/pub/debian/debian-cloud-image/cloud/bookworm/latest/debian-12-generic-amd64.qcow2
https://mirror.nju.edu.cn/debian-cdimage/cloud/bookworm/latest/debian-12-generic-amd64.qcow2
https://mirrors.cernet.edu.cn/debian-cdimage/cloud/bookworm/latest/debian-12-generic-amd64.qcow2
"

MIRROR_debian_11="
https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2
https://cdimage.debian.org/cdimage/cloud/bullseye/latest/debian-11-generic-amd64.qcow2
https://ftp.acc.umu.se/cdimage/cloud/bullseye/latest/debian-11-generic-amd64.qcow2
https://ftp.gwdg.de/pub/debian/debian-cloud-image/cloud/bullseye/latest/debian-11-generic-amd64.qcow2
https://mirror.nju.edu.cn/debian-cdimage/cloud/bullseye/latest/debian-11-generic-amd64.qcow2
https://mirrors.cernet.edu.cn/debian-cdimage/cloud/bullseye/latest/debian-11-generic-amd64.qcow2
"

MIRROR_ubuntu_2404="
https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img
https://mirror.nju.edu.cn/ubuntu-cloud-images/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img
https://mirror.yandex.ru/ubuntu-cloud-images/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img
"

MIRROR_ubuntu_2204="
https://cloud-images.ubuntu.com/releases/jammy/release/ubuntu-22.04-server-cloudimg-amd64.img
https://mirror.nju.edu.cn/ubuntu-cloud-images/releases/jammy/release/ubuntu-22.04-server-cloudimg-amd64.img
https://mirror.yandex.ru/ubuntu-cloud-images/releases/jammy/release/ubuntu-22.04-server-cloudimg-amd64.img
"

MIRROR_ubuntu_2004="
https://cloud-images.ubuntu.com/releases/focal/release/ubuntu-20.04-server-cloudimg-amd64.img
https://mirror.nju.edu.cn/ubuntu-cloud-images/releases/focal/release/ubuntu-20.04-server-cloudimg-amd64.img
https://mirror.yandex.ru/ubuntu-cloud-images/releases/focal/release/ubuntu-20.04-server-cloudimg-amd64.img
"

MIRROR_arch="
https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
https://mirror.rackspace.com/archlinux/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
https://mirror.leaseweb.net/archlinux/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
https://mirror.netcologne.de/archlinux/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
https://ftp.acc.umu.se/mirror/archlinux/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
https://ftp.gwdg.de/pub/linux/archlinux/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
https://mirrors.ocf.berkeley.edu/archlinux/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
https://plug-mirror.rcac.purdue.edu/archlinux/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
https://mirror.nju.edu.cn/archlinux/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
https://mirrors.ustc.edu.cn/archlinux/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
https://mirrors.tuna.tsinghua.edu.cn/archlinux/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
"

KALI_VERSION="2026.3" # Update when there is a new Kali release
# Only kali.download (a CDN, so served from near each client) carries the
# cloud images; Kali's mirrors have the ISOs only. The release folder keeps
# the URL working after the next release replaces current/.
MIRROR_kali="
https://kali.download/cloud-images/kali-${KALI_VERSION}/kali-linux-${KALI_VERSION}-cloud-genericcloud-amd64.tar.xz
"
SUPPORTED_IMAGES="debian-13-genericcloud-amd64.qcow2 debian-12-generic-amd64.qcow2 debian-11-generic-amd64.qcow2 ubuntu-24.04-server-cloudimg-amd64.img ubuntu-22.04-server-cloudimg-amd64.img ubuntu-20.04-server-cloudimg-amd64.img Arch-Linux-x86_64-cloudimg.qcow2 kali-linux-cloud-genericcloud-amd64.qcow2"

image_label() {
  case "$1" in
  debian-13-*) echo "Debian 13" ;;
  debian-12-*) echo "Debian 12" ;;
  debian-11-*) echo "Debian 11" ;;
  ubuntu-24.04-*) echo "Ubuntu 24.04" ;;
  ubuntu-22.04-*) echo "Ubuntu 22.04" ;;
  ubuntu-20.04-*) echo "Ubuntu 20.04" ;;
  Arch-Linux-*) echo "Arch Linux" ;;
  kali-linux-*) echo "Kali Linux" ;;
  *) echo "$1" ;;
  esac
}

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

# The size (from Content-Range) tells mirrors with another build apart.
test_mirror_speed() {
  local url="$1" tmp_dir="$2" idx="$3" result size
  result=$(curl -4 --http1.1 -sS -L --max-redirs 3 -o /dev/null -D "$tmp_dir/headers_$idx" \
    -w '%{http_code} %{time_total} %{speed_download}' \
    --connect-timeout 5 --max-time 10 -r 0-1048575 "$url" 2>/dev/null) || return 1
  case "${result%% *}" in
  2* | 416) ;;
  *) return 1 ;;
  esac
  size=$(tr -d '\r' <"$tmp_dir/headers_$idx" | awk 'tolower($1) == "content-range:" { n = split($0, a, "/"); s = a[n] } END { print s + 0 }')
  awk -v i="$idx" -v u="$url" -v z="$size" '{ printf "%s %.2f %.2f %s %s\n", i, $2, $3 / 1048576, z, u }' <<<"$result" >"$tmp_dir/result_$idx"
}
export -f test_mirror_speed

rank_mirrors() {
  local filename="${1:-}" mirrors tmp_dir url idx=0 ranked
  if [ -z "$filename" ]; then
    echo "ERROR: filename required" >&2
    return 1
  fi
  mirrors=$(get_mirrors "$filename") || {
    echo "ERROR: No mirrors for $filename" >&2
    return 1
  }
  echo "Testing mirrors (parallel)..." >&2
  tmp_dir=$(mktemp -d)
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    test_mirror_speed "$url" "$tmp_dir" "$idx" &
    idx=$((idx + 1))
  done <<<"$mirrors"
  wait
  ranked=$(cat "$tmp_dir"/result_* 2>/dev/null | sort -k3,3gr -k2,2g)
  rm -rf "$tmp_dir"
  if [ -z "$ranked" ]; then
    echo "ERROR: No working mirrors found" >&2
    return 1
  fi
  awk '{ printf "  Mirror: %s -> %s MB/s (latency: %ss)\n", $5, $3, $2 }' <<<"$ranked" >&2
  awk 'NR == 1 { printf "\n★ Best mirror: %s (%s MB/s, latency: %ss)\n", $5, $3, $2 }' <<<"$ranked" >&2
  awk '{ print $5, $4 }' <<<"$ranked"
}

select_best_mirror() { rank_mirrors "$@" | head -1 | cut -d' ' -f1; }

checksum_for_file() {
  awk -v f="$1" '{ n = $2; sub(/^\*/, "", n); if (n == f) { print tolower($1); exit } }'
}

fetch_text() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 5 --max-time 20 "$1" 2>/dev/null
  else
    wget -q -T 20 -O - "$1" 2>/dev/null
  fi
}

# Checks a downloaded image against the checksums its publisher puts next to
# it: SHA256SUMS or SHA512SUMS in the same folder, or <file>.SHA256. Looks on
# the mirror it came from, then on the other mirrors that serve the same file
# name (most mirrors don't copy the checksum files; the official servers do).
# Returns 0 if a published checksum matches, 1 if checksums were found but
# none matches, 2 if no mirror publishes one.
verify_published_checksum() {
  local filename="$1" url="$2" file="$3"
  local base="${url##*/}" found=false dir sums hash algo
  local -A digest=()
  local dirs
  dirs=$({
    echo "$url"
    get_mirrors "$filename" 2>/dev/null
  } | awk -v b="$base" 'NF { n = $0; sub(/.*\//, "", n); if (n == b) { sub(/\/[^\/]*$/, ""); if (!seen[$0]++) print } }')
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    for sums in SHA256SUMS SHA512SUMS "$base.SHA256"; do
      hash=$(fetch_text "$dir/$sums" | checksum_for_file "$base")
      case ${#hash} in
      64) algo=sha256 ;;
      128) algo=sha512 ;;
      *) continue ;;
      esac
      found=true
      [ -n "${digest[$algo]:-}" ] || digest[$algo]=$("${algo}sum" "$file" | awk '{print $1}')
      if [ "${digest[$algo]}" = "$hash" ]; then
        echo "INFO: $algo checksum verified against $dir/$sums" >&2
        return 0
      fi
    done
  done <<<"$dirs"
  $found && return 1
  return 2
}

check_download() {
  local filename="$1" url="$2" file="$3" expected_sha256="$4" actual rc
  if [ -n "$expected_sha256" ]; then
    actual=$(sha256sum "$file" | awk '{print $1}')
    [ "$actual" = "$expected_sha256" ] && return 0
    echo "WARNING: Checksum mismatch (expected $expected_sha256, got $actual)" >&2
    return 1
  fi
  verify_published_checksum "$filename" "$url" "$file"
  rc=$?
  case $rc in
  0) return 0 ;;
  1)
    echo "WARNING: Download from $url does not match its published checksum" >&2
    return 1
    ;;
  *)
    echo "WARNING: No published checksum found for ${url##*/}; download not verified" >&2
    return 0
    ;;
  esac
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
  local ranked best
  ranked=$(rank_mirrors "$filename") || ranked=""
  best=$(head -1 <<<"$ranked" | cut -d' ' -f1)

  local url_list=()
  while IFS= read -r url; do
    [ -n "$url" ] && url_list+=("$url")
  done < <(printf '%s\n%s\n' "$(cut -d' ' -f1 <<<"$ranked")" "$mirrors" | awk 'NF && !seen[$0]++')

  if command -v aria2c >/dev/null 2>&1 && [ -n "$best" ]; then
    # Only mirrors serving the same file as the fastest one (same name and
    # size): a mirror with an older build would mix two files.
    local -a sources
    mapfile -t sources < <(awk -v b="${best##*/}" -v z="$(head -1 <<<"$ranked" | cut -s -d' ' -f2)" \
      '{ n = $1; sub(/.*\//, "", n) } n == b && $2 == z { print $1 }' <<<"$ranked" | head -n "${DCVM_ARIA2_MIRRORS:-4}")
    echo "INFO: Using aria2c with ${#sources[@]} mirror(s): ${sources[*]}" >&2
    local aria_args=(-c -s "${DCVM_ARIA2_SPLIT:-16}" -x "${DCVM_ARIA2_CONN:-4}" -k "${DCVM_ARIA2_MIN_SPLIT_SIZE:-4M}"
      --file-allocation=none --allow-overwrite=true --auto-file-renaming=false
      --summary-interval=1 --console-log-level=warn --download-result=hide
      --dir="$(dirname "$tmp_file")" --out="$(basename "$tmp_file")")
    local start_time end_time elapsed_time
    start_time=$(date +%s)
    aria2c "${aria_args[@]}" "${sources[@]}"
    local rc=$?
    end_time=$(date +%s)
    elapsed_time=$((end_time - start_time))

    if [ "$rc" -eq 0 ]; then
      local file_size
      file_size=$(stat -c%s "$tmp_file" 2>/dev/null || echo 0)
      if [ "$file_size" -ge "$min_size" ]; then
        if ! check_download "$filename" "$best" "$tmp_file" "$expected_sha256"; then
          rm -f "$tmp_file" 2>/dev/null
          rc=2
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
      curl -4 --http1.1 -L --fail -o "$tmp_file" "$url"
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
        if ! check_download "$filename" "$url" "$tmp_file" "$expected_sha256"; then
          rm -f "$tmp_file" 2>/dev/null
          continue
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

# checksum (Ubuntu keeps release-<date>/ folders, Debian dated folders, Arch
# v<version>/ folders; daily builds are not kept) and prints its URL. Looks
# at the newest 60 folders; fails when the build is not there.
find_archived_build() {
  local img="$1" sha256="$2" sha512="$3" url archive dir sums line name
  valid_image_name "$img" && valid_sha256 "$sha256" || return 1
  valid_sha512 "$sha512" || sha512=""
  url=$(get_mirrors "$img" | head -1)
  case "$url" in
  *kali.download*) return 1 ;; # converted locally: no published checksum of the qcow2
  esac
  archive=${url%/*}
  archive=${archive%/*}
  while IFS= read -r dir; do
    for sums in SHA256SUMS SHA512SUMS $(fetch_text "$archive/$dir/" | grep -oE 'href="[^"]+\.SHA256"' | sed 's/href="//;s/"$//'); do
      line=$(fetch_text "$archive/$dir/$sums" | awk -v a="$sha256" -v b="$sha512" 'tolower($1) == a || (b != "" && tolower($1) == b) { print; exit }')
      [ -n "$line" ] || continue
      name=$(awk '{ print $2 }' <<<"$line")
      echo "$archive/$dir/${name#\*}"
      return 0
    done
  done < <(fetch_text "$archive/" | grep -oE 'href="[A-Za-z-]*[0-9][0-9.-]*/"' | sed 's/href="//;s/\/"$//' | sort -ru | head -60)
  return 1
}

fetch_archived_build() {
  local img="$1" sha256="$2" sha512="$3" url tmp b
  if ! url=$(find_archived_build "$img" "$sha256" "$sha512"); then
    return 1
  fi
  mkdir -p "$(builds_dir)"
  tmp="$(builds_dir)/.fetch.$$"
  if ! ui_run "Fetching base" curl -fsSL -o "$tmp" "$url" || [ "$(sha256sum "$tmp" | cut -d' ' -f1)" != "$sha256" ]; then
    rm -f "$tmp"
    ui_step fail "Base image" "could not fetch the original build from ${url%/*}" >&2
    return 1
  fi
  b=$(register_build "$tmp" "$img")
  rm -f "$tmp"
  ui_step ok "Base image" "fetched the original build from ${url#*://} (${UI_RUN_SECS}s)" >&2
  echo "$b"
}

download_progress() {
  tail -c 4096 "$1" 2>/dev/null | tr '\r' '\n' | awk '
    function bytes(x, n, u) {
      n = x + 0; sub(/i?B$/, "", x); u = substr(x, length(x))
      return int(n * (u == "k" || u == "K" ? 1024 : u == "M" ? 1048576 : u == "G" ? 1073741824 : 1))
    }
    function secs(t, a, n) {
      if (t ~ /:/) { n = split(t, a, ":"); return a[n] + 60 * a[n - 1] + (n > 2 ? 3600 * a[n - 2] : 0) }
      n = 0; if (match(t, /[0-9]+h/)) n += 3600 * substr(t, RSTART, RLENGTH - 1)
      if (match(t, /[0-9]+m/)) n += 60 * substr(t, RSTART, RLENGTH - 1)
      if (match(t, /[0-9]+s/)) n += substr(t, RSTART, RLENGTH - 1)
      return n
    }
    # curl: % Total % Received % Xferd Dload Upload Total Spent Left Speed
    /^ *[0-9]+ +[0-9.]+[kMGT]? +[0-9]+ +[0-9.]+[kMGT]? / && NF >= 12 {
      p = $1 "|" bytes($4) "|" bytes($2) "|" bytes($12) "|" ($11 ~ /-/ ? "" : secs($11)); next
    }
    # aria2c: [#2089b0 138MiB/327MiB(42%) CN:16 DL:11MiB ETA:16s]
    /\[#[0-9a-f]+ / && match($0, /[0-9.]+[KMG]?i?B\/[0-9.]+[KMG]?i?B\([0-9]+%\)/) {
      r = substr($0, RSTART, RLENGTH); split(r, a, /[\/(%]/); sp = ""; et = ""
      if (match($0, /DL:[0-9.]+[KMG]?i?B/)) sp = bytes(substr($0, RSTART + 3, RLENGTH - 3))
      if (match($0, /ETA:[0-9hms]+/)) et = secs(substr($0, RSTART + 4, RLENGTH - 4))
      p = a[3] "|" bytes(a[1]) "|" bytes(a[2]) "|" sp "|" et; next
    }
    # wget: 42%[=====>     ] 138.12M  11.8MB/s    eta 16s
    match($0, /[0-9]+%\[/) { p = substr($0, RSTART, RLENGTH - 2) "||||" }
    END { print p }'
}

download_image_ui() {
  if ! ui_live; then
    download_with_mirrors "$@" >/dev/null
    return
  fi
  local img="$1" label log rc=0 start=$SECONDS line summary=() sum_url host via
  label=$(image_label "$img")
  log=$(mktemp)
  download_with_mirrors "$@" >"$log" 2>&1 &
  ui_watch $! download_tick || rc=$?

  if [ "$rc" -ne 0 ]; then
    if grep -q 'No working mirrors' "$log"; then
      ui_step fail "$label" "download failed: no mirror answered from this host"
    else
      ui_step fail "$label" "download failed: every mirror failed"
    fi
    grep -E '^WARNING' "$log" | sed -E 's/^WARNING: //; s#https?://([^/ ]+)[^ ]*#\1#g' | awk '!seen[$0]++' |
      tail -4 | while IFS= read -r line; do echo -e "      ${DIM}${line}${NC}"; done
    echo -e "      ${DIM}dcvm template check $img shows which mirrors answer from here${NC}"
    rm -f "$log"
    return "$rc"
  fi
  # SUCCESS: Downloaded 327.0MB in 28s (avg: 11.68 MB/s) via aria2c | from <url>
  line=$(grep '^SUCCESS: Downloaded' "$log" | tail -1)
  summary+=("$(sed -E 's/^SUCCESS: Downloaded ([0-9.]+)MB in ([0-9]+s) \(avg: ([^)]*)\).*/\1 MB in \2, \3/; s/, N\/A MB\/s$//' <<<"$line")")
  if via=$(sed -n 's/.*aria2c with \([0-9]*\) mirror.*/\1/p' "$log" | head -1) && [ -n "$via" ] && [[ $line == *"via aria2c" ]]; then
    summary+=("$(plural "$via" mirror) via aria2c")
  else
    host=${line##* from } host=${host#*://} host=${host%%/*}
    summary+=("$host via curl$(command -v aria2c >/dev/null 2>&1 || echo " (install aria2 for faster downloads)")")
  fi
  local kind=ok
  if line=$(grep -o -m1 '^INFO: sha[0-9]* checksum verified' "$log"); then
    summary+=("$(cut -d' ' -f2 <<<"$line") verified")
  elif [ -n "${4:-}" ]; then
    summary+=("SHA-256 verified")
  else
    summary+=("not verified: no mirror publishes a checksum")
    kind=warn
  fi
  if line=$(grep -m1 'image converted to qcow2' "$log"); then
    # Kali: SUCCESS: Kali Linux image converted to qcow2 (12G -> 3.1G)
    line=${line##*(}
    summary+=("converted to qcow2, ${line%)}")
  fi
  ui_step "$kind" "$label" "$(IFS='|' && echo "${summary[*]}" | sed "s/|/ $SYM_DOT /g")"
  rm -f "$log"
}

download_tick() {
  local lines=() phase detail="" url host prog pct done total speed left sources warn
  if grep -q 'Best mirror' "$log"; then
    # ★ Best mirror: <url> (12.34 MB/s, latency: 0.12s)
    url=$(sed -n 's/.*Best mirror: \([^ ]*\) .*/\1/p' "$log" | head -1)
    host=${url#*://} host=${host%%/*}
    detail="$host, fastest of $(grep -c '^  Mirror: ' "$log") that answered out of $(get_mirrors "$img" | grep -c .)"
  elif grep -q 'No working mirrors' "$log"; then
    detail="none answered the speed test; trying each in turn"
  fi
  sources=$(sed -n 's/.*aria2c with \([0-9]*\) mirror.*/\1/p' "$log" | head -1)
  warn=$(grep '^WARNING' "$log" | grep -v 'No published checksum' | tail -1 | sed -E 's#https?://([^/ ]+)[^ ]*#\1#g')
  prog=$(download_progress "$log")

  if grep -q 'Extracting Kali' "$log"; then
    phase="converting the raw disk to qcow2, $((SECONDS - start))s"
  elif [ -z "$detail" ]; then
    phase="testing $(plural "$(get_mirrors "$img" | grep -c .)" mirror), $((SECONDS - start))s"
  else
    phase="downloading $img"
  fi
  lines+=("$(ui_spin_line "$label" "$phase")")
  [ -n "$detail" ] && lines+=("      ${DIM}mirror      $(ui_fit 18 "$detail")${NC}")
  if [ -n "$sources" ] && ! grep -q 'aria2c download failed' "$log"; then
    lines+=("      ${DIM}via         aria2c, from $(plural "$sources" mirror) at once${NC}")
  elif [ -n "$detail" ]; then
    lines+=("      ${DIM}via         curl, one mirror at a time${NC}")
  fi
  [ -n "$warn" ] && lines+=("      ${YELLOW}${SYM_WARN}${NC} ${DIM}$(ui_fit 8 "${warn#WARNING: }")${NC}")
  if [ -n "$detail" ] && [ -n "$prog" ] && ! grep -q 'Extracting Kali' "$log"; then
    IFS='|' read -r pct done total speed left <<<"$prog"
  fi
  # The bar once data arrives (curl reports 0 of 0 while it connects).
  if [ "${pct:-0}" -gt 0 ] || [ "${done:-0}" -gt 0 ]; then
    lines+=("      $(ui_bar "$pct" 20) $(printf '%3s' "$pct")%${DIM}$(ui_fit 32 "${done:+  $(format_bytes "$done") of $(format_bytes "$total")}${speed:+ $SYM_DOT $(format_bytes "$speed")/s}${left:+ $SYM_DOT $([ "$left" -ge 60 ] && echo "$((left / 60))m ")$((left % 60))s left}")${NC}")
  fi
  ui_region "${lines[@]}"
}

is_kali_image() {
  local filename="$1"
  [[ "$filename" == "kali-linux-cloud-genericcloud-amd64.qcow2" ]]
}

extract_kali_image() {
  local tarxz_path="$1"
  local target_qcow2="$2"
  local extract_dir=""

  cleanup_kali_extract() {
    [ -n "$extract_dir" ] && [ -d "$extract_dir" ] && rm -rf "$extract_dir" 2>/dev/null
  }
  # Preserve any existing EXIT trap by appending cleanup
  local previous_exit_trap
  previous_exit_trap=$(trap -p EXIT 2>/dev/null | sed -E "s/^trap -- '(.*)' EXIT$/\1/" || true)
  if [ -n "$previous_exit_trap" ]; then
    trap "$previous_exit_trap; cleanup_kali_extract" EXIT
  else
    trap cleanup_kali_extract EXIT
  fi

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

  local -a raw_candidates=()
  mapfile -t raw_candidates < <(find "$extract_dir" -name "*.raw" -type f 2>/dev/null)
  if [ "${#raw_candidates[@]}" -eq 0 ]; then
    mapfile -t raw_candidates < <(find "$extract_dir" -name "disk*" -type f 2>/dev/null)
  fi

  if [ "${#raw_candidates[@]}" -eq 0 ]; then
    echo "ERROR: No raw disk image found in tar.xz archive" >&2
    echo "Archive contents:" >&2
    find "$extract_dir" -type f >&2
    return 1
  fi

  if [ "${#raw_candidates[@]}" -gt 1 ]; then
    echo "ERROR: Multiple raw disk images found in tar.xz archive; expected exactly one." >&2
    echo "Candidate images:" >&2
    printf '%s\n' "${raw_candidates[@]}" >&2
    return 1
  fi

  local raw_file="${raw_candidates[0]}"

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
  cleanup_kali_extract

  local final_size
  final_size=$(du -h "$target_qcow2" 2>/dev/null | cut -f1)
  echo "SUCCESS: Kali Linux image converted to qcow2 (${raw_size} -> ${final_size})" >&2
  return 0
}

best_mirror_rows() {
  local img
  for img in $SUPPORTED_IMAGES; do
    printf '%s\t%s\n' "$img" "$(select_best_mirror "$img" 2>/dev/null || echo -)"
  done
}

is_force() { [ "${1:-}" = --force ] || [ "${1:-}" = -f ]; }

mirror_table() {
  local filename="$1" total ok
  total=$(get_mirrors "$filename" | grep -c .)
  if [ "$total" -eq 0 ]; then
    print_error "Unknown image: $filename (dcvm template list)"
    return 1
  fi
  ui_run "Testing $total mirrors" rank_mirrors "$filename" || true
  ok=$(grep -c '^  Mirror: ' "$UI_RUN_LOG" || true)
  if [ "$ok" -gt 0 ]; then
    {
      printf 'MIRROR\tSPEED\tLATENCY\n'
      sed -n 's/^  Mirror: \(.*\) -> \(.*\) (latency: \(.*\)s)$/\1\t\2\t\3 s/p' "$UI_RUN_LOG"
    } | ui_table
  fi
  echo -e "  ${DIM}$ok of $total mirrors answered$([ "$ok" -lt "$total" ] && echo "; the others failed or timed out")${NC}"
}

download_image() {
  local img="$1" path="$TEMPLATE_DIR/$1" old="" new vm disk base running="" pinned
  mkdir -p "$TEMPLATE_DIR"
  if [ -f "$path" ]; then
    old=$(current_build "$img") || return 1
    # Disks from before 0.9.9 refer to templates/<image> itself: pin the
    # stopped ones to the build being replaced; running ones cannot change
    # while they run.
    while IFS=$'\t' read -r vm disk base; do
      [ "$base" = "$path" ] || continue
      if [ "$(get_vm_state "$vm")" = running ]; then
        running+="${running:+, }$vm"
      elif pinned=$(pin_vm_disk "$vm" "$disk" "$base"); then
        ui_step ok "$vm" "pinned to ${pinned##*/} before the download"
      else
        return 1
      fi
    done < <(vm_disks)
    if [ -n "$running" ]; then
      ui_step fail "$(image_label "$img")" "not replaced: running VMs use this file directly ($running)"
      echo -e "      ${DIM}They were created before 0.9.9. Stop them (dcvm stop), then download again.${NC}"
      return 1
    fi
  fi
  download_image_ui "$img" "$path" 100000000 || return 1
  [ -n "$old" ] || return 0
  new=$(current_build "$img") || return 1
  if [ "$new" = "$old" ]; then
    ui_step skip "VMs" "the mirror has no newer build; nothing to move"
    return 0
  fi
  update_vms_to_build "$img" "$new"
}

update_vms_to_build() {
  local img="$1" new="$2" vm disk base removed
  while IFS=$'\t' read -r vm disk base <&3; do
    [[ "$base" == "$(builds_dir)/${img%.*}-"* ]] && [ "$base" != "$new" ] || continue
    if [ "$(get_vm_state "$vm")" = running ]; then
      if [ "${RESTART_RUNNING:-false}" = true ] && confirm_action "Restart $vm to move it onto the new build now?"; then
        stop_vm_gracefully "$vm" 60 >/dev/null 2>&1
        prepare_vm_disk "$vm" "$vm" && virsh start "$vm" >/dev/null 2>&1
      else
        ui_step skip "$vm" "running; moves to the new build at its next start (or: dcvm restart $vm)"
      fi
    else
      prepare_vm_disk "$vm" "$vm"
    fi
  done 3< <(vm_disks)
  removed=$(prune_builds)
  [ -n "$removed" ] && ui_step ok "Old builds" "removed $(echo $removed)"
  return 0
}

main() {
  if [ -f /etc/dcvm-install.conf ]; then
    source /etc/dcvm-install.conf
  fi
  DATACENTER_BASE="${DATACENTER_BASE:-/srv/datacenter}"
  TEMPLATE_DIR="$DATACENTER_BASE/storage/templates"
  local img target="${2:-}" n=0 failed=0

  case "${1:-}" in
  list)
    if [ -n "$target" ]; then
      local mirrors
      mirrors=$(get_mirrors "$target")
      [ -n "$mirrors" ] || {
        print_error "Unknown image: $target"
        return 1
      }
      ui_title "Mirrors" "$target"
      {
        printf '#\tURL\n'
        grep . <<<"$mirrors" | awk '{ print NR "\t" $0 }'
      } | ui_table
      echo ""
      return 0
    fi
    ui_title "Images" "cloud images dcvm can build VMs from"
    {
      printf 'OS\tIMAGE\tDOWNLOADED\n'
      for img in $SUPPORTED_IMAGES; do
        printf '%s\t%s\t%s\n' "$(image_label "$img")" "$img" "$([ -f "$TEMPLATE_DIR/$img" ] && format_bytes "$(file_bytes "$TEMPLATE_DIR/$img")" || echo -)"
      done
    } | ui_table
    echo ""
    ;;
  check)
    if [ "$target" = "-a" ] || [ "$target" = "--all" ]; then
      ui_section "Mirror check" "all images"
      for img in $SUPPORTED_IMAGES; do
        ui_section "$img"
        mirror_table "$img"
      done
    elif [ -z "$target" ]; then
      print_error "Image name required: dcvm template check <image> (or -a for all)"
      echo -e "  ${DIM}Images: dcvm template list${NC}"
      exit 1
    else
      ui_title "Mirror check" "$target"
      mirror_table "$target" || exit 1
    fi
    echo ""
    ;;
  best)
    if [ "$target" = "-a" ] || [ "$target" = "--all" ]; then
      ui_title "Fastest mirrors" "all images"
      ui_run "Testing mirrors" best_mirror_rows || true
      {
        printf 'IMAGE\tFASTEST MIRROR\n'
        cat "$UI_RUN_LOG"
      } | ui_table
      echo ""
    elif [ -z "$target" ]; then
      print_error "Image name required: dcvm template best <image> (or -a for all)"
      exit 1
    else
      local best
      if ui_run "Testing mirrors" select_best_mirror "$target" && best=$(tail -1 "$UI_RUN_LOG") && [ -n "$best" ]; then
        ui_done ok "Fastest mirror for $target" "$(grep -o '([0-9.]* MB/s' "$UI_RUN_LOG" | tail -1 | tr -d '(')"
        echo "  $best"
        echo ""
      else
        ui_done fail "No working mirror for $target"
        echo ""
        exit 1
      fi
    fi
    ;;
  download)
    local force="${3:-}" arg
    for arg in "$@"; do [ "$arg" = --restart ] && RESTART_RUNNING=true; done
    if [ "$target" = "-a" ] || [ "$target" = "--all" ]; then
      ui_title "Downloading images" "into $TEMPLATE_DIR"
      for img in $SUPPORTED_IMAGES; do
        n=$((n + 1))
        if [ -f "$TEMPLATE_DIR/$img" ] && ! is_force "$force"; then
          ui_step skip "$img" "already downloaded"
        else
          download_image "$img" || failed=$((failed + 1))
        fi
      done
      if [ "$failed" -eq 0 ]; then ui_done ok "All $n images ready"; else ui_done warn "$((n - failed)) of $n images ready" "$failed failed"; fi
      echo ""
      [ "$failed" -eq 0 ]
      exit
    fi

    if [ -z "$target" ]; then
      print_error "Image name required: dcvm template download <image> [--force]"
      echo -e "  ${DIM}Images: dcvm template list${NC}"
      exit 1
    fi
    if [ -z "$(get_mirrors "$target")" ]; then
      print_error "Unknown image: $target (dcvm template list)"
      exit 1
    fi
    if [ -f "$TEMPLATE_DIR/$target" ] && ! is_force "$force"; then
      ui_done ok "$target is already downloaded" "--force downloads it again"
      echo ""
      exit 0
    fi
    ui_title "Downloading $target" "into $TEMPLATE_DIR"
    if download_image "$target"; then
      ui_done ok "$target ready" "dcvm create uses it from now on"
      echo ""
    else
      ui_done fail "Could not download $target" "dcvm template check $target tests the mirrors"
      echo ""
      exit 1
    fi
    ;;
  status)
    ui_title "Images" "$TEMPLATE_DIR"
    local rows="" missing="" size vsize corrupt=0
    for img in $SUPPORTED_IMAGES; do
      if [ -f "$TEMPLATE_DIR/$img" ]; then
        size=$(format_bytes "$(file_bytes "$TEMPLATE_DIR/$img")")
        vsize=$(qemu-img info "$TEMPLATE_DIR/$img" 2>/dev/null | awk -F': ' '/^virtual size/ { split($2, a, " "); print a[1] " " a[2] }')
        if qemu-img check "$TEMPLATE_DIR/$img" >/dev/null 2>&1; then
          rows+="$img"$'\t'"$size"$'\t'"${vsize:--}"$'\t'"$SYM_OK"$'\n'
        else
          rows+="$img"$'\t'"$size"$'\t'"${vsize:--}"$'\t'"$SYM_FAIL CORRUPT"$'\n'
          corrupt=$((corrupt + 1))
        fi
      else
        missing+="$img "
      fi
    done
    if [ -n "$rows" ]; then
      printf 'IMAGE\tSIZE\tDISK\tCHECK\n%s' "$rows" | ui_table
    else
      echo -e "  ${DIM}none yet; dcvm create downloads the image it needs${NC}"
    fi
    if [ -n "$missing" ]; then
      ui_section "Not downloaded"
      for img in $missing; do echo -e "  ${DIM}${SYM_DOT} $img${NC}"; done
    fi
    if [ "$corrupt" -gt 0 ]; then
      echo ""
      print_warning "$corrupt image(s) are corrupt: dcvm template download <image> --force (VMs built on the old file break)"
    fi
    echo ""
    ;;
  verify)
    ui_title "Image check" "qemu-img check"
    if [ "$target" = "-a" ] || [ "$target" = "--all" ] || [ -z "$target" ]; then
      for img in $SUPPORTED_IMAGES; do
        [ -f "$TEMPLATE_DIR/$img" ] || continue
        n=$((n + 1))
        if qemu-img check "$TEMPLATE_DIR/$img" >/dev/null 2>&1; then
          ui_step ok "$img" "no errors"
        else
          ui_step fail "$img" "corrupt"
          failed=$((failed + 1))
        fi
      done
      [ "$n" -eq 0 ] && echo -e "  ${DIM}No images downloaded yet${NC}"
    else
      [ -f "$TEMPLATE_DIR/$target" ] || {
        print_error "Not downloaded: $target"
        exit 1
      }
      n=1
      if qemu-img check "$TEMPLATE_DIR/$target" >/dev/null 2>&1; then
        ui_step ok "$target" "no errors"
      else
        ui_step fail "$target" "corrupt"
        failed=1
      fi
    fi
    if [ "$failed" -gt 0 ]; then
      ui_done warn "$failed of $n images corrupt" "dcvm template download <image> --force"
      echo ""
      exit 1
    fi
    [ "$n" -gt 0 ] && ui_done ok "$(plural "$n" image) OK"
    echo ""
    ;;
  help | --help | -h | "")
    {
      cat <<EOF
dcvm template - the cloud images VMs are built from

Usage: dcvm template <command> [image]

Commands:
  status                  Downloaded images, their size and an integrity check
  list [image]            Supported images, or the mirrors of one
  download <image> [-f]   Download an image (-f: again, even if present)
  download -a [-f]        Download every image
  verify [image|-a]       Check downloaded images with qemu-img
  check <image|-a>        Test the mirrors of an image: speed and latency
  best <image|-a>         The fastest mirror of an image

Images:
EOF
      for img in $SUPPORTED_IMAGES; do echo "  $img"; done
      cat <<EOF

Examples:
  dcvm template status
  dcvm template download debian-13-genericcloud-amd64.qcow2
EOF
    } | ui_help
    ;;
  *)
    print_error "Unknown command: ${1:-}"
    echo "Use: dcvm template help"
    exit 1
    ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
  main "$@"
fi
