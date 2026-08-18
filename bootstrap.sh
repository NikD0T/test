#!/bin/bash

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

# === QEMU CHECK ===
if grep -qi "qemu" /proc/cpuinfo 2>/dev/null; then
	msg red "QEMU virtual CPU detected. This script does not support QEMU. Exiting."
	exit 1
fi

# === ROOT CHECK ===
if [[ $EUID -ne 0 ]]; then
	msg red "No root access. Attempting to restart with sudo..."
	exec sudo -E bash "$0" "$@"
fi

# === OS CHECK ===
[[ -f /etc/os-release ]] && . /etc/os-release
if [[ "$ID" != "debian" || "$VERSION_ID" != "13" ]]; then
	msg red "Script supports only Debian 13. Exiting."
	exit 1
fi

# === BASH VERSION CHECK ===
if [[ ${BASH_VERSINFO[0]} -lt 4 || ( ${BASH_VERSINFO[0]} -eq 4 && ${BASH_VERSINFO[1]} -lt 3 ) ]]; then
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

# === SCRIPT STATE ===
STATE_FILE="/var/lib/bootstrap.state"
BASH_PROFILE_MOD="$0 $*"

set_stage() {
  printf '%s\n' "$1" > "$STATE_FILE"
}

get_stage() {
  [[ -f $STATE_FILE ]] && cat "$STATE_FILE" || echo 0
}

bash_profile_mod() {
  local profile="${HOME}/.bash_profile"
  local line="$BASH_PROFILE_MOD"

  if [[ $(get_stage) -eq 0 ]]; then
    grep -Fxq "$line" "$profile" 2>/dev/null || echo "$line" >> "$profile"
  else
    [[ -f "$profile" ]] && sed -i "\|$line|d" "$profile"
  fi
}

# === PORT CONFLICT HELPERS ===
reserve_port() {
	local port=$1 old_port=$2
	if ! validate_port "$port"; then
		msg bright_red "  Invalid port number"
		return 1
	fi
	if port_is_reserved "$port"; then
		msg bright_red "  Port already reserved by another service"
		return 1
	fi
	if port_is_used "$port"; then
		msg bright_red "  Port already in use on system"
		return 1
	fi
	remove_used_port "$old_port"
	add_used_port "$port"
	return 0
}

reserve_knock_sequence() {
	local seq=$1 old_seq=$2
	local p
	for p in $seq; do
		if port_is_reserved "$p"; then
			msg bright_red "  Port $p already reserved"
			return 1
		elif port_is_used "$p"; then
			msg bright_red "  Port $p already in use on system"
			return 1
		fi
	done
	release_knock_ports "$old_seq"
	reserve_knock_ports "$seq"
	return 0
}

check_knock_ports() {
	local key=$1 seq=$2 label=$3
	local -n conflicts_ref=$4
	if ! validate_knock_sequence "$seq"; then
		config_set "$key" ""
		return 1
	fi
	local conflict=false
	for p in $seq; do
		if port_is_used "$p"; then
			conflicts_ref+=("$label port $p – in use by system")
			conflict=true
		elif port_is_reserved "$p"; then
			conflicts_ref+=("$label port $p – conflicts with another service")
			conflict=true
		fi
	done
	if [[ $conflict == true ]]; then
		config_set "$key" ""
		return 1
	fi
	reserve_knock_ports "$seq"
}

check_and_register_port() {
	local key=$1 port=$2 label=$3
	local -n conflicts_ref=$4
	if ! validate_port "$port"; then
		config_set "$key" ""
		return 1
	fi
	if port_is_used "$port"; then
		conflicts_ref+=("$label=$port – in use by system")
		config_set "$key" ""
		return 1
	fi
	if port_is_reserved "$port"; then
		conflicts_ref+=("$label=$port – conflicts with another service")
		config_set "$key" ""
		return 1
	fi
	add_used_port "$port"
}

# === CONFIG MANAGEMENT ===
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_BASE="$(basename "$0")"
SCRIPT_BASE="${SCRIPT_BASE%.*}"
CONFIG_FILE="${SCRIPT_DIR}/${SCRIPT_BASE}.env"
declare -A CONFIG
declare -A USED_PORTS

config_save() {
	local tmpfile
	tmpfile=$(mktemp)
	for key in "${!CONFIG[@]}"; do
		printf '%s=%s\n' "$key" "${CONFIG[$key]}" >>"$tmpfile"
	done
	cp -f "$tmpfile" "$CONFIG_FILE"
	chmod 600 "$CONFIG_FILE"
	rm -f "$tmpfile"
}

config_get() {
	local key=$1 default=$2
	echo "${CONFIG[$key]:-$default}"
}

config_set() {
	CONFIG["$1"]="$2"
	config_save
}

config_is_true() {
	local val=$(config_get "$1" "n")
	[[ "$val" == "y" ]] || [[ "$val" == "Y" ]] || [[ "$val" == "yes" ]]
}

config_load() {
	if [[ -f "$CONFIG_FILE" ]]; then
		while IFS='=' read -r key value; do
			[[ -z "$key" || "$key" == \#* ]] && continue
			CONFIG["$key"]="$value"
		done <"$CONFIG_FILE"
	fi

	local -A DEFAULTS=(
		[TELEGRAM_ALERTS]="y"
		[TAILSCALE]="y"
		[RCLONE]="y"
		[THREE_X_UI]="y"
		[DOCKER_PROXY]="y"
		[PIHOLE]="y"
		[SSH_USER]="xworker"
		[SECURE_PROC]="n"
		[RKN_AS]="n"
		[ETURNAL]="n"
		[MASTERDNSVPN]="n"
		[THREE_X_UI_ENTRY_MODE]="y"
  [LOCALES]="en_US.UTF-8"
	)
	for key in "${!DEFAULTS[@]}"; do
		[[ -z "${CONFIG[$key]+x}" ]] && CONFIG[$key]="${DEFAULTS[$key]}"
	done

	local -A DYNAMIC_DEFAULTS=(
		[CURRENT_INTERFACE]="$(get_interfaces | head -1)"
		[HOSTNAME]="$(hostname)"
		[TIMEZONE]="$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")"
		[SWAP_SIZE]="$(swap_recommend)"
	)
	for key in "${!DYNAMIC_DEFAULTS[@]}"; do
		[[ -z "${CONFIG[$key]+x}" ]] && CONFIG[$key]="${DYNAMIC_DEFAULTS[$key]}"
	done

	local conflicts=()

	local ssh_port=$(config_get SSH_PORT "")
	[[ -n "$ssh_port" ]] && check_and_register_port SSH_PORT "$ssh_port" "SSH_PORT" conflicts

	local knock=$(config_get SSH_KNOCK_SEQUENCE "")
	[[ -n "$knock" ]] && check_knock_ports SSH_KNOCK_SEQUENCE "$knock" "SSH_KNOCK_SEQUENCE" conflicts

	local ph_port=$(config_get PIHOLE_PORT "")
	[[ -n "$ph_port" ]] && check_and_register_port PIHOLE_PORT "$ph_port" "PIHOLE_PORT" conflicts

	if [[ ${#conflicts[@]} -gt 0 ]]; then
		echo ""
		msg bright_red "  ┌─ Port conflicts in config ──────────────────────────────"
		for c in "${conflicts[@]}"; do
			msg bright_red "  │ $c – reset"
		done
		msg bright_red "  └─────────────────────────────────────────────────────────"
	fi
}

# === UTILITY FUNCTIONS ===
human_readable_ram() {
	local mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
	local mem_mb=$((mem_kb / 1024))
	local mem_gb=$((mem_mb / 1024))
	if [[ $mem_gb -gt 0 ]]; then
		echo "${mem_gb} GB"
	else
		echo "${mem_mb} MB"
	fi
}

swap_recommend() {
	local mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
	local mem_gb=$((mem_kb / 1024 / 1024))
	local swap

	if [[ $mem_gb -lt 2 ]]; then
		swap=$((mem_gb * 2))
	elif [[ $mem_gb -lt 8 ]]; then
		swap=$mem_gb
	elif [[ $mem_gb -lt 64 ]]; then
		swap=$((mem_gb / 2))
	else
		swap=4
	fi

	[[ $swap -gt 32 ]] && swap=32
	local max_swap_gb=$(($(max_swap_kb) / 1024 / 1024))
	[[ $swap -lt 1 ]] && swap=1
	[[ $swap -gt $max_swap_gb ]] && swap=$max_swap_gb
	echo "${swap}G"
}

get_interfaces() {
	ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -v lo
}

port_is_used() {
	local port=$1
	command -v ss &>/dev/null && ss -tlnp 2>/dev/null | grep -qP ":$port\b"
}

port_is_reserved() {
	local port=$1
	[[ -n "${USED_PORTS[$port]}" ]] && return 0
	return 1
}

add_used_port() {
	local port=$1
	USED_PORTS[$port]=1
}

remove_used_port() {
	local port=$1
	unset USED_PORTS[$port]
}

reserve_knock_ports() {
	local seq=$1
	local p
	for p in $seq; do add_used_port "$p"; done
}

release_knock_ports() {
	local seq=$1
	local p
	for p in $seq; do remove_used_port "$p"; done
}

max_swap_kb() {
	local disk_kb=$(df / --output=avail 2>/dev/null | tail -1)
	echo $((disk_kb / 2))
}

# === VALIDATION FUNCTIONS ===
validate_hostname() {
	local val=$1 len
	[[ -z "$val" ]] && return 1
	len=${#val}
	[[ $len -gt 253 ]] && return 1
	[[ "$val" == .* || "$val" == *. ]] && return 1
	[[ "$val" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]
}

validate_username() {
	local val=$1
	[[ -z "$val" ]] && return 1
	[[ "$val" =~ ^[a-z_][a-z0-9_-]*$ ]] || return 1
	[[ ${#val} -le 32 ]] || return 1
	id "$val" &>/dev/null && return 1
	return 0
}

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

validate_port() {
	local val=$1
	[[ -z "$val" ]] && return 1
	[[ "$val" =~ ^[0-9]+$ ]] || return 1
	[[ $val -ge 1 && $val -le 60000 ]]
}

validate_knock_sequence() {
	local val=$1
	[[ -z "$val" ]] && return 1
	local ports=($val)
	[[ ${#ports[@]} -lt 2 ]] && return 1
	[[ ${#ports[@]} -gt 5 ]] && return 1
	for p in "${ports[@]}"; do
		[[ "$p" =~ ^[0-9]+$ ]] || return 1
		[[ $p -ge 1 && $p -le 60000 ]] || return 1
	done
	return 0
}

validate_telegram_token() {
	local val=$1
	[[ -z "$val" ]] && return 1
	[[ "$val" =~ ^[0-9]{8,10}:[a-zA-Z0-9_-]{35}$ ]]
}

validate_telegram_user_id() {
	local val=$1
	[[ -z "$val" ]] && return 1
	[[ "$val" =~ ^[0-9]+$ ]]
}

validate_proxy() {
	local val=$1
	[[ -z "$val" ]] && return 0
	[[ "$val" == *"://"* || "$val" == *":"* ]] || return 1
	[[ "$val" != *" "* ]] || return 1
	return 0
}

validate_socks5_proxy() {
	local val=$1
	[[ -z "$val" ]] && return 1
	[[ "$val" == socks5://* || "$val" == socks5h://* ]] || return 1
	[[ "$val" != *" "* ]] || return 1
	return 0
}

validate_url() {
	local val=$1
	[[ -z "$val" ]] && return 1
	[[ "$val" == https://* ]] || return 1
	[[ "$val" != *" "* ]] || return 1
	return 0
}

validate_domain() {
	local val=$1
	local allow_wildcard_prefix=${2:-n}

	[[ -z "$val" ]] && return 1

	# Disallow wildcard only at start
	if [[ "$allow_wildcard_prefix" != y && "$val" == \*.* ]]; then
		return 1
	fi

	[[ "$val" == .* || "$val" == *. ]] && return 1

	local clean=$val

	# Replace "*" labels with valid name for regex testing
	clean=${clean//\*/wildcard}

	local re='^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$'
	[[ "$clean" =~ $re ]]
}

validate_ip() {
	local val=$1
	[[ -z "$val" ]] && return 1

	# IPv4
	[[ "$val" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && return 0

	# IPv6
	local h='[0-9a-fA-F]{1,4}'
	[[ "$val" =~ ^(${h}:){7}${h}$ ]] && return 0
	[[ "$val" =~ ^::(${h}:){0,6}${h}?$ ]] && return 0
	[[ "$val" =~ ^(${h}:){0,6}${h}::$ ]] && return 0
	[[ "$val" =~ ^(${h}:){1,6}:(${h}:){0,5}${h}?$ ]] && return 0
	return 1
}

validate_hs_preauth_key() {
	local val=$1
	[[ -z "$val" ]] && return 1
	[[ "$val" =~ ^hskey-auth-[A-Za-z0-9_-]{77}$ ]]
}

validate_filename() {
	local val=$1
	[[ -z "$val" ]] && return 1
	[[ "$val" == "." || "$val" == ".." ]] && return 1
	[[ "$val" == *"/"* ]] && return 1
	[[ ${#val} -gt 255 ]] && return 1
	[[ "$val" =~ ^[a-zA-Z0-9._-]+$ ]]
}

validate_ca_certificate() {
	local val=$1
	[[ -z "$val" ]] && return 1
	openssl x509 -noout 2>/dev/null <<<"$val"
}

validate_rclone_name() {
	local val=$1
	[[ -z "$val" ]] && return 1
	[[ "${val:0:1}" == "-" || "${val:0:1}" == " " ]] && return 1
	[[ "${val: -1}" == " " ]] && return 1
	local re='^[a-zA-Z0-9_.@+ -]+$'
	[[ "$val" =~ $re ]]
}

validate_timezone() {
	local val=$1
	[[ -z "$val" ]] && return 1
	timedatectl list-timezones 2>/dev/null | grep -Fxq "$val"
}

validate_locales() {
	local val=$1
	[[ -z "$val" ]] && return 1
	local -a locales=($val)
	local bad
	bad=$(printf '%s\n' "${locales[@]}" | grep -Fxv -f <(locale -a 2>/dev/null))
	if [[ -n "$bad" ]]; then
		echo "$bad"
		return 1
	fi
	return 0
}

validate_swap_value() {
	local val=$1
	[[ -z "$val" ]] && return 1
	[[ "$val" == "0" ]] && return 0
	[[ "$val" =~ ^[0-9]+(\.[0-9]+)?[GMKgmk]?$ ]]
}

# === UI HELPERS ===
TAB_NAMES=(
	"System Info"
	"System Configuration"
	"Secure Server"
	"Custom CA"
	"Soft"
	"Certbot (Cloudflare DNS)"
	"Confirmation"
)

render_header() {
	local page=$1
	echo ""
	p_gray "─────────────────────────────────────────────────────────────────"
	echo ""
	local i
	for ((i=1; i<=${#TAB_NAMES[@]}; i++)); do
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

# === Y/N PROMPT HELPER ===
prompt_yn() {
	local key=$1 prompt=$2 default=${3:-y}
	while true; do
		local hint
		[[ "$default" == "y" ]] && hint="Y/n" || hint="y/N"
		read -r -e -p "$(p_yellow "  $prompt ($hint, /c to cancel): ")" val
		[[ "$val" == "/c" ]] && return 1
		[[ -z "$val" ]] && val="$default"
		val="${val,,}"
		[[ "$val" == "y" || "$val" == "n" ]] || { msg bright_red "  Enter y or n"; continue; }
		config_set "$key" "$val"
		return 0
	done
}

# === PAGE 1: SYSTEM INFO ===
page_system_info() {
	local iface
	iface=$(config_get CURRENT_INTERFACE)

	while true; do
		render_header 1

		local ram ipv4 ipv6
		ram=$(human_readable_ram)
		ipv4=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
		ipv6=$(ip -6 addr show "$iface" 2>/dev/null | awk '/inet6 / {print $2}' | cut -d/ -f1 | grep -v '^fe80' | head -1)

		echo ""
		p_gray "  Internet:"
		echo ""
		p_gray "    Network interface: "
		p_bright_yellow "$iface"
		echo ""
		p_gray "    IPv4: "
		p_bright_yellow "${ipv4:--}"
		echo ""
		p_gray "    IPv6: "
		p_bright_yellow "${ipv6:--}"
		echo ""
		p_gray "  RAM: "
		p_bright_yellow "$ram"
		echo ""
		echo ""
		p_gray "  Your Interface is < "
		p_bright_yellow "$iface"
		p_gray " >"
		echo ""
		echo ""
		p_mark n "  [1] Change interface"
		echo ""
		msg gray "  [ 0]  Back"
		echo ""
		read -r -e -p "$(p_bright_yellow "  > ")" input

		case "$input" in
		0) return ;;
		1)
			while true; do
				echo ""
				local interfaces=()
				while IFS= read -r iface_entry; do
					interfaces+=("$iface_entry")
				done < <(get_interfaces)

				for i in "${!interfaces[@]}"; do
					local num=$((i + 1))
					p_mark n "  [$num] ${interfaces[$i]}"
					echo ""
				done

				echo ""
				read -r -e -p "$(p_yellow "  Select interface (/c to cancel): ")" input

				[[ "$input" == "/c" ]] && break
				if [[ -z "$input" ]]; then
					break
				elif [[ "$input" =~ ^[0-9]+$ ]] && [[ "$input" -ge 1 && "$input" -le "${#interfaces[@]}" ]]; then
					iface="${interfaces[$((input - 1))]}"
					config_set CURRENT_INTERFACE "$iface"
					break
				else
					msg bright_red "  Invalid selection"
				fi
			done
			;;
		*) msg bright_red "  Invalid option" ;;
		esac
	done
}

# === PAGE 2: SYSTEM CONFIGURATION ===
page_system_config() {
	while true; do
		render_header 2

		local hname tzone locs swap
		hname=$(config_get HOSTNAME)
		tzone=$(config_get TIMEZONE)
		locs=$(config_get LOCALES)
		swap=$(config_get SWAP_SIZE)

		echo ""
		p_mark y "  [1] Host name: "
		p_bright_yellow "$hname"
		echo ""
		p_mark y "  [2] Time Zone: "
		p_bright_yellow "$tzone"
		echo ""
		p_mark y "  [3] Generate locales: "
		local first_loc=$(awk '{print $1}' <<<"$locs")
		local rest_locs=$(awk '{for(i=2;i<=NF;i++) printf " %s", $i}' <<<"$locs")
		p_gray "["
		p_bright_yellow "$first_loc"
		p_gray "]"
		p_bright_yellow "$rest_locs"
		echo ""
		p_mark y "  [4] SWAP: "
		p_bright_yellow "$swap"
		echo ""
		msg gray "  [ 0]  Back"
		echo ""
		read -r -e -p "$(p_bright_yellow "  > ")" input

		case "$input" in
		0) return ;;
		1)
			while true; do
				read -r -e -p "$(p_yellow "  Host name (empty for $(hostname), /c to cancel): ")" val
				[[ "$val" == "/c" ]] && break
				[[ -z "$val" ]] && val=$(hostname)
				if validate_hostname "$val"; then
					config_set HOSTNAME "$val"
					break
				else
					msg bright_red "  Invalid hostname format"
				fi
			done
			;;
		2)
			while true; do
				read -r -e -p "$(p_yellow "  Time Zone (empty for $tzone, /c to cancel): ")" val
				[[ "$val" == "/c" ]] && break
				[[ -z "$val" ]] && val=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
				if validate_timezone "$val"; then
					config_set TIMEZONE "$val"
					break
				else
					msg bright_red "  Invalid timezone"
				fi
			done
			;;
		3)
			while true; do
				read -r -e -p "$(p_yellow "  Generate locales (empty for en_US.utf8, space-separated, /c to cancel): ")" val
				[[ "$val" == "/c" ]] && break
				[[ -z "$val" ]] && val="en_US.utf8"
				local bad_locales
				if bad_locales=$(validate_locales "$val"); then
					local -a unique=()
					for loc in $val; do
						local found=false
						for u in "${unique[@]}"; do
							[[ "$u" == "$loc" ]] && {
								found=true
								break
							}
						done
						[[ $found == true ]] || unique+=("$loc")
					done
					config_set LOCALES "${unique[*]}"
					break
				else
					msg bright_red "  Invalid locales: $bad_locales"
				fi
			done
			;;
		4)
			while true; do
				read -r -e -p "$(p_yellow "  SWAP (empty for $(swap_recommend), 0 to disable, suffixes: G/M/K, /c to cancel): ")" val
				[[ "$val" == "/c" ]] && break
				[[ -z "$val" ]] && val=$(swap_recommend)
				val="${val^^}"
				if validate_swap_value "$val"; then
					[[ "$val" =~ ^[0-9]+(\.[0-9]+)?$ ]] && val="${val}G"
					if [[ "$val" != "0" ]]; then
						local num="${val//[A-Z]/}" unit="${val//[0-9.]/}"
						local need_kb
						case "$unit" in
						G) need_kb=$(awk "BEGIN{printf \"%d\", $num * 1024 * 1024}") ;;
						M) need_kb=$(awk "BEGIN{printf \"%d\", $num * 1024}") ;;
						K) need_kb=${num%.*} ;;
						esac
						local max_kb=$(max_swap_kb)
						if [[ $need_kb -ge $max_kb ]]; then
							local max_gb=$((max_kb / 1024 / 1024))
							msg bright_red "  Not enough disk (need ~${val}, max swap: ${max_gb}G – half of free space)"
							continue
						fi
					fi
					config_set SWAP_SIZE "$val"
					break
				else
					msg bright_red "  Invalid swap value"
				fi
			done
			;;
		*) msg bright_red "  Invalid option" ;;
		esac
	done
}

# === PAGE 3: SECURE SERVER ===
page_secure_server() {
	while true; do
		render_header 3

		local ssh_user ssh_key ssh_port knock tg sec_proc rkn unique
		ssh_user=$(config_get SSH_USER)
		ssh_key=$(config_get SSH_PUBLIC_KEY "")
		ssh_port=$(config_get SSH_PORT "")
		knock=$(config_get SSH_KNOCK_SEQUENCE "")
		tg=$(config_get TELEGRAM_ALERTS)
		sec_proc=$(config_get SECURE_PROC)
		rkn=$(config_get RKN_AS)

		echo ""
		local q=1
		p_mark y "  [$q] SSH user login: "
		p_bright_yellow "$ssh_user"
		echo ""
		q=$((q + 1))
		p_mark n "  [$q] Custom SSH public key: "
		if [[ -n "$ssh_key" ]]; then p_gray "[public key]"; else p_gray "(will be generated)"; fi
		echo ""
		q=$((q + 1))
		p_mark y "  [$q] Custom port: "
		if [[ -n "$ssh_port" ]]; then p_bright_yellow "$ssh_port"; else p_gray "45055"; fi
		echo ""
		q=$((q + 1))
		p_mark n "  [$q] SSH knock sequence: "
		if [[ -n "$knock" ]]; then p_bright_yellow "$knock"; else p_gray "(disabled)"; fi
		echo ""
		q=$((q + 1))
		p_mark n "  [$q] Telegram login alerts: "
		p_bright_yellow "$tg"
		echo ""
		q=$((q + 1))
		if config_is_true TELEGRAM_ALERTS; then
			local tg_token tg_id tg_proxy
			tg_token=$(config_get TELEGRAM_TOKEN "")
			tg_id=$(config_get TELEGRAM_ID "")
			tg_proxy=$(config_get TELEGRAM_PROXY "")
			p_mark y "  [$q]   Token: "
			[[ -n "$tg_token" ]] && p_gray "[token set]" || p_gray "(not set)"
			echo ""
			q=$((q + 1))
			p_mark y "  [$q]   ID: "
			[[ -n "$tg_id" ]] && p_bright_yellow "$tg_id" || p_gray "(not set)"
			echo ""
			q=$((q + 1))
			p_mark n "  [$q]   Proxy: "
			[[ -n "$tg_proxy" ]] && p_bright_yellow "$tg_proxy" || p_gray "(not set)"
			echo ""
			q=$((q + 1))
		fi
		p_mark n "  [$q] Secure /proc: "
		p_bright_yellow "$sec_proc"
		echo ""
		q=$((q + 1))
		p_mark n "  [$q] Fuck RKN AS: "
		p_bright_yellow "$rkn"
		echo ""
		q=$((q + 1))
		if config_is_true RKN_AS; then
			local rkn_proxy
			rkn_proxy=$(config_get RKN_PROXY "")
			p_mark n "  [$q]   Proxy: "
			[[ -n "$rkn_proxy" ]] && p_bright_yellow "$rkn_proxy" || p_gray "(not set)"
			echo ""
			q=$((q + 1))
		fi
		msg gray "  [ 0]  Back"
		echo ""

		read -r -e -p "$(p_bright_yellow "  > ")" input

		[[ "$input" == "0" ]] && return
		[[ -z "$input" ]] && {
			msg bright_red "  Invalid option"
			continue
		}
		[[ ! "$input" =~ ^[0-9]+$ ]] && {
			msg bright_red "  Invalid option"
			continue
		}

		local idx=$input
		local tg_base=5
		config_is_true TELEGRAM_ALERTS && tg_base=8
		local total_q=$((tg_base + 3))
		config_is_true RKN_AS && total_q=$((total_q + 1))

		if [[ $idx -lt 1 || $idx -gt $total_q ]]; then
			msg bright_red "  Invalid option"
			continue
		fi

		# Map question number to action
		if [[ $idx -eq 1 ]]; then
			while true; do
				read -r -e -p "$(p_yellow "  SSH user login (empty for xworker, /c to cancel): ")" val
				[[ "$val" == "/c" ]] && break
				[[ -z "$val" ]] && val="xworker"
				if validate_username "$val"; then
					config_set SSH_USER "$val"
					break
				else
					msg bright_red "  Invalid username format or already exists"
				fi
			done
		elif [[ $idx -eq 2 ]]; then
			local cur_key=$(config_get SSH_PUBLIC_KEY "")
			echo ""
			[[ -n "$cur_key" ]] && {
				p_yellow "  Current key: "
				p_gray "$cur_key"
				echo ""
			}
			while true; do
				read -r -e -p "$(p_yellow "  SSH public key (empty to generate, /c to cancel): ")" val
				[[ "$val" == "/c" ]] && break
				if [[ -z "$val" ]]; then
					config_set SSH_PUBLIC_KEY ""
					break
				elif validate_ssh_key "$val"; then
					config_set SSH_PUBLIC_KEY "$val"
					break
				else
					msg bright_red "  Invalid SSH key format"
				fi
			done
		elif [[ $idx -eq 3 ]]; then
			local old_ssh_port=$(config_get SSH_PORT "")
			while true; do
				read -r -e -p "$(p_yellow "  Custom port (empty for 45055, /c to cancel): ")" val
				[[ "$val" == "/c" ]] && break
				if [[ -z "$val" ]]; then
					if reserve_port "45055" "$old_ssh_port"; then
						config_set SSH_PORT "45055"
						break
					fi
				elif reserve_port "$val" "$old_ssh_port"; then
					config_set SSH_PORT "$val"
					break
				fi
			done
		elif [[ $idx -eq 4 ]]; then
			local old_knock=$(config_get SSH_KNOCK_SEQUENCE "")
			while true; do
				read -r -e -p "$(p_yellow "  SSH knock sequence (space-separated, 2+ ports, empty to disable, /c to cancel): ")" val
				[[ "$val" == "/c" ]] && break
				if [[ -z "$val" ]]; then
					config_set SSH_KNOCK_SEQUENCE ""
					break
				elif validate_knock_sequence "$val"; then
					unique=($(printf '%s\n' $val | sort -un))
					if [[ ${#unique[@]} -lt 2 ]]; then
						msg bright_red "  Need at least 2 unique ports"
						continue
					fi
					if reserve_knock_sequence "${unique[*]}" "$old_knock"; then
						config_set SSH_KNOCK_SEQUENCE "${unique[*]}"
						break
					fi
				else
					msg bright_red "  Invalid sequence (need 2+ valid ports)"
				fi
			done
		elif [[ $idx -eq 5 ]]; then
			prompt_yn TELEGRAM_ALERTS "Telegram login alerts" "y"
		elif config_is_true TELEGRAM_ALERTS && [[ $idx -eq 6 ]]; then
			while true; do
				read -r -e -p "$(p_yellow "  Telegram Token (/c to cancel): ")" val
				[[ "$val" == "/c" ]] && break
				if validate_telegram_token "$val"; then
					config_set TELEGRAM_TOKEN "$val"
					break
				else
					msg bright_red "  Invalid token format"
				fi
			done
		elif config_is_true TELEGRAM_ALERTS && [[ $idx -eq 7 ]]; then
			while true; do
				read -r -e -p "$(p_yellow "  Telegram ID (/c to cancel): ")" val
				[[ "$val" == "/c" ]] && break
				if validate_telegram_user_id "$val"; then
					config_set TELEGRAM_ID "$val"
					break
				else
					msg bright_red "  Invalid ID (must be int64)"
				fi
			done
		elif config_is_true TELEGRAM_ALERTS && [[ $idx -eq 8 ]]; then
			while true; do
				read -r -e -p "$(p_yellow "  Telegram Proxy (/c to cancel): ")" val
				[[ "$val" == "/c" ]] && break
				if validate_proxy "$val" || [[ -z "$val" ]]; then
					config_set TELEGRAM_PROXY "$val"
					break
				else
					msg bright_red "  Invalid proxy format"
				fi
			done
		elif [[ $idx -eq $((tg_base + 1)) ]]; then
			prompt_yn SECURE_PROC "Secure /proc" "n"
		elif [[ $idx -eq $((tg_base + 2)) ]]; then
			prompt_yn RKN_AS "Fuck RKN AS" "y"
		elif config_is_true RKN_AS && [[ $idx -eq $((tg_base + 4)) ]]; then
			while true; do
				read -r -e -p "$(p_yellow "  RKN Proxy (/c to cancel): ")" val
				[[ "$val" == "/c" ]] && break
				if [[ -z "$val" ]] || validate_socks5_proxy "$val"; then
					config_set RKN_PROXY "$val"
					break
				else
					msg bright_red "  Invalid socks5 URL"
				fi
			done
		else
			msg bright_red "  Invalid option"
		fi
	done
}

# === PAGE 4: CUSTOM CA ===
page_custom_ca() {
	while true; do
		render_header 4

		local count=$(config_get CA_COUNT 0)
		echo ""
		if [[ $count -gt 0 ]]; then
			for ((i=1; i<=count; i++)); do
				local name=$(config_get "CA_${i}_NAME" "")
				p_mark n "  [$i] "
				p_bright_yellow "${name:-"(unnamed)"}"
				p_gray " [CA]"
				echo ""
			done
		else
			msg gray "  (no certificates added)"
		fi
		echo ""
		p_mark n "  [a] Add custom CA"
		echo ""
		msg gray "  [ 0]  Back"
		echo ""
		read -r -e -p "$(p_bright_yellow "  > ")" input

		[[ "$input" == "0" ]] && return

		if [[ "$input" == "a" || "$input" == "A" ]]; then
			add_ca
		elif [[ "$input" =~ ^[0-9]+$ ]] && [[ $input -ge 1 ]] && [[ $input -le $count ]]; then
			edit_ca "$input"
		else
			msg bright_red "  Invalid option"
		fi
	done
}

ca_name_exists() {
	local name=$1 skip_idx=$2
	local count=$(config_get CA_COUNT 0)
	local i
	for ((i=1; i<=count; i++)); do
		[[ -n "$skip_idx" && $i -eq $skip_idx ]] && continue
		[[ "$(config_get "CA_${i}_NAME" "")" == "$name" ]] && return 0
	done
	return 1
}

add_ca() {
	while true; do
		echo ""
		read -r -e -p "$(p_mark y "  CA name") (/c to cancel): " name
		[[ "$name" == "/c" ]] && return
		validate_filename "$name" || {
			msg bright_red "  Invalid filename (use [a-zA-Z0-9._-])"
			continue
		}
		ca_name_exists "$name" && {
			msg bright_red "  CA name already exists"
			continue
		}

		echo ""
		p_mark y "  CA"
		echo " (paste certificate, end with empty line): "
		local ca_content=""
		while IFS= read -r line; do
			[[ -z "$line" ]] && break
			ca_content+="$line"$'\n'
		done

		if ! validate_ca_certificate "$ca_content"; then
			msg bright_red "  Invalid PEM certificate"
			continue
		fi

		local count=$(config_get CA_COUNT 0)
		count=$((count + 1))
		local ca_b64
		ca_b64=$(base64 -w0 <<<"$ca_content")
		config_set CA_COUNT "$count"
		config_set "CA_${count}_NAME" "$name"
		config_set "CA_${count}_CA_B64" "$ca_b64"
		msg green "  CA added"
		break
	done
}

edit_ca() {
	local idx=$1
	while true; do
		local name=$(config_get "CA_${idx}_NAME" "")
		echo ""
		p_yellow "  CA: "
		p_bright_yellow "$name"
		echo ""
		echo ""
		p_mark n "  [1] Edit name"
		echo ""
		p_mark n "  [2] Replace CA"
		echo ""
		p_mark n "  [3] Delete"
		echo ""
		msg gray "  /c to go back"
		echo ""

		read -r -e -p "$(p_bright_yellow "  > ")" input

		[[ "$input" == "/c" ]] && return

		if [[ "$input" == "1" ]]; then
			while true; do
				read -r -e -p "$(p_yellow "  CA name (/c to cancel): ")" new_name
				[[ "$new_name" == "/c" ]] && break
				if validate_filename "$new_name"; then
					if ca_name_exists "$new_name" "$idx"; then
						msg bright_red "  CA name already exists"
					else
						config_set "CA_${idx}_NAME" "$new_name"
						break
					fi
				else
					msg bright_red "  Invalid filename (use [a-zA-Z0-9._-])"
				fi
			done
		elif [[ "$input" == "2" ]]; then
			while true; do
				echo ""
				p_yellow "  CA"
				echo " (paste certificate, end with empty line): "
				local ca_content=""
				while IFS= read -r line; do
					[[ -z "$line" ]] && break
					ca_content+="$line"$'\n'
				done
				if validate_ca_certificate "$ca_content"; then
					local ca_b64
					ca_b64=$(base64 -w0 <<<"$ca_content")
					config_set "CA_${idx}_CA_B64" "$ca_b64"
					msg green "  CA replaced"
					break
				else
					[[ -z "$ca_content" ]] && break
					msg bright_red "  Invalid PEM certificate"
				fi
			done
		elif [[ "$input" == "3" ]]; then
			local count=$(config_get CA_COUNT 0)
			for ((i=idx; i<=count-1; i++)); do
				local nxt=$((i + 1))
				config_set "CA_${i}_NAME" "$(config_get "CA_${nxt}_NAME" "")"
				config_set "CA_${i}_CA_B64" "$(config_get "CA_${nxt}_CA_B64" "")"
			done
			CONFIG["CA_${count}_NAME"]=""
			CONFIG["CA_${count}_CA_B64"]=""
			config_set CA_COUNT $((count - 1))
			msg green "  CA deleted"
			return
		else
			msg bright_red "  Invalid option"
		fi
	done
}

# === PAGE 5: SOFT ===
page_soft() {
	while true; do
		render_header 5

		local ts rc xu dp et ph md
		ts=$(config_get TAILSCALE)
		rc=$(config_get RCLONE)
		xu=$(config_get THREE_X_UI)
		dp=$(config_get DOCKER_PROXY)
		et=$(config_get ETURNAL)
		ph=$(config_get PIHOLE)
		md=$(config_get MASTERDNSVPN)

		echo ""
		local q=1
		p_mark n "  [$q] Tailscale: "
		p_bright_yellow "$ts"
		echo ""
		q=$((q + 1))
		if config_is_true TAILSCALE; then
			local ts_srv ts_key
			ts_srv=$(config_get TAILSCALE_SERVER "")
			ts_key=$(config_get TAILSCALE_PREAUTH_KEY "")
			p_mark y "  [$q]   Server: "
			[[ -n "$ts_srv" ]] && p_bright_yellow "$ts_srv" || p_gray "(not set)"
			echo ""
			q=$((q + 1))
			p_mark y "  [$q]   Pre-auth key: "
			[[ -n "$ts_key" ]] && p_gray "[key set]" || p_gray "(not set)"
			echo ""
			q=$((q + 1))
		fi
		p_mark n "  [$q] Rclone WebDAV: "
		p_bright_yellow "$rc"
		echo ""
		q=$((q + 1))
		if config_is_true RCLONE; then
			local rc_name rc_url rc_vendor rc_user rc_pass rc_token
			rc_name=$(config_get RCLONE_NAME "")
			rc_url=$(config_get RCLONE_URL "")
			rc_vendor=$(config_get RCLONE_VENDOR "")
			rc_user=$(config_get RCLONE_USER "")
			rc_pass=$(config_get RCLONE_PASSWORD "")
			rc_token=$(config_get RCLONE_BEARER_TOKEN "")
			p_mark y "  [$q]   Name: "
			[[ -n "$rc_name" ]] && p_bright_yellow "$rc_name" || p_gray "(not set)"
			echo ""
			q=$((q + 1))
			p_mark y "  [$q]   URL: "
			[[ -n "$rc_url" ]] && p_bright_yellow "$rc_url" || p_gray "(not set)"
			echo ""
			q=$((q + 1))
			p_mark n "  [$q]   Vendor: "
			[[ -n "$rc_vendor" ]] && p_bright_yellow "$rc_vendor" || p_gray "(not set)"
			echo ""
			q=$((q + 1))
			p_mark n "  [$q]   User: "
			[[ -n "$rc_user" ]] && p_bright_yellow "$rc_user" || p_gray "(not set)"
			echo ""
			q=$((q + 1))
			p_mark n "  [$q]   Password: "
			[[ -n "$rc_pass" ]] && p_gray "[set]" || p_gray "(not set)"
			echo ""
			q=$((q + 1))
			p_mark n "  [$q]   Bearer Token: "
			[[ -n "$rc_token" ]] && p_gray "[set]" || p_gray "(not set)"
			echo ""
			q=$((q + 1))
		fi
		p_mark n "  [$q] 3X-UI: "
		p_bright_yellow "$xu"
		echo ""
		q=$((q + 1))
		if config_is_true THREE_X_UI; then
			local xu_panel xu_reality xu_entry
			xu_panel=$(config_get THREE_X_UI_PANEL_DOMAIN "")
			xu_reality=$(config_get THREE_X_UI_REALITY_DOMAIN "")
			xu_entry=$(config_get THREE_X_UI_ENTRY_MODE)
			p_mark y "  [$q]   Panel domain: "
			[[ -n "$xu_panel" ]] && p_bright_yellow "$xu_panel" || p_gray "(not set)"
			echo ""
			q=$((q + 1))
			p_mark y "  [$q]   Reality domain: "
			[[ -n "$xu_reality" ]] && p_bright_yellow "$xu_reality" || p_gray "(not set)"
			echo ""
			q=$((q + 1))
			p_mark n "  [$q]   In entry mode: "
			p_bright_yellow "$xu_entry"
			echo ""
			q=$((q + 1))
		fi
		p_mark n "  [$q] Docker Proxy: "
		p_bright_yellow "$dp"
		echo ""
		q=$((q + 1))
		if config_is_true DOCKER_PROXY; then
			local dp_ip
			dp_ip=$(config_get DOCKER_PROXY_HOST_IP "")
			p_mark y "  [$q]   Host IP: "
			[[ -n "$dp_ip" ]] && p_bright_yellow "$dp_ip" || p_gray "(not set)"
			echo ""
			q=$((q + 1))
		fi
		p_mark n "  [$q] Eturnal: "
		p_bright_yellow "$et"
		echo ""
		q=$((q + 1))
		p_mark n "  [$q] Pi-hole DNS: "
		p_bright_yellow "$ph"
		echo ""
		q=$((q + 1))
		if config_is_true PIHOLE; then
			local ph_port
			ph_port=$(config_get PIHOLE_PORT "")
			p_mark y "  [$q]   Port: "
			[[ -n "$ph_port" ]] && p_bright_yellow "$ph_port" || p_gray "(not set)"
			echo ""
			q=$((q + 1))
		fi
		p_mark n "  [$q] MasterDnsVPN: "
		p_bright_yellow "$md"
		echo ""
		q=$((q + 1))
		if config_is_true MASTERDNSVPN; then
			local md_domains md_proxy
			md_domains=$(config_get MASTERDNSVPN_DOMAINS "")
			md_proxy=$(config_get MASTERDNSVPN_PROXY "")
			p_mark y "  [$q]   Domains: "
			[[ -n "$md_domains" ]] && p_bright_yellow "$md_domains" || p_gray "(not set)"
			echo ""
			q=$((q + 1))
			p_mark n "  [$q]   Proxy: "
			[[ -n "$md_proxy" ]] && p_bright_yellow "$md_proxy" || p_gray "(not set)"
			echo ""
			q=$((q + 1))
		fi
		msg gray "  [ 0]  Back"
		echo ""

		read -r -e -p "$(p_bright_yellow "  > ")" input
		[[ "$input" == "0" ]] && return
		[[ ! "$input" =~ ^[0-9]+$ ]] && {
			msg bright_red "  Invalid option"
			continue
		}

		local idx=$input
		# Always: 1=ts, 2=ts_srv(if ts), 3=ts_key(if ts), 4=rc, etc.
		local -a question_map=()
		local qi=1
		question_map[$qi]="ts"
		qi=$((qi + 1))
		if config_is_true TAILSCALE; then
			question_map[$qi]="ts_srv"
			qi=$((qi + 1))
			question_map[$qi]="ts_key"
			qi=$((qi + 1))
		fi
		question_map[$qi]="rc"
		qi=$((qi + 1))
		if config_is_true RCLONE; then
			question_map[$qi]="rc_name"
			qi=$((qi + 1))
			question_map[$qi]="rc_url"
			qi=$((qi + 1))
			question_map[$qi]="rc_vendor"
			qi=$((qi + 1))
			question_map[$qi]="rc_user"
			qi=$((qi + 1))
			question_map[$qi]="rc_pass"
			qi=$((qi + 1))
			question_map[$qi]="rc_token"
			qi=$((qi + 1))
		fi
		question_map[$qi]="xu"
		qi=$((qi + 1))
		if config_is_true THREE_X_UI; then
			question_map[$qi]="xu_panel_domain"
			qi=$((qi + 1))
			question_map[$qi]="xu_reality_domain"
			qi=$((qi + 1))
			question_map[$qi]="xu_entry"
			qi=$((qi + 1))
		fi
		question_map[$qi]="dp"
		qi=$((qi + 1))
		if config_is_true DOCKER_PROXY; then
			question_map[$qi]="dp_ip"
			qi=$((qi + 1))
		fi
		question_map[$qi]="et"
		qi=$((qi + 1))
		question_map[$qi]="ph"
		qi=$((qi + 1))
		if config_is_true PIHOLE; then
			question_map[$qi]="ph_port"
			qi=$((qi + 1))
		fi
		question_map[$qi]="md"
		qi=$((qi + 1))
		if config_is_true MASTERDNSVPN; then
			question_map[$qi]="md_domains"
			qi=$((qi + 1))
			question_map[$qi]="md_proxy"
			qi=$((qi + 1))
		fi
		local max_q=$((qi - 1))

		[[ $idx -lt 1 || $idx -gt $max_q ]] && {
			msg bright_red "  Invalid option"
			continue
		}

		local action="${question_map[$idx]}"

		case "$action" in
		ts)
			prompt_yn TAILSCALE "Tailscale" "y"
			;;
		ts_srv)
			while true; do
				read -r -e -p "$(p_yellow "  Tailscale Server (/c to cancel): https://")" val
				[[ "$val" == "/c" ]] && break
				val="https://${val}"
				if validate_url "$val"; then
					config_set TAILSCALE_SERVER "$val"
					break
				else
					msg bright_red "  Invalid URL format"
				fi
			done
			;;
		ts_key)
			while true; do
				read -r -e -p "$(p_yellow "  Tailscale Pre-auth key (empty to none, 77 chars, without prefix, /c to cancel): hskey-auth-")" val
				[[ "$val" == "/c" ]] && break
				val="hskey-auth-${val}"
				if validate_hs_preauth_key "$val"; then
					config_set TAILSCALE_PREAUTH_KEY "$val"
					break
				else
					msg bright_red "  Key must be exactly 77 characters"
				fi
			done
			;;
		rc)
			prompt_yn RCLONE "Rclone WebDAV" "y"
			;;
		rc_name)
			while true; do
				read -r -e -p "$(p_yellow "  Rclone WebDAV Name (/c to cancel): ")" val
				[[ "$val" == "/c" ]] && break
				if validate_rclone_name "$val"; then
					config_set RCLONE_NAME "$val"
					break
				else
					msg bright_red "  Invalid name (allowed: letters, numbers, _.@+- and space, not start with -/space)"
				fi
			done
			;;
		rc_url)
			while true; do
				read -r -e -p "$(p_yellow "  Rclone WebDAV URL (/c to cancel): https://")" val
				[[ "$val" == "/c" ]] && break
				val="https://${val}"
				if validate_url "$val"; then
					config_set RCLONE_URL "$val"
					break
				else
					msg bright_red "  Invalid URL format"
				fi
			done
			;;
		rc_vendor)
			read -r -e -p "$(p_yellow "  Vendor [nextcloud/owncloud/sharepoint/sharepoint-ntlm/other] (empty to none, /c to cancel): ")" val
			[[ "$val" != "/c" ]] && config_set RCLONE_VENDOR "$val"
			;;
		rc_user)
			read -r -e -p "$(p_yellow "  User (empty to none, /c to cancel): ")" val
			[[ "$val" != "/c" ]] && config_set RCLONE_USER "$val"
			;;
		rc_pass)
			read -r -e -p "$(p_yellow "  Password (empty to none, /c to cancel): ")" val
			[[ "$val" != "/c" ]] && config_set RCLONE_PASSWORD "$val"
			;;
		rc_token)
			read -r -e -p "$(p_yellow "  Bearer Token (empty to none, /c to cancel): ")" val
			[[ "$val" != "/c" ]] && config_set RCLONE_BEARER_TOKEN "$val"
			;;
		xu)
			prompt_yn THREE_X_UI "3X-UI" "y"
			;;
		xu_panel_domain)
			while true; do
				read -r -e -p "$(p_yellow "  3X-UI Panel domain (/c to cancel): ")" val
				[[ "$val" == "/c" ]] && break
				if validate_domain "$val"; then
					config_set THREE_X_UI_PANEL_DOMAIN "$val"
					break
				else
					msg bright_red "  Invalid domain format"
				fi
			done
			;;
		xu_reality_domain)
			while true; do
				read -r -e -p "$(p_yellow "  3X-UI Reality domain (/c to cancel): ")" val
				[[ "$val" == "/c" ]] && break
				if validate_domain "$val"; then
					config_set THREE_X_UI_REALITY_DOMAIN "$val"
					break
				else
					msg bright_red "  Invalid domain format"
				fi
			done
			;;
		xu_entry)
			prompt_yn THREE_X_UI_ENTRY_MODE "3X-UI In entry mode" "y"
			;;
		dp)
			prompt_yn DOCKER_PROXY "Docker Proxy" "y"
			;;
		dp_ip)
			while true; do
				read -r -e -p "$(p_yellow "  Docker Proxy Host IP (/c to cancel): ")" val
				[[ "$val" == "/c" ]] && break
				if validate_ip "$val"; then
					config_set DOCKER_PROXY_HOST_IP "$val"
					break
				else
					msg bright_red "  Invalid IP address"
				fi
			done
			;;
		et)
			prompt_yn ETURNAL "Eturnal" "n"
			;;
		ph)
			prompt_yn PIHOLE "Pi-hole DNS" "y"
			;;
		ph_port)
			local old_ph_port=$(config_get PIHOLE_PORT "")
			while true; do
				read -r -e -p "$(p_yellow "  Pi-hole Port (/c to cancel): ")" val
				[[ "$val" == "/c" ]] && break
				if reserve_port "$val" "$old_ph_port"; then
					config_set PIHOLE_PORT "$val"
					break
				fi
			done
			;;
		md)
			prompt_yn MASTERDNSVPN "MasterDnsVPN" "n"
			;;
		md_domains)
			while true; do
				read -r -e -p "$(p_yellow "  MasterDnsVPN Domains (space-separated, /c to cancel): ")" val
				[[ "$val" == "/c" ]] && break
				local valid=true
				for d in $val; do
					validate_domain "$d" || {
						valid=false
						break
					}
				done
				if [[ $valid == true ]]; then
					config_set MASTERDNSVPN_DOMAINS "$val"
					break
				else
					msg bright_red "  Invalid domain(s)"
				fi
			done
			;;
		md_proxy)
			while true; do
				read -r -e -p "$(p_yellow "  MasterDnsVPN Proxy (empty to clear, /c to cancel): socks5://")" val
				[[ "$val" == "/c" ]] && break
				if [[ -z "$val" ]]; then
					config_set MASTERDNSVPN_PROXY ""
					break
				fi
				val="socks5://${val}"
				if validate_socks5_proxy "$val"; then
					config_set MASTERDNSVPN_PROXY "$val"
					break
				else
					msg bright_red "  Invalid proxy URL"
				fi
			done
			;;
		esac
	done
}

# === PAGE 6: CERTBOT (CLOUDFLARE DNS) ===
page_certbot() {
	while true; do
		render_header 6

		local count=$(config_get CERTBOT_COUNT 0)
		echo ""
		if [[ $count -gt 0 ]]; then
			for ((i=1; i<=count; i++)); do
				local cfolder=$(config_get "CERTBOT_${i}_FOLDER" "")
				p_mark n "  [$i] "
				p_bright_yellow "${cfolder:-"(unnamed)"}"
				echo ""
			done
		else
			msg gray "  (no domains added)"
		fi
		echo ""
		p_mark n "  [a] Add Domain"
		echo ""
		msg gray "  [ 0]  Back"
		echo ""
		read -r -e -p "$(p_bright_yellow "  > ")" input

		[[ "$input" == "0" ]] && return

		if [[ "$input" == "a" || "$input" == "A" ]]; then
			add_certbot
		elif [[ "$input" =~ ^[0-9]+$ ]] && [[ $input -ge 1 ]] && [[ $input -le $count ]]; then
			edit_certbot "$input"
		else
			msg bright_red "  Invalid option"
		fi
	done
}

add_certbot() {
	local token folder domains posthook

	while true; do
		echo ""
		read -r -e -p "$(p_mark y "  Cloudflare API token") (/c to cancel): " token
		[[ "$token" == "/c" ]] && return
		if [[ -n "$token" ]]; then
			local dup_idx=""
			local cc_count=$(config_get CERTBOT_COUNT 0)
			for ((ci=1; ci<=cc_count; ci++)); do
				[[ "$(config_get "CERTBOT_${ci}_TOKEN" "")" == "$token" ]] && dup_idx="$ci"
			done
			if [[ -n "$dup_idx" ]]; then
				echo ""
				p_yellow "  [!] Token matches Certbot #"
				p_bright_yellow "$dup_idx"
				msg yellow " — credentials file will be shared"
			fi
			break
		else
			msg bright_red "  Token required"
		fi
	done
	while true; do
		read -r -e -p "$(p_mark y "  Folder name") (/c to cancel): " folder
		[[ "$folder" == "/c" ]] && return
		if validate_filename "$folder"; then
			local exists=false
			local c_count=$(config_get CERTBOT_COUNT 0)
			for ((ci=1; ci<=c_count; ci++)); do
				[[ "$(config_get "CERTBOT_${ci}_FOLDER" "")" == "$folder" ]] && {
					exists=true
					break
				}
			done
			if [[ $exists == true ]]; then
				msg bright_red "  Folder name already exists"
			else
				break
			fi
		else
			msg bright_red "  Invalid folder name (use [a-zA-Z0-9._-])"
		fi
	done

	while true; do
		read -r -e -p "$(p_mark y "  Domains (space-separated)") (/c to cancel): " domains
		[[ "$domains" == "/c" ]] && return
		if [[ -z "$domains" ]]; then
			msg bright_red "  Domain required"
			continue
		fi
		local valid=true
		for d in $domains; do
			validate_domain "$d" y || {
				valid=false
				break
			}
		done
		if [[ $valid == true ]]; then
			break
		else
			msg bright_red "  Invalid domain(s)"
		fi
	done

	while true; do
		read -r -e -p "$(p_mark n "  Post-Hook (optional)") (/c to cancel): " posthook
		[[ "$posthook" == "/c" ]] && return
		break
	done

	local count=$(config_get CERTBOT_COUNT 0)
	count=$((count + 1))
	config_set CERTBOT_COUNT "$count"
	config_set "CERTBOT_${count}_TOKEN" "$token"
	config_set "CERTBOT_${count}_FOLDER" "$folder"
	config_set "CERTBOT_${count}_DOMAINS" "$domains"
	config_set "CERTBOT_${count}_POSTHOOK" "$posthook"
	msg green "  Domain added"
}

edit_certbot() {
	local idx=$1
	while true; do
		local domains=$(config_get "CERTBOT_${idx}_DOMAINS" "")
		echo ""
		p_yellow "  Domains: "
		p_bright_yellow "$domains"
		echo ""
		echo ""
		p_mark n "  [1] Edit Cloudflare API token"
		echo ""
		p_mark n "  [2] Edit folder name"
		echo ""
		p_mark n "  [3] Edit Domains"
		echo ""
		p_mark n "  [4] Edit Post-Hook"
		echo ""
		p_mark n "  [5] Delete"
		echo ""
		msg gray "  /c to go back"
		echo ""

		read -r -e -p "$(p_bright_yellow "  > ")" input

		[[ "$input" == "/c" ]] && return

		case "$input" in
		1)
			while true; do
				read -r -e -p "$(p_yellow "  Cloudflare API token (/c to cancel): ")" val
				[[ "$val" == "/c" ]] && break
				if [[ -n "$val" ]]; then
					config_set "CERTBOT_${idx}_TOKEN" "$val"
					break
				else
					msg bright_red "  Token required"
				fi
			done
			;;
		2)
			while true; do
				read -r -e -p "$(p_yellow "  Folder name (/c to cancel): ")" val
				[[ "$val" == "/c" ]] && break
				if validate_filename "$val"; then
					local exists=false
					local c_count=$(config_get CERTBOT_COUNT 0)
					for ((ci=1; ci<=c_count; ci++)); do
						[[ $ci -eq $idx ]] && continue
						[[ "$(config_get "CERTBOT_${ci}_FOLDER" "")" == "$val" ]] && {
							exists=true
							break
						}
					done
					if [[ $exists == true ]]; then
						msg bright_red "  Folder name already exists"
					else
						config_set "CERTBOT_${idx}_FOLDER" "$val"
						break
					fi
				else
					msg bright_red "  Invalid folder name (use [a-zA-Z0-9._-])"
				fi
			done
			;;
		3)
			while true; do
				read -r -e -p "$(p_yellow "  Domains (space-separated, /c to cancel): ")" val
				[[ "$val" == "/c" ]] && break
				if [[ -z "$val" ]]; then
					msg bright_red "  Domain required"
					continue
				fi
				local valid=true
				for d in $val; do
					validate_domain "$d" y || {
						valid=false
						break
					}
				done
			if [[ $valid == true ]]; then
				config_set "CERTBOT_${idx}_DOMAINS" "$val"
					break
				else
					msg bright_red "  Invalid domain(s)"
				fi
			done
			;;
		4)
			while true; do
				read -r -e -p "$(p_yellow "  Post-Hook (/c to cancel): ")" val
				[[ "$val" == "/c" ]] && break
				config_set "CERTBOT_${idx}_POSTHOOK" "$val"
				break
			done
			;;
		5)
			local count=$(config_get CERTBOT_COUNT 0)
			for ((i=idx; i<=count-1; i++)); do
				local nxt=$((i + 1))
				config_set "CERTBOT_${i}_TOKEN" "$(config_get "CERTBOT_${nxt}_TOKEN" "")"
				config_set "CERTBOT_${i}_FOLDER" "$(config_get "CERTBOT_${nxt}_FOLDER" "")"
				config_set "CERTBOT_${i}_DOMAINS" "$(config_get "CERTBOT_${nxt}_DOMAINS" "")"
				config_set "CERTBOT_${i}_POSTHOOK" "$(config_get "CERTBOT_${nxt}_POSTHOOK" "")"
			done
			CONFIG["CERTBOT_${count}_TOKEN"]=""
			CONFIG["CERTBOT_${count}_FOLDER"]=""
			CONFIG["CERTBOT_${count}_DOMAINS"]=""
			CONFIG["CERTBOT_${count}_POSTHOOK"]=""
			config_set CERTBOT_COUNT $((count - 1))
			msg green "  Domain deleted"
			return
			;;
		*) msg bright_red "  Invalid option" ;;
		esac
	done
}

# === PAGE 7: CONFIRMATION ===
validate_all() {
	local errors=()

	local hostname=$(config_get HOSTNAME)
	validate_hostname "$hostname" || errors+=("Hostname: invalid format")

	local tz=$(config_get TIMEZONE)
	validate_timezone "$tz" || errors+=("Timezone: invalid")

	local locs=$(config_get LOCALES)
	local bad_locales
	if ! bad_locales=$(validate_locales "$locs"); then
		errors+=("Locales: invalid – $bad_locales")
	fi

	local swap=$(config_get SWAP_SIZE)
	validate_swap_value "$swap" || errors+=("SWAP: invalid value")

	local ssh_user=$(config_get SSH_USER)
	validate_username "$ssh_user" || errors+=("SSH user: invalid or already exists")

	local ssh_key=$(config_get SSH_PUBLIC_KEY "")
	[[ -z "$ssh_key" ]] || validate_ssh_key "$ssh_key" || errors+=("SSH key: invalid format")

	local ssh_port=$(config_get SSH_PORT "")
	if [[ -n "$ssh_port" ]]; then
		validate_port "$ssh_port" || errors+=("SSH port: invalid")
		port_is_used "$ssh_port" && errors+=("SSH port: already in use on system")
	fi

	local knock=$(config_get SSH_KNOCK_SEQUENCE "")
	if [[ -n "$knock" ]]; then
		validate_knock_sequence "$knock" || errors+=("SSH knock: invalid format")
	fi

	if config_is_true TELEGRAM_ALERTS; then
		local token=$(config_get TELEGRAM_TOKEN "")
		validate_telegram_token "$token" || errors+=("Telegram token: invalid")
		local id=$(config_get TELEGRAM_ID "")
		validate_telegram_user_id "$id" || errors+=("Telegram ID: invalid")
		local proxy=$(config_get TELEGRAM_PROXY "")
		[[ -z "$proxy" ]] || validate_proxy "$proxy" || errors+=("Telegram proxy: invalid")
	fi

	if config_is_true RKN_AS; then
		local rkn_proxy=$(config_get RKN_PROXY "")
		[[ -z "$rkn_proxy" ]] || validate_socks5_proxy "$rkn_proxy" || errors+=("RKN proxy: invalid")
	fi

	local ca_count=$(config_get CA_COUNT 0)
	local -a ca_names=()
	for ((i=1; i<=ca_count; i++)); do
		local ca_name=$(config_get "CA_${i}_NAME" "")
		validate_filename "$ca_name" || errors+=("CA #$i: name is empty or invalid")
		for existing in "${ca_names[@]}"; do
			[[ "$existing" == "$ca_name" ]] && errors+=("CA #$i: duplicate name '$ca_name'")
		done
		ca_names+=("$ca_name")
		local ca_b64=$(config_get "CA_${i}_CA_B64" "")
		local ca_pem
		ca_pem=$(base64 -d 2>/dev/null <<<"$ca_b64")
		validate_ca_certificate "$ca_pem" || errors+=("CA #$i: invalid PEM certificate")
	done

	if config_is_true TAILSCALE; then
		local ts_srv=$(config_get TAILSCALE_SERVER "")
		validate_url "$ts_srv" || errors+=("Tailscale server: invalid URL")
		local ts_key=$(config_get TAILSCALE_PREAUTH_KEY "")
		validate_hs_preauth_key "$ts_key" || errors+=("Tailscale pre-auth key: must be 77 chars")
	fi

	if config_is_true RCLONE; then
		local rc_name=$(config_get RCLONE_NAME "")
		validate_rclone_name "$rc_name" || errors+=("Rclone name: invalid")
		local rc_url=$(config_get RCLONE_URL "")
		validate_url "$rc_url" || errors+=("Rclone URL: invalid")
	fi

	if config_is_true THREE_X_UI; then
		local xu_panel=$(config_get THREE_X_UI_PANEL_DOMAIN "")
		validate_domain "$xu_panel" || errors+=("3X-UI panel domain: invalid or empty")
		local xu_reality=$(config_get THREE_X_UI_REALITY_DOMAIN "")
		validate_domain "$xu_reality" || errors+=("3X-UI reality domain: invalid or empty")
	fi

	if config_is_true DOCKER_PROXY; then
		local dp_ip=$(config_get DOCKER_PROXY_HOST_IP "")
		validate_ip "$dp_ip" || errors+=("Docker proxy host IP: invalid")
	fi

	if config_is_true PIHOLE; then
		local ph_port=$(config_get PIHOLE_PORT "")
		validate_port "$ph_port" || errors+=("Pi-hole port: invalid")
		port_is_used "$ph_port" && errors+=("Pi-hole port: already in use on system")
	fi

	if config_is_true MASTERDNSVPN; then
		local md_domains=$(config_get MASTERDNSVPN_DOMAINS "")
		for d in $md_domains; do
			validate_domain "$d" || errors+=("MasterDnsVPN domain '$d': invalid")
		done
		local md_proxy=$(config_get MASTERDNSVPN_PROXY "")
		[[ -z "$md_proxy" ]] || validate_proxy "$md_proxy" || errors+=("MasterDnsVPN proxy: invalid")
	fi

	local cert_count=$(config_get CERTBOT_COUNT 0)
	local -A seen_tokens
	for ((i=1; i<=cert_count; i++)); do
		local c_token=$(config_get "CERTBOT_${i}_TOKEN" "")
		[[ -n "$c_token" ]] || errors+=("Certbot #$i: API token is empty")
		local c_folder=$(config_get "CERTBOT_${i}_FOLDER" "")
		validate_filename "$c_folder" || errors+=("Certbot #$i: folder name is invalid")
		local c_domains=$(config_get "CERTBOT_${i}_DOMAINS" "")
		for d in $c_domains; do
			validate_domain "$d" y || errors+=("Certbot #$i: domain '$d' invalid")
		done
		if [[ -n "$c_token" ]]; then
			local prev_idx="${seen_tokens[$c_token]}"
			if [[ -n "$prev_idx" ]]; then
				errors+=("Certbot #$i: API token matches Certbot #$prev_idx (duplicate)")
			else
				seen_tokens[$c_token]="$i"
			fi
		fi
	done

	if [[ ${#errors[@]} -gt 0 ]]; then
		echo ""
		msg bright_red "  ┌─ Validation Errors ─────────────────────"
		for err in "${errors[@]}"; do
			msg bright_red "  │ $err"
		done
		msg bright_red "  └──────────────────────────────────────────"
		return 1
	fi
	return 0
}

page_confirmation() {
	while true; do
		render_header 7
		echo ""
		p_mark y "  [1] Let's go: "
		p_gray "[ ]"
		echo ""
		msg gray "  [ 0]  Back"
		echo ""
		read -r -e -p "$(p_bright_yellow "  > ")" input
		[[ "$input" == "0" ]] && return 1

		if [[ "$input" == "1" ]]; then
			echo ""
			msg yellow "  Running validation..."
			if validate_all; then
				p_yellow "  [1] Let's go: "
				p_bright_green "[✓]"
				echo ""
				msg bright_green "  All checks passed! Proceeding to setup..."
				echo ""
				return 0
			else
				msg bright_red "  Fix the errors above and try again"
			fi
		else
			msg bright_red "  Invalid option"
		fi
	done
}

# === MAIN MENU ===
main_menu() {
  echo ""
  msg red "  [!] Be careful! Keep in mind that this script is intended to be run on a blank system. If you run it on a configured server, you might lose data or something might break. Whatever..."
  msg red "  [!!] Port range: 1–60000 (ports above 60000 are not allowed)"

	while true; do
		echo ""
		msg bright_yellow "  bootstrap script by nik durachyo"
		echo ""
		for ((i=1; i<=7; i++)); do
			p_bright_yellow "  [$i] "
			msg yellow "${TAB_NAMES[$((i - 1))]}"
		done
		msg gray "  [0] Exit"
		echo ""
		read -r -e -p "$(p_bright_yellow "  Select page > ")" choice

		case "$choice" in
		0)
			msg yellow "Exiting."
			exit 0
			;;
		1) page_system_info ;;
		2) page_system_config ;;
		3) page_secure_server ;;
		4) page_custom_ca ;;
		5) page_soft ;;
		6) page_certbot ;;
		7)
			if page_confirmation; then
				break
			fi
			;;
		*) msg bright_red "  Invalid option" ;;
		esac
	done
}

create_swap() {
	local size=$1
	[[ $size -eq 0 ]] && return 0
	local swapfile="/swapfile"

	local old_paths=()
	while IFS=' ' read -r path _; do
		[[ "$path" == /* ]] && old_paths+=("$path")
	done < <(swapon --show --noheadings 2>/dev/null || true)

	if [[ ${#old_paths[@]} -gt 0 ]]; then
		msg yellow "Deactivating swap..."
		swapoff -a
	fi

	if grep -qs '\s\+swap\s\+' /etc/fstab 2>/dev/null; then
		msg yellow "Removing swap entries from fstab..."
		while IFS=' ' read -r path _ _ _ _; do
			[[ "$path" == /* && -f "$path" ]] && rm -f "$path"
		done < <(grep '\s\+swap\s\+' /etc/fstab)
		sed -i '/\s\+swap\s\+/d' /etc/fstab
	fi

	for p in "${old_paths[@]}"; do
		[[ -f "$p" && "$p" != "$swapfile" ]] && rm -f "$p"
	done

	[[ -f "$swapfile" ]] && rm -f "$swapfile"

	msg yellow "Creating swap file ($size)..."
	dd if=/dev/zero of="$swapfile" bs=1M count=${size%[A-Za-z]} status=progress
	chmod 600 "$swapfile"
	mkswap "$swapfile"
	echo "$swapfile none swap sw 0 0" >> /etc/fstab
	swapon "$swapfile"
	msg green "Swap ready ($size)"
}

secure_proc() {
  config_is_true SECURE_PROC && echo "proc /proc proc defaults,hidepid=2,gid=988 0 0" >> /etc/fstab
}

add_ca_to_system() {
  local ca_count=$(config_get CA_COUNT 0)
  [[ $ca_count -eq 0 ]] && return 0
  for ((i=1; i<=ca_count; i++)); do
    local ca_name=$(config_get "CA_${i}_NAME" "")
    local ca_b64=$(config_get "CA_${i}_CA_B64" "")
    local ca_pem
    ca_pem=$(base64 -d <<<"$ca_b64")
    echo "$ca_pem" > "/usr/local/share/ca-certificates/${ca_name}.crt"
  done
  update-ca-certificates
}

certbot_setup() {
  local cert_count=$(config_get CERTBOT_COUNT 0)
  [[ $cert_count -eq 0 ]] && return 0

  local -A TOKEN_FILES
  local cf_token_dir="/etc/letsencrypt/cf-tokens"
  local token_counter=0
  mkdir -p "$cf_token_dir"

  for ((i=1; i<=cert_count; i++)); do
    local c_token=$(config_get "CERTBOT_${i}_TOKEN" "")
    local c_folder=$(config_get "CERTBOT_${i}_FOLDER" "")
    local c_domains=$(config_get "CERTBOT_${i}_DOMAINS" "")
    local c_posthook=$(config_get "CERTBOT_${i}_POSTHOOK" "")

    local creds_file
    if [[ -n "${TOKEN_FILES[$c_token]}" ]]; then
      creds_file="${TOKEN_FILES[$c_token]}"
    else
      token_counter=$((token_counter + 1))
      creds_file="${cf_token_dir}/$(printf '%03d' "$token_counter").ini"
      echo "dns_cloudflare_api_token = $c_token" > "$creds_file"
      chmod 600 "$creds_file"
      TOKEN_FILES[$c_token]="$creds_file"
    fi

    local hook_cmd=""
    if [[ -n "$c_posthook" ]]; then
      hook_cmd="--deploy-hook '$c_posthook'"
    fi

    local certbot_args=()
    for d in $c_domains; do certbot_args+=(-d "$d"); done
    certbot certonly --authenticator dns-cloudflare --dns-cloudflare-credentials "$creds_file" "${certbot_args[@]}" --key-type ecdsa $hook_cmd --non-interactive --agree-tos --register-unsafely-without-email --cert-name "$c_folder"
  done

  (crontab -l 2>/dev/null
  echo '@monthly certbot renew --non-interactive > /dev/null 2>&1'
  ) | crontab -
}

configure_sysctl() {
  local sysctl_file="/etc/sysctl.d/99-bootstrap.conf"

  cat > "$sysctl_file" <<'SYSCTL_EOF' || { msg red "  Failed to write $sysctl_file"; return 1; }
# /etc/sysctl.d/99-bootstrap.conf
# These parameters in this file will be added/updated to the sysctl.conf file.
# Read More: https://github.com/hawshemi/Linux-Optimizer/blob/main/files/sysctl.conf


## File system settings
## ----------------------------------------------------------------

# Set the maximum number of open file descriptors
fs.file-max = 67108864


## Network core settings
## ----------------------------------------------------------------

# Specify default queuing discipline for network devices
net.core.default_qdisc = fq

# Configure maximum network device backlog
net.core.netdev_max_backlog = 32768

# Set maximum socket receive buffer
net.core.optmem_max = 262144

# Define maximum backlog of pending connections
net.core.somaxconn = 65536

# Configure maximum TCP receive buffer size
net.core.rmem_max = 33554432

# Set default TCP receive buffer size
net.core.rmem_default = 1048576

# Configure maximum TCP send buffer size
net.core.wmem_max = 33554432

# Set default TCP send buffer size
net.core.wmem_default = 1048576


## TCP settings
## ----------------------------------------------------------------

# Define socket receive buffer sizes
net.ipv4.tcp_rmem = 16384 1048576 33554432

# Specify socket send buffer sizes
net.ipv4.tcp_wmem = 16384 1048576 33554432

# Set TCP congestion control algorithm to BBR
net.ipv4.tcp_congestion_control = bbr

# Enable TCP Fast Open (client + server)
net.ipv4.tcp_fastopen = 3

# Configure TCP FIN timeout period
net.ipv4.tcp_fin_timeout = 25

# Set keepalive time (seconds)
net.ipv4.tcp_keepalive_time = 1200

# Configure keepalive probes count and interval
net.ipv4.tcp_keepalive_probes = 7
net.ipv4.tcp_keepalive_intvl = 30

# Define maximum orphaned TCP sockets
net.ipv4.tcp_max_orphans = 819200

# Set maximum TCP SYN backlog
net.ipv4.tcp_max_syn_backlog = 20480

# Configure maximum TCP Time Wait buckets
net.ipv4.tcp_max_tw_buckets = 1440000

# Define TCP memory limits
net.ipv4.tcp_mem = 65536 1048576 33554432

# Enable TCP MTU probing
net.ipv4.tcp_mtu_probing = 1

# Define minimum amount of data in the send buffer before TCP starts sending
net.ipv4.tcp_notsent_lowat = 32768

# Specify retries for TCP socket to establish connection
net.ipv4.tcp_retries2 = 8

# Enable TCP SACK and DSACK
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1

# Disable TCP slow start after idle
net.ipv4.tcp_slow_start_after_idle = 0

# Enable TCP window scaling
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 2

# Enable TCP ECN
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1

# Enable the use of TCP SYN cookies to help protect against SYN flood attacks
net.ipv4.tcp_syncookies = 1


## ICMP rate limiting
## ----------------------------------------------------------------

# Limit ICMP rate (IPv4 and IPv6)
net.ipv4.icmp_msgs_burst = 20
net.ipv4.icmp_msgs_per_sec = 20
net.ipv4.icmp_ratelimit = 100
net.ipv6.icmp.ratelimit = 100


## UDP settings
## ----------------------------------------------------------------

# Define UDP memory limits
net.ipv4.udp_mem = 65536 1048576 33554432


## IPv6 settings
## ----------------------------------------------------------------

# Enable IPv6
#net.ipv6.conf.all.disable_ipv6 = 0

# Enable IPv6 by default
#net.ipv6.conf.default.disable_ipv6 = 0

# Enable IPv6 on the loopback interface (lo)
#net.ipv6.conf.lo.disable_ipv6 = 0


## UNIX domain sockets
## ----------------------------------------------------------------

# Set maximum queue length of UNIX domain sockets
net.unix.max_dgram_qlen = 256


## Virtual memory (VM) settings
## ----------------------------------------------------------------

# Specify minimum free Kbytes at which VM pressure happens
vm.min_free_kbytes = 45056

# Define how aggressively swap memory pages are used
vm.swappiness = 15

# Set the tendency of the kernel to reclaim memory used for caching of directory and inode objects
vm.vfs_cache_pressure = 150


## Network Configuration
## ----------------------------------------------------------------

# Configure reverse path filtering
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.rp_filter = 2

# Disable source route acceptance
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Neighbor table settings
net.ipv4.neigh.default.gc_thresh1 = 512
net.ipv4.neigh.default.gc_thresh2 = 2048
net.ipv4.neigh.default.gc_thresh3 = 16384
net.ipv4.neigh.default.gc_stale_time = 60

# ARP settings
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.lo.arp_announce = 2
net.ipv4.conf.all.arp_announce = 2

# Kernel panic timeout
kernel.panic = 10

# Set dirty page ratio for virtual memory
vm.dirty_ratio = 20
vm.dirty_ratio = 10

# Heuristic overcommit — kernel decides what's safe, standard for most workloads.
vm.overcommit_memory = 0

# Sets overcommit to 100% of RAM when enabled, but ignored here since overcommit_memory = 2 disables it.
vm.overcommit_ratio = 100

## Security hardening
## ----------------------------------------------------------------
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1

SYSCTL_EOF

  enable_bbr
}

enable_bbr() {
  local sysctl_file="/etc/sysctl.d/99-bootstrap.conf"
  local available_cc
  available_cc=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "")

  if ! echo "$available_cc" | grep -qw "bbr"; then
    modprobe tcp_bbr 2>/dev/null || true
    available_cc=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "")
  fi

  if ! echo "$available_cc" | grep -qw "bbr"; then
    sed -i 's/tcp_congestion_control = bbr/tcp_congestion_control = cubic/' "$sysctl_file"
  fi
}

configure_systemd_limits() {
  local systemd_system="/etc/systemd/system.conf"
  local systemd_user="/etc/systemd/user.conf"

  sed -i '/^DefaultLimitNOFILE=/d; /^DefaultLimitSTACK=/d' "$systemd_system" 2>/dev/null
  cat >> "$systemd_system" <<'SD_EOF' || { msg red "  Failed to write $systemd_system"; return 1; }
DefaultLimitNOFILE=1048576
DefaultLimitSTACK=65536
SD_EOF

  sed -i '/^DefaultLimitNOFILE=/d; /^DefaultLimitSTACK=/d' "$systemd_user" 2>/dev/null
  cat >> "$systemd_user" <<'SD_USER_EOF' || { msg red "  Failed to write $systemd_user"; return 1; }
DefaultLimitNOFILE=1048576
DefaultLimitSTACK=65536
SD_USER_EOF
}

install_base_packages() {
  DEBIAN_FRONTEND=noninteractive apt update -q && apt -y full-upgrade
  DEBIAN_FRONTEND=noninteractive apt install -yq unattended-upgrades curl wget psad rkhunter sudo fwknop-apparmor-profile libpam-google-authenticator expect git pwgen cryptsetup rclone nginx-full python3-certbot-dns-cloudflare jq sqlite3 ufw fail2ban ipset
}

add_apt_repositories() {
  local codename
  codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $codename
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  curl -fsSL "https://pkgs.tailscale.com/stable/debian/$codename.noarmor.gpg" -o /usr/share/keyrings/tailscale-archive-keyring.gpg
  curl -fsSL "https://pkgs.tailscale.com/stable/debian/$codename.tailscale-keyring.list" -o /etc/apt/sources.list.d/tailscale.list
}

install_netdata() {
  curl https://get.netdata.cloud/kickstart.sh > /tmp/netdata-kickstart.sh && DISABLE_TELEMETRY=1 sh /tmp/netdata-kickstart.sh --no-updates --stable-channel --disable-telemetry --non-interactive
}

install_extra_packages() {
  DEBIAN_FRONTEND=noninteractive apt update -q && apt -y full-upgrade && apt -y autoremove --purge && apt -y autoclean && apt clean
  DEBIAN_FRONTEND=noninteractive apt install -yq netdata tailscale docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  DEBIAN_FRONTEND=noninteractive apt -y autoremove --purge && apt -y autoclean && apt clean
}

configure_system() {
  local hostname=$(config_get HOSTNAME "")

  echo "${hostname%%.*}" > /etc/hostname
  tee /etc/hosts > /dev/null << EOF
127.0.0.1       localhost
127.0.1.1       ${hostname} ${hostname%%.*}

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

  timedatectl set-timezone $(config_get TIMEZONE "UTC")

  sed -i -E 's/^([^#])/#\1/' /etc/locale.gen
  local locs=$(config_get LOCALES)
  for loc in $locs; do
    loc=$(printf '%s' "$loc" | sed 's/[][\.*^$+?{|()]/\\&/g')
    sed -i "/^# *${loc}/s/^# *//i" /etc/locale.gen
  done
  locale-gen
  sed -i '/^LC_/d' /etc/default/locale
  localectl set-locale "LANG=$(echo "$locs" | awk '{print $1}')"

  create_swap $(config_get SWAP_SIZE "0")
  secure_proc
  add_ca_to_system
  certbot_setup

  configure_sysctl
  sysctl --system || msg yellow "  Some sysctl parameters failed to apply"
  configure_systemd_limits
}

first_stage() {
  install_base_packages
  add_apt_repositories
  install_netdata
  install_extra_packages
  configure_system
}

second_stage() {
  
}

final_screen() {

  #не забыть написать про перезагрузку
}

# === ENTRY POINT ===
main() {
  if [[ -n "$1" ]]; then
    CONFIG_FILE="$1"
  fi
  config_load

  case "$(get_stage)" in
    0)
      main_menu

      msg green "Let me configure something..."
      first_stage

      read -r -e -p "$(msg yellow "Please return after the system restarts to continue the installation. (tap enter)")" _
      msg green "Ok... Reeboting in 3"
      sleep 1
      msg green "      Reeboting in 2"
      sleep 1
      msg green "      Reeboting in 1"
      sleep 1

      set_stage 1
      bash_profile_mod
      reboot
      exit
      ;;
    1)
      msg green "Let's finish up the rest!"
      second_stage


      set_stage 2
      bash_profile_mod
      final_screen
      exit
      ;;
    *)
      msg red "You've already used the bootstrap script! Bye-bye :)"
      bash_profile_mod
      exit
      ;;
  esac
}

main "$@"
