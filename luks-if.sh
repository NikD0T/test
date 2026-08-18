#!/bin/bash
# This script is intended to be run on an installed Debian system with a LUKS-encrypted root.
# It lets you select the network interface on which Dropbear (initramfs SSH) listens and rebuilds the initramfs.

# === COLOR HELPERS ===
p_yellow() { echo -ne "\e[0;33m$1\e[0m"; }
p_bright_yellow() { echo -ne "\e[1;33m$1\e[0m"; }
p_gray() { echo -ne "\e[1;37m$1\e[0m"; }
p_red() { echo -ne "\e[0;31m$1\e[0m"; }
p_bright_red() { echo -ne "\e[1;31m$1\e[0m"; }
p_green() { echo -ne "\e[0;32m$1\e[0m"; }

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

# === OS CHECK ===
[[ -f /etc/os-release ]] && . /etc/os-release
if [[ "$ID" != "debian" || "$VERSION_ID" != "13" ]]; then
	msg red "Script supports only Debian 13. Exiting."
	exit 1
fi

# === BASH VERSION CHECK ===
if [[ ${BASH_VERSINFO[0]} -lt 3 || (${BASH_VERSINFO[0]} -eq 3 && ${BASH_VERSINFO[1]} -lt 1) ]]; then
	msg red "Bash 3.1+ required (current: ${BASH_VERSION}). Exiting."
	exit 1
fi

# === CONFIG STORAGE ===
CONFIG_FILE="/etc/initramfs-tools/initramfs.conf"

# === NETWORK INTERFACE HELPERS ===
get_interfaces() {
	ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -v lo
}

get_ip_line() {
	awk '/^IP=/ {print; exit}' "$CONFIG_FILE" 2>/dev/null
}

get_ip_device() {
	local line
	line=$(get_ip_line)
	[[ -n "$line" ]] && awk -F= '{print $2}' <<<"$line" | awk -F: '{print $6}'
}

set_ip_device() {
	local iface="$1"
	local line
	line=$(get_ip_line)

	if [[ -n "$line" ]]; then
		local value
		value=$(awk -F= '{print $2}' <<<"$line")
		local -a fields=()
		IFS=: read -ra fields <<<"$value"
		while [[ ${#fields[@]} -lt 6 ]]; do
			fields+=("")
		done
		fields[5]="$iface"
		local new_value
		new_value=$(
			IFS=:
			echo "${fields[*]}"
		)
		sed -i "s|^IP=.*|IP=${new_value}|" "$CONFIG_FILE"
	else
		echo "IP=:::::${iface}:dhcp" >>"$CONFIG_FILE"
	fi
}

# === PAGE 1: INTERFACE ===
page_iface() {
	while true; do
		echo ""
		p_gray "─────────────────────────────────────────────────────────────────"
		echo ""
		p_bright_yellow " [ Interface ] "
		echo ""
		p_gray "─────────────────────────────────────────────────────────────────"
		echo ""

		local current_iface
		current_iface=$(get_ip_device)

		echo ""
		p_gray "  Current interface: "
		if [[ -n "$current_iface" ]]; then
			p_bright_yellow "$current_iface"
		else
			p_gray "(not set)"
		fi
		echo ""
		echo ""

		local -a interfaces=()
		while IFS= read -r iface; do
			interfaces+=("$iface")
		done < <(get_interfaces)

		if [[ ${#interfaces[@]} -eq 0 ]]; then
			msg bright_red "  No network interfaces found."
			echo ""
			msg gray "  [ 0]  Back"
			echo ""
			read -r -e -p "$(p_bright_yellow "  > ")" input
			[[ "$input" == "0" ]] && return
			continue
		fi

		local i
		for ((i = 0; i < ${#interfaces[@]}; i++)); do
			local num=$((i + 1))
			if [[ "${interfaces[$i]}" == "$current_iface" ]]; then
				p_mark n "  [$num] "
				p_bright_yellow "${interfaces[$i]}"
				p_gray " (current)"
				echo ""
			else
				p_mark n "  [$num] ${interfaces[$i]}"
				echo ""
			fi
		done

		echo ""
		msg gray "  [ 0]  Back"
		echo ""
		read -r -e -p "$(p_bright_yellow "  Select interface > ")" input

		[[ "$input" == "0" ]] && return

		if [[ "$input" =~ ^[0-9]+$ ]] && [[ "$input" -ge 1 && "$input" -le "${#interfaces[@]}" ]]; then
			local idx=$((input - 1))
			set_ip_device "${interfaces[$idx]}"
			msg green "  Interface set to ${interfaces[$idx]}"
			return
		else
			msg bright_red "  Invalid selection"
		fi
	done
}

# === MAIN MENU ===
main_menu() {
	while true; do
		echo ""
		msg bright_yellow "  dropbear initramfs interface changer"
		echo ""

		local iface line
		iface=$(get_ip_device)
		line=$(get_ip_line)

		msg gray "  ┌─ Dropbear interface ─────────────────────────────────────────"
		p_gray "  │ Interface: "
		if [[ -n "$iface" ]]; then
			p_bright_yellow "$iface"
		else
			p_bright_red "(not set)"
		fi
		echo ""
		p_gray "  │ IP line:   "
		if [[ -n "$line" ]]; then
			p_bright_yellow "$line"
		else
			p_gray "(none)"
		fi
		echo ""
		msg gray "  └──────────────────────────────────────────────────────────────"
		echo ""
		p_mark n "  [1] Interface"
		echo ""
		p_mark y "  [2] Rebuild initramfs"
		echo ""
		msg gray "  [ 0]  Exit"
		echo ""
		read -r -e -p "$(p_bright_yellow "  Select page > ")" choice

		case "$choice" in
		0)
			msg yellow "Exiting."
			exit 0
			;;
		1) page_iface ;;
		2)
			if [[ -z "$iface" ]]; then
				msg bright_red "  Interface is not set."
				continue
			fi
			echo ""
			msg yellow "  Rebuilding initramfs..."
			update-initramfs -u -k all
			local rc=$?
			echo ""
			if [[ $rc -eq 0 ]]; then
				msg green "  Initramfs rebuilt successfully."
			else
				msg bright_red "  update-initramfs failed with exit code $rc."
			fi
			return
			;;
		*) msg bright_red "  Invalid option" ;;
		esac
	done
}

# === ENTRY POINT ===
main() {
	main_menu
}

main || exit $?
