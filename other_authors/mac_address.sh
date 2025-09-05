#!/usr/bin/env bash

iface="${1:-eth0}"

scan() {
	local msg="Discovering MAC addresses with $iface. Please wait..."
	local len=$(( ${#msg} + 4 ))
	len=$(( len + (len % 2) ))

	dialog --infobox "$msg" 3 "$len" 1>&2
	fping -q -r 0 -t 10 -I "$iface" -g "$1"
	ip neigh | awk '{print $5}' | sort -u
}

gen() {
	local msg="Generating MAC address for $iface. Please wait..."
	local len=$(( ${#msg} + 4 ))
	len=$(( len + (len % 2) ))

	dialog --infobox "$msg" 3 "$len" 1>&2
	local blacklist
	mapfile -t blacklist <<< "$1"
	while :; do
		local hex
		local mac

		hex=$(tr -dc '0-9a-f' </dev/urandom | head -c 12)
		mac=$(echo "$hex" | sed 's/../&:/g; s/:$//')

		# Don't allow broadcast or zero
		if [[ "$mac" = "FF:FF:FF:FF:FF:FF" ]] || [[ "$mac" = "00:00:00:00:00:00" ]]; then
			continue
		fi

		# Don't allow multi-cast or universally administered MAC addresses
		first_byte=$((16#${hex:0:2}))
		first_byte=$((first_byte & ~1)) # Ensure unicast
		first_byte=$((first_byte | 2))  # Ensure locally administered
		first_byte=$(printf "%02x" $first_byte)
		hex="${first_byte}${hex:2}"

		# Skip address already in use
		local skip=0
		for b in "${blacklist[@]}"; do
			[[ "$mac" = "$b" ]] && skip=1 && break
		done
		[[ $skip -eq 1 ]] && continue

		echo "$mac"
		break
	done
}

update_uboot() {
	local file="/media/fat/linux/u-boot.txt"
	if [ -n "$1" ] && [ "$iface" = "eth0" ]; then
		if [ ! -e "$file" ]; then
			echo "ethaddr=${1^^}" > "$file"
		elif grep -q 'ethaddr=' "$file"; then
			sed -i "s/\(ethaddr=\)[0-9A-Fa-f:]\+/\1${1^^}/" "$file"
		else
			echo "ethaddr=${1^^}" >> "$file"
		fi
	fi
}

update_mac() {
	local msg="Configuring MAC address for $iface. Please wait..."
	local len=$(( ${#msg} + 4 ))
	len=$(( len + (len % 2) ))

	dialog --infobox "$msg" 3 "$len" 1>&2
	dhcpcd -k 2>/dev/null 1>/dev/null # Sadly can't specify a iface here due to dhcpcd bug
	ip link set dev "$iface" down 2>/dev/null 1>/dev/null
	ip link set dev "$iface" address "$1" 2>/dev/null 1>/dev/null
	ip link set dev "$iface" up 2>/dev/null 1>/dev/null
	sleep 3
	dhcpcd --waitip -t 7 2>/dev/null 1>/dev/null
}

warn() {
	dialog --yesno "Changing MAC address will cause network disruptions on this device.\nMake\
	sure any file transfers or SSH sessions are finished and disconnected before proceeding.\
	\n\nDo you want to continue?" 10 52 1>&2
}

auto() {
	if ! warn; then
		return
	fi

	local choice
	local macs=""
	local msg="Would you like to discover MAC addresses already in use on $iface network.\
		Doing so helps prevent a MAC address already in use being assigned to this device,\
		however on some networks it may take a long time to complete."
	choice=$(dialog --menu "$msg" 12 64 3 \
		Y "Yes, discover MAC addresses on $iface" N "No, just generate a MAC address" 3>&1 1>&2 2>&3)

	case $choice in
		Y)
			local cidr
			cidr=$(ip -o -f inet addr show "$iface" | awk 'NR==0 {exit 1} {print $4}')
			if [ -n "$cidr" ]; then
				macs=$(scan "$cidr")
			else
				local msg="There doesn't appear to be a network connection on $iface. It will not be possible to discover MAC addresses in use on your network.\
					\n\nWould you like to continue generating a new MAC address anyway?"

				if ! dialog --yesno "$msg" 8 72 1>&2; then
					return
				fi
			fi
		;;
		N) ;;
		*) return ;;
	esac

	local mac
	local check
	mac=$(gen "$macs")

	update_mac "$mac"

	check=$(cat "/sys/class/net/$iface/address")

	if [ "$check" = "$mac" ]; then
		update_uboot "$check"

		local msg="The MAC address for $iface is now '$check'"
		local len=$(( ${#msg} + 4 ))
		len=$(( len + (len % 2) ))

		dialog --msgbox "$msg" 5 "$len" 1>&2
		dialog --clear
		exit 0
	else
		dialog --msgbox "There was an error configuring the MAC address" 5 52 1>&2
	fi
}

manual() {
	if ! warn; then
		return
	fi

	local current
	current=$(cat "/sys/class/net/$iface/address")
	local input="$current"
	while true; do
		if ! input=$(dialog --inputbox "The MAC address for $iface is currently '$current'\n\nPlease enter a new MAC address..." 11 42 "$input" 3>&1 1>&2 2>&3); then
			return
		fi

		# Convert '-' to ':'
		input=${input//-/:}

		# Validate user input is a MAC address
		if [[ ! "$input" =~ ^([0-9A-Fa-f]{2}([-:])){5}([0-9A-Fa-f]{2})$ ]]; then
			dialog --msgbox "Not a valid MAC address." 5 52 1>&2
			continue
		fi

		# Validate user input isn't a special address
		first_byte=$((16#${input:0:2}))
		if (( first_byte & 1 )) || [[ "$input" = "FF:FF:FF:FF:FF:FF" ]] || [[ "$input" = "00:00:00:00:00:00" ]]; then
			dialog --msgbox "This MAC address can not be assigned to a network adapter." 7 32 1>&2
			continue
		fi

		# Don't reconfigure if the users MAC address is already what is set
		if [ "${input^^}" = "${current^^}" ]; then
			return
		fi

		update_mac "$input"

		local check
		check=$(cat "/sys/class/net/$iface/address")

		if [ "${check^^}" = "${input^^}" ]; then
			update_uboot "$check"

			local msg="The MAC address for $iface is now '$check'"
			local len=$(( ${#msg} + 4 ))
			len=$(( len + (len % 2) ))

			dialog --msgbox "$msg" 5 "$len" 1>&2
			dialog --clear
			exit 0
		else
			dialog --msgbox "There was an error configuring the MAC address" 5 52 1>&2
		fi
	done
}

main_menu() {
  # Check required commands exist
  for cmd in dialog fping ip dhcpcd; do
	if ! command -v "$cmd" &> /dev/null; then
		echo "Error: Required command '$cmd' not found." >&2
		exit 1
	fi
  done

	# Check script is running as root
	if [ "$EUID" -ne 0 ]; then
		dialog --msgbox "Configuring MAC addresses requires root.\nPlease run again as root." 6 52
		dialog --clear
		exit 1
	fi

	# Check network interface exists
	if [ ! -d "/sys/class/net/$iface" ]; then
		dialog --msgbox "No interface named '$iface'.\nPlease run again and specify the interface." 6 52
		dialog --clear
		exit 1
	fi

	# Don't allow SSH sessions to run the script (as they would SIGHUP in the process)
	if [ -n "$SSH_TTY" ]; then
		dialog --msgbox "You appear to be running in a SSH session.\
		Changing MAC address will cause network disruptions to this device.\
		\n\nPlease run again locally on the device." 9 52
		dialog --clear
		exit 1
	fi

	while true; do
	  local addr
	  local choice
		addr=$(cat "/sys/class/net/$iface/address")
		choice=$(dialog --menu "The current MAC address for $iface is '$addr'.\n\nWhat do you want to do?" 12 36 3 \
			1 "Generate MAC address" 2 "Set MAC address manually" 3>&1 1>&2 2>&3)

		case $choice in
			1)
				auto
			;;
			2)
				manual
			;;
			*)
				dialog --clear
				exit 0
			;;
		esac
	done
}

main_menu
