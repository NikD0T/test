#!/bin/bash
# This script is intended to be run on Alpine LiveCD with Bash.
# It will do necessary work in live system and then mount alredy LUKSefiyd system and download and run the special script for installed system.

# === COLOR HELPERS ===
p_yellow() { echo -ne "\e[0;33m$1\e[0m"; }
p_bright_yellow() { echo -ne "\e[1;33m$1\e[0m"; }
p_gray() { echo -ne "\e[1;37m$1\e[0m"; }
p_red() { echo -ne "\e[0;31m$1\e[0m"; }
p_bright_red() { echo -ne "\e[1;31m$1\e[0m"; }
p_green() { echo -ne "\e[0;32m$1\e[0m"; }
p_bright_green() { echo -ne "\e[1;32m$1\e[0m"; }

p_mark() {
  local required="$1"
  local t="$2"
  if [[ "$t" == *"["*"]"* ]]; then
    local before="${t%%\[*}"
    local inner="${t#*\[}"
    inner="${inner%%\]*}"
    local after="${t#*\]}"
    after="${after# }"

    printf -v inner "%2s" "$inner"

    p_yellow "${before}[${inner}]"
    if [[ "$required" == "y" ]]; then
      p_bright_red " *"
    else
      p_yellow "  "
    fi
    p_yellow "$after"
  else
    local indent="${t%%[^ ]*}"
    local rest="${t#$indent}"
    p_yellow "$indent"
    if [[ "$required" == "y" ]]; then
      p_bright_red "*"
    else
      p_yellow " "
    fi
    p_yellow "$rest"
  fi
}

msg() {
  local color=$1 text=$2
  "p_${color}" "$text"
  echo
}

# === ROOT CHECK ===
if [[ $EUID -ne 0 ]]; then
  msg red "No root access. Exiting."
  exit 1
fi

# === LIVECD CHECK ===
[[ "$(awk '$2 == "/" { print $3 }' /proc/mounts)" != "tmpfs" ]] && {
  msg red "This script must be run from LiveCD. Exiting."
  exit 1
}

# === OS CHECK ===
[[ -f /etc/os-release ]] && . /etc/os-release
if [[ "$ID" != "alpine" ]]; then
  msg red "This script is intended to be run on Alpine. Exiting."
  exit 1
fi

VERSION_ID_MAJOR="${VERSION_ID%%.*}"
VERSION_ID_MINOR="${VERSION_ID#*.}"
VERSION_ID_MINOR="${VERSION_ID_MINOR%%.*}"
if [ "$VERSION_ID_MAJOR" -lt 3 ] || { [ "$VERSION_ID_MAJOR" -eq 3 ] && [ "$VERSION_ID_MINOR" -lt 24 ]; }; then
  msg red "Alpine 3.24+ required. Current version: $VERSION_ID. Exiting."
  exit 1
fi

# === SUPPORTED TARGET SYSTEMS ===
declare -A SUPPORTED_SYSTEMS
# Format: [distro_id]="min_version:fs_type1,fs_type2,..."
SUPPORTED_SYSTEMS["debian"]="13:ext4"

# === BASH VERSION CHECK ===
if [[ ${BASH_VERSINFO[0]} -lt 4 || (${BASH_VERSINFO[0]} -eq 4 && ${BASH_VERSINFO[1]} -lt 3) ]]; then
  msg red "Bash 4.3+ required (current: ${BASH_VERSION}). Exiting."
  exit 1
fi

# === INTERNET CHECK ===
if ! ping -c 1 1.1.1 &>/dev/null && ! ping -c 1 8.8.8.8 &>/dev/null; then
  msg red "No internet connection. Exiting."
  exit 1
fi

if ! ping -c 1 cloudflare.com &>/dev/null && ! ping -c 1 google.com &>/dev/null; then
  msg red "Please check your DNS settings. Exiting."
  exit 1
fi

# === CONFIG STORAGE ===
CONFIG_FILE="/var/lib/luks-config"

config_set() {
  local key="$1" val="$2"
  sed -i "/^${key}=/d" "$CONFIG_FILE" 2>/dev/null
  printf '%s=%s\n' "$key" "$val" >>"$CONFIG_FILE"
}

config_get() {
  [[ -f "$CONFIG_FILE" ]] && awk -F= -v k="$1" '$1==k {print $2; exit}' "$CONFIG_FILE" || echo ""
}

# === VERSION COMPARISON ===
ver_ge() {
  local v1="${1%%.*}" v2="${2%%.*}"
  [[ "$v1" -ge "$v2" ]]
}

# === TARGET SYSTEM VALIDATION ===
validate_target_system() {
  local distro="$1" version="$2" fstype="$3"
  local -n _out_msg=$4

  if [[ ! -v SUPPORTED_SYSTEMS["$distro"] ]]; then
    _out_msg="Unsupported distribution: $distro"
    return 1
  fi

  local info="${SUPPORTED_SYSTEMS["$distro"]}"
  local min_ver="${info%%:*}"
  local fs_list="${info#*:}"

  if ! ver_ge "$version" "$min_ver"; then
    _out_msg="$distro $version < minimum $min_ver"
    return 1
  fi

  if [[ ",$fs_list," != *",$fstype,"* ]]; then
    _out_msg="$distro $version: unsupported filesystem $fstype (supported: $fs_list)"
    return 1
  fi

  return 0
}

# === TARGET NETWORK INTERFACES DETECTION ===
detect_target_interfaces() {
  local root_mnt="$1"
  local -a ifaces=()
  local line iface

  if [[ -f "$root_mnt/etc/network/interfaces" ]]; then
    while IFS= read -r line; do
      line="${line%%#*}"
      if [[ "$line" =~ ^[[:space:]]*iface[[:space:]]+([^[:space:]]+)[[:space:]]+(inet|inet6)[[:space:]]+(loopback|dhcp|static|manual|auto) ]]; then
        iface="${BASH_REMATCH[1]}"
        [[ "$iface" != "lo" ]] && ifaces+=("$iface")
      fi
    done <"$root_mnt/etc/network/interfaces"
  fi

  if [[ -d "$root_mnt/etc/systemd/network" ]]; then
    local f
    for f in "$root_mnt/etc/systemd/network/"*.network; do
      [[ -f "$f" ]] || continue
      while IFS= read -r line; do
        line="${line%%#*}"
        if [[ "$line" =~ ^Name=([^[:space:]]+) ]]; then
          iface="${BASH_REMATCH[1]}"
          [[ "$iface" != "lo" ]] && ifaces+=("$iface")
        fi
      done <"$f"
    done
  fi

  if [[ ${#ifaces[@]} -gt 0 ]]; then
    local -A seen
    local -a unique=()
    for iface in "${ifaces[@]}"; do
      [[ -v seen["$iface"] ]] && continue
      seen["$iface"]=1
      unique+=("$iface")
    done
    echo "${unique[*]}"
  fi
}

# === UI HELPERS ===
TAB_NAMES=(
  "Disk Selection"
  "Dropbear Configuration"
  "Confirmation"
)

render_header() {
  local page=$1
  echo ""
  p_gray "─────────────────────────────────────────────────────────────────"
  echo ""
  local i
  for ((i = 1; i <= ${#TAB_NAMES[@]}; i++)); do
    if [[ $i -eq $page ]]; then
      p_bright_yellow " [ ${TAB_NAMES[$((page - 1))]} ] "
    else
      p_gray " [$i] "
    fi
  done
  echo ""
  p_gray "─────────────────────────────────────────────────────────────────"
  echo ""
}

# === PAGE 1: DISK SELECTION ===
find_boot_device() {
  local root_mnt="$1" root_part="$2"

  if [[ -f "$root_mnt/etc/fstab" ]]; then
    local boot_spec
    boot_spec=$(awk '$2 == "/boot" {print $1; exit}' "$root_mnt/etc/fstab" 2>/dev/null)
    if [[ -n "$boot_spec" ]]; then
      if [[ "$boot_spec" == UUID=* ]]; then
        local uuid="${boot_spec#UUID=}"
        blkid -U "$uuid" 2>/dev/null && return
      elif [[ "$boot_spec" == LABEL=* ]]; then
        local label="${boot_spec#LABEL=}"
        blkid -L "$label" 2>/dev/null && return
      else
        echo "$boot_spec"
        return
      fi
    fi
  fi

  if [[ -d "$root_mnt/boot" ]] && [[ -n "$(ls -A "$root_mnt/boot" 2>/dev/null)" ]]; then
    echo "$root_part"
    return
  fi

  echo ""
}

scan_systems() {
  local -n _root_ref=$1 _distro_ref=$2 _ver_ref=$3 _boot_ref=$4 _skip_ref=$5 _ifaces_ref=$6
  _root_ref=()
  _distro_ref=()
  _ver_ref=()
  _boot_ref=()
  _skip_ref=()
  _ifaces_ref=()

  local tmp_mnt
  tmp_mnt=$(mktemp -d)

  while IFS= read -r part; do
    [[ -z "$part" ]] && continue
    local devpath="/dev/$part"
    local fstype
    fstype=$(lsblk -ln -o FSTYPE "$devpath" 2>/dev/null)

    case "$fstype" in
    ext4 | ext3 | ext2 | xfs | btrfs) ;;
    *) continue ;;
    esac

    if mount "$devpath" "$tmp_mnt" 2>/dev/null; then
      if [[ -f "$tmp_mnt/etc/os-release" ]]; then
        local id="" version_id=""
        id=$(awk -F= '/^ID=/ {gsub(/"/,"",$2); print $2}' "$tmp_mnt/etc/os-release")
        version_id=$(awk -F= '/^VERSION_ID=/ {gsub(/"/,"",$2); print $2}' "$tmp_mnt/etc/os-release")

        local reason=""
        if validate_target_system "$id" "$version_id" "$fstype" reason; then
          _root_ref+=("$devpath")
          _distro_ref+=("$id")
          _ver_ref+=("$version_id")
          _boot_ref+=("$(find_boot_device "$tmp_mnt" "$devpath")")
          _ifaces_ref+=("$(detect_target_interfaces "$tmp_mnt")")
        else
          _skip_ref+=("$devpath: $reason")
          _ifaces_ref+=("")
        fi
      fi
      umount "$tmp_mnt" 2>/dev/null
    fi
  done < <(lsblk -ln -o NAME,TYPE | awk '$2=="part" {print $1}')

  rm -rf "$tmp_mnt"
}

page_disks() {
  while true; do
    render_header 1

    local root boot distro ver pass
    root=$(config_get SELECTED_ROOT_DEVICE)
    boot=$(config_get SELECTED_BOOT_DEVICE)
    distro=$(config_get SELECTED_DISTRO)
    ver=$(config_get SELECTED_VERSION)
    pass=$(config_get LUKS_PASSWORD)

    echo ""
    p_mark n "  [1] Select system partition: "
    if [[ -n "$root" ]]; then
      p_bright_yellow "$root — $distro $ver"
      echo ""
      p_gray "       Boot: "
      p_bright_yellow "$boot"
    else
      p_gray "(not selected)"
    fi
    echo ""
    echo ""
    p_mark n "  [2] LUKS password: "
    [[ -n "$pass" ]] && p_gray "[set]" || p_gray "(not set)"
    echo ""
    echo ""
    msg gray "  [ 0]  Back"
    echo ""
    read -r -e -p "$(p_bright_yellow "  > ")" input || return

    case "$input" in
    0) return ;;

    1)
      while true; do
        local -a root_devices=()
        local -a distro_ids=()
        local -a distro_versions=()
        local -a boot_devices=()
        local -a skip_reasons=()
        local -a ifaces_per_part=()

        scan_systems root_devices distro_ids distro_versions boot_devices skip_reasons ifaces_per_part

        if [[ ${#root_devices[@]} -eq 0 ]]; then
          msg bright_red "  No supported Linux installations found."
          local r
          for r in "${skip_reasons[@]}"; do
            msg gray "    - $r"
          done
          echo ""
          msg gray "  [0] Back"
          echo ""
          read -r -e -p "$(p_bright_yellow "  > ")" input || break
          [[ "$input" == "0" ]] && break
          continue
        fi

        echo ""
        local i
        for ((i = 0; i < ${#root_devices[@]}; i++)); do
          local num=$((i + 1))
          local boot_info=""
          if [[ -n "${boot_devices[$i]}" ]]; then
            boot_info=" (boot: ${boot_devices[$i]})"
          fi
          local ifaces_info=""
          if [[ -n "${ifaces_per_part[$i]}" ]]; then
            ifaces_info=", ifaces: ${ifaces_per_part[$i]}"
          fi
          p_mark n "  [$num] ${root_devices[$i]} — ${distro_ids[$i]} ${distro_versions[$i]}${boot_info}${ifaces_info}"
          echo ""
        done

        echo ""
        msg gray "  [0] Back"
        echo ""
        read -r -e -p "$(p_bright_yellow "  Select partition > ")" input || break

        [[ "$input" == "0" ]] && break

        if [[ "$input" =~ ^[0-9]+$ ]] && [[ "$input" -ge 1 && "$input" -le "${#root_devices[@]}" ]]; then
          local idx=$((input - 1))
          config_set SELECTED_ROOT_DEVICE "${root_devices[$idx]}"
          config_set SELECTED_BOOT_DEVICE "${boot_devices[$idx]}"
          config_set SELECTED_DISTRO "${distro_ids[$idx]}"
          config_set SELECTED_VERSION "${distro_versions[$idx]}"
          config_set SELECTED_INTERFACES "${ifaces_per_part[$idx]}"
          break
        else
          msg bright_red "  Invalid selection"
        fi
      done
      ;;

    2)
      while true; do
        echo ""
        read -r -s -p "$(p_yellow "  Enter LUKS password: ")" pass1 || break
        echo ""
        if [[ -z "$pass1" ]]; then
          msg bright_red "  Password cannot be empty"
          continue
        fi
        read -r -s -p "$(p_yellow "  Confirm LUKS password: ")" pass2 || break
        echo ""
        if [[ "$pass1" != "$pass2" ]]; then
          msg bright_red "  Passwords do not match"
          continue
        fi
        config_set LUKS_PASSWORD "$pass1"
        msg green "  Password set"
        break
      done
      ;;

    *) msg bright_red "  Invalid option" ;;
    esac
  done
}

# === VALIDATION FUNCTIONS ===
validate_ssh_key() {
  local val=$1
  [[ -z "$val" ]] && return 1
  local parts=($val)
  [[ ${#parts[@]} -lt 2 ]] && return 1
  case "${parts[0]}" in
  ssh-rsa | ssh-dss | ssh-ed25519 | ecdsa-sha2-nistp256 | ecdsa-sha2-nistp384 | ecdsa-sha2-nistp521) ;;
  *) return 1 ;;
  esac
  [[ "${parts[1]}" =~ ^[A-Za-z0-9+/=]+$ ]] || return 1
  return 0
}

# === PAGE 2: DROPBEAR ===
page_dropbear() {
  while true; do
    render_header 2

    local port pub_key db_iface
    port=$(config_get DB_PORT)
    pub_key=$(config_get DB_PUB_KEY)
    db_iface=$(config_get DB_INTERFACE)

    echo ""
    p_mark n "  [1] Dropbear port: "
    if [[ -n "$port" ]]; then
      p_bright_yellow "$port"
    else
      p_gray "(not set)"
    fi
    echo ""
    echo ""
    p_mark n "  [2] SSH public key: "
    if [[ -n "$pub_key" ]]; then
      p_gray "[public key set]"
    else
      p_gray "(not set — will generate)"
    fi
    echo ""
    echo ""
    p_mark n "  [3] Network interface: "
    if [[ -n "$db_iface" ]]; then
      p_bright_yellow "$db_iface"
    else
      p_gray "(not set)"
    fi
    echo ""
    echo ""
    msg gray "  [ 0]  Back"
    echo ""
    read -r -e -p "$(p_bright_yellow "  > ")" input || return

    case "$input" in
    0) return ;;

    1)
      while true; do
        echo ""
        read -r -e -p "$(p_yellow "  Port (empty for 45055, 1024-65535, /c to cancel): ")" val || break
        [[ "$val" == "/c" ]] && break
        if [[ -z "$val" ]]; then
          config_set DB_PORT "45055"
          break
        elif [[ "$val" =~ ^[0-9]+$ ]] && [[ "$val" -ge 1024 && "$val" -le 65535 ]]; then
          config_set DB_PORT "$val"
          break
        else
          msg bright_red "  Port must be between 1024 and 65535"
        fi
      done
      ;;

    2)
      while true; do
        local cur_key
        cur_key=$(config_get DB_PUB_KEY "")
        echo ""
        [[ -n "$cur_key" ]] && {
          p_yellow "  Current key: "
          p_gray "$cur_key"
          echo ""
        }
        read -r -e -p "$(p_yellow "  SSH public key (empty to generate, /c to cancel): ")" val || break
        [[ "$val" == "/c" ]] && break
        if [[ -z "$val" ]]; then
          local key_dir="/var/lib/luks-keys"
          mkdir -p "$key_dir"
          local key_file="$key_dir/dropbear_ed25519"
          ssh-keygen -t ed25519 -f "$key_file" -N "" -q
          config_set DB_PUB_KEY "$(cat "${key_file}.pub")"
          config_set DB_PRIV_KEY "$key_file"
          msg green "  ED25519 key pair generated"
          break
        elif validate_ssh_key "$val"; then
          config_set DB_PUB_KEY "$val"
          break
        else
          msg bright_red "  Invalid SSH key format"
        fi
      done
      ;;

    3)
      while true; do
        echo ""
        local available
        available=$(config_get SELECTED_INTERFACES)
        if [[ -n "$available" ]]; then
          p_yellow "  Available interfaces: "
          p_gray "$available"
          echo ""
        fi
        local cur_iface
        cur_iface=$(config_get DB_INTERFACE)
        [[ -n "$cur_iface" ]] && {
          p_yellow "  Current: "
          p_gray "$cur_iface"
          echo ""
        }
        read -r -e -p "$(p_yellow "  Interface name (empty to clear, /c to cancel): ")" val || break
        [[ "$val" == "/c" ]] && break
        if [[ -z "$val" ]]; then
          config_set DB_INTERFACE ""
          msg green "  Interface cleared"
          break
        elif [[ "$val" =~ ^[a-zA-Z][a-zA-Z0-9_]+$ ]]; then
          config_set DB_INTERFACE "$val"
          msg green "  Interface set to $val"
          break
        else
          msg bright_red "  Invalid interface name"
        fi
      done
      ;;

    *) msg bright_red "  Invalid option" ;;
    esac
  done
}

# === PAGE 7: CONFIRMATION ===
page_confirmation() {
  while true; do
    render_header 7

    local root boot distro ver pass port pub_key db_iface
    root=$(config_get SELECTED_ROOT_DEVICE)
    boot=$(config_get SELECTED_BOOT_DEVICE)
    distro=$(config_get SELECTED_DISTRO)
    ver=$(config_get SELECTED_VERSION)
    pass=$(config_get LUKS_PASSWORD)
    port=$(config_get DB_PORT)
    pub_key=$(config_get DB_PUB_KEY)
    db_iface=$(config_get DB_INTERFACE)

    echo ""
    p_gray "  ┌─ Disk ─────────────────────────────────────────────"
    echo ""
    p_gray "  │ System:  "
    p_bright_yellow "$root"
    p_gray " — "
    p_bright_yellow "$distro $ver"
    echo ""
    p_gray "  │ Boot:    "
    p_bright_yellow "$boot"
    echo ""
    p_gray "  │ LUKS:    "
    if [[ -n "$pass" ]]; then p_gray "[set]"; else p_bright_red "[not set]"; fi
    echo ""
    p_gray "  └────────────────────────────────────────────────────"
    echo ""
    p_gray "  ┌─ Dropbear ─────────────────────────────────────────"
    echo ""
    p_gray "  │ Port:    "
    p_bright_yellow "$port"
    echo ""
    p_gray "  │ Key:     "
    if [[ -n "$pub_key" ]]; then p_gray "[set]"; else p_bright_red "[not set]"; fi
    echo ""
    p_gray "  │ Iface:   "
    if [[ -n "$db_iface" ]]; then p_bright_yellow "$db_iface"; else p_gray "(not set)"; fi
    echo ""
    p_gray "  └────────────────────────────────────────────────────"
    echo ""
    echo ""
    p_mark y "  [1] Start encryption"
    echo ""
    msg gray "  [ 0]  Back"
    echo ""
    read -r -e -p "$(p_bright_yellow "  > ")" input || return 1

    case "$input" in
    0) return 1 ;;
    1)
      local errors=false
      [[ -z "$root" ]] && {
        msg bright_red "  System partition not selected"
        errors=true
      }
      [[ -z "$pass" ]] && {
        msg bright_red "  LUKS password not set"
        errors=true
      }
      [[ -z "$pub_key" ]] && {
        msg bright_red "  SSH public key not set"
        errors=true
      }
      [[ "$errors" == true ]] && continue
      return 0
      ;;
    *) msg bright_red "  Invalid option" ;;
    esac
  done
}

# === PARTITION HELPERS ===
parse_part_device() {
  local dev="$1"
  local disk="" part=""

  if [[ "$dev" =~ ^(/dev/[a-z]+)([0-9]+)$ ]]; then
    disk="${BASH_REMATCH[1]}"
    part="${BASH_REMATCH[2]}"
  elif [[ "$dev" =~ ^(/dev/nvme[0-9]+n[0-9]+)p([0-9]+)$ ]]; then
    disk="${BASH_REMATCH[1]}"
    part="${BASH_REMATCH[2]}"
  elif [[ "$dev" =~ ^(/dev/mmcblk[0-9]+)p([0-9]+)$ ]]; then
    disk="${BASH_REMATCH[1]}"
    part="${BASH_REMATCH[2]}"
  elif [[ "$dev" =~ ^(/dev/loop[0-9]+)p([0-9]+)$ ]]; then
    disk="${BASH_REMATCH[1]}"
    part="${BASH_REMATCH[2]}"
  fi

  if [[ -n "$disk" && -n "$part" ]]; then
    echo "$disk $part"
  else
    echo ""
  fi
}

# === ENCRYPTION ===
run_encryption() {
  echo ""

  local root boot password
  local new_boot=""
  root=$(config_get SELECTED_ROOT_DEVICE)
  boot=$(config_get SELECTED_BOOT_DEVICE)
  password=$(config_get LUKS_PASSWORD)

  [[ -z "$root" ]] && {
    msg bright_red "  Root device not selected. Aborting."
    return 1
  }
  [[ -z "$password" ]] && {
    msg bright_red "  LUKS password not set. Aborting."
    return 1
  }

  echo ""
  msg yellow "  ═══════════════════════════════════════════"
  msg yellow "  Starting encryption..."
  echo ""

  local boot_needs_create=false
  [[ -z "$boot" || "$boot" == "$root" ]] && boot_needs_create=true

  msg yellow "  [1/7] Configuring repositories and installing packages..."
  setup-apkrepos -1 2>/dev/null
  setup-apkrepos -r 2>/dev/null
  apk update

  apk add cryptsetup e2fsprogs lsblk parted udev

  if [[ $? -ne 0 ]]; then
    msg bright_red "  Failed to install packages. Aborting."
    return 1
  fi

  msg yellow "  [2/7] Checking filesystem..."
  e2fsck -fy "$root"
  echo ""

  local block_size blocks
  block_size=$(dumpe2fs -h "$root" 2>/dev/null | awk -F': ' '/Block size/ {print $2}')
  blocks=$(dumpe2fs -h "$root" 2>/dev/null | awk -F': ' '/Block count/ {print $2}')

  if [[ -z "$block_size" || -z "$blocks" ]]; then
    msg bright_red "  Cannot read filesystem info from $root. Aborting."
    return 1
  fi

  if [[ "$boot_needs_create" == true ]]; then
    msg yellow "  [3/7] Creating separate boot partition..."
    local boot_mb=512 luks_mb=32 total_mb=$((boot_mb + luks_mb))
    local remove_blocks new_blocks

    remove_blocks=$((total_mb * 1024 * 1024 / block_size))
    new_blocks=$((blocks - remove_blocks))

    msg gray "  Shrinking filesystem by ${total_mb}M ($boot_mb M for boot + $luks_mb M for LUKS)..."
    resize2fs "$root" "$new_blocks"

    if [[ $? -ne 0 ]]; then
      msg bright_red "  Failed to shrink filesystem. Aborting."
      return 1
    fi

    local parse disk part
    parse=$(parse_part_device "$root")
    if [[ -z "$parse" ]]; then
      msg bright_red "  Cannot parse device name: $root. Aborting."
      return 1
    fi
    disk="${parse%% *}"
    part="${parse##* }"

    local sector_end new_end_mb
    sector_end=$(parted -s "$disk" unit MiB print | awk -v p="$part" '$1==p {gsub(/MiB$/,"",$3); print $3}')

    if [[ -z "$sector_end" ]]; then
      msg bright_red "  Cannot determine end sector of $root. Aborting."
      return 1
    fi

    new_end_mb=$((sector_end - boot_mb))
    msg gray "  Shrinking partition $root to ${new_end_mb}MiB..."
    parted -s "$disk" resizepart "$part" "${new_end_mb}MiB"

    if [[ $? -ne 0 ]]; then
      msg bright_red "  Failed to shrink partition. Aborting."
      return 1
    fi

    partprobe "$disk"
    udevadm settle

    msg gray "  Creating boot partition at ${new_end_mb}MiB — ${sector_end}MiB..."
    parted -s "$disk" mkpart primary ext4 "${new_end_mb}MiB" "${sector_end}MiB"
    partprobe "$disk"
    udevadm settle

    local new_part_num
    new_part_num=$(parted -s "$disk" print | awk '$1 ~ /^[0-9]+$/ {n=$1} END {print n}')

    if [[ "$disk" =~ /dev/nvme || "$disk" =~ /dev/mmcblk || "$disk" =~ /dev/loop ]]; then
      new_boot="${disk}p${new_part_num}"
    else
      new_boot="${disk}${new_part_num}"
    fi

    msg gray "  New boot partition: $new_boot"
    mkfs.ext4 -F "$new_boot"

    if [[ $? -ne 0 ]]; then
      msg bright_red "  Failed to format boot partition. Aborting."
      return 1
    fi

    config_set SELECTED_BOOT_DEVICE "$new_boot"
    boot="$new_boot"

    local luks_blocks
    luks_blocks=$((luks_mb * 1024 * 1024 / block_size))
    msg gray "  LUKS header space: ${luks_mb}M (inside root partition)"
  else
    msg yellow "  [3/7] Shrinking filesystem to make room for LUKS header..."
    local remove_blocks new_blocks
    remove_blocks=$((32 * 1024 * 1024 / block_size))
    new_blocks=$((blocks - remove_blocks))

    msg gray "  Block size: $block_size, Blocks: $blocks -> $new_blocks"
    resize2fs "$root" "$new_blocks"

    if [[ $? -ne 0 ]]; then
      msg bright_red "  Failed to shrink filesystem. Aborting."
      return 1
    fi
  fi

  msg yellow "  [4/7] Encrypting partition (this may take a very long time)..."
  cryptsetup reencrypt \
    --encrypt \
    --type luks2 \
    --reduce-device-size 32M \
    --batch-mode \
    --verbose \
    --progress-frequency 5 \
    --key-file <(echo -n "$password") \
    "$root"

  if [[ $? -ne 0 ]]; then
    msg bright_red "  Encryption failed. Aborting."
    return 1
  fi

  msg yellow "  [5/7] Opening encrypted device..."
  cryptsetup open --key-file <(echo -n "$password") "$root" cryptroot

  if [[ $? -ne 0 ]]; then
    msg bright_red "  Failed to open encrypted device. Aborting."
    return 1
  fi

  msg yellow "  [6/7] Checking filesystem on encrypted device..."
  e2fsck -fy /dev/mapper/cryptroot
  echo ""

  msg yellow "  [7/7] Mounting encrypted root..."
  mount /dev/mapper/cryptroot /mnt

  if [[ $? -ne 0 ]]; then
    msg bright_red "  Failed to mount encrypted root. Aborting."
    return 1
  fi

  if [[ -n "$boot" ]]; then
    if [[ "$boot_needs_create" == true ]]; then
      msg yellow "  Moving boot contents to new partition..."
      mkdir -p /tmp/bootbak
      cp -a /mnt/boot/. /tmp/bootbak/
      umount /mnt/boot 2>/dev/null || true
      rmdir /mnt/boot 2>/dev/null || true
      mkdir -p /mnt/boot
      mount "$boot" /mnt/boot

      if [[ $? -ne 0 ]]; then
        msg bright_red "  Failed to mount new boot partition."
        return 1
      fi

      cp -a /tmp/bootbak/. /mnt/boot/
      rm -rf /tmp/bootbak
    else
      msg yellow "  Mounting boot partition..."
      mount "$boot" /mnt/boot

      if [[ $? -ne 0 ]]; then
        msg bright_red "  Failed to mount boot partition."
        return 1
      fi
    fi
  fi

  local pub_key priv_key
  pub_key=$(config_get DB_PUB_KEY)
  priv_key=$(config_get DB_PRIV_KEY)

  if [[ -n "$pub_key" ]]; then
    msg yellow "  Deploying SSH keys..."
    mkdir -p /mnt/etc/dropbear/initramfs
    echo "$pub_key" >/mnt/etc/dropbear/initramfs/authorized_keys
    chmod 600 /mnt/etc/dropbear/initramfs/authorized_keys
    msg gray "    Public key  -> /etc/dropbear/initramfs/authorized_keys"

    if [[ -n "$priv_key" && -f "$priv_key" ]]; then
      cp "$priv_key" /mnt/root/
      chmod 600 /mnt/root/"${priv_key##*/}"
      msg gray "    Private key -> /root/${priv_key##*/}"
    fi
  fi

  echo ""
  msg green "  ═══════════════════════════════════════════"
  msg green "  Encryption complete!"
  echo ""
  msg green "    Encrypted root: /dev/mapper/cryptroot -> /mnt"
  if [[ -n "$boot" ]]; then
    msg green "    Boot:           $boot -> /mnt/boot"
  fi
  msg green "  ═══════════════════════════════════════════"
  echo ""

  return 0
}

# === MAIN MENU ===
main_menu() {
  echo ""
  msg red "  [!] Be careful! This script is intended to be run from a LiveCD and to operate on a clean system. A \"clean system\" means a freshly installed system with no user data or configuration."
  msg red "  [!!] The encryption process carries an extremely high risk of data loss."
  msg red "  [!!!] Running this script on a system that is not clean is unsupported. It may fail unexpectedly, terminate with errors, or leave the system in an inconsistent state."

  while true; do
    echo ""
    msg bright_yellow "  disk encryption script by nik durachyo"
    echo ""
    for ((i = 1; i <= #TAB_NAMES[@]; i++)); do
      p_bright_yellow "  [$i] "
      msg yellow "${TAB_NAMES[$((i - 1))]}"
    done
    msg gray "  [0] Exit"
    echo ""
    read -r -e -p "$(p_bright_yellow "  Select page > ")" choice || exit 0

    case "$choice" in
    0)
      msg yellow "Exiting."
      exit 0
      ;;
    1) page_disks ;;
    2) page_dropbear ;;
    3)
      if page_confirmation; then
        break
      fi
      ;;
    *) msg bright_red "  Invalid option" ;;
    esac
  done

  run_encryption
}

# === ENTRY POINT ===
main() {
  main_menu
}

main || exit $?
