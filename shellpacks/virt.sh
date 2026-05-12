# shellpacks/virt.sh
# Implicit dependencies:
# - shellpacks/common.sh (SHELLPACK_ERROR, SHELLPACK_SUCCESS)
# - MARVIN_KVM_DOMAIN

: "${SHELLPACK_SUCCESS:=0}"
: "${SHELLPACK_ERROR:=-1}"
: "${SHELLPACK_FAILURE:=-1}"

default_timeout=600
default_shutdown_timeout=30

# Waits until a machine is running and available over SSH.
# Parameters: <VM_IP> [timeout_sec] [poll_intervall_sec]
function vm_wait_ssh() {
	if [[ -z "${1:-}" ]]; then
		echo "ERROR: vm_wait_ssh requires a target IP/hostname as the first argument." >&2
		return "${SHELLPACK_ERROR}"
	fi

	local target="${1}"
	local timeout="${2:-${default_timeout}}"
	local interval="${3:-10}"
	local elapsed=0

	while (( elapsed < timeout )); do
		# BatchMode disables interactive pronts (i.e., we don't need expect scripts).
		if ssh -q "${MMTESTS_SSH_OPTIONS:-}" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "root@${target}" echo "marvin-ping" >/dev/null 2>&1; then
			return "${SHELLPACK_SUCCESS}"
		fi
		sleep "${interval}"
		(( elapsed += interval ))
	done

	return "${SHELLPACK_ERROR}"
}

# Accepts the VM name as parameter (fallback to MARVIN_KVM_DOMAIN or
# its default, if none is provided).
function libvirt::vm_is_defined() {
	local vm="${1:-${MARVIN_KVM_DOMAIN:-marvin-mmtests}}"

	if virsh dominfo "${vm}" >/dev/null 2>&1; then
		return "${SHELLPACK_SUCCESS}"
	fi

	return "${SHELLPACK_ERROR}"
}

# Accepts the VM name as parameter (fallback to MARVIN_KVM_DOMAIN or
# its default, if none is provided).
function libvirt::vm_is_running() {
	local vm="${1:-${MARVIN_KVM_DOMAIN:-marvin-mmtests}}"
	local state

	if ! state=$(virsh domstate "${vm}" 2>/dev/null); then
		return "${SHELLPACK_ERROR}"
	fi

	if [[ "${state}" == "running" ]]; then
		return "${SHELLPACK_SUCCESS}"
	fi

	return "${SHELLPACK_ERROR}"
}

# Obtains the IP address of a VM, given the name of the VM (as it is known
# to libvirt).
function libvirt::vm_ip_address() {
	local vm="${1}"
	local timeout="${2:-${default_timeout:-600}}"
	local start_time current_time running

	[[ "${timeout}" == "0" ]] && timeout=""
	start_time=$(date +%s)

	while true; do
		if [[ -n "${timeout}" ]]; then
			current_time=$(date +%s)
			running=$(( current_time - start_time ))
			if (( running > timeout )); then
				echo "ERROR: Timeout exceeded for discovering ${vm} IP address" >&2
				return "${SHELLPACK_ERROR}"
			fi
		fi

		local ip_addr=""

		# TIER 1: Libvirt DHCP Leases (O(1) lookup, zero traffic)
		ip_addr=$(virsh domifaddr "${vm}" --source lease 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -n 1 || true)

		# TIER 2: QEMU Guest Agent (Bypasses host networking)
		if [[ -z "${ip_addr}" ]]; then
			ip_addr=$(virsh domifaddr "${vm}" --source agent 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -n 1 || true)
		fi

		# TIER 3: Legacy ARP Fallback
		if [[ -z "${ip_addr}" ]]; then
			local macs
			macs=$(virsh dumpxml "${vm}" 2>/dev/null | grep "mac address" | sed "s/.*'\(.*\)'.*/\1/g" || true)

			if [[ -n "${macs}" ]]; then
				# 3.1: Dynamic ARP Cache Warm-up
				# Discovers the bridge the VM is attached to and extracts the broadcast address
				local bridge bcast
				bridge=$(virsh domiflist "${vm}" 2>/dev/null | awk 'NR>2 && $3!="" {print $3; exit}' || true)
				if [[ -n "${bridge:-}" && "${bridge}" != "-" ]]; then
					bcast=$(ip -4 addr show "${bridge}" 2>/dev/null | awk '/brd/ {print $6}' || true)
					if [[ -n "${bcast:-}" ]]; then
						ping -c 2 -b "${bcast}" >/dev/null 2>&1 || true
					fi
				fi

				# 3.2: L2 Cache Parsing (ARP/Neighbor)
				local mac guest_ips test_ip
				for mac in ${macs}; do
					guest_ips=""
					if command -v ip >/dev/null 2>&1; then
						guest_ips=$(ip n show 2>/dev/null | awk -v m="${mac}" 'tolower($0) ~ tolower(m) {print $1}' || true)
					elif command -v arp >/dev/null 2>&1; then
						guest_ips=$(arp -an 2>/dev/null | grep -i "${mac}" | awk '{ gsub(/[\(\)]/,"",$2); print $2 }' || true)
					fi

					# 3.3: L3 Validation (Ping + REACHABLE state lock)
					for test_ip in ${guest_ips}; do
						if ping -c 1 -q "${test_ip}" >/dev/null 2>&1; then
							local state="UNKNOWN"
							while [[ "${state}" != "REACHABLE" ]]; do
								if command -v ip >/dev/null 2>&1; then
									state=$(ip n show 2>/dev/null | awk -v ip="${test_ip}" '$1 == ip {print $NF}' || echo "UNKNOWN")
								else
									# Fallback loop breaker if 'ip' is missing
									state="REACHABLE"
								fi
								[[ "${state}" != "REACHABLE" ]] && sleep 1
							done
							
							# Validation complete
							ip_addr="${test_ip}"
							break 2 # Break out of both IP and MAC loops
						fi
					done
				done
			fi
		fi

		# Exit Condition
		if [[ -n "${ip_addr:-}" ]]; then
			echo "${ip_addr}"
			return "${SHELLPACK_SUCCESS}"
		fi

		sleep 10
	done
}

# Checks if a VM has already been defined and is known to libvirt. If not,
# looks for a valid XML config file for such VM (within some directories),
# and defines it if it finds one.
# Parameters: <vm_name> <dir_1> [dir_2] ...
function libvirt::vm_define_if_missing() {
	if [[ -z "${1:-}" ]]; then
		echo "ERROR: libvirt::vm_define_if_missing requires a VM name." >&2
		return "${SHELLPACK_ERROR}"
	fi

	local vm="${1}"
	shift
	local dirs=("$@")

	if libvirt::vm_is_defined "${vm}" ; then
		# If the VM exists already, we're done!
		return "${SHELLPACK_SUCCESS}"
	fi

	echo "${vm} not found: looking for a suitable XML config file..."

	local dir xml_file match_found="false"

	# For iterating through files
	local shopt_save
	shopt_save=$(shopt -p nullglob) || true
	shopt -s nullglob nocaseglob

	for dir in "${dirs[@]}"; do
		if [[ ! -d "${dir}" ]]; then continue; fi

		for xml_file in "${dir}"/*.xml; do
			# We only care about valid libvirt VM config files.
			if ! virt-xml-validate "${xml_file}" >/dev/null 2>&1; then
				continue
			fi

			local xml_name
			xml_name=$(xmllint --xpath 'string(//domain/name)' "${xml_file}" 2>/dev/null || true)

			if [[ "${xml_name}" == "${vm}" ]]; then
				echo "Match found! Defining ${vm} using ${xml_file}"
				if virsh define "${xml_file}" >/dev/null; then
					match_found="true"
					break 2 # Esce da entrambi i cicli (file e directory)
				else
					echo "ERROR: Failed to define ${vm} from ${xml_file}" >&2
					eval "${shopt_save}"
					return "${SHELLPACK_ERROR}"
				fi
			fi
		done
	done

	eval "${shopt_save}"

	if [[ "${match_found}" == "false" ]]; then
		echo "ERROR: ${vm} not defined, and no suitable XML config file found." >&2
		return "${SHELLPACK_ERROR}"
	fi

	return "${SHELLPACK_SUCCESS}"
}

# Start one or more VMs via libvirt (virsh). The names of the VMs (as libvirt
# knows them) are the parameters.
function libvirt::vm_start() {
	local vms=("$@")
	local timeout="${default_timeout}"

	if (( ${#vms[@]} == 0 )); then
		vms=( "${MARVIN_KVM_DOMAIN}" )
	fi

	local vm
	for vm in "${vms[@]}"; do
		if ! libvirt::vm_is_defined "${vm}"; then
			echo "ERROR: Cannot start ${vm} as it is not defined in libvirt." >&2
			return "${SHELLPACK_ERROR}"
		fi

		if libvirt::vm_is_running "${vm}" ; then
			echo "${vm} already running according to virsh"
			continue
		fi

		# This is only supported if we're running inside Marvin.
		if command -v kvm-boot-restore >/dev/null 2>&1; then
			screen -dmS kvm-boot-restore kvm-boot-restore "${vm}"
		fi

		local start_time current_time running
		echo "Starting ${vm}"
		virsh start "${vm}"
		start_time=$(date +%s)

		while ! libvirt::vm_is_running "${vm}" ; do
			current_time=$(date +%s)
			running=$(( current_time - start_time ))
			if (( running > timeout )); then
				echo "ERROR: Timeout exceeded for ${vm} to become 'running'" >&2
				return "${SHELLPACK_ERROR}"
			fi
			sleep 1
		done
		echo "Console available via \"virsh console ${vm}\""
	done

	# Check the VMS are actually running and reacheable
	for vm in "${vms[@]}"; do
	        local guest_ip
		echo "Waiting on ${vm} IP"

		if guest_ip=$(libvirt::vm_ip_address "${vm}" 600); then
			if ! vm_wait_ssh "${guest_ip}"; then
				echo "ERROR: ${vm} not reacheable via SSH" >&2
				return "${SHELLPACK_ERROR}"
			fi
		else
			echo "ERROR: cannot find ${vm}'s IP address" >&2
			return "${SHELLPACK_ERROR}"
		fi
	done

	return "${SHELLPACK_SUCCESS}"
}

# Stop one or more VMs via libvirt (virsh). The names of the VMs (as libvirt
# knows them) are the parameters.
function libvirt::vm_stop() {
	local vms=("$@")

	if (( ${#vms[@]} == 0 )); then
		vms=( "${MARVIN_KVM_DOMAIN:-marvin-mmtests}" )
	fi

	local vm
	for vm in "${vms[@]}"; do
		if ! libvirt::vm_is_running "${vm}" ; then
			echo "Not stopping ${vm} as it is not running..."
			continue
		fi
		
		echo "Shutting down ${vm}"
		virsh shutdown "${vm}" >/dev/null 2>&1 || true
	done

	for vm in "${vms[@]}"; do
		if ! libvirt::vm_is_running "${vm}" ; then
			continue
		fi

		local duration=0
		echo -n "Waiting on ${vm} shutdown to complete"
		while libvirt::vm_is_running "${vm}" ; do
			echo -n "."
			sleep 5
			(( duration += 5 ))

			if (( duration > default_shutdown_timeout )); then
				echo -e "\nWARNING: Normal ${vm} shutdown exceeded, destroying"
				virsh destroy "${vm}" >/dev/null 2>&1 || true
				duration=0
			fi
		done
		echo ""
	done

	return "${SHELLPACK_SUCCESS}"
}

# Legacy orchestrator: performs infinite polling with a threshold-based hard-reset policy.
# Parameters: <VM_IP_or_hostname> [reset_mode]
function vm_wait_ssh_with_reset() {
	if [[ -z "${1:-}" ]]; then
		echo "ERROR: vm_wait_ssh_with_reset requires a target IP/hostname as the first argument." >&2
		return "${SHELLPACK_ERROR}"
	fi

	local target="${1}"
	local reset_mode="${2:-}"
	local count=0

	if [[ "${reset_mode}" != "quiet" ]]; then
		echo -n "Waiting for ssh to be available at ${target}:22"
		[[ "${reset_mode}" == "reset" ]] && echo -n " with reset"
		echo ""
	fi

	while true; do
		# Deleghiamo il check alla funzione core (timeout 30s, check ogni 10s)
		if vm_wait_ssh "${target}" 30 10; then
			return "${SHELLPACK_SUCCESS}"
		fi

		(( count++ )) || true

		if [[ "${reset_mode}" != "quiet" ]]; then
			echo -n "."
		fi

		if (( count >= 400 && count % 50 == 0 )); then
			if [[ "${reset_mode}" == "reset" ]]; then
				echo -e "\nPower resetting ${target}"
				power-ctrl -s "${target}" off
				sleep 30
				power-ctrl -s "${target}" on
			elif [[ "${reset_mode}" == "kvm-start" ]]; then
				echo -e "\nAttempting kvm-start"
				# NOTE: This only works if we're running in Marvin!
				libvirt::vm_start || true
			fi
		fi
	done
}
