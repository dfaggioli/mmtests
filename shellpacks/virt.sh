# shellpacks/virt.sh
# Implicit dependencies:
# - shellpacks/common.sh (SHELLPACK_ERROR, SHELLPACK_SUCCESS)
# - MARVIN_KVM_DOMAIN

: "${SHELLPACK_SUCCESS:=0}"
: "${SHELLPACK_ERROR:=-1}"
: "${SHELLPACK_FAILURE:=-1}"

default_timeout=600
default_shutdown_timeout=30

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
		if kvm-check-running "${vm}" >/dev/null 2>&1; then
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

		while ! kvm-check-running "${vm}" >/dev/null 2>&1; do
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

		if guest_ip=$(kvm-ip-address --vm "${vm}" 600); then
			if ! wait_ssh_available "${guest_ip}"; then
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
		if ! kvm-check-running "${vm}" >/dev/null 2>&1; then
			echo "Not stopping ${vm} as it is not running..."
			continue
		fi
		
		echo "Shutting down ${vm}"
		virsh shutdown "${vm}" >/dev/null 2>&1 || true
	done

	for vm in "${vms[@]}"; do
		if ! kvm-check-running "${vm}" >/dev/null 2>&1; then
			continue
		fi

		local duration=0
		echo -n "Waiting on ${vm} shutdown to complete"
		while kvm-check-running "${vm}" >/dev/null 2>&1; do
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
