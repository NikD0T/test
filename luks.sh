#!/bin/sh
# This script is intended to be run on LiveCD or USB drive with BusyBox.
# It will do necessary work in live system and then download and run the special script for your live system.

# === COLOR HELPERS ===
p_yellow() { printf "\033[0;33m%s\033[0m" "$1"; }
p_red() { printf "\033[0;31m%s\033[0m" "$1"; }

msg() {
  local color=$1 text=$2
  "p_${color}" "$text"
  echo
}

# === ROOT CHECK ===
[ "$(id -u)" -ne 0 ] && {
  msg red "No root access. Exiting."
  exit 1
}

# === LIVECD CHECK ===
[ "$(awk '$2 == "/" { print $3 }' /proc/mounts)" != "tmpfs" ] && {
  msg red "This script must be run from LiveCD. Exiting."
  exit 1
}

# === INTERNET CHECK ===
! ping -c 1 1.1.1.1 >/dev/null 2>&1 && ! ping -c 1 8.8.8.8 >/dev/null 2>&1 && {
  msg red "No internet connection. Exiting."
  exit 1
}
! ping -c 1 cloudflare.com >/dev/null 2>&1 && ! ping -c 1 google.com >/dev/null 2>&1 && {
  msg red "Please check your DNS settings. Exiting."
  exit 1
}

# === MAIN SCRIPT ===
prepare_alpine() {
  msg yellow "Preparing Alpine..."

  setup-apkrepos -1 || {
    msg red "Failed to set up apk repositories (1)"
    return 1
  }
  setup-apkrepos -r || {
    msg red "Failed to set up apk repositories (r)"
    return 1
  }
  apk update || {
    msg red "apk update failed"
    return 1
  }
  apk add --no-cache -q cryptsetup e2fsprogs lsblk parted udev bash dropbear ||
    {
      msg red "Failed to install required packages"
      return 1
    }
}

main() {
  msg yellow "Starting prepare script..."

  [ -f /etc/os-release ] && . /etc/os-release
  case "$ID" in
  alpine)
    VERSION_ID_MAJOR="${VERSION_ID%%.*}"
    VERSION_ID_MINOR="${VERSION_ID#*.}"
    VERSION_ID_MINOR="${VERSION_ID_MINOR%%.*}"
    if [ "$VERSION_ID_MAJOR" -lt 3 ] || { [ "$VERSION_ID_MAJOR" -eq 3 ] && [ "$VERSION_ID_MINOR" -lt 23 ]; }; then
      msg red "Alpine 3.23+ required. Current version: $VERSION_ID. Exiting."
      return 1
    fi
    prepare_alpine
    ;;
  *)
    msg red "System '${ID:-unknown}' is not supported."
    msg yellow "Supported systems: alpine"
    return 1
    ;;
  esac

  msg yellow "Downloading and running the main script..."
  wget -qO "$ID-luks.sh" "https://raw.githubusercontent.com/NikD0T/luks/main/live-systems/$ID.sh" || {
    msg red "Failed to download the main script"
    return 1
  }
  chmod +x "$ID-luks.sh"
  bash "$ID-luks.sh" || {
    msg red "Main script exited with code $?"
    return 1
  }
}

main || exit $?
