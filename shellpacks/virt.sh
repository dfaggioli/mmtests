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
		if ssh -q ${MMTESTS_SSH_OPTIONS:-} -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "root@${target}" echo "marvin-ping" >/dev/null 2>&1; then
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

# Forcefully undefines a VM. If the VM is running, it stops it first.
# Handles retry loops for transient locks and NVRAM/Storage cleanup.
# Parameters: <vm_name> [remove_storage_flag (yes/no)]
function libvirt::vm_undefine() {
	if [[ -z "${1:-}" ]]; then
		echo "ERROR: libvirt::vm_undefine requires a VM name." >&2
		return "${SHELLPACK_ERROR}"
	fi

	local vm="${1}"
	local remove_storage="${2:-no}"

	if ! libvirt::vm_is_defined "${vm}"; then
		# The VM does not exist, nothing to do
		return "${SHELLPACK_SUCCESS}"
	fi

	if libvirt::vm_is_running "${vm}"; then
		echo "VM ${vm} is running. Stopping it before undefine..."
		libvirt::vm_stop "${vm}" || return "${SHELLPACK_ERROR}"
	fi

	local -a undef_opts=()
	if [[ "${remove_storage}" == "yes" ]]; then
		undef_opts+=("--remove-all-storage")
	fi

	local attempt
	for attempt in {1..3}; do
		echo "Undefining VM: ${vm} (attempt ${attempt}/3)"
		
		# Attempt 1: with NVRAM cleanup (required for UEFI VMs)
		# Attempt 2: standard (fallback if libvirt doesn't support --nvram or it's a BIOS VM)
		if virsh undefine "${vm}" "${undef_opts[@]}" --nvram >/dev/null 2>&1 || \
		   virsh undefine "${vm}" "${undef_opts[@]}" >/dev/null 2>&1; then
			
			# Libvirt might report success but the VM could still
			# exist as transient. Verify that it is actually gone.
			if ! libvirt::vm_is_defined "${vm}"; then
				echo "${vm} successfully undefined."
				return "${SHELLPACK_SUCCESS}"
			fi
		fi
		
		sleep 2
	done

	echo "ERROR: Failed to undefine ${vm} after 3 attempts." >&2
	return "${SHELLPACK_ERROR}"
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

		virsh dumpxml ${vm} > "${vm_xml_backup_dir}/${vm}".xml
		ln -s "${vm_xml_backup_dir}/${vm}".xml "${vm_xml_backup_dir}/${vm}".LIVE.xml
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

# Checks if a libvirt storage pool exists and is active
function libvirt::_check_disk_pool() {
	local pool="${1}"
	virsh pool-info "${pool}" >/dev/null 2>&1
}

# Formally verifies if a file is a valid AutoYaST profile.
# Prints the effective file path to stdout if valid.
function libvirt::_check_autoyast() {
	local ay_file="${1}"

	# Fallback to .erb extension if the base file is missing
	if [[ ! -f "${ay_file}" ]] && [[ -f "${ay_file}.erb" ]]; then
		ay_file="${ay_file}.erb"
	fi

	if [[ -f "${ay_file}" ]]; then
		# Validate SuSE XML signature using file(1) and head+grep
		if file "${ay_file}" | grep -q 'ASCII text' && \
		   head -n 1 "${ay_file}" | grep -q '^<profile.*http://www.suse.com/.*/configns'; then
			echo "${ay_file}"
			return 0
		fi
	fi

	return 1
}

# Dynamically retrieves a VM configuration property.
# Resolution order:
# 1. Associative array (e.g., VM_CPUS["opensuse-leap.1"]) -> Safe for all chars
# 2. Standard variable (e.g., vm1_CPUS) -> Evaluated ONLY if VM name is POSIX-compliant
# 3. Global default (e.g., MMTESTS_VMS_CPUS)
# Prints the property to the stdout (if a valid one is found).
# Parameters: <vm_name> <property_suffix>
function libvirt::_get_vm_prop() {
	local vm="${1}"
	local prop="${2}"
	local val=""

	# 1. Associative array check
	local assoc_ref="VM_${prop}[\"${vm}\"]"
	val="${!assoc_ref:-}"
	if [[ -n "${val}" ]]; then
		echo "${val}"
		return 0
	fi

	# 2. Standard variable check
	# Evaluate indirect expansion ONLY if the VM name is a valid Bash
	# identifier (e.g., "opensuse-leap" is not, due to the "-").
	if [[ "${vm}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
		local var_ref="${vm}_${prop}"
		val="${!var_ref:-}"
		if [[ -n "${val}" ]]; then
			echo "${val}"
			return 0
		fi
	fi

	# 3. Fallback to global default
	local global_ref="MMTESTS_VMS_${prop}"
	val="${!global_ref:-}"

	echo "${val}"
}

# Resolves the deployment specification for a given distribution
# Merges internal defaults with user-defined overrides in MMTESTS_DEPLOY_DISTRO_SPEC
# Applies a last-match-wins logic to allow users to override default entries
# Parameters: <distro_name>
function libvirt::_get_distro_spec() {
	local distro="${1:-}"
	[[ -z "${distro}" ]] && return 0


	# Define base defaults
	# Appending the user variable at the bottom ensures overrides are read last
	local default_spec="
openSUSE-Leap-15.3@https://download.opensuse.org/pub/opensuse/distribution/leap/15.3/repo/oss/@${SCRIPTDIR}/autoyast/openSUSE-Leap-15.3.xml
openSUSE-Leap-15.4@https://download.opensuse.org/pub/opensuse/distribution/leap/15.4/repo/oss/@${SCRIPTDIR}/autoyast/openSUSE-Leap-15.4.xml
openSUSE-Tumbleweed@https://download.opensuse.org/pub/opensuse/tumbleweed/repo/oss/@${SCRIPTDIR}/autoyast/openSUSE-Tumbleweed.xml
${MMTESTS_DEPLOY_DISTRO_SPEC:-}
"

	# Parse the table and retain only the last matched row
	echo "${default_spec}" | awk -v d="${distro}@" '$0 ~ "^" d { match_line=$0 } END { if (match_line) print match_line }' || true
}

# Triggers the background deployment of a VM with virt-install. If there's
# the need to deploy multiple VMs, this function can be called for all of them,
# so installation can happen in parallel.
# Parameters: <vm_name> [autoyast_dir_1] [autoyast_dir_2] ...
function libvirt::vm_deploy_start() {
	if [[ -z "${1:-}" ]]; then
		echo "ERROR: libvirt::vm_deploy_start requires a VM name." >&2
		return "${SHELLPACK_ERROR}"
	fi

	local vm="${1:-}"
	shift
	local ayast_dirs=("$@")

	echo "Initiating deployment for missing VM: ${vm}..."

	# Let's try to figure out (from the host config file) the hardware

	# For a VM called "vm1", we check (in this order) if we have:
	# - VM_MEMORY["vm1"]=<...>
	# - vm1_MEMORY=<...>
	# - MMTESTS_VMS_MEMORY
	# If none of the above exists, we try to compute some kind of
	# default value (suitable for running only one, pretty big, VM).
	local memory
	memory=$(libvirt::_get_vm_prop "${vm}" "MEMORY")
	if [[ -z "${memory}" ]]; then
		local memtotal
		memtotal=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
		memory=$((memtotal * 4 / 5 / 1024))
	fi

	# Pretty much the same as what we do above for memory.
	local cpus
	cpus=$(libvirt::_get_vm_prop "${vm}" "CPUS")
	if [[ -z "${cpus}" ]]; then
		cpus=$(nproc --all)
		local nr_spare
		nr_spare=$(numactl --hardware 2>/dev/null | grep -c cpus: || echo 1)
		nr_spare=$((nr_spare * 2))
		# Default here is: same number of CPUs as the host, minus
		# 2 CPUs per NUMA node.
		if (( cpus > nr_spare * 2 )); then
			cpus=$((cpus - nr_spare))
		fi
	fi

	# NOTE: Libvirt is now able to deal with this automatically, but that
	# depends on the version of Libvirt we have on the host. For now, let's
	# just set it explicitly.
	local -a iommu_opts=()
	if (( cpus > 255 )); then
		iommu_opts=("--iommu" "model=intel,driver.intremap=on,driver.eim=on" "--features" "ioapic.driver=qemu")
	fi

	# Let's figure out storage for the VM
	local pool
	pool=$(libvirt::_get_vm_prop "${vm}" "DISK_POOL")
	pool="${pool:-default}"

	local disk_spec="" is_import="false"
	local import_disk copy_disk copy_cow
	import_disk=$(libvirt::_get_vm_prop "${vm}" "IMPORT_DISK_FILE")
	copy_disk=$(libvirt::_get_vm_prop "${vm}" "COPY_DISK_FILE")
	copy_cow=$(libvirt::_get_vm_prop "${vm}" "COPY_DISK_COW")

	if [[ -n "${import_disk}" && -n "${copy_disk}" ]]; then
		echo "ERROR: Cannot both copy and import the same disk file for ${vm}" >&2
		return "${SHELLPACK_ERROR}"
	fi

	if [[ "${copy_cow}" == "yes" && -z "${copy_disk}" ]]; then
		echo "ERROR: Unknown backing disk file for COW for ${vm}" >&2
		return "${SHELLPACK_ERROR}"
	fi

	# Importing means picking up an existing disk image and use it for the
	# new VM. Such image can be used directly or copied to a new file.
	if [[ -n "${import_disk}" || -n "${copy_disk}" ]]; then
		is_import="true"
		if [[ -n "${copy_disk}" ]]; then
			install-depends qemu-tools

			local copy_dest_path
			copy_dest_path=$(libvirt::_get_vm_prop "${vm}" "COPY_DISK_DEST_PATH")
			if [[ -z "${copy_dest_path}" ]]; then
				if ! libvirt::_check_disk_pool "${pool}"; then
					echo "ERROR: requested storage pool ${pool} for ${vm} is not available" >&2
					return "${SHELLPACK_ERROR}"
				fi
				copy_dest_path=$(virsh pool-dumpxml "${pool}" | xmllint --xpath 'string(//path)' - 2>/dev/null || true)
			fi

			local copy_dest_file
			local disk_format=""
			copy_dest_file=$(mktemp "${copy_dest_path}/${vm}-XXXX.disk")
			if [[ "${copy_cow}" == "yes" ]]; then
				echo "Creating COW snapshot of ${copy_disk} at ${copy_dest_file}..."

				# Create the overlay. A COW overlay must structurally be qcow2.
				qemu-img create -f qcow2 -F qcow2 -b "${copy_disk}" "${copy_dest_file}" || return "${SHELLPACK_ERROR}"
				disk_format=",format=qcow2"
			else
				echo "Copying disk ${copy_disk} to ${copy_dest_file}..."
				cp -a "${copy_disk}" "${copy_dest_file}" || return "${SHELLPACK_ERROR}"

				# Auto-discover original file format if qemu-img is available on the host
				if command -v qemu-img >/dev/null 2>&1; then
					local fmt
					fmt=$(qemu-img info "${copy_disk}" 2>/dev/null | awk '/^file format:/ {print $3}' || true)
					[[ -n "${fmt}" ]] && disk_format=",format=${fmt}"
				fi
			fi

			# Append the detected or forced format to the virt-install specification
			disk_spec="${copy_dest_file},bus=virtio,discard=unmap${disk_format}"
		else
			disk_spec="${import_disk},bus=virtio,discard=unmap"
		fi
	else
		disk_spec=$(libvirt::_get_vm_prop "${vm}" "DISK_SPEC")
		if [[ -z "${disk_spec}" ]]; then
			local fsize
			fsize=$(libvirt::_get_vm_prop "${vm}" "DISK_FILE_SIZE")
			fsize="${fsize:-12}"
			disk_spec="size=${fsize},pool=${pool},bus=virtio,discard=unmap"
		fi
		
		# Extract pool from spec to validate it
		pool=$(echo "${disk_spec}" | grep -o 'pool=[^,]*' | cut -d= -f2 || echo "default")
		if ! libvirt::_check_disk_pool "${pool}"; then
			echo "ERROR: requested storage pool ${pool} for ${vm} is not available" >&2
			return "${SHELLPACK_ERROR}"
		fi
	fi

	# Let's now start to put together the actual virt-install command
	local serial_log="${SHELLPACK_LOG_BASE:-/tmp}/${vm}-serial.log"
	rm -f "${serial_log}"

	local -a virt_cmd=(
		virt-install
		--connect qemu:///system
		--virt-type kvm
		--machine q35
		--name "${vm}"
		--vcpus "${cpus}"
		"${iommu_opts[@]}"
		--memory "${memory}"
		--disk "${disk_spec}"
		--network network=default,model=virtio
		--graphics none
		--boot uefi
		--serial "file,path=${serial_log}"
		--console pty,target_type=serial
		--noautoconsole
	)

	# If we're importing the VM, fine. If not, we need an automatic
	# install "strategy", with all it takes (e.g., AutoYaST... for now!)
	if [[ "${is_import}" == "true" ]]; then
		virt_cmd+=("--import" "--osinfo" "detect=on,require=off")
		# Signal the wait barrier (through a "filesystem marker"
		# that no OS installation is actually taking place.
		touch "${SHELLPACK_LOG_BASE:-/tmp}/${vm}-import.marker"
	else
		virt_cmd+=("--osinfo" "detect=on,require=off")

		local distro
		distro=$(libvirt::_get_vm_prop "${vm}" "DEPLOY_DISTRO")
		[[ -z "${distro}" && -f ~/.marvin.deploy.distro ]] && distro=$(< ~/.marvin.deploy.distro)
		[[ -z "${distro}" && -f ~/.mmtests.deploy.distro ]] && distro=$(< ~/.mmtests.deploy.distro)
		[[ -z "${distro}" ]] && distro="openSUSE-Tumbleweed"

		local location autoyast
		location=$(libvirt::_get_vm_prop "${vm}" "INSTALL_LOCATION")
		autoyast=$(libvirt::_get_vm_prop "${vm}" "AUTOYAST")

		if [[ -z "${autoyast}" || ! -f "${autoyast}" ]]; then
			local dir candidate
			for dir in "${ayast_dirs[@]}"; do
				[[ ! -d "${dir}" ]] && continue
				
				candidate=$(libvirt::_check_autoyast "${dir}/${autoyast}") ||
				candidate=$(libvirt::_check_autoyast "${dir}/${vm}.xml") ||
				candidate=$(libvirt::_check_autoyast "${dir}/${vm}_${distro}.xml") ||
				candidate=$(libvirt::_check_autoyast "${dir}/${vm}_${distro}_autoyast.xml") ||
				candidate=$(libvirt::_check_autoyast "${dir}/${vm}_autoyast.xml") ||
				candidate=$(libvirt::_check_autoyast "${MMTESTS_VMS_AUTOYAST:-}") ||
				candidate=$(libvirt::_check_autoyast "${dir}/${distro}_autoyast.xml") ||
				candidate=$(libvirt::_check_autoyast "${dir}/${distro}.xml") ||
				candidate=$(libvirt::_check_autoyast "${dir}/autoyast.xml") ||
				candidate=$(libvirt::_check_autoyast "${SCRIPTDIR}/autoyast/opensuse.xml.erb") || candidate=""

				if [[ -n "${candidate}" ]]; then
					autoyast="${candidate}"
					break
				fi
			done
		fi

		if [[ -z "${location}" || -z "${autoyast}" ]]; then
			local config_spec=""
			if [[ -n "${MMTESTS_DEPLOY_DISTRO_SPEC:-}" ]]; then
				config_spec=$(echo "${MMTESTS_DEPLOY_DISTRO_SPEC}" | awk -v d="${distro}@" '$0 ~ "^" d {print; exit}' || true)
			fi
			
			if [[ -n "${config_spec}" ]]; then
				local _ parsed_loc parsed_ay
				IFS='@' read -r _ parsed_loc parsed_ay <<< "${config_spec}"
				[[ -z "${location}" ]] && location="${parsed_loc}"
				[[ -z "${autoyast}" ]] && autoyast=$(libvirt::_check_autoyast "${parsed_ay}" || echo "${parsed_ay}")
			fi
		fi

		if [[ -z "${location}" || -z "${autoyast}" ]]; then
			echo "ERROR: Install location or autoyast profile missing or invalid for ${vm}" >&2
			return "${SHELLPACK_ERROR}"
		fi

		virt_cmd+=("--location" "${location}")

    		install-depends virt-install

		# The AutoYaST profile can be a local file or an URL. In the
		# former case, we inject it into the VM's initrd image. In
		# the latter, we'll try to download it.
		if [[ -f "${autoyast}" ]]; then
			virt_cmd+=("--initrd-inject" "${autoyast}")
			virt_cmd+=("--extra-args" "network=1 install=${location} autoyast=file:///$(basename "${autoyast}") console=ttyS0,115200n8")
			cp "${autoyast}" "${SHELLPACK_LOG_BASE:-/tmp}/${vm}-autoyast" || true
		else
			virt_cmd+=("--extra-args" "network=1 install=${location} autoyast=${autoyast} console=ttyS0,115200n8")
		fi
	fi

	"${virt_cmd[@]}" || return "${SHELLPACK_ERROR}"
	return "${SHELLPACK_SUCCESS}"
}

# Barrier Function: Waits for the OS deployment to finish by polling the serial log.
# Consumes the import marker to bypass wait if applicable.
# Parameters: <vm_name>
function libvirt::vm_deploy_wait() {
	local vm="${1:-}"
	local marker="${SHELLPACK_LOG_BASE:-/tmp}/${vm}-import.marker"
	local serial_log="${SHELLPACK_LOG_BASE:-/tmp}/${vm}-serial.log"

	if [[ -f "${marker}" ]]; then
		rm -f "${marker}"
		echo "VM ${vm} imported successfully (no OS deployment wait required)."
		libvirt::vm_stop "${vm}" || true
		return "${SHELLPACK_SUCCESS}"
	fi

	echo "Waiting for OS deployment to complete on ${vm} (check ${serial_log} for details)..."
	while true; do
		if [[ -f "${serial_log}" ]] && grep -q " login:" "${serial_log}"; then
			echo "Installation completed for ${vm}."
			break
		fi

		if ! libvirt::vm_is_running "${vm}"; then
			echo "ERROR: VM ${vm} stopped unexpectedly during deployment." >&2
			return "${SHELLPACK_ERROR}"
		fi
		sleep 10
	done

	# Provisioning with virt-install typicall leaves the VM up. Shut it
	# down, as the prosecution of the automatio expects it to be that.
	libvirt::vm_stop "${vm}" || true
	return "${SHELLPACK_SUCCESS}"
}

# Pins the current dynamic IP of a VM to a static DHCP reservation in libvirt.
# This prevents IP shifting during long benchmarks due to DHCP lease starvation.
# Parameters: <vm_name> [network_name]
function libvirt::pin_vm_ip() {
	local vm="${1}"
	local net="${2:-default}"

	install-depends libxml2-tools

	local mac
	mac=$(virsh dumpxml "${vm}" 2>/dev/null | xmllint --xpath 'string(//interface[@type="network"]/mac/@address)' - 2>/dev/null || true)

	if [[ -z "${mac}" ]]; then
		echo "WARNING: Could not find network MAC address for VM ${vm}. Skipping IP pin." >&2
		return "${SHELLPACK_SUCCESS}" # Soft fail, don't crash the orchestrator
	fi
	local ip
	ip=$(libvirt::vm_ip_address "${vm}" 60)
	if [[ -z "${ip}" ]]; then
		echo "WARNING: Could not determine current IP for VM ${vm}. Skipping IP pin." >&2
		return "${SHELLPACK_SUCCESS}"
	fi

	# Check if a static binding already exists for this MAC (Idempotency)
	if virsh net-dumpxml "${net}" 2>/dev/null | grep -qi "mac='${mac}'"; then
		echo "Static IP binding for ${vm} (${ip}) already exists."
		return "${SHELLPACK_SUCCESS}"
	fi

	echo "Pinning current IP (${ip}) to MAC (${mac}) for VM ${vm}..."

	# Add the static lease to Libvirt's dnsmasq
	# --live applies it to the running dnsmasq instance.
	# --config saves it to the XML for persistence across host reboots.
	virsh net-update "${net}" add ip-dhcp-host \
		"<host mac='${mac}' name='${vm}' ip='${ip}'/>" \
		--live --config >/dev/null 2>&1 || {
		echo "ERROR: Failed to inject static DHCP binding for ${vm}" >&2
		return "${SHELLPACK_ERROR}"
	}

	return "${SHELLPACK_SUCCESS}"
}

# Removes a static IP and hostname binding from a libvirt network.
# Fails softly to ensure teardown sequences are not interrupted.
# Parameters: <network_name> <mac_address> <ip_address> <vm_name>
function libvirt::unpin_vm_ip() {
	local net="${1}"
	local mac="${2}"
	local ip="${3}"
	local vm="${4}"

	if [[ -z "${net}" || -z "${mac}" || -z "${ip}" || -z "${vm}" ]]; then
		echo "ERROR: Missing arguments for libvirt::unpin_vm_ip" >&2
		return 0 # Soft fail for cleanup routines
	fi

	local xml_payload="<host mac='${mac}' name='${vm}' ip='${ip}'/>"

	# Attempt to remove the lease from live and config states
	virsh net-update "${net}" delete ip-dhcp-host "${xml_payload}" --live --config >/dev/null 2>&1 || {
		echo "WARNING: Failed to remove static lease for ${vm} (${ip}) from network '${net}'. It might not exist." >&2
		return 0
	}

	echo "INFO: Successfully removed static IP binding for ${vm}."
	return 0
}

# Retrieves the primary disk path of a VM.
# Parameters: <vm_name>
function libvirt::get_vm_disk_path() {
	local vm="${1}"
	# Returns the first valid block device (ignoring CD-ROMs)
	# TODO: Handle VMs with multiple disks
	virsh domblklist "${vm}" | awk 'NR>2 && $2 != "-" {print $2; exit}'
}

function libvirt::backup_vms_definitions() {
	local vms=("$@")
	if (( ${#vms[@]} == 0 )); then
		vms=( "${MARVIN_KVM_DOMAIN}" )
	fi

	local vm
	mkdir -p "${vm_xml_backup_dir}"
	for vm in "${vms[@]}"; do
		virsh dumpxml "${vm}" > "${vm_xml_backup_dir}/${vm}.PERSISTENT.xml" || {
			echo "FATAL: Can't create baseline XML backup for ${vm}"
			return "${SHELLPACK_ERROR}"
		}
	done

	activity_log "run-kvm: VM baselines backed up successfully"
	return "${SHELLPACK_SUCCESS}"
}

function libvirt::tune_vms_offline() {
    local vms=("$@")
    local vm
    
    if (( ${#vms[@]} == 0 )); then
        vms=( "${MARVIN_KVM_DOMAIN}" )
    fi

    install-depends virt-install
 
    if ! command -v virt-xml >/dev/null 2>&1; then
        echo "WARNING: virt-xml not found. Skipping hardware overrides." >&2
        return "${SHELLPACK_SUCCESS}"
    fi

    for vm in "${vms[@]}"; do
        # --- HUGEPAGES ---
        if [[ "${MMTESTS_VMS_HUGEPAGES:-no}" == "yes" ]]; then
            local hp_args="hugepages=on"
            if [[ "${MMTESTS_VMS_HUGEPAGES_SIZE:-}" == "1G" ]]; then
                hp_args="${hp_args},hugepages.page.size=1,hugepages.page.unit=G"
            elif [[ "${MMTESTS_VMS_HUGEPAGES_SIZE:-}" == "2M" ]]; then
                hp_args="${hp_args},hugepages.page.size=2,hugepages.page.unit=M"
            fi
            activity_log "run-kvm: Injecting hugepages backing into ${vm}"
            virt-xml "${vm}" --edit --memorybacking "${hp_args}" >/dev/null 2>&1 || true
        fi

        # --- NUMATUNE ---
        local numa_nodes numa_mode
        numa_nodes=$(libvirt::_get_vm_prop "${vm}" "NUMATUNE_NODES")
        numa_mode=$(libvirt::_get_vm_prop "${vm}" "NUMATUNE_MODE")
        if [[ -n "${numa_nodes}" ]]; then
            numa_mode="${numa_mode:-strict}"
            local safe_nodes="${numa_nodes//,/,,}"
            activity_log "run-kvm: Injecting numatune (mode=${numa_mode}, nodeset=${numa_nodes}) into ${vm}"
            virt-xml "${vm}" --edit --numatune "mode=${numa_mode},nodeset=${safe_nodes}" >/dev/null 2>&1 || {
                echo "FATAL: Failed to inject numatune in ${vm}"
                return "${SHELLPACK_FAILURE}"
            }
        fi

	# 3. --- VCPUS COUNT & VTOPOLOGY ---
        # Libvirt requires vCPUs == sockets * dies * cores * threads.
        # virt-xml forbids editing --vcpus and --cpu in the same command.
        # Solution: temporarily strip the topology to break the validation deadlock.
        local target_cpus=$(libvirt::_get_vm_prop "${vm}" "CPUS")
        local vtopology_raw=$(libvirt::_get_vm_prop "${vm}" "VTOPOLOGY")

        if [[ -n "${target_cpus}" || -n "${vtopology_raw}" ]]; then
            # Nuke the old topology constraint from the XML
            local tmp_xml=$(mktemp)
            virsh dumpxml "${vm}" > "${tmp_xml}"
            sed -i '/<topology /d' "${tmp_xml}"
            virsh define "${tmp_xml}" >/dev/null 2>&1
            rm -f "${tmp_xml}"
            
            # Now we can freely apply vCPUs and new Topology without conflicts
            if [[ -n "${target_cpus}" ]]; then
                activity_log "run-kvm: Overriding vCPU count to ${target_cpus} for ${vm}"
                virt-xml "${vm}" --edit --vcpus "${target_cpus}" >/dev/null 2>&1 || {
                    echo "FATAL: Failed to inject vCPUs count in ${vm}"
                    return "${SHELLPACK_FAILURE}"
                }
            fi

            if [[ -n "${vtopology_raw}" ]]; then
                activity_log "run-kvm: Injecting topology (${vtopology_raw}) into ${vm}"
                local cpu_args=""
                local -a topo_arr
                IFS=',' read -r -a topo_arr <<< "${vtopology_raw}"
                local prop k v
                for prop in "${topo_arr[@]}"; do
                    k="${prop%%=*}"; v="${prop##*=}"
                    case "${k}" in
                        socket|sockets)  k="sockets" ;;
                        die|dies)        k="dies" ;;
                        core|cores)      k="cores" ;;
                        thread|threads)  k="threads" ;;
                        *) continue ;;
                    esac
                    cpu_args="${cpu_args},topology.${k}=${v}"
                done
                virt-xml "${vm}" --edit --cpu "${cpu_args#,}" >/dev/null 2>&1 || {
                    echo "FATAL: Failed to inject CPU topology in ${vm}"
                    return "${SHELLPACK_FAILURE}"
                }
            fi
        fi

        # --- GLOBAL VM PINNING (CPUSPIN, CORESPIN, NODESPIN) ---
        local final_vm_cpuset=""
        local cpuspin=$(libvirt::_get_vm_prop "${vm}" "CPUSPIN")
        local global_corespin=$(libvirt::_get_vm_prop "${vm}" "CORESPIN")
        local nodespin=$(libvirt::_get_vm_prop "${vm}" "NODESPIN")

        if [[ -n "${cpuspin}" ]]; then
            final_vm_cpuset="${cpuspin}"
        elif [[ -n "${global_corespin}" ]]; then
            local -a host_cores_global=()
            while IFS= read -r core_cpus; do
                host_cores_global+=("${core_cpus}")
            done < <(LC_ALL=C lscpu -p=SOCKET,CORE,CPU | grep -v '^#' | sort -t, -k1,1n -k2,2n -k3,3n | awk -F, '{
                ck = $1 "_" $2;
                if (!seen[ck]++) { c_order[idx++] = ck; }
                cores[ck] = (cores[ck] == "" ? $3 : cores[ck] "," $3);
            } END {
                for (i=0; i<idx; i++) print cores[c_order[i]];
            }')
            local -a core_arr_global
            IFS=',' read -r -a core_arr_global <<< "${global_corespin}"
            local -a collected_cpus=()
            for pcore in "${core_arr_global[@]}"; do
                if [[ -n "${host_cores_global[pcore]:-}" ]]; then
                    collected_cpus+=("${host_cores_global[pcore]}")
                fi
            done
            final_vm_cpuset=$(IFS=,; echo "${collected_cpus[*]}")
        elif [[ -n "${nodespin}" ]]; then
            local -a node_arr
            IFS=',' read -r -a node_arr <<< "${nodespin}"
            local -a collected_nodes=()
            for node in "${node_arr[@]}"; do
                if [[ -f "/sys/devices/system/node/node${node}/cpulist" ]]; then
                    collected_nodes+=("$(cat "/sys/devices/system/node/node${node}/cpulist")")
                fi
            done
            final_vm_cpuset=$(IFS=,; echo "${collected_nodes[*]}")
        fi

        # Inject global cpuset into <vcpu> root node and set emulatorpin
        if [[ -n "${final_vm_cpuset}" ]]; then
            activity_log "run-kvm: Injecting global cpuset (${final_vm_cpuset}) into ${vm}"
            local safe_cpuset="${final_vm_cpuset//,/,,}"
            virt-xml "${vm}" --edit --vcpu cpuset="${safe_cpuset}" >/dev/null 2>&1 || {
                echo "FATAL: Failed to apply global cpuset to ${vm}"
                return "${SHELLPACK_FAILURE}"
            }
            virsh emulatorpin "${vm}" "${final_vm_cpuset}" --config >/dev/null 2>&1 || true
        fi

        # --- VCPUPIN 1TO1 ---
        local vcpupin_raw=$(libvirt::_get_vm_prop "${vm}" "VCPUPIN_1TO1")
        if [[ -n "${vcpupin_raw}" ]]; then
            activity_log "run-kvm: Injecting vcpupin (${vcpupin_raw}) into ${vm}"
            local -a pin_arr
            IFS=',' read -r -a pin_arr <<< "${vcpupin_raw}"
            local vcpu
            for vcpu in "${!pin_arr[@]}"; do
                local pcpu="${pin_arr[vcpu]}"
                if [[ "${pcpu}" != "-" ]]; then
                    virsh vcpupin "${vm}" "${vcpu}" "${pcpu}" --config >/dev/null 2>&1 || true
                fi
            done
        fi

        # --- VCOREPIN 1TO1 ---
        local vcorepin_raw=$(libvirt::_get_vm_prop "${vm}" "VCOREPIN_1TO1")
        if [[ -n "${vcorepin_raw}" ]]; then
            activity_log "run-kvm: Injecting vcorepin (${vcorepin_raw}) into ${vm}"

            # Safely cast XML threads attribute to integer
            local guest_threads=$(virsh dumpxml "${vm}" 2>/dev/null | xmllint --xpath 'string(//cpu/topology/@threads)' - 2>/dev/null || true)
            guest_threads="${guest_threads//[^0-9]/}"
            guest_threads="${guest_threads:-2}"
            (( guest_threads == 0 )) && guest_threads=2

            # Deterministic host topology extraction (Fixed boolean and array key tracking)
            local -a host_cores=()
            while IFS= read -r core_cpus; do
                host_cores+=("${core_cpus}")
            done < <(LC_ALL=C lscpu -p=SOCKET,CORE,CPU | grep -v '^#' | sort -t, -k1,1n -k2,2n -k3,3n | awk -F, '{
                ck = $1 "_" $2;
                if (!seen[ck]++) { c_order[idx++] = ck; }
                cores[ck] = (cores[ck] == "" ? $3 : cores[ck] " " $3);
            } END {
                for (i=0; i<idx; i++) print cores[c_order[i]];
            }')

            local -a core_arr
            IFS=',' read -r -a core_arr <<< "${vcorepin_raw}"
            local vcore
            for vcore in "${!core_arr[@]}"; do
                local pcore="${core_arr[vcore]}"
                if [[ "${pcore}" != "-" && -n "${host_cores[pcore]:-}" ]]; then
                    # Intentional unquoted array expansion to split space-separated CPUs
                    local -a pcpus=(${host_cores[pcore]})
                    local t
                    for (( t=0; t<guest_threads; t++ )); do
                        local vcpu_idx=$(( vcore * guest_threads + t ))
                        local pcpu_idx="${pcpus[t]}"
                        if [[ -n "${pcpu_idx}" ]]; then
                            virsh vcpupin "${vm}" "${vcpu_idx}" "${pcpu_idx}" --config >/dev/null 2>&1 || true
                        fi
                    done
                fi
            done
        fi
    done

    return "${SHELLPACK_SUCCESS}"
}

function libvirt::restore_vms_definitions() {
	local vms=("$@")
	if (( ${#vms[@]} == 0 )); then
		vms=( "${MARVIN_KVM_DOMAIN}" )
	fi

	if [[ ! -d "${vm_xml_backup_dir:-}" ]]; then
		return "${SHELLPACK_SUCCESS}"
	fi

	local vm
	local backup_file
	for vm in "${vms[@]}"; do
		backup_file="${vm_xml_backup_dir}/${vm}.PERSISTENT.xml"
		if [[ -f "${backup_file}" ]]; then
			virsh define "${backup_file}" >/dev/null 2>&1 || {
				echo "WARNING: Failed to restore original XML for ${vm}" >&2
			}
		fi
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
