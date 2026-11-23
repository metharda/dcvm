#!/usr/bin/env bash

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]; then
  RED='\033[31m' GREEN='\033[32m' YELLOW='\033[33m' BLUE='\033[34m'
  CYAN='\033[36m' BOLD='\033[1m' DIM='\033[2m' NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
fi
case "${TERM:-}:${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
dumb:*) UI_UNICODE=false ;;
*[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) UI_UNICODE=true ;;
*) UI_UNICODE=false ;;
esac
if [ "$UI_UNICODE" = true ]; then
  SYM_OK='✓' SYM_FAIL='✗' SYM_WARN='!' SYM_INFO='›' SYM_DOT='·' SYM_ARROW='→'
  SYM_RUN='●' SYM_STOP='○' SYM_DASH='—' SYM_BAR='━'
  BOX_TL='╭' BOX_TR='╮' BOX_BL='╰' BOX_BR='╯' BOX_H='─' BOX_V='│'
  SPIN_FRAMES='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
else
  SYM_OK='+' SYM_FAIL='x' SYM_WARN='!' SYM_INFO='>' SYM_DOT='-' SYM_ARROW='->'
  SYM_RUN='*' SYM_STOP='o' SYM_DASH='-' SYM_BAR='#'
  BOX_TL='+' BOX_TR='+' BOX_BL='+' BOX_BR='+' BOX_H='-' BOX_V='|'
  SPIN_FRAMES='|/-\'
fi

UI_QUIET=false
ui_quiet() { [ "${DCVM_VERBOSE:-0}" = 1 ] || UI_QUIET=true; }

print_info() { [ "$UI_QUIET" = true ] || echo -e "${BLUE}${SYM_INFO}${NC} $1"; }
print_success() { [ "$UI_QUIET" = true ] || echo -e "${GREEN}${SYM_OK}${NC} $1"; }
print_warning() { echo -e "${YELLOW}${SYM_WARN}${NC} $1" >&2; }
print_error() { echo -e "${RED}${SYM_FAIL} error:${NC} $1" >&2; }

ui_title() {
  echo ""
  echo -e "${BOLD}$1${NC}${2:+  ${DIM}$2${NC}}"
  echo ""
}

ui_step() {
  local sym col
  case "$1" in
  ok) sym=$SYM_OK col=$GREEN ;;
  warn) sym=$SYM_WARN col=$YELLOW ;;
  fail) sym=$SYM_FAIL col=$RED ;;
  *) sym=$SYM_DOT col=$DIM ;;
  esac
  printf '  %b%s%b %-15s %b%s%b\n' "$col" "$sym" "$NC" "$2" "$DIM" "${3:-}" "$NC"
}

ui_live() { [ -t 2 ] && [ "${TERM:-}" != dumb ] && [ "${DCVM_VERBOSE:-0}" != 1 ]; }

# The terminal's width in columns, read once from the terminal itself (tput
# in a command substitution has no terminal to ask and says 80).
# Numbers only: $(( )) runs commands hidden in an array subscript.
ui_cols() {
  if [[ ! "${UI_COLS:-}" =~ ^[1-9][0-9]{0,3}$ ]]; then
    UI_COLS=$(stty size </dev/tty 2>/dev/null | awk '{ print $2 }')
    [[ "$UI_COLS" =~ ^[1-9][0-9]{0,3}$ ]] || UI_COLS=${COLUMNS:-80}
    [[ "$UI_COLS" =~ ^[1-9][0-9]{0,3}$ ]] || UI_COLS=80
  fi
  echo "$UI_COLS"
}

UI_REGION_ROWS=0
ui_region() {
  local out="\r" first=true line plain cols rows=0
  ui_cols >/dev/null
  cols=$UI_COLS
  [ "$UI_REGION_ROWS" -gt 1 ] && out+="\033[$((UI_REGION_ROWS - 1))A"
  out+="\033[J"
  for line in "$@"; do
    $first || out+="\n"
    out+="$line"
    first=false
    plain=$(printf '%b' "$line" | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g')
    rows=$((rows + (${#plain} > 0 ? (${#plain} - 1) / cols + 1 : 1)))
  done
  printf '%b' "$out" >&2
  UI_REGION_ROWS=$rows
}

# Cuts text to the room left on a line that already holds <used> columns:
# ui_fit <used> <text>. Backslashes are doubled, as ui_region prints lines
# with %b and a tool's "\n" would otherwise start a new row.
ui_fit() {
  local room=$(($(ui_cols) - $1 - 1)) text="$2"
  [ "${#text}" -gt "$room" ] && [ "$room" -gt 1 ] && text="${text:0:room-1}…"
  echo "${text//\\/\\\\}"
}

UI_SPIN_I=0
ui_spin_line() {
  printf '  %b%s%b %-15s %b%s%b' "$CYAN" "${SPIN_FRAMES:UI_SPIN_I++%${#SPIN_FRAMES}:1}" "$NC" "$1" "$DIM" "$(ui_fit 20 "${2:-}")" "$NC"
}
ui_spin() { ui_region "$(ui_spin_line "$1" "${2:-}")"; }
ui_spin_clear() { ui_region; }

ui_bar() {
  local w=${2:-20} fill on off
  fill=$((${1:-0} * w / 100))
  printf -v on '%*s' "$fill" ''
  printf -v off '%*s' $((w - fill)) ''
  printf '%b%s%b%b%s%b' "$CYAN" "${on// /$SYM_BAR}" "$NC" "$DIM" "${off// /$BOX_H}" "$NC"
}

ui_watch() {
  local _w_pid=$1 _w_tick=$2 _w_rc=0 _w_traps
  _w_traps=$(trap -p INT TERM)
  trap 'ui_spin_clear; printf "\033[?25h" >&2; pkill -P "$_w_pid" 2>/dev/null; kill "$_w_pid" 2>/dev/null; exit 130' INT TERM
  printf '\033[?25l' >&2
  while kill -0 "$_w_pid" 2>/dev/null; do
    "$_w_tick"
    sleep 0.1
  done
  wait "$_w_pid" || _w_rc=$?
  ui_spin_clear
  printf '\033[?25h' >&2
  # Put back the caller's handlers (custom-iso's undo relies on its own).
  trap - INT TERM
  eval "$_w_traps"
  return "$_w_rc"
}

ui_run() {
  local label="$1" start=$SECONDS rc=0
  shift
  UI_RUN_LOG=$(mktemp)
  if ui_live; then
    "$@" >"$UI_RUN_LOG" 2>&1 &
    ui_watch $! ui_run_tick || rc=$?
  else
    "$@" >"$UI_RUN_LOG" 2>&1 || rc=$?
  fi
  UI_RUN_SECS=$((SECONDS - start))
  return "$rc"
}
ui_run_tick() {
  local -a lines=("$(ui_spin_line "$label" "$((SECONDS - start))s")")
  local line
  if [ -n "${UI_RUN_DETAIL:-}" ]; then
    while IFS= read -r line; do lines+=("$line"); done < <("$UI_RUN_DETAIL")
  elif line=$(ui_last_line "$UI_RUN_LOG") && [ -n "$line" ]; then
    lines+=("      ${DIM}$(ui_fit 6 "$line")${NC}")
  fi
  ui_region "${lines[@]}"
}

ui_last_line() {
  local line
  line=$(tail -c 4096 "$1" 2>/dev/null | tr '\r\t' '\n ' | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/[[:space:]]*$//' | grep -v '^$' | tail -1)
  if [ "$UI_UNICODE" = true ]; then echo "$line"; else
    LC_ALL=C tr -cd '\40-\176' <<<"$line"
    echo
  fi
}

plural() { echo "$1 $2$([ "$1" = 1 ] || echo s)"; }

ui_box() {
  local title="$1" line w top bottom
  shift
  w=$((${#title} + 3))
  for line in "$@"; do [ $((${#line} + 2)) -gt "$w" ] && w=$((${#line} + 2)); done
  printf -v top '%*s' $((w - ${#title} - 3)) ''
  printf -v bottom '%*s' "$w" ''
  echo ""
  echo -e "  ${DIM}${BOX_TL}${BOX_H}${NC} ${BOLD}${title}${NC} ${DIM}${top// /$BOX_H}${BOX_TR}${NC}"
  for line in "$@"; do
    printf '  %b%s%b %-*s %b%s%b\n' "$DIM" "$BOX_V" "$NC" $((w - 2)) "$line" "$DIM" "$BOX_V" "$NC"
  done
  echo -e "  ${DIM}${BOX_BL}${bottom// /$BOX_H}${BOX_BR}${NC}"
}

ui_next() {
  local -a args=("$@")
  local i w=24
  for ((i = 0; i < ${#args[@]}; i += 2)); do
    [ "${#args[i]}" -gt "$w" ] && w=${#args[i]}
  done
  echo ""
  echo -e "  ${BOLD}Next steps${NC}"
  for ((i = 0; i < ${#args[@]}; i += 2)); do
    printf '    %b%-*s%b  %b%s%b\n' "$CYAN" "$w" "${args[i]}" "$NC" "$DIM" "${args[i + 1]:-}" "$NC"
  done
  echo ""
}

ui_section() {
  echo ""
  echo -e "${BOLD}$1${NC}${2:+  ${DIM}$2${NC}}"
}

ui_kv() {
  while [ $# -gt 0 ]; do
    printf '  %b%-12s%b %s\n' "$DIM" "$1" "$NC" "${2:-}"
    shift 2 || shift
  done
}

ui_done() {
  local sym=$SYM_OK col=$GREEN
  case "$1" in
  warn) sym=$SYM_WARN col=$YELLOW ;;
  fail) sym=$SYM_FAIL col=$RED ;;
  skip) sym=$SYM_DOT col=$DIM ;;
  esac
  echo ""
  echo -e "${col}${sym}${NC} ${BOLD}$2${NC}${3:+  ${DIM}$3${NC}}"
}

ui_help() {
  local line first=true
  if [ -z "$BOLD" ]; then
    cat
    return
  fi
  while IFS= read -r line; do
    if $first; then
      echo -e "${BOLD}${line}${NC}"
      first=false
    elif [[ $line =~ ^[A-Za-z][A-Za-z\ /\&-]*:(\ .*)?$ ]]; then
      echo -e "${BOLD}${line%%:*}:${NC}${line#*:}"
    elif [[ $line =~ ^(\ +)([^ ]+(\ [^ ]+)*)(\ {2,})(.*)$ ]]; then
      local desc=${BASH_REMATCH[5]}
      [[ $desc == "#"* ]] && desc="${DIM}${desc}${NC}"
      echo -e "${BASH_REMATCH[1]}${CYAN}${BASH_REMATCH[2]}${NC}${BASH_REMATCH[4]}${desc}"
    elif [[ $line =~ ^(\ +)(dcvm\ .*)$ ]]; then
      echo -e "${BASH_REMATCH[1]}${CYAN}${BASH_REMATCH[2]}${NC}"
    else
      echo "$line"
    fi
  done
}

ui_table() {
  local -a rows=() widths=() cells=()
  local row cell i out col pad
  while IFS= read -r row; do
    # Tabs are IFS whitespace, so read would merge "a<tab><tab>b": mark
    # empty cells first.
    row=-$'\t'$row$'\t'-
    while [[ $row == *$'\t\t'* ]]; do row=${row//$'\t\t'/$'\t'-$'\t'}; done
    row=${row#-$'\t'} row=${row%$'\t'-}
    if [ ${#rows[@]} -gt 0 ]; then
      IFS=$'\t' read -r -a cells <<<"$row"
      for i in "${!cells[@]}"; do
        case "${cells[i]}" in
        running) cells[i]="$SYM_RUN running" ;;
        "shut off") cells[i]="$SYM_STOP shut off" ;;
        paused) cells[i]="$SYM_STOP paused" ;;
        "" | -) cells[i]=$SYM_DASH ;;
        esac
      done
      row=$(
        IFS=$'\t'
        echo "${cells[*]}"
      )
    fi
    rows+=("$row")
  done
  [ ${#rows[@]} -gt 0 ] || return 0
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r -a cells <<<"$row"
    for i in "${!cells[@]}"; do
      [ "${#cells[i]}" -gt "${widths[i]:-0}" ] && widths[i]=${#cells[i]}
    done
  done
  for i in "${!rows[@]}"; do
    IFS=$'\t' read -r -a cells <<<"${rows[i]}"
    out="  "
    for col in "${!cells[@]}"; do
      # Pad by characters: printf pads by bytes, which breaks on ✓ and ✗.
      pad=""
      [ "$col" -lt $((${#cells[@]} - 1)) ] && printf -v pad '%*s' $((widths[col] - ${#cells[col]})) ''
      cell=${cells[col]}$pad
      if [ "$i" -eq 0 ]; then
        cell="${DIM}${cell}${NC}"
      else
        case "${cells[col]}" in
        "$SYM_RUN running" | "$SYM_OK") cell="${GREEN}${cell}${NC}" ;;
        "$SYM_FAIL" | "$SYM_FAIL "*) cell="${RED}${cell}${NC}" ;;
        "$SYM_WARN "*) cell="${YELLOW}${cell}${NC}" ;;
        "$SYM_STOP shut off" | "$SYM_DASH" | deleted) cell="${DIM}${cell}${NC}" ;;
        "$SYM_STOP paused") cell="${YELLOW}${cell}${NC}" ;;
        esac
      fi
      out+="${cell}  "
    done
    echo -e "${out%"${out##*[![:space:]]}"}"
  done
}
print_status() {
  local status=$1
  local message=$2
  case $status in
  "INFO") print_info "$message" ;;
  "SUCCESS") print_success "$message" ;;
  "WARNING") print_warning "$message" ;;
  "ERROR") print_error "$message" ;;
  esac
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] ${*:2}"; }
log_message() { log "INFO" "$1"; }
log_to_file() {
  local log_file="${1:-/var/log/dcvm.log}"
  local message="$2"
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $message" >>"$log_file"
}

load_dcvm_config() {
  local config_file="${1:-/etc/dcvm-install.conf}"

  if [ ! -f "$config_file" ]; then
    print_error "Configuration file not found: $config_file"
    print_info "Please run the dcvm installer first"
    exit 1
  fi

  source "$config_file"

  DATACENTER_BASE="${DATACENTER_BASE:-/srv/datacenter}"
  NETWORK_NAME="${NETWORK_NAME:-datacenter-net}"
  BRIDGE_NAME="${BRIDGE_NAME:-virbr-dc}"
  NETWORK_SUBNET="${NETWORK_SUBNET:-10.10.10}"

  if [[ "$NETWORK_SUBNET" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    local oct1="${BASH_REMATCH[1]}"
    local oct2="${BASH_REMATCH[2]}"
    local oct3="${BASH_REMATCH[3]}"
    if [ "$oct1" -gt 255 ] || [ "$oct2" -gt 255 ] || [ "$oct3" -gt 255 ]; then
      echo "WARNING: Invalid NETWORK_SUBNET octets ($NETWORK_SUBNET), using default 10.10.10" >&2
      NETWORK_SUBNET="10.10.10"
    fi
  else
    echo "WARNING: Invalid NETWORK_SUBNET format ($NETWORK_SUBNET), using default 10.10.10" >&2
    NETWORK_SUBNET="10.10.10"
  fi
}

require_root() {
  if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root"
    exit 1
  fi
}

check_permissions() {
  if [ "$EUID" -ne 0 ]; then
    print_warning "Script should be run as root for best results"
    print_info "Some operations may fail without root privileges"
  fi
}

leases_table() {
  local leases
  leases=$(virsh net-dhcp-leases "$NETWORK_NAME" 2>/dev/null | awk 'NR > 2 && NF >= 5 { ip = $5; sub(/\/.*/, "", ip); print $6 "\t" ip "\t" $3 "\t" $1 " " $2 }')
  if [ -z "$leases" ]; then
    echo -e "  ${DIM}none${NC}"
    return
  fi
  {
    printf 'VM\tIP\tMAC\tEXPIRES\n'
    echo "$leases"
  } | ui_table
}

fetch_repo_file() {
  local base_url="https://raw.githubusercontent.com/${DCVM_REPO_SLUG:-metharda/dcvm}/${DCVM_REPO_BRANCH:-main}"
  mkdir -p "$(dirname "$2")" 2>/dev/null || true
  if command_exists curl; then
    curl -fsSL -o "$2" "$base_url/$1" 2>>"${LOG_FILE:-/dev/null}"
  else
    wget -q -O "$2" "$base_url/$1" 2>>"${LOG_FILE:-/dev/null}"
  fi
}

# Root runs these files: on Debian /usr/local can be setgid staff, so the
# owner, the group and every mode are set, never inherited.
dcvm_tree_permissions() {
  local bin="$1" lib="$2"
  chown root:root "$bin" && chmod 755 "$bin" || return 1
  chown -R root:root "$lib" || return 1
  find "$lib" -type d -exec chmod 755 {} + -exec chmod g-s {} +
  find "$lib" -type f -exec chmod 644 {} +
  find "$lib" -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod 755 {} +
}

install_dcvm_tree() {
  local stage="$1" bin="$2" lib="$3" old
  [ -f "$stage/dcvm" ] && [ -d "$stage/lib" ] || return 1
  dcvm_tree_permissions "$stage/dcvm" "$stage/lib" || return 1
  old="$lib.old.$$"
  [ -d "$lib" ] && { mv "$lib" "$old" || return 1; }
  if ! mv "$stage/lib" "$lib"; then
    [ -d "$old" ] && mv "$old" "$lib"
    return 1
  fi
  mv -f "$stage/dcvm" "$bin/dcvm" || return 1
  rm -rf "$old"
}

list_repo_files() {
  local api_url="https://api.github.com/repos/${DCVM_REPO_SLUG:-metharda/dcvm}/git/trees/${DCVM_REPO_BRANCH:-main}?recursive=1"
  local response files
  if command_exists curl; then
    response=$(curl -fsSL -H "Accept: application/vnd.github.v3+json" "$api_url" 2>>"${LOG_FILE:-/dev/null}")
  elif command_exists wget; then
    response=$(wget -q -O - --header="Accept: application/vnd.github.v3+json" "$api_url" 2>>"${LOG_FILE:-/dev/null}")
  else
    print_error "Neither curl nor wget is available"
    return 1
  fi
  if [[ -z "$response" || "$response" != *'"tree"'* ]]; then
    print_warning "GitHub API request failed or rate limited"
    echo "$response" >>"${LOG_FILE:-/dev/null}" 2>/dev/null
    return 1
  fi
  if command_exists jq; then
    files=$(jq -r '.tree[]? | select(.type == "blob") | select(.path == "dcvm" or (.path | startswith("lib/"))) | .path' <<<"$response" 2>/dev/null)
  elif command_exists python3; then
    files=$(python3 -I -S -c '
import sys, json
for item in json.load(sys.stdin).get("tree", []):
    p = item.get("path", "")
    if item.get("type") == "blob" and (p == "dcvm" or p.startswith("lib/")):
        print(p)' <<<"$response" 2>/dev/null)
  else
    files=$(grep -o '"path": *"[^"]*"' <<<"$response" | sed 's/"path": *"//;s/"$//' | grep -E '^(dcvm$|lib/.+\.[a-z]+$)')
  fi
  [[ -n "$files" ]] || return 1
  echo "$files"
}

templates_dir() { echo "${DATACENTER_BASE:-/srv/datacenter}/storage/templates"; }
builds_dir() { echo "$(templates_dir)/builds"; }

disk_backing() {
  qemu-img info -U "$1" 2>/dev/null | sed -n 's/^backing file: //p' | sed 's/ (actual path: .*)$//' | head -1
}

build_image() {
  local b=${1##*/}
  local stem=${b%.*}
  echo "${stem%-*}.${b##*.}"
}

build_sum() { sed -n "s/^$2=//p" "${1%.*}.sums" 2>/dev/null | head -1; }

# Names also come from backup records and archives: a slash would write anywhere.
valid_image_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] && [[ "$1" != *..* ]]; }
valid_sha256() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
valid_sha512() { [[ "$1" =~ ^[0-9a-f]{128}$ ]]; }

inside_dir() {
  local rp dir
  rp=$(realpath -e -- "$1" 2>/dev/null) && dir=$(realpath -e -- "$2" 2>/dev/null) && [[ "$rp" == "$dir"/* ]]
}

registered_build() {
  local rp dir
  rp=$(realpath -e -- "$1" 2>/dev/null) && dir=$(realpath -e -- "$(builds_dir)" 2>/dev/null) || return 1
  [[ "$rp" == "$dir"/* ]] && [ -f "$rp" ] && [ -f "${rp%.*}.sums" ]
}

# Backups and archives are untrusted: a qcow2 can name any host file as its
# data file or backing file, and a non-qcow2 header (a VMDK extent) can too.
check_disk_image() {
  local info backing
  info=$(qemu-img info -U -f qcow2 --output=json -- "$1" 2>/dev/null) || return 1
  backing=$(python3 -I -S -c '
import json, sys
i = json.load(sys.stdin)
if i.get("format") != "qcow2": sys.exit(1)
if ((i.get("format-specific") or {}).get("data") or {}).get("data-file"): sys.exit(1)
b = i.get("full-backing-filename") or i.get("backing-filename") or ""
if b and (i.get("backing-filename-format", "qcow2") != "qcow2" or b.startswith("json:") or "://" in b): sys.exit(1)
print(b)' <<<"$info") || return 1
}

sanitize_domain_xml() {
  python3 -I -S - "$1" "$2" "$3" "$4" <<'PY'
import os, sys, xml.etree.ElementTree as ET
path, name, disk, renamed = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "true"
tree = ET.parse(path)
dom = tree.getroot()
if dom.tag != "domain":
    sys.exit(1)
top = {"name", "title", "description", "memory", "currentMemory", "maxMemory", "vcpu", "vcpus", "iothreads",
       "cputune", "numatune", "memtune", "os", "features", "cpu", "clock", "on_poweroff", "on_reboot",
       "on_crash", "on_lockfailure", "pm", "devices", "genid", "sysinfo", "perf"}
devs = {"disk", "controller", "interface", "input", "graphics", "video", "sound", "audio", "memballoon", "rng",
        "watchdog", "panic", "tpm", "vsock", "hub", "serial", "console", "channel", "iommu"}
for child in list(dom):
    if child.tag not in top:
        dom.remove(child)
for el in list(dom.iter()):
    for sub in [c for c in el if c.tag == "seclabel"]:
        el.remove(sub)
dom.find("name").text = name
osel = dom.find("os")
if osel is not None:
    for child in list(osel):
        text = (child.text or "").strip()
        if child.tag in ("kernel", "initrd", "cmdline", "dtb", "acpi", "init", "initarg", "initenv", "initdir", "inituser", "initgroup", "shim"):
            osel.remove(child)
        elif child.tag == "loader" and (not text.startswith("/usr/share/") or ".." in text):
            osel.remove(child)
        elif child.tag == "nvram" and (renamed or not text.startswith("/var/lib/libvirt/qemu/nvram/") or ".." in text or not child.get("template", "/usr/share/").startswith("/usr/share/")):
            osel.remove(child)
    t = osel.find("type")
    if t is not None:
        m = t.get("machine", "")
        if m and m != "q35":
            if "q35" in m:
                t.set("machine", "q35")
            else:
                del t.attrib["machine"]
devices = dom.find("devices")
if devices is None:
    sys.exit(1)
kept_disk = False
for d in list(devices):
    tag = d.tag
    keep = tag in devs
    if tag == "disk":
        keep = d.get("device", "disk") == "disk" and not kept_disk
        if keep:
            kept_disk = True
            d.set("type", "file")
            d.set("device", "disk")
            for c in [c for c in d if c.tag in ("source", "backingStore", "driver", "auth", "mirror", "encryption", "reservations")]:
                d.remove(c)
            ET.SubElement(d, "driver", {"name": "qemu", "type": "qcow2"})
            ET.SubElement(d, "source", {"file": disk})
    elif tag == "controller":
        keep = d.get("type") != "ide"
    elif tag == "interface":
        keep = d.get("type") in ("network", "bridge")
        for c in [c for c in d if c.tag in ("script", "downscript", "backenddomain", "teaming", "portForward")]:
            d.remove(c)
        mac = d.find("mac")
        if keep and renamed and mac is not None:
            b = os.urandom(3)
            mac.set("address", "52:54:00:%02x:%02x:%02x" % (b[0], b[1], b[2]))
    elif tag == "graphics":
        keep = d.get("type") in ("vnc", "spice")
        if keep:
            if d.get("listen") is not None:
                d.set("listen", "127.0.0.1")
            for c in [c for c in d if c.tag == "listen"]:
                d.remove(c)
            ET.SubElement(d, "listen", {"type": "address", "address": "127.0.0.1"})
    elif tag == "audio":
        keep = d.get("type") in ("none", "spice")
    elif tag == "rng":
        b = d.find("backend")
        keep = b is not None and b.get("model") == "random" and (b.text or "/dev/urandom").strip() in ("/dev/urandom", "/dev/random")
    elif tag == "tpm":
        b = d.find("backend")
        keep = b is not None and b.get("type") == "emulator"
    elif tag in ("serial", "console"):
        keep = d.get("type") == "pty"
    elif tag == "channel":
        keep = d.get("type") in ("unix", "spicevmc", "qemu-vdagent")
        src = d.find("source")
        if keep and src is not None:
            src.attrib.pop("path", None)
    if not keep:
        devices.remove(d)
if not kept_disk:
    sys.exit(1)
tree.write(path)
PY
}

register_build() {
  local file="$1" img="$2" dir sha b
  valid_image_name "$img" || return 1
  dir=$(builds_dir)
  mkdir -p "$dir" || return 1
  sha=$(sha256sum "$file" | cut -d' ' -f1) || return 1
  b="$dir/${img%.*}-${sha:0:12}.${img##*.}"
  if [ ! -e "$b" ]; then
    ln "$file" "$b" 2>/dev/null || cp -p --sparse=always "$file" "$b" || return 1
  fi
  [ -f "${b%.*}.sums" ] || printf 'image=%s\nsha256=%s\nsha512=%s\nadded=%s\n' \
    "$img" "$sha" "$(sha512sum "$file" | cut -d' ' -f1)" "$(date -Is)" >"${b%.*}.sums"
  echo "$b"
}

current_build() {
  local img="$1" file b
  valid_image_name "$img" || return 1
  file="$(templates_dir)/$img"
  [ -f "$file" ] || return 1
  for b in "$(builds_dir)/${img%.*}"-*."${img##*.}"; do
    [ -f "$b" ] && [ "$b" -ef "$file" ] && echo "$b" && return 0
  done
  b=$(register_build "$file" "$img") || return 1
  [ "$b" -ef "$file" ] || ln -f "$b" "$file"
  echo "$b"
}

find_build() {
  local f b
  valid_sha256 "$1" || return 1
  for f in "$(builds_dir)"/*.sums; do
    [ -f "$f" ] && grep -qxF "sha256=$1" "$f" || continue
    for b in "${f%.sums}".*; do [ "${b##*.}" != sums ] && [ -f "$b" ] && echo "$b" && return 0; done
  done
  return 1
}

vm_disks() {
  local vm disk
  while read -r vm; do
    [ -n "$vm" ] || continue
    disk=$(get_vm_disk_path "$vm")
    [ -n "$disk" ] && printf '%s\t%s\t%s\n' "$vm" "$disk" "$(disk_backing "$disk")"
  done < <(virsh list --all --name 2>/dev/null)
}

backup_builds() {
  sed -n 's/^build=//p' "${DATACENTER_BASE:-/srv/datacenter}"/backups/*/base 2>/dev/null
}

# Whether a disk or backup from before 0.9.9 exists: they do not record the
# build they need, so no build may be deleted while one does.
legacy_references() {
  local base="${DATACENTER_BASE:-/srv/datacenter}" f
  vm_disks | cut -f3 | grep -q "^$(templates_dir)/[^/]*$" && return 0
  for f in "$base"/backups/*-????????_?????? "$base"/backups/*-disk-*.qcow2*; do
    [ -d "$f" ] && [ ! -f "$f/base" ] && return 0
    [ -f "$f" ] && return 0
  done
  return 1
}

prune_builds() {
  local b used
  # ponytail: builds staged by a restore in flight aren't counted, so only root and admins prune; add a build lock if that races.
  [ "$(caller_role)" = user ] && return 0
  legacy_references && return 0
  used=$({
    vm_disks | cut -f3
    backup_builds
    cat "${DATACENTER_BASE:-/srv/datacenter}"/vms/*/base.pending 2>/dev/null
  } | sed 's#.*/##')
  for b in "$(builds_dir)"/*; do
    [ -f "$b" ] && [ "${b##*.}" != sums ] || continue
    [ "$b" -ef "$(templates_dir)/$(build_image "$b")" ] && continue
    grep -qxF "${b##*/}" <<<"$used" && continue
    rm -f "$b" "${b%.*}.sums" && echo "${b##*/}"
  done
}

# Moves a stopped VM's disk onto <build> without changing what the VM sees:
# qemu-img's safe rebase reads both bases and copies the blocks that differ
# into the disk. It works on a copy, which replaces the disk only after the
# rebase and a check succeed, so an interruption cannot damage the disk.
rebase_disk() {
  local disk="$1" build="$2" tmp="$1.rebase"
  rm -f "$tmp"
  if cp -p --sparse=always "$disk" "$tmp" && qemu-img rebase -f qcow2 -b "$build" -F qcow2 "$tmp" &&
    qemu-img check -q "$tmp" && mv -f "$tmp" "$disk"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# Whether <disk> reads as clean file systems on top of <build>: every ext*
# file system passes fsck in preen mode (status 0 or 1) and every btrfs one
# btrfs check. Runs on a throwaway copy, so the check cannot change the disk.
# Used for disks from before 0.9.9, which do not record their build; a disk
# on the wrong build typically fails on /boot even when / still passes.
disk_fits_build() {
  local disk="$1" build="$2" tmp fs type rc ok=1
  tmp=$(mktemp --suffix=.qcow2) || return 1
  if ! cp --sparse=always "$disk" "$tmp" || ! qemu-img rebase -u -f qcow2 -b "$build" -F qcow2 "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  while read -r fs type; do
    case "$type" in
    ext2 | ext3 | ext4)
      rc=$(guestfish --format=qcow2 -a "$tmp" run : fsck "$type" "$fs" 2>/dev/null | tail -1)
      case "$rc" in 0 | 1 | 0x0 | 0x1) ok=0 ;; *)
        ok=1
        break
        ;;
      esac
      ;;
    btrfs)
      guestfish --format=qcow2 -a "$tmp" run : btrfs-check "$fs" >/dev/null 2>&1 && ok=0 || {
        ok=1
        break
      }
      ;;
    esac
  done < <(guestfish --ro --format=qcow2 -a "$tmp" run : list-filesystems 2>/dev/null | sed 's/: / /')
  rm -f "$tmp"
  return "$ok"
}

legacy_disk_build() {
  local disk="$1" img="$2" b fits=()
  for b in "$(builds_dir)/${img%.*}"-*."${img##*.}" "$(current_build "$img" 2>/dev/null)"; do
    [ -f "$b" ] || continue
    printf '%s\n' "${fits[@]}" | grep -qxF "$b" && continue
    disk_fits_build "$disk" "$b" && fits+=("$b")
  done
  [ ${#fits[@]} -eq 1 ] && echo "${fits[0]}"
}

pin_vm_disk() {
  local vm="$1" disk="$2" backing="$3" img build pending="${DATACENTER_BASE:-/srv/datacenter}/vms/$1/base.pending"
  img=${backing##*/}
  if [ -f "$pending" ] && [ -f "$(cat "$pending")" ]; then
    build=$(cat "$pending")
  elif [ "$(stat -c %W "$disk" 2>/dev/null || echo 0)" -gt "$(stat -c %Y "$(templates_dir)/$img" 2>/dev/null || echo 0)" ]; then
    # The template was saved before the disk was created, so it is still
    # the build the disk was made on.
    build=$(current_build "$img")
  else
    build=$(legacy_disk_build "$disk" "$img")
  fi
  if [ -z "$build" ]; then
    print_error "$vm's base image ($img) was replaced after $vm was created, and no build on this host fits its disk. Restore a backup (dcvm backup restore $vm) or see dcvm doctor."
    return 1
  fi
  qemu-img rebase -u -f qcow2 -b "$build" -F qcow2 "$disk" || return 1
  rm -f "$pending"
  echo "$build"
}

prepare_vm_disk() {
  local vm="$1" label="${2:-Base image}" disk backing img cur
  disk=$(get_vm_disk_path "$vm")
  [ -n "$disk" ] && [ -f "$disk" ] || return 0
  backing=$(disk_backing "$disk")
  case "$backing" in
  "$(builds_dir)"/*) img=$(build_image "$backing") ;;
  "$(templates_dir)"/*)
    img=${backing##*/}
    backing=$(pin_vm_disk "$vm" "$disk" "$backing") || return 1
    ;;
  *) return 0 ;;
  esac
  if [ ! -f "$backing" ]; then
    print_error "$vm's base image is missing: $backing (see dcvm doctor)"
    return 1
  fi
  cur=$(current_build "$img" 2>/dev/null) || return 0
  [ "$cur" = "$backing" ] && return 0
  if ui_run "$label" rebase_disk "$disk" "$cur"; then
    ui_step ok "$label" "moved to the current build ${cur##*/} (${UI_RUN_SECS}s)"
    prune_builds >/dev/null
  else
    ui_step warn "$label" "could not move to ${cur##*/}; $vm stays on ${backing##*/}"
  fi
  return 0
}

vm_disk_outdated() {
  local disk backing
  disk=$(get_vm_disk_path "$1")
  [ -n "$disk" ] && [ -f "$disk" ] || return 1
  backing=$(disk_backing "$disk")
  case "$backing" in
  "$(templates_dir)"/*) return 0 ;;
  "$(builds_dir)"/*) [ "$(current_build "$(build_image "$backing")" 2>/dev/null)" != "$backing" ] && [ -f "$(templates_dir)/$(build_image "$backing")" ] ;;
  *) return 1 ;;
  esac
}

write_base_record() {
  local disk="$1" folder="$2" backing
  backing=$(disk_backing "$disk")
  [ -n "$backing" ] || return 0
  printf 'image=%s\nbuild=%s\nsha256=%s\nsha512=%s\n' "$(build_image "$backing")" "$backing" \
    "$(build_sum "$backing" sha256)" "$(build_sum "$backing" sha512)" >"$folder/base"
}

shell_files_matching() {
  local home f
  while IFS= read -r home; do
    for f in "$home/.bashrc" "$home/.zshrc" "$home/.bash_profile" "$home/.profile" "$home/.zprofile" "$home/.zshenv"; do
      [ -f "$f" ] && grep -qE "$1" "$f" 2>/dev/null && echo "$f"
    done
  done < <({
    echo "$HOME"
    [ -n "${SUDO_USER:-}" ] && getent passwd "$SUDO_USER" | cut -d: -f6
  } | awk 'NF && !seen[$0]++')
}

remove_shell_lines() {
  local f
  while IFS= read -r f; do
    if sed -i.bak -E "\#$1#d" "$f"; then echo "$f"; else print_warning "Could not update $f"; fi
  done < <(shell_files_matching "$1")
}

free_bytes() { echo $(($(df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print $4 }') * 1024)); }

DCVM_UNITS="/etc/systemd/system/datacenter-storage.service /etc/systemd/system/datacenter-storage.timer /etc/systemd/system/dcvm-boot.service /etc/systemd/system/dcvm.socket /etc/systemd/system/dcvm@.service /etc/systemd/system/dcvm-reaper.service /etc/systemd/system/dcvm-reaper.timer"
DCVM_USER_GROUP=dcvm
DCVM_ADMIN_GROUP=dcvm-admin

ensure_dcvm_groups() {
  getent group "$DCVM_USER_GROUP" >/dev/null || groupadd --system "$DCVM_USER_GROUP" || return 1
  getent group "$DCVM_ADMIN_GROUP" >/dev/null || groupadd --system "$DCVM_ADMIN_GROUP"
}

install_dcvm_services() {
  command_exists systemctl || return 1
  cat >/etc/systemd/system/datacenter-storage.service <<'EOF' || return 1
[Unit]
Description=dcvm storage check and health report
After=libvirtd.service

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/bin/dcvm storage-cleanup
ExecStartPost=-/usr/local/bin/dcvm doctor --quiet --fast
EOF
  cat >/etc/systemd/system/datacenter-storage.timer <<'EOF' || return 1
[Unit]
Description=Run the dcvm storage check hourly
Requires=datacenter-storage.service

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF
  ensure_dcvm_groups || return 1
  cat >/etc/systemd/system/dcvm.socket <<EOF || return 1
[Unit]
Description=dcvm for users without root

[Socket]
ListenStream=/run/dcvm/dcvm.sock
SocketUser=root
SocketGroup=$DCVM_USER_GROUP
SocketMode=0660
DirectoryMode=0755
Accept=yes
MaxConnections=64

[Install]
WantedBy=sockets.target
EOF
  cat >/etc/systemd/system/dcvm@.service <<'EOF' || return 1
[Unit]
Description=dcvm request
After=libvirtd.service

[Service]
ExecStart=/usr/bin/python3 -I -S /usr/local/lib/dcvm/server/dcvm-server.py
StandardInput=socket
StandardOutput=journal
StandardError=journal
CollectMode=inactive-or-failed
EOF
  cat >/etc/systemd/system/dcvm-reaper.service <<'EOF' || return 1
[Unit]
Description=dcvm: delete VMs whose --ttl has passed

[Service]
Type=oneshot
ExecStart=/usr/local/bin/dcvm reap
EOF
  cat >/etc/systemd/system/dcvm-reaper.timer <<'EOF' || return 1
[Unit]
Description=Delete expired dcvm VMs every 5 minutes

[Timer]
OnCalendar=*:0/5

[Install]
WantedBy=timers.target
EOF
  cat >/etc/systemd/system/dcvm-boot.service <<'EOF' || return 1
[Unit]
Description=dcvm: bring back the dcvm network and port forwards after boot
After=libvirtd.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=-/usr/local/bin/dcvm doctor --fix --quiet --only network

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload &&
    systemctl enable --now datacenter-storage.timer dcvm-reaper.timer >/dev/null 2>&1 &&
    systemctl enable dcvm-boot.service >/dev/null 2>&1 &&
    systemctl enable dcvm.socket >/dev/null 2>&1 && systemctl restart dcvm.socket >/dev/null 2>&1
}

dcvm_services_ok() {
  command_exists systemctl || return 0
  grep -qs 'dcvm doctor' /etc/systemd/system/datacenter-storage.service &&
    grep -qs 'dcvm-server.py' /etc/systemd/system/dcvm@.service &&
    systemctl is-enabled datacenter-storage.timer dcvm-boot.service dcvm-reaper.timer dcvm.socket >/dev/null 2>&1 &&
    systemctl is-active dcvm.socket >/dev/null 2>&1
}

# Whether net.ipv4.ip_forward=1 is applied at boot. Asks systemd which
# files it loads: Debian 13 no longer reads /etc/sysctl.conf.
ip_forwarding_persisted() {
  local conf
  conf=$(systemd-analyze cat-config sysctl.d 2>/dev/null) || conf=$(cat /etc/sysctl.conf /etc/sysctl.d/*.conf 2>/dev/null)
  grep -qE '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1' <<<"$conf"
}

enable_ip_forwarding() {
  echo 1 >/proc/sys/net/ipv4/ip_forward 2>/dev/null || return 1
  ip_forwarding_persisted || echo "net.ipv4.ip_forward=1" >/etc/sysctl.d/90-dcvm.conf
}

# "alias dcvm=..." lines, written by installs before 0.9 (they pointed at
# $DATACENTER_BASE/scripts/vm-manager.sh); in an interactive shell such an
# alias shadows /usr/local/bin/dcvm.
DCVM_ALIAS_LINE='^[[:space:]]*alias[[:space:]]+dcvm='

# Saves the live iptables rules for iptables-persistent, if it is set up
# (/etc/iptables exists); otherwise there is nothing to keep in sync.
IPTABLES_RULES_FILE="${IPTABLES_RULES_FILE:-/etc/iptables/rules.v4}"
save_iptables_rules() {
  if command_exists iptables-save && [ -d "${IPTABLES_RULES_FILE%/*}" ]; then
    iptables-save >"$IPTABLES_RULES_FILE" 2>/dev/null || true
  fi
  return 0
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Fedora sets no ID_LIKE, so it must stay optional under set -u.
distro_family() {
  local name file="${1:-/etc/os-release}"
  for name in $( ([ -r "$file" ] && . "$file" && echo "${ID:-} ${ID_LIKE:-}") 2>/dev/null); do
    case "$name" in
    debian | ubuntu) echo debian && return ;;
    arch) echo arch && return ;;
    fedora) echo fedora && return ;;
    esac
  done
}

check_dependencies() {
  local missing_deps=()
  for cmd in "$@"; do
    if ! command_exists "$cmd"; then
      missing_deps+=("$cmd")
    fi
  done
  if [ ${#missing_deps[@]} -gt 0 ]; then
    print_error "Missing required dependencies: ${missing_deps[*]}"
    print_info "Please install them first and try again"
    exit 1
  fi
}

validate_vm_name() {
  local vm_name="$1"
  if [ -z "$vm_name" ]; then
    print_error "VM name cannot be empty"
    return 1
  fi
  if [[ ! "$vm_name" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_-]*$ ]]; then
    print_error "VM name can only contain letters, numbers, underscores, and hyphens, and cannot start with a hyphen"
    return 1
  fi
  # Commands read these words as "every VM" or "the newest backup".
  if [[ "$vm_name" =~ ^(all|latest|help)$ ]]; then
    print_error "'$vm_name' is reserved, choose another VM name"
    return 1
  fi
  if [ ${#vm_name} -lt 3 ] || [ ${#vm_name} -gt 64 ]; then
    print_error "VM name must be between 3 and 64 characters"
    return 1
  fi
  return 0
}

# Trim leading/trailing whitespace without xargs (preserves quotes/backslashes).
trim_whitespace() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Validate a comma-separated package list (-k). Names end up in a shell
# command inside the guest, so only package-name characters are allowed.
validate_package_list() {
  local list="$1" pkg
  local -a pkgs=()
  if [[ "$list" == *$'\n'* || "$list" == *$'\r'* ]]; then
    print_error "Invalid package list: newlines and carriage returns are not allowed (separate packages with commas)"
    return 1
  fi
  IFS=',' read -ra pkgs <<<"$list"
  for pkg in "${pkgs[@]}"; do
    pkg=$(trim_whitespace "$pkg")
    [ -z "$pkg" ] && continue
    if [[ ! "$pkg" =~ ^[A-Za-z0-9][A-Za-z0-9@._+-]*$ ]]; then
      print_error "Invalid package name: '$pkg' (must start with a letter or number; allowed: letters, numbers, @ . _ + -)"
      return 1
    fi
  done
  return 0
}

validate_vm_name_list() {
  local raw="$1"
  local -a names
  local name seen=","
  if [[ "$raw" == *$'\n'* || "$raw" == *$'\r'* ]]; then
    print_error "VM names cannot contain newlines (separate them with commas)"
    return 1
  fi
  if [[ "$raw" =~ (^|,)[[:space:]]*(,|$) ]]; then
    print_error "VM name cannot be empty"
    return 1
  fi
  IFS=',' read -ra names <<<"$raw"
  for name in "${names[@]}"; do
    name=$(trim_whitespace "$name")
    if ! validate_vm_name "$name"; then
      return 1
    fi
    # A repeated name would overwrite the disk of the VM created just before it.
    if [[ "$seen" == *",$name,"* ]]; then
      print_error "VM $name is named twice"
      return 1
    fi
    seen+="$name,"
  done
  return 0
}

validate_username() {
  local username="$1"
  if [ -z "$username" ]; then
    return 1
  fi
  if [[ ! "$username" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    return 1
  fi
  if [[ ! "$username" =~ ^[a-zA-Z_] ]]; then
    return 1
  fi
  if [ ${#username} -lt 3 ] || [ ${#username} -gt 32 ]; then
    return 1
  fi
  if [[ "$username" =~ ^(admin|administrator|sysadmin|user|guest)$ ]]; then
    return 1
  fi
  return 0
}

validate_password() {
  local password="$1"
  if [ ${#password} -lt 4 ]; then
    echo "Password must be at least 4 characters long"
    return 1
  fi
  if [ ${#password} -gt 128 ]; then
    echo "Password must be at most 128 characters"
    return 1
  fi
  # YAML also breaks lines at U+0085, U+2028 and U+2029.
  if [[ "$password" == *[$'\n\r']* || "$password" == *$'\xc2\x85'* ||
    "$password" == *$'\xe2\x80\xa8'* || "$password" == *$'\xe2\x80\xa9'* ]]; then
    echo "Password must not contain line breaks"
    return 1
  fi
  return 0
}

get_vm_state() {
  local vm_name="$1"
  virsh domstate "$vm_name" 2>/dev/null || echo "not-found"
}

valid_vm_ip() {
  local subnet="${NETWORK_SUBNET:-10.10.10}" host
  [[ "$1" == "$subnet".* ]] || return 1
  host=${1#"$subnet".}
  [[ "$host" =~ ^[0-9]{1,3}$ ]] && [ "$host" -ge 2 ] && [ "$host" -le 254 ]
}

# Host-side sources first: the guest agent reports whatever the guest wants.
get_vm_ip() {
  local vm_name="$1" attempts="${2:-1}" ip="" count=0 mac
  local network_name="${NETWORK_NAME:-datacenter-net}"
  local static_conf="${DATACENTER_BASE:-/srv/datacenter}/config/network/${vm_name}.conf"

  while [ -z "$ip" ] && [ "$count" -lt "$attempts" ]; do
    mac=$(virsh domiflist -- "$vm_name" 2>/dev/null | awk -v n="$network_name" '$3 == n { print $5; exit }')
    [ -n "$mac" ] && ip=$(virsh net-dhcp-leases "$network_name" 2>/dev/null | filter_lease_lines "$mac" 3 | awk '{ print $5 }' | cut -d/ -f1 | head -1)
    valid_vm_ip "$ip" || ip=$(virsh domifaddr -- "$vm_name" --source lease 2>/dev/null | awk '/ipv4/ { print $4 }' | cut -d/ -f1 | head -1)
    valid_vm_ip "$ip" || ip=$([ -f "$static_conf" ] && grep '^IP=' "$static_conf" | head -1 | cut -d= -f2- | sed 's/^"//;s/"$//')
    valid_vm_ip "$ip" || ip=$(virsh domifaddr -- "$vm_name" --source agent 2>/dev/null | awk '/ipv4/ { print $4 }' | cut -d/ -f1 | head -1)
    valid_vm_ip "$ip" || ip=""
    [ -z "$ip" ] && [ "$attempts" -gt 1 ] && sleep 2
    count=$((count + 1))
  done

  if [ -z "$ip" ]; then
    echo "N/A"
    return 1
  fi
  echo "$ip"
}

get_vm_mac() {
  local vm_name="$1"
  local network_name="${NETWORK_NAME:-datacenter-net}"
  virsh domiflist "$vm_name" 2>/dev/null | grep "$network_name" | awk '{print $5}'
}

get_vm_disk_path() {
  local vm_name="$1"
  local disk_path=""
  # Disks only: an attached ISO is never "the VM's disk" to back up or delete.
  disk_path=$(virsh domblklist "$vm_name" --details 2>/dev/null | awk '$2 == "disk" { sub(/^ *[^ ]+ +[^ ]+ +[^ ]+ +/, ""); print; exit }')
  echo "$disk_path"
}

vm_login() {
  local login
  login=$(registry_get "$1" user)
  # Without cloud-init (an ISO install) dcvm can't know the user; get_vm_username would guess "admin".
  [ -n "$login" ] || [ ! -f "${DATACENTER_BASE:-/srv/datacenter}/vms/$1/cloud-init/user-data" ] || login=$(get_vm_username "$1")
  echo "$login"
}

get_vm_username() {
  local vm_name="$1"
  local base="${DATACENTER_BASE:-/srv/datacenter}"
  local user_data="${base}/vms/${vm_name}/cloud-init/user-data"
  local username=""

  if [[ "$vm_name" =~ ^[a-zA-Z0-9_-]+$ ]] && [ -f "$user_data" ]; then
    username=$(awk '
      /^users:/ { in_users = 1; next }
      in_users && /^[^[:space:]#]/ { in_users = 0 }
      in_users && /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
        sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "")
        sub(/[[:space:]#].*$/, "")
        gsub(/"/, "")
        print
        exit
      }
    ' "$user_data")
    if [ -z "$username" ]; then
      username=$(awk '
        /^[[:space:]]*VM_USERNAME="/ {
          sub(/^[[:space:]]*VM_USERNAME="/, "")
          sub(/".*$/, "")
          print
          exit
        }
      ' "$user_data")
    fi
  fi

  if [[ ! "$username" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]; then
    username="admin"
  fi
  echo "$username"
}

read_password() {
  local prompt="$1"
  local var_name="$2"
  local password=""
  echo -n "$prompt"
  IFS= read -rs password || no_input
  echo
  printf -v "$var_name" '%s' "$password"
}

generate_password_hash() {
  local password="$1"
  local salt=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
  printf '%s\n' "$password" | openssl passwd -6 -salt "$salt" -stdin
}

generate_random_mac() {
  printf "52:54:00:%02x:%02x:%02x\n" $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256))
}

file_bytes() { stat -c %s "$1" 2>/dev/null || echo 0; }

format_bytes() {
  awk -v b="${1:-0}" 'BEGIN {
    split("B KB MB GB TB", u); i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf (b < 10 && b != int(b) ? "%.1f %s\n" : "%.0f %s\n"), b, u[i]
  }'
}

create_dir_safe() {
  local dir_path="$1"
  local permissions="${2:-755}"
  if [ ! -d "$dir_path" ]; then
    if ! mkdir -p "$dir_path"; then
      print_error "Failed to create directory: $dir_path"
      return 1
    fi
    chmod "$permissions" "$dir_path"
  fi
  return 0
}

backup_file() {
  local file_path="$1"
  local backup_suffix="${2:-.backup}"
  if [ -f "$file_path" ]; then
    cp "$file_path" "${file_path}${backup_suffix}"
    print_info "Backup created: ${file_path}${backup_suffix}"
  fi
}

confirm_action() {
  local default="${2:-n}" answer
  read -r -p "  $1 ($([ "$default" = y ] && echo Y/n || echo y/N)): " answer || answer=n
  [[ "${answer:-$default}" =~ ^[Yy] ]] && return 0
  echo "  Cancelled."
  return 1
}

get_system_info() {
  echo "System Information:"
  echo "  OS: $(lsb_release -d 2>/dev/null | cut -f2 || echo 'Unknown')"
  echo "  Kernel: $(uname -r)"
  echo "  CPUs: $(nproc)"
  echo "  Memory: $(free -h | awk '/^Mem:/ {print $2}')"
  echo "  Disk: $(df -h / | awk 'NR==2 {print $4 " available"}')"
}

get_host_info() {
  HOST_MEMORY_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  HOST_MEMORY_MB=$((HOST_MEMORY_KB / 1024))
  HOST_CPUS=$(nproc)
  HOST_CPU_MODEL=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | sed 's/^ *//')
  MAX_VM_MEMORY=$((HOST_MEMORY_MB * 75 / 100))
  MAX_VM_CPUS=$((HOST_CPUS - 1))
  if [ $MAX_VM_CPUS -lt 1 ]; then
    MAX_VM_CPUS=1
  fi
}

check_port_connectivity() {
  local ip="$1"
  local port="$2"
  timeout 3 bash -c "</dev/tcp/$ip/$port" 2>/dev/null
}

# Check a host-port forward: the DNAT and FORWARD rules setup_vm_forwarding
# adds must both exist, and the VM must answer on the target port. Probing
# 127.0.0.1:<host_port> from the host is not enough: locally generated packets
# skip PREROUTING, so that probe
# fails even when forwarding works for other machines.
check_port_forward() {
  local host_port="$1"
  local vm_ip="$2"
  local vm_port="$3"
  iptables -t nat -C PREROUTING ! -i "${BRIDGE_NAME:-virbr-dc}" -p tcp -m addrtype --dst-type LOCAL --dport "$host_port" -j DNAT --to-destination "$vm_ip:$vm_port" 2>/dev/null || return 1
  iptables -C FORWARD -p tcp -d "$vm_ip" --dport "$vm_port" -j ACCEPT 2>/dev/null || return 1
  check_port_connectivity "$vm_ip" "$vm_port"
}

registry_file() { echo "${DCVM_STATE_DIR:-/var/lib/dcvm}/vms/$1"; }
registry_get() { sed -n "s/^$2=//p" "$(registry_file "$1")" 2>/dev/null | head -1; }
registry_remove() { rm -f "$(registry_file "$1")"; }

registry_set() {
  local vm="$1" file tmp kv
  shift
  file=$(registry_file "$vm")
  mkdir -p -m 700 "${file%/*}" || return 1
  tmp="$file.tmp.$$"
  {
    [ -f "$file" ] && grep -v -E "^($(printf '%s\n' "$@" | cut -d= -f1 | paste -sd'|'))=" "$file"
    for kv in "$@"; do printf '%s\n' "${kv//$'\n'/ }"; done
  } >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$file"
}

caller_uid() { echo "${DCVM_CALLER_UID:-$(id -u)}"; }
caller_user() { echo "${DCVM_CALLER_USER:-$(id -un)}"; }
caller_role() { echo "${DCVM_CALLER_ROLE:-root}"; }
vm_owner_uid() {
  local o
  o=$(registry_get "$1" owner_uid)
  echo "${o:-0}"
}
vm_visible() { [ "$(caller_role)" != user ] || [ "$(vm_owner_uid "$1")" = "$(caller_uid)" ]; }

read_dcvm_secrets() {
  local line
  [[ "${DCVM_SECRETS_FD:-}" =~ ^[0-9]+$ ]] || return 0
  while IFS= read -r line <&"$DCVM_SECRETS_FD"; do
    case "$line" in
    password=*) DCVM_SECRET_PASSWORD=${line#*=} ;;
    root_password=*) DCVM_SECRET_ROOT_PASSWORD=${line#*=} ;;
    tailscale_authkey=*) DCVM_SECRET_TAILSCALE_AUTHKEY=${line#*=} ;;
    esac
  done
  exec {DCVM_SECRETS_FD}<&-
  unset DCVM_SECRETS_FD
}

# The server passes what is left of a user's quota; prompts and backups can ask for more than it charged.
within_quota() {
  [ -n "${DCVM_QUOTA_LEFT:-}" ] || return 0
  local c m d
  read -r c m d <<<"$DCVM_QUOTA_LEFT"
  if [ "$1" -gt "$c" ] || [ "$2" -gt "$m" ] || [ "$3" -gt "$d" ]; then
    print_error "Over your quota: this VM needs $1 vCPU, $2 MB, $3 GB; you have $c vCPU, $m MB, $d GB left"
    return 1
  fi
}

# Another VM's lease or static record: forwarding to it would reach that VM.
ip_held_by_other_vm() {
  local ip="$1" vm="$2" mac f
  mac=$(get_vm_mac "$vm" 2>/dev/null)
  virsh net-dhcp-leases "${NETWORK_NAME:-datacenter-net}" 2>/dev/null |
    awk -v ip="$ip/" -v mac="${mac,,}" 'index($5, ip) == 1 && tolower($3) != mac { f = 1 } END { exit !f }' && return 0
  for f in "${DATACENTER_BASE:-/srv/datacenter}"/config/network/*.conf; do
    [ -f "$f" ] && [ "${f##*/}" != "$vm.conf" ] && grep -qE "^IP=\"?${ip//./\\.}\"?$" "$f" && return 0
  done
  return 1
}

# `shift 2` fails without shifting when the value is missing; looping on it never ends.
wants_help() {
  local a
  for a in "$@"; do
    case "$a" in -h | --help) return 0 ;; esac
  done
  return 1
}

need_value() {
  print_error "$1 needs a value"
  exit 1
}

no_input() {
  print_error "No answer (end of input): run it in a terminal, or give the answer as an option (see --help)"
  exit 1
}

claim_static_ip() {
  local vm="$1" ip="$2"
  validate_ip_in_subnet "$ip" || return 1
  if ip_held_by_other_vm "$ip" "$vm"; then
    print_error "$ip is already used by another VM"
    return 1
  fi
}

# Only once the VM is defined: a record left by a cancelled create would hold the address forever.
save_static_ip() {
  local vm="$1" ip="$2"
  mkdir -p "$DATACENTER_BASE/config/network" &&
    printf 'VM_NAME="%s"\nIP="%s"\nASSIGNED_AT="%s"\nSOURCE="static"\n' "$vm" "$ip" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      >"$DATACENTER_BASE/config/network/$vm.conf"
}

size_gb() {
  local v="${1^^}"
  [[ "$v" =~ ^[0-9]+[MGT]?$ ]] || {
    echo 0
    return
  }
  case "$v" in
  *M) echo $(((${v%M} + 1023) / 1024)) ;;
  *G) echo "${v%G}" ;;
  *T) echo $((${v%T} * 1024)) ;;
  *) echo "${v:-0}" ;;
  esac
}

ttl_seconds() {
  [[ "$1" =~ ^([1-9][0-9]{0,4})([mhd])$ ]] || return 1
  case "${BASH_REMATCH[2]}" in
  m) echo $((BASH_REMATCH[1] * 60)) ;;
  h) echo $((BASH_REMATCH[1] * 3600)) ;;
  d) echo $((BASH_REMATCH[1] * 86400)) ;;
  esac
}

wait_for_vm() {
  local vm="$1" timeout="${2:-300}" start=$SECONDS ip
  while [ $((SECONDS - start)) -lt "$timeout" ]; do
    ip=$(get_vm_ip "$vm")
    if valid_vm_ip "$ip" && timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/22"' _ "$ip" 2>/dev/null; then
      echo "$ip"
      return 0
    fi
    sleep 3
  done
  return 1
}

vnc_password() { head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-8; }

# QEMU only takes a VNC password set before it starts, and other local users
# can read a root process's arguments, so it goes into the XML through the
# environment: virt-install prints the domain, dcvm defines and starts it.
virt_install_with_vnc_password() {
  local pw="$1" xml name
  shift
  xml=$(mktemp) || return 1
  if ! "$@" --print-xml >"$xml.all" || ! VNC_PW="$pw" python3 -I -S -c '
import os, re, sys, xml.etree.ElementTree as ET
docs = re.findall(r"<domain[\s\S]*?</domain>", open(sys.argv[1]).read())
d = ET.fromstring(docs[-1])
for g in d.iter("graphics"):
    g.set("passwd", os.environ["VNC_PW"])
open(sys.argv[2], "w").write(ET.tostring(d, encoding="unicode"))
print(d.findtext("name"))' "$xml.all" "$xml" >"$xml.name"; then
    rm -f "$xml" "$xml.all" "$xml.name"
    return 1
  fi
  name=$(cat "$xml.name")
  local rc=0
  virsh define "$xml" >/dev/null || rc=1
  if [ "$rc" -eq 0 ] && ! virsh start "$name" >/dev/null; then
    rc=1
    virsh undefine "$name" --nvram >/dev/null 2>&1 || virsh undefine "$name" >/dev/null 2>&1
  fi
  rm -f "$xml" "$xml.all" "$xml.name"
  return $rc
}

vnc_password_of() { virsh dumpxml --security-info -- "$1" 2>/dev/null | sed -n "s/.*<graphics[^>]* passwd='\([^']*\)'.*/\1/p" | head -1; }

cleanup_port_forwarding_for_vm() {
  local vm_ip="$1"
  local ssh_port="$2"
  local http_port="$3"

  print_info "Cleaning up port forwarding rules"

  if [ -n "$ssh_port" ] && [ -n "$http_port" ]; then
    local rule args
    # By port and destination, whatever else the rule matches: older rules have no address match.
    while read -r rule; do
      read -ra args <<<"${rule#-A }"
      iptables -t nat -D "${args[@]}" 2>/dev/null && print_info "Removed port rule: ${rule#-A PREROUTING }" || true
    done < <(iptables -t nat -S PREROUTING 2>/dev/null | awk -v s="$ssh_port $vm_ip:22" -v h="$http_port $vm_ip:80" '
      $1 == "-A" { d = t = ""; for (i = 2; i < NF; i++) { if ($i == "--dport") d = $(i + 1); if ($i == "--to-destination") t = $(i + 1) }
        if (d " " t == s || d " " t == h) print }')
    iptables -D FORWARD -p tcp -d "$vm_ip" --dport 22 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -p tcp -d "$vm_ip" --dport 80 -j ACCEPT 2>/dev/null || true
  else
    print_info "Searching and removing all rules with IP $vm_ip"
    local nat_rules=$(iptables -t nat -L PREROUTING -n --line-numbers | grep -wF "$vm_ip" | awk '{print $1}' | tac)
    for rule_num in $nat_rules; do
      iptables -t nat -D PREROUTING "$rule_num" 2>/dev/null && print_info "Removed NAT rule $rule_num" || true
    done

    local forward_rules=$(iptables -L FORWARD -n --line-numbers | grep -wF "$vm_ip" | awk '{print $1}' | tac)
    for rule_num in $forward_rules; do
      iptables -D FORWARD "$rule_num" 2>/dev/null && print_info "Removed FORWARD rule $rule_num" || true
    done
  fi

  save_iptables_rules
}

register_vm() {
  local vm="$1"
  shift
  registry_set "$vm" "owner_uid=$(caller_uid)" "owner=$(caller_user)" "state=ready" "created=$(date +%s)" "$@"
}

is_vm_in_network() {
  vm_visible "$1" || return 1
  local vm_name="$1"
  local network_name="${NETWORK_NAME:-datacenter-net}"
  virsh domiflist "$vm_name" 2>/dev/null | grep -q "$network_name"
}

get_port_mappings_file() {
  echo "${DATACENTER_BASE:-/srv/datacenter}/port-mappings.txt"
}

read_port_mappings() {
  local file=$(get_port_mappings_file)
  [ -f "$file" ] && grep -v "^#" "$file" | grep -v "^$"
}

# libvirt's pidfile, checked against the command line: a pgrep pattern also
# matches other VMs whose names contain this one.
vm_qemu_pid() {
  local pid
  pid=$(cat "/run/libvirt/qemu/$1.pid" 2>/dev/null) && [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  tr '\0' '\n' <"/proc/$pid/cmdline" 2>/dev/null | grep -qxF -e "guest=$1,debug-threads=on" -e "guest=$1" -e "$1" || return 1
  echo "$pid"
}

NFS_SQUASH_USER=dcvm-nfs

# With no_root_squash, root in any VM could plant a setuid-root file that every
# host user can run. all_squash maps every NFS user to one unprivileged account.
nfs_unsafe_files() {
  find "$1" \( \( -perm /4000 ! -user "$2" \) -o \( -perm /2000 ! -group "$3" \) -o -type b -o -type c \) "${@:4}" 2>/dev/null
}

nfs_share_secure() {
  local share="$1" uid gid
  uid=$(id -u "$NFS_SQUASH_USER" 2>/dev/null) && gid=$(id -g "$NFS_SQUASH_USER") || return 1
  awk -v p="$share" -v u="anonuid=$uid" '$1 == p && $2 ~ /all_squash/ && index($2, u) { f = 1 } END { exit !f }' /etc/exports 2>/dev/null || return 1
  [ "$(stat -c '%u %a' "$share" 2>/dev/null)" = "$uid 700" ] || return 1
  [ -z "$(nfs_unsafe_files "$share" "$uid" "$gid" -print -quit)" ]
}

secure_nfs_share() {
  local share="$1" subnet="$2" uid gid quarantine f rel moved=0 tmp
  if ! id -u "$NFS_SQUASH_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --home-dir /nonexistent --shell "$(command -v nologin || echo /bin/false)" "$NFS_SQUASH_USER" || return 1
  fi
  uid=$(id -u "$NFS_SQUASH_USER") gid=$(id -g "$NFS_SQUASH_USER")
  mkdir -p "$share" || return 1
  quarantine="${DATACENTER_BASE:-/srv/datacenter}/quarantine/nfs-$(date +%Y%m%d%H%M%S)"
  while IFS= read -r -d '' f; do
    rel=${f#"$share"/}
    mkdir -p "$quarantine/$(dirname "$rel")" && chmod 700 "${quarantine%/*}" "$quarantine" &&
      mv -- "$f" "$quarantine/$rel" && chmod a-s "$quarantine/$rel" 2>/dev/null
    moved=$((moved + 1))
  done < <(nfs_unsafe_files "$share" "$uid" "$gid" -print0)
  chown -R "$uid:$gid" "$share" && chmod 700 "$share" || return 1
  tmp=$(mktemp) || return 1
  {
    awk -v p="$share" '$1 != p' /etc/exports 2>/dev/null
    echo "$share ${subnet}.0/24(rw,sync,no_subtree_check,all_squash,anonuid=$uid,anongid=$gid)"
  } >"$tmp" &&
    cat "$tmp" >/etc/exports
  rm -f "$tmp"
  command_exists exportfs && exportfs -ra 2>/dev/null
  NFS_QUARANTINED=$moved NFS_QUARANTINE_DIR=$quarantine
}

check_vm_exists() {
  virsh dominfo -- "$1" >/dev/null 2>&1
}

vm_exists() { check_vm_exists "$@"; }

list_all_vms() {
  virsh list --all | grep -E "(running|shut off)" | while read line; do
    vm=$(echo "$line" | awk '{print $2}')
    state=$(echo "$line" | awk '{print $3}')
    [ -n "$vm" ] && [ "$vm" != "Name" ] && printf "  %-15s: %s\n" "$vm" "$state"
  done
}

list_datacenter_vm_names() {
  list_datacenter_vms | awk -F': ' '{ gsub(/^ +| +$/, "", $1); print $1 }'
}

list_datacenter_vms() {
  virsh list --all | grep -E "(running|shut off)" | while read line; do
    vm=$(echo "$line" | awk '{print $2}')
    state=$(echo "$line" | awk '{print $3}')
    if [ -n "$vm" ] && [ "$vm" != "Name" ] && is_vm_in_network "$vm"; then
      printf "  %-15s: %s\n" "$vm" "$state"
    fi
  done
}

get_host_ip() {
  local ip
  ip=$(grep "^DATACENTER_IP=" "${1:-/etc/dcvm-install.conf}" 2>/dev/null | cut -d'=' -f2 | tr -d '"')
  echo "${ip:-$(detect_host_ip)}"
}

check_ping() {
  local ip="$1"
  ping -c 1 -W 2 "$ip" >/dev/null 2>&1
}

require_confirmation() {
  local message="$1"
  print_warning "$message"
  confirm_action "Are you sure?" || exit 0
}

validate_memory_size() {
  local memory="$1"
  local max_memory="${2:-$MAX_VM_MEMORY}"

  [[ ! "$memory" =~ ^[0-9]+$ ]] && return 1
  [ "$memory" -lt 512 ] && return 1
  [ "$memory" -gt "$max_memory" ] && return 2
  return 0
}

validate_cpu_count() {
  local cpus="$1"
  local max_cpus="${2:-$MAX_VM_CPUS}"

  [[ ! "$cpus" =~ ^[0-9]+$ ]] && return 1
  [ "$cpus" -lt 1 ] && return 1
  [ "$cpus" -gt "$max_cpus" ] && return 2
  return 0
}

validate_disk_size() {
  local disk_size="$1"

  [[ ! "$disk_size" =~ ^[0-9]+[GMT]$ ]] && return 1

  local size_num=$(echo "$disk_size" | sed 's/[GMT]$//')
  local size_unit=$(echo "$disk_size" | sed 's/^[0-9]*//')

  case "$size_unit" in
  "M") [ "$size_num" -lt 100 ] && return 1 ;;
  "G") [ "$size_num" -lt 1 ] || [ "$size_num" -gt 1000 ] && return 1 ;;
  "T") [ "$size_num" -gt 10 ] && return 1 ;;
  esac
  return 0
}

stop_vm_gracefully() {
  local vm_name="$1"
  local timeout="${2:-60}"

  if ! virsh list | grep -q " $vm_name .*running"; then
    return 0
  fi

  virsh shutdown "$vm_name" >/dev/null 2>&1

  local count=0
  while [ $count -lt $timeout ]; do
    if ! virsh list | grep -q " $vm_name .*running"; then
      return 0
    fi
    sleep 2
    count=$((count + 2))
  done

  virsh destroy "$vm_name" >/dev/null 2>&1
  return 0
}

filter_lease_lines() {
  awk -v v="$1" -v f="$2" '
    function has_mac(h) {
      h = "[0-9a-f][0-9a-f]"
      return tolower($3) ~ ("^" h ":" h ":" h ":" h ":" h ":" h "$")
    }
    v != "" && has_mac() && tolower($f) == tolower(v)'
}

# Release the lease of MAC $1 and/or hostname $2 (whole field, any case) in
# libvirt's dnsmasq with dhcp_release, and drop it from the libvirt status
# file. libvirt runs dnsmasq with --leasefile-ro, so the status file is the
# only lease store, and SIGHUP does not drop leases. Never restarts the
# network. Runs under a lock so parallel cleanups do not undo each other's
# edits.
# Returns 0 when a lease was cleared, 1 when nothing matched (no MAC/host given, empty or missing status file, no matching entry), 2 on any failure (dhcp_release or jq missing, lock timeout, unreadable or unparseable status file, mktemp failure, status file write failed, dhcp_release failed).
cleanup_dhcp_lease() {
  local lock="${DNSMASQ_DIR:-/var/lib/libvirt/dnsmasq}/${BRIDGE_NAME}.dcvm.lock"
  if ! command_exists flock || ! { : >>"$lock"; } 2>/dev/null; then
    cleanup_dhcp_lease_unlocked "$@"
    return
  fi
  (
    flock -w 30 9 || {
      print_error "Timed out waiting for $lock"
      exit 2
    }
    cleanup_dhcp_lease_unlocked "$@"
  ) 9>>"$lock"
}

cleanup_dhcp_lease_unlocked() {
  local mac="${1,,}" host="${2,,}"
  # The guest picks its own DHCP hostname; with a MAC, a hostname match could free another VM's lease.
  [ -n "$mac" ] && host=""
  local status_file="${DNSMASQ_DIR:-/var/lib/libvirt/dnsmasq}/${BRIDGE_NAME}.status"
  local tmp matches lmac ip n rc=0

  [ -z "$mac" ] && [ -z "$host" ] && return 1
  print_info "Clearing DHCP lease for MAC: ${mac:-unknown}, VM: ${2:-unknown}"

  if ! command_exists dhcp_release; then
    print_error "dhcp_release not found; cannot release the lease in dnsmasq (install dnsmasq-utils on Debian/Ubuntu, dnsmasq on Arch)"
    return 2
  fi
  if [ ! -s "$status_file" ]; then
    print_info "No matching DHCP lease found"
    return 1
  fi
  if ! command_exists jq; then
    print_error "jq not available; the lease is still listed in $status_file (install jq)"
    return 2
  fi
  if ! tmp=$(mktemp); then
    print_error "Could not create a temp file; $status_file left unchanged"
    return 2
  fi
  # shellcheck disable=SC2016 # jq variables
  local sel='(($mac != "" and ((."mac-address" // "") | ascii_downcase) == $mac) or
    ($host != "" and ((.hostname // "") | ascii_downcase) == $host))'
  if ! jq -e 'type == "array"' "$status_file" >/dev/null 2>&1 ||
    ! matches=$(jq -r --arg mac "$mac" --arg host "$host" ".[] | select($sel) | [(.\"mac-address\" // \"\"), (.\"ip-address\" // \"\")] | @tsv" "$status_file" 2>/dev/null) ||
    ! jq --arg mac "$mac" --arg host "$host" "[.[] | select($sel | not)]" "$status_file" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    print_error "Could not parse $status_file; left unchanged"
    return 2
  fi
  if [ -z "$matches" ]; then
    rm -f "$tmp"
    print_info "No matching DHCP lease found"
    return 1
  fi

  # Write the status file first: dnsmasq's release makes libvirt's lease
  # helper rewrite it, and that write must come last.
  n=$(($(jq length "$status_file") - $(jq length "$tmp")))
  if ! cat "$tmp" >"$status_file"; then
    rm -f "$tmp"
    print_error "Could not write $status_file; no lease was released"
    return 2
  fi
  rm -f "$tmp"
  while IFS=$'\t' read -r lmac ip; do
    [[ "$ip" == *.* ]] && [ -n "$lmac" ] || continue
    dhcp_release "$BRIDGE_NAME" "$ip" "$lmac" 2>/dev/null || {
      print_error "dhcp_release failed for $ip ($lmac); dnsmasq keeps it until it expires"
      rc=2
    }
  done <<<"$matches"
  if [ "$rc" = 0 ]; then
    print_info "Released and removed $n lease(s) from $status_file"
  else
    print_info "Removed $n lease(s) from $status_file"
  fi
  return "$rc"
}

# MACs (lower case) of every interface of every defined domain; fails when libvirt does not answer.
domain_macs() {
  local names d
  names=$(virsh list --all --name 2>/dev/null) || return 1
  while read -r d; do
    [ -n "$d" ] && virsh domiflist -- "$d" 2>/dev/null | awk 'NR > 2 && $5 ~ /:/ { print tolower($5) }'
  done <<<"$names"
}

# Status-file leases whose MAC belongs to no defined domain, whatever the guest
# calls itself; by hostname only when the lease has no MAC. One line each:
# mac, ip, hostname, reason separated by | (dnsmasq allows no | in hostnames).
stale_leases() {
  local status="${DNSMASQ_DIR:-/var/lib/libvirt/dnsmasq}/${BRIDGE_NAME}.status" macs vms
  macs=$(domain_macs) || return 1
  vms=$(virsh list --all --name 2>/dev/null | tr '[:upper:]' '[:lower:]')
  [ -s "$status" ] || return 0
  # shellcheck disable=SC2016 # jq variables
  jq -r --arg macs "$macs" --arg vms "$vms" --argjson now "$(date +%s)" '
    ($macs | split("\n")) as $m | ($vms | split("\n")) as $v | . as $all | .[]
    | ((."mac-address" // "") | ascii_downcase) as $mac | ((.hostname // "") | ascii_downcase) as $h
    | select(if $mac != "" then ($m | index($mac)) == null
      else $h != "" and ($v | index($h)) == null
        and ([$all[] | select((."mac-address" // "") != "" and ((.hostname // "") | ascii_downcase) == $h)] | length) == 0 end)
    | [$mac, (."ip-address" // ""), (.hostname // ""),
      ((if $mac != "" then "no VM has this MAC" else "no VM named \(.hostname)" end)
        + (if (."expiry-time" // 0) < $now then ", expired" else "" end))] | join("|")' "$status"
}

interactive_prompt_memory_common() {
  local var_name="${1:-VM_MEMORY}"
  local host_mem=$(free -m | awk '/^Mem:/ {print $2}')
  local max_mem=$((host_mem * 75 / 100))
  local result=""

  while true; do
    read -p "Memory in MB (available: ${host_mem}MB, recommended max: ${max_mem}MB) [2048]: " result || no_input
    result=${result:-2048}
    if [[ ! "$result" =~ ^[0-9]+$ ]]; then
      print_error "Memory must be a number"
      continue
    fi
    if [ "$result" -lt 512 ]; then
      print_error "Memory must be at least 512MB"
      continue
    fi
    if [ "$result" -gt "$max_mem" ]; then
      print_warning "Requested ${result}MB exceeds recommended ${max_mem}MB"
      read -p "Continue anyway? (y/N): " cont || no_input
      [[ ! "$cont" =~ ^[Yy]$ ]] && continue
    fi
    break
  done
  printf -v "$var_name" '%s' "$result"
}

interactive_prompt_cpus_common() {
  local var_name="${1:-VM_CPUS}"
  local host_cpus=$(nproc)
  local max_cpus=$((host_cpus > 1 ? host_cpus - 1 : 1))
  local result=""

  while true; do
    read -p "Number of CPUs (available: ${host_cpus}, recommended max: ${max_cpus}) [2]: " result || no_input
    result=${result:-2}
    if [[ ! "$result" =~ ^[0-9]+$ ]]; then
      print_error "CPU count must be a number"
      continue
    fi
    if [ "$result" -lt 1 ]; then
      print_error "CPU count must be at least 1"
      continue
    fi
    if [ "$result" -gt "$max_cpus" ]; then
      print_warning "Requested ${result} CPUs exceeds recommended ${max_cpus}"
      read -p "Continue anyway? (y/N): " cont || no_input
      [[ ! "$cont" =~ ^[Yy]$ ]] && continue
    fi
    break
  done
  printf -v "$var_name" '%s' "$result"
}

interactive_prompt_disk_common() {
  local var_name="${1:-VM_DISK_SIZE}"
  local result=""

  while true; do
    read -p "Disk size (formats: 20G, 512M, 1T) [20G]: " result || no_input
    result=${result:-20G}
    result=${result^^}
    if [[ ! "$result" =~ ^[0-9]+[GMT]$ ]]; then
      print_error "Invalid format. Use number + G/M/T (e.g., 20G, 512M, 1T)"
      continue
    fi
    local size_num=$(echo "$result" | sed 's/[GMT]$//')
    local size_unit=$(echo "$result" | sed 's/^[0-9]*//')
    case "$size_unit" in
    "M") [ "$size_num" -lt 100 ] && {
      print_error "Minimum disk size is 100M"
      continue
    } ;;
    "G") [ "$size_num" -lt 1 ] || [ "$size_num" -gt 1000 ] && {
      print_error "Disk size must be between 1G and 1000G"
      continue
    } ;;
    "T") [ "$size_num" -gt 10 ] && {
      print_error "Maximum disk size is 10T"
      continue
    } ;;
    esac
    break
  done
  printf -v "$var_name" '%s' "$result"
}

detect_host_ip() {
  local host_ip=""
  local subnet="${NETWORK_SUBNET:-10.10.10}"
  local subnet_re="${subnet//./\\.}"
  for interface in eth0 ens3 ens18 enp0s3 wlan0; do
    host_ip=$(ip addr show "$interface" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -1)
    [ -n "$host_ip" ] && [[ ! "$host_ip" =~ ^127\. ]] && [[ ! "$host_ip" =~ ^${subnet_re}\. ]] && break
  done
  [ -z "$host_ip" ] && host_ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}')
  [ -z "$host_ip" ] && host_ip="YOUR_HOST_IP"
  echo "$host_ip"
}

get_fix_lock_script_path() {
  local script_dir="${1:-}"
  if [ -n "$script_dir" ] && [ -f "$script_dir/../utils/fix-lock.sh" ]; then
    echo "$script_dir/../utils/fix-lock.sh"
  elif [ -f "/usr/local/lib/dcvm/utils/fix-lock.sh" ]; then
    echo "/usr/local/lib/dcvm/utils/fix-lock.sh"
  else
    echo ""
  fi
}

validate_ip_in_subnet() {
  local ip="$1"
  local subnet="${NETWORK_SUBNET:-10.10.10}"
  local subnet_re="${subnet//./\\.}"

  if [[ ! "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    print_error "Invalid IP address format: $ip"
    return 1
  fi

  local oct1="${BASH_REMATCH[1]}"
  local oct2="${BASH_REMATCH[2]}"
  local oct3="${BASH_REMATCH[3]}"
  local oct4="${BASH_REMATCH[4]}"

  if [ "$oct1" -gt 255 ] || [ "$oct2" -gt 255 ] || [ "$oct3" -gt 255 ] || [ "$oct4" -gt 255 ]; then
    print_error "Invalid IP address: octets must be 0-255"
    return 1
  fi

  if [[ ! "$ip" =~ ^${subnet_re}\. ]]; then
    print_error "IP address $ip is not in subnet ${subnet}.0/24"
    print_info "Valid range: ${subnet}.2 - ${subnet}.254"
    return 1
  fi

  if [ "$oct4" -lt 2 ] || [ "$oct4" -gt 254 ]; then
    print_error "Last octet must be between 2-254 (1 is gateway, 255 is broadcast)"
    return 1
  fi

  return 0
}

interactive_prompt_static_ip_common() {
  local var_name="${1:-STATIC_IP}"
  local subnet="${NETWORK_SUBNET:-10.10.10}"
  local result=""

  echo ""
  print_info "Static IP Configuration..."
  echo "  Network subnet: ${subnet}.0/24"
  echo "  Gateway: ${subnet}.1"
  echo "  Valid range: ${subnet}.2 - ${subnet}.254"
  echo ""

  while true; do
    read -p "Use static IP? (y/N, default: DHCP): " use_static || no_input
    use_static=${use_static:-n}

    if [[ "$use_static" =~ ^[Nn]$ ]]; then
      result=""
      print_success "Using DHCP for automatic IP assignment"
      break
    elif [[ "$use_static" =~ ^[Yy]$ ]]; then
      while true; do
        read -p "Enter static IP (e.g., ${subnet}.50): " result || no_input
        if [ -z "$result" ]; then
          print_error "IP address cannot be empty"
          continue
        fi
        if validate_ip_in_subnet "$result"; then
          print_success "Static IP set to: $result"
          break 2
        fi
      done
    else
      print_error "Please enter 'y' for static IP or 'n' for DHCP"
    fi
  done
  printf -v "$var_name" '%s' "$result"
}

default_username() {
  local os_choice="$1"
  os_choice=$(echo "$os_choice" | sed 's/[0-9.].*$//')
  local os_list=("ubuntu" "debian" "archlinux" "kali" "fedora")
  if [[ " ${os_list[*]} " == *" $os_choice "* ]]; then
    echo "$os_choice"
  else
    echo "osadmin" # cannot use admin because its reserved in some OSes
  fi
}

export -f print_info print_success print_warning print_error print_status ui_quiet ui_title ui_step ui_run ui_box ui_next ui_table
export -f log log_message log_to_file
export -f load_dcvm_config require_root check_permissions command_exists check_dependencies
export -f validate_vm_name validate_vm_name_list validate_package_list trim_whitespace validate_username validate_password
export -f vm_exists get_vm_state get_vm_ip get_vm_mac get_vm_disk_path get_vm_username valid_vm_ip
export -f registry_file registry_get caller_uid caller_user caller_role vm_owner_uid vm_visible
export -f read_password generate_password_hash generate_random_mac
export -f format_bytes create_dir_safe backup_file confirm_action
export -f get_system_info get_host_info
export -f check_port_connectivity check_port_forward is_vm_in_network get_port_mappings_file read_port_mappings
export -f check_vm_exists list_all_vms list_datacenter_vms get_host_ip check_ping require_confirmation
export -f validate_memory_size validate_cpu_count validate_disk_size stop_vm_gracefully
export -f detect_host_ip get_fix_lock_script_path
export -f filter_lease_lines cleanup_dhcp_lease cleanup_dhcp_lease_unlocked
export -f validate_ip_in_subnet interactive_prompt_static_ip_common
export -f interactive_prompt_memory_common interactive_prompt_cpus_common interactive_prompt_disk_common default_username
