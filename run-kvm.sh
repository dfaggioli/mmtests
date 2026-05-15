#!/bin/bash
# shellcheck enable=require-variable-braces

# Author: Dario Faggioli <dfaggioli@suse.com>
# script for running mmtests in one or multiple VMs

set "${MMTESTS_SH_DEBUG:-+x}"
#set -euo pipefail

export MARVIN_KVM_DOMAIN=${MARVIN_KVM_DOMAIN:-"marvin-mmtests"}
export MMTESTS_HOST_PORT=${MMTESTS_HOST_PORT:-1234}

function usage() {
	echo "$0 [-pkonmh] [-C CONFIG_HOST] [--vm VMNAME[,VMNAME][,...]] [--] run-mmtests-options"
	echo
	echo "-H|-h|--help                Prints this help."
	echo "-P|--host-performance       Force performance CPUFreq governor on the host before starting the tests"
	echo "-L|--host-logs              Collect logs and hardware info about the host"
	echo "-K|--keep-kernel            Use whatever kernel the VM currently has."
	echo "-O|--offline-iothreads      Take down some VM's CPUs and use for IOthreads."
	echo "-M|--run-host-monitor       Force enable monitoring on the host."
	echo "-N|--no-host-monitor        Force disable monitoring on the host."
	echo "-C|--config-host CFG        Use CFG as config file for the host. Can be specified multiple times"
	echo "-X|--vm-xml-dir DIR,[...]   Where to find the libvirt config files for VMs that"
	echo "                            are not defined already. A comma-separated list of dirs"
	echo "                            can be specified. The main MMTests directory is always checked."
	echo "                            Note that the order of the directories matters, as we will"
	echo "                            stop scanning as soon as the first suitable config file is found."
	echo "--vm VMNAME[,VMNAME]        Name(s) of existing, and already known to 'virsh', VM(s)."
	echo "                            If not specified, use \${MARVIN_KVM_DOMAIN} as VM name."
	echo "                            If that is not defined, use 'marvin-mmtests'."
	echo "run-mmtests-options         Parameters for run-mmtests.sh inside the VM (check them"
	echo "                            with ./run-mmtests.sh -h)."
	echo ""
	echo "NOTE that 'run-mmtests-options', i.e., the parameters that will be used to execute"
	echo "run-mmtests.sh inside the VMs, must always follow all the parameters intended for"
	echo "run-kvm.sh itself. For learning more about them, run './run-mmtests.sh -h'"
	echo ""
	echo "If a \"--\" parameter is found, parsing of run-kvm.sh arguments will immediately stop"
	echo "and everything that follows will be passed to run-mmtests.sh (inside of the VMs)."
	echo "Using this separator is recommended, as it makes clear which group of argument is meant"
	echo "to what script, but not strictly required (for compatibility reasons)."
}

# Returns true if we're (reasonably) sure we're running inside Marvin.
function running_in_marvin() {
	[[ -z "${MMTESTS_HOST_IP:-}" &&
	    ${#VMS[@]} -eq 1 &&
	    "${VMS[0]}" = "${MARVIN_KVM_DOMAIN}" ]]
}

function should_sync_host_and_guests() {
	[[ -n "${MMTESTS_HOST_IP:-}" ]]
}

# Parameters handling. Note that our own parmeters (i.e., run-kvm.sh
# parameters) must always come *before* the parameters we want MMTests
# inside the VM to use.
#
# Additionally, we want to stash this second set of parameters somewhere
# and be able to both inspect them and actually forward them to run-mmtests.sh.
#
# This is why this code looks different than "traditional" parameter handling.
function parse_args() {
	declare -ga RUN_ARGS=()
	declare -ga CONFIGS=()
	declare -ga VM_XML_DIRS=()
	declare -ga VM_AYAST_DIRS=()

	# Default values
	force_host_performance="no"
	host_logs="no"
	run_monitor=""

	while true; do
		case "${1:-}" in
			-P|--host-performance)
				force_host_performance="yes"
				shift
				;;
			-L|--host-logs)
				host_logs="yes"
				shift
				;;
			-K|-k|--keep-kernel)
				keep_kernel="yes"
				shift
				;;
			-O|-o|--offline-iothreads)
				offline_iothreads="yes"
				shift
				;;
			-M|--run-host-monitor)
				run_monitor="yes"
				shift
				;;
			-N|--no-host-monitor)
				run_monitor="no"
				shift
				;;
			-C|--config-host)
				if [[ -z "${2:-}" ]]; then
					echo "ERROR: ${1} requires at least one config file name as an argument." >&2
					usage
					exit "${SHELLPACK_ERROR}"
				fi
				CONFIGS+=( "${2}" )
				shift 2
				;;
			--vm|--vms|--VM|--VMS)
				if [[ -z "${2:-}" ]]; then
					echo "ERROR: ${1} requires at least one VM name as an argument." >&2
					usage
					exit "${SHELLPACK_ERROR}"
				fi
				vms_from_cli="${2}"
				shift 2
				;;
			-X|--vm-xml-dir)
				if [[ -z "${2:-}" ]]; then
					echo "ERROR: ${1} requires at least one directory as an argument." >&2
					usage
					exit "${SHELLPACK_ERROR}"
				fi
				IFS=',' read -r -a VM_XML_DIRS <<< "${2}"
				shift 2
				;;
			-A|--vm-autoyast-dir)
				if [[ -z "${2:-}" ]]; then
					echo "ERROR: ${1} requires at least one directory as an argument." >&2
					usage
					exit "${SHELLPACK_ERROR}"
				fi
				IFS=',' read -r -a VM_AYAST_DIRS <<< "${2}"
				shift 2
				;;
			-h|-H|--help)
				usage
				exit "${SHELLPACK_SUCCESS}"
				;;
			--)
				shift
				;&
			*)
				break
				;;
		esac
	done

	# Save the remaining arguments destined for run-mmtests.sh inside the VMs
	RUN_ARGS=("$@")

	# NB: 'runname' is the last of our parameters, as it is the last
	# parameter of run-mmtests.sh.
	RUNNAME="default"
	if [ ${#RUN_ARGS[@]} -gt 0 ]; then
		RUNNAME="${RUN_ARGS[${#RUN_ARGS[@]}-1]}"
	fi
}

function prologue() {
	DIRNAME="$(dirname "${0}")"
	SCRIPTDIR="$(cd "${DIRNAME}" && pwd)"

	#set +euo pipefail
	source "${SCRIPTDIR}/shellpacks/common.sh"
	source "${SCRIPTDIR}/shellpacks/common-config.sh"
	source "${SCRIPTDIR}/shellpacks/monitors.sh"
	#set -euo pipefail
	source "${SCRIPTDIR}/shellpacks/virt.sh"

	export PATH="${SCRIPTDIR}/bin:${PATH}:${SCRIPTDIR}/bin-virt"

	# Custom unbiffer script, for clean termination of monitors
	export EXPECT_UNBUFFER="${SCRIPTDIR}/bin/unbuffer"
	# CURRENT_TEST is used only by monitors, so define it to
	# 'monitor' for now. We may change this, if/when we will
	# support per-test monitoring.
	export CURRENT_TEST="monitor"

	# Global states, for trap safety
	NCPID=""
	EXIT_CODE=""
}

function parse_config() {
	declare -ga MMTESTS_CONFIGS=()
	declare -ga VMS=()
	declare -ga GUEST_IP=()

	local default_mmtests_config=config
	local default_host_config=host_config

	# We want to read the config(s) that run-mmtests.sh will use inside
	# the guests. Retrieve them from the command line parameters that we
	# have not parsed, but without "consuming" them.
	local i
	for (( i=0; i < ${#RUN_ARGS[@]}; i++ ))
	do
		if [[ "${RUN_ARGS[i]}" = "-c"  || "${RUN_ARGS[i]}" = "--config" ]]; then
			if (( i + 1 < ${#RUN_ARGS[@]} )); then
				MMTESTS_CONFIGS+=( "${RUN_ARGS[i+1]}" )
				(( i++ ))
			else
				die "ERROR: Malformed ${RUN_ARGS[i]} passed to run-mmtests.sh"
			fi
		fi
	done
	if (( ${#MMTESTS_CONFIGS[@]} == 0 )); then
		echo "No config file specified for guests. They will use ${default_mmtests_config}"
		MMTESTS_CONFIGS=( "${default_mmtests_config}" )

	fi

	if (( ${#CONFIGS[@]} == 0 )); then
		echo "No config file specified for the host. We will use ${default_host_config}"
		CONFIGS=( "${default_host_config}" )
	fi

	# A way of specifying various VM properties (namely, for automatic
	# deployment) is through associative arrays (e.g., VM_CPUS["vm1"]=4).
	# Let's define the ones that we support here, so the users don't need
	# to remember of clobbering their host config files with these lines.
	declare -gA VM_CPUS=()
	declare -gA VM_MEMORY=()
	declare -gA VM_DISK_POOL=()
	declare -gA VM_DISK_SPEC=()
	declare -gA VM_DISK_FILE_SIZE=()
	declare -gA VM_IMPORT_DISK_FILE=()
	declare -gA VM_COPY_DISK_FILE=()
	declare -gA VM_COPY_DISK_COW=()
	declare -gA VM_COPY_DISK_DEST_PATH=()
	declare -gA VM_DEPLOY_DISTRO=()
	declare -gA VM_INSTALL_LOCATION=()
	declare -gA VM_AUTOYAST=()
	# XXX
	declare -gA VM_NUMATUNE_NODES=()
	declare -gA VM_NUMATUNE_MODE=()
	declare -gA VM_VCPUPIN_1TO1=()
	declare -gA VM_VCOREPIN_1TO1=()
	declare -gA VM_VTOPOLOGY=()

	import_configs

	# If we don't collect host logs, we cannot run any monitor, not even
	# the ones configured as MONITORS_ALWAYS.
	if [[ "${host_logs}" == "no" ]]; then
		echo "WARNING: Cannot run monitors without host logs. Disabling them (including MONITOR_ALWAYS)"
		run_monitor="no"
		unset MONITORS_GZIP
		unset MONITORS_WITH_LATENCY
		unset MONITORS_TRACER
		unset MONITORS_ALWAYS
	fi

	# Merge the paths of the VM config files coming from the command
	# line and from the host config file.
	if [[ -n "${MMTESTS_VMS_XML_DIR:-}" ]]; then
		local -a cfg_dirs
		IFS=',' read -r -a cfg_dirs <<< "${MMTESTS_VMS_XML_DIR}"
		VM_XML_DIRS+=("${cfg_dirs[@]}")
	fi
	# The script base directory always acts as the final fallback
	VM_XML_DIRS+=("${SCRIPTDIR}")

	# Same as with the xml config file, prepare the paths in where
	# the automatic deployment functions will look for autoyast profiles.
	# And for them as well, the base directory is always considered.
	if [[ -n "${MMTESTS_VMS_AUTOYAST_DIR:-}" ]]; then
		local -a ay_dirs
		IFS=',' read -r -a ay_dirs <<< "${MMTESTS_VMS_AUTOYAST_DIR}"
		VM_AYAST_DIRS+=("${ay_dirs[@]}")
	fi
	[[ -d "${SCRIPTDIR}/autoyast" ]] && VM_AYAST_DIRS+=("${SCRIPTDIR}/autoyast")
	VM_AYAST_DIRS+=("${SCRIPTDIR}")

	# Command line has priority. However, if there wasn't any `--vm` param, check
	# if we have a list of VMs to use in the config files. If there's nothing
	# there either, default to ${MARVIN_KVM_DOMAIN}
	if [[ -n "${vms_from_cli:-}" ]]; then
		IFS=',' read -r -a VMS <<< "${vms_from_cli}"
	else
		if [[ -n "${MMTESTS_VMS:-}" && -n "${MMTESTS_VMS_IP:-}" ]]; then
			die "ERROR: define either MMTESTS_IP or MMTESTS_VMS_IP, not both!"
		fi
		if [[ -n "${MMTESTS_VMS:-}" ]]; then
			read -r -a VMS <<< "${MMTESTS_VMS}"
		elif [[ -n "${MMTESTS_VMS_IP:-}" ]]; then
			# We only have the IPs of the VMs. Let's come
			# up with some names...
			local -a TMP_VMS_IPS=()
			local ip
			read -r -a TMP_VMS_IPS <<< "${MMTESTS_VMS_IP}"
			for ip in "${TMP_VMS_IPS[@]}"; do
				VMS+=( "vm${ip//./}" )
			done
			# As a "bonus", we can already populate GUEST_IP
			read -r -a GUEST_IP <<< "${MMTESTS_VMS_IP}"
		else
			# No --vm, no MMTESTS_VMS and no MMTESTS_VMS_IP. Let's
			# assume we're running inside marvin and try to continue.
			VMS=( "${MARVIN_KVM_DOMAIN}" )
		fi
	fi
	vmcount=${#VMS[@]}

	# Whether we are running in Marvin or, if not, from wherever we got
	# the list of VMs, the array VMS _must_ exist at this point.
	[[ ${#VMS[@]} -gt 0 ]] || die "ASSERT FAILED: VMS must exist at this point!"

	# When using more than 1 VMs, we need MMTESTS_HOST_IP to be explicitly
	# defined, so that we know that we should follow the lockstep protocol,
	# and not just let them run.
	#
	# TODO: If more than 1 VM is used, and MMTESTS_HOST_IP is not defined, we
	# can try to automatically figure it out, and let things proceed...
	if (( vmcount > 1 )) && ! should_sync_host_and_guests ; then
		die "ERROR: When using more than 1 VM, define MMTESTS_HOST_IP!"
	fi

	export MMTESTS_VMS_SSHKEY="${MMTESTS_VMS_SSHKEY:-${SCRIPTDIR}/.ssh/id_mmtests_ed25519}"
	MMTESTS_VMS_SSHKEY="${MMTESTS_VMS_SSHKEY%.pub}"
	MMTESTS_SSH_OPTIONS=" ${MMTESTS_SSH_CONFIG_OPTIONS:-} -o StrictHostKeyChecking=no -o ForwardAgent=no -o ForwardX11=no -o BatchMode=yes -o IdentitiesOnly=yes -i ${MMTESTS_VMS_SSHKEY}"
}

function prepare_host() {
	# If MMTESTS_HOST_IP is defined, we are running as a standalone
	# virtualization bench suite and we need to install some additional packages.
	if should_sync_host_and_guests ; then
		install-depends expect netcat-openbsd iputils

		# We also need to check that MMTESTS_HOST_IP is defined in the
		# guests' configs too, or we'll get stuck (as guests tells from
		# this that they need to contact the host for coordination).
		# So, we add it (and while there, AUTO_PACKAGE_INSTALL too).
		local c
		for c in "${MMTESTS_CONFIGS[@]}"; do
			if ! grep -q MMTESTS_HOST_IP "${c}" ; then
				echo "export MMTESTS_HOST_IP=${MMTESTS_HOST_IP}" >> "${c}"
			fi
			if ! grep -q AUTO_PACKAGE_INSTALL "${c}" ; then
				echo "export AUTO_PACKAGE_INSTALL=\"yes\"" >> "${c}"
			fi
		done
	fi

	install-depends time openssh-clients rsync

	install_numad
	install_tuned
}

# We need the VMs to be able to reach the host, for the guest-host
# synchronization protocol's purposes.
function adjust_firewall() {
	# This is all relevant only if we're running as a standalone suite
	# and if there's more than just one VM.
	if running_in_marvin || ! should_sync_host_and_guests ; then return; fi

	if command -v firewall-cmd &> /dev/null &&
	   [[ "$(firewall-cmd --state 2>/dev/null)" == "running" ]]; then
		# Guests must be able to reach the host
		local ip
		for ip in "${GUEST_IP[@]}"; do
			firewall-cmd --zone=trusted --add-source="${ip}" &>/dev/null || \
				die "ERROR: Cannot allow traffic from ${ip} in the firewall!"
		done
		# Above allow-listing should be enough, but let's just be sure
		# by explicitly opening the "host port".
		firewall-cmd --add-port="${MMTESTS_HOST_PORT}/tcp" &>/dev/null || \
			die "ERROR: Cannot open ${MMTESTS_HOST_PORT} in the firewall!"
	elif command -v iptables &> /dev/null; then
		# Let's save the current state first...
		iptables_backup_file=$(mktemp /tmp/mmtests-iptables-XXXXXX.bak)
		iptables-save > "${iptables_backup_file}"
		# ...And then, as above, open things up.
		for ip in "${GUEST_IP[@]}"; do
			iptables -I INPUT 1 -s "${ip}" -j ACCEPT 2>/dev/null || \
				die "ERROR: Cannot allow traffic from ${ip} in the firewall!"
		done
		iptables -I INPUT 1 -p tcp --dport "${MMTESTS_HOST_PORT}" -j ACCEPT 2>/dev/null || \
			die "ERROR: Cannot allow traffic to port ${MMTESTS_HOST_PORT} in the firewall!"
	fi
}

function reset_firewall() {
	if command -v firewall-cmd &> /dev/null &&
	   [[ "$(firewall-cmd --state 2>/dev/null)" == "running" ]]; then
		local ip
		for ip in "${GUEST_IP[@]}"; do
			firewall-cmd --zone=trusted --remove-source="${ip}" &>/dev/null || true
		done
		firewall-cmd --remove-port="${MMTESTS_HOST_PORT}/tcp" &>/dev/null || true
	elif command -v iptables &> /dev/null &&
	     [[ -n "${iptables_backup_file:-}" && -f "${iptables_backup_file}" ]]; then
		iptables-restore < "${iptables_backup_file}" 2>/dev/null || true
		rm -f "${iptables_backup_file}"
		iptables_backup_file=""
	fi
}

# Applies all offline configurations to a VM disk image (e.g., SSH key
# injection and hostname adjustment) and also execute the offline hook
# scripts defined by the user.
# Parameters: <vm_name> <disk_path>
function offline_configs_and_hooks() {
	local vm="${1}"
	local disk_path="${2}"
	local config_path

	install-depends guestfs-tools

	local priv_key="${MMTESTS_VMS_SSHKEY}"
	local pub_key="${priv_key}.pub"

	if [[ -f "${pub_key}" ]]; then
		if ! ssh-keygen -l -f "${pub_key}" >/dev/null 2>&1; then
			die "ERROR: File ${pub_key} exists but is not a valid SSH public key" >&2
		fi
	else
		echo "Generating a new SSH key at ${priv_key}..."
		mkdir -p "$(dirname "${priv_key}")"
		ssh-keygen -t ed25519 -f "${priv_key}" -N "" -q -C "mmtests-automation@vms" || die "${SHELLPACK_ERROR}"
	fi

	# "Cross-Distro" SSH configuration. We try to support both Distro that
	# still have a monolithic /etc/ssh/sshd_config, and modern ones that
	# have /usr/etc/ssh/ + /etc/ssh/sshd_config.d/.
	local ssh_setup_payload='
	set -e
	if [ -d /etc/ssh/sshd_config.d ] || grep -qs "Include /etc/ssh/sshd_config.d" /etc/ssh/sshd_config /usr/etc/ssh/sshd_config; then
		# Modern distributions (Tumbleweed, newer SLES, RHEL 9+)
		mkdir -p /etc/ssh/sshd_config.d
		echo "PermitRootLogin yes" > /etc/ssh/sshd_config.d/99-mmtests-debug.conf
		echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config.d/99-mmtests-debug.conf
	else
		# Legacy distributions (CentOS 7, older SLES/Debian)
		[ -f /etc/ssh/sshd_config ] || touch /etc/ssh/sshd_config

		# Replace if existing, otherwise append safely
		if grep -q "^#*PermitRootLogin" /etc/ssh/sshd_config; then
			sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
		else
			echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
		fi

		if grep -q "^#*PasswordAuthentication" /etc/ssh/sshd_config; then
			sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
		else
			echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
		fi
	fi
	'

	echo "Applying offline configurations to ${vm}..."

	local -a virt_opts=(
		"-a" "${disk_path}"
		"--hostname" "${vm}"
		"--run-command" "echo '${vm}' > /etc/hostname"
		"--run-command" "echo '${vm}' > /etc/HOSTNAME"
		"--run-command" "systemctl enable sshd || true"
		"--run-command" "${ssh_setup_payload}"
		"--root-password" "password:test"
		"--run-command" "sed -i '/mmtests-automation@vms/d' /root/.ssh/authorized_keys 2>/dev/null || true"
		"--ssh-inject" "root:file:${pub_key}"
	)

	# Parse and append offline hooks
	local offline_hooks="${MMTESTS_VM_OFFLINE_SCRIPTS:-}"
	if [[ -n "${offline_hooks}" ]]; then
		local -a scripts
		IFS=',' read -r -a scripts <<< "${offline_hooks}"

		local script payload hook_name
		for script in "${scripts[@]}"; do
			# Resolve the script path
			if [[ -x "${SCRIPTDIR}/bin-virt/${script}" ]]; then
				payload="${SCRIPTDIR}/bin-virt/${script}"
			elif [[ -x "${SCRIPTDIR}/${script}" ]]; then
				payload="${SCRIPTDIR}/${script}"
			elif command -v "${script}" >/dev/null 2>&1; then
				payload="${script}"
			else
				echo "WARNING: Offline hook '${script}' not found. Skipping." >&2
				continue
			fi

			# Instruct virt-customize to upload, execute, and cleanup the payload
			hook_name=$(basename "${payload}")
			virt_opts+=("--upload" "${payload}:/tmp/mmtests_offline_${hook_name}")
			virt_opts+=("--run-command" "bash /tmp/mmtests_offline_${hook_name}")
			virt_opts+=("--run-command" "rm -f /tmp/mmtests_offline_${hook_name}")
		done
	fi

	# Core requirement for RHEL/Fedora/SUSE guests to avoid SELinux lockouts
	virt_opts+=("--selinux-relabel")

	virt-customize "${virt_opts[@]}" >/dev/null 2>&1 || die "ERROR: Failed to apply offline configurations for ${vm}" >&2
}

function tune_vms_running() {
	# LEGACY: This is only supported if we are running inside Marvin,
	# and with only one VM.
	if [[ "${offline_iothreads:-}" == "yes" ]] &&
	    running_in_marvin ; then
		local offline_cpus=$(virsh dumpxml marvin-mmtests | grep -c iothreadpin)
		if [ "${offline_cpus}" != "0" ]; then
			local phys_cpu
			local virt_cpu
			echo Taking "${offline_cpus}" offline for pinned io threads
			for phys_cpu in $(virsh dumpxml marvin-mmtests | grep iothreadpin | sed -e "s/.* cpuset='\([0-9]\+\)'.*/\1/"); do
				local virt_cpu="$(virsh dumpxml marvin-mmtests | grep vcpupin | grep "cpuset='${phys_cpu}'" | sed -e "s/.* vcpu='\([0-9]\+\)'.*/\1/")"
				ssh "root@${GUEST_IP[0]}" "echo 0 > /sys/devices/system/cpu/cpu${virt_cpu}/online"
				echo "o Virt ${virt_cpu} phys ${phys_cpu}"
			done
		fi
	fi
}

function prepare_and_start_vms() {
	# We need a "runname" that is different for each VM as, otherwise,
	# when running the same benchmark in several VMs results would
	# overwrite each other.
	declare -ga VM_RUNNAME=()

	local v
	if [[ -n "${MMTESTS_VMS_IP:-}" ]]; then
		for v in "${!VMS[@]}"
		do
			VM_RUNNAME[v]="${RUNNAME}-${VMS[v]}"

			echo -n "checking VM: ${VMS[v]} at IP: ${GUEST_IP[v]} ..."
			vm_wait_ssh_with_reset "${GUEST_IP[v]}"
			echo "Ok!"

			activity_log "run-kvm: VM ${VMS[v]} IP ${GUEST_IP[v]}"
		done
		teststate_log "VMs up :: $(date +%s)"
	else
		echo "Booting the VM(s)"
		activity_log "run-kvm: Booting VMs"

		# Let's make sure VMs are actually there. Define them ourselves
		# if they're not.
		local -a deploying_vms=()
		for v in "${!VMS[@]}"; do
			# Undefine already existing VMs, if we're being told so
			if [[ "${MMTESTS_VMS_UNDEF_BEFORE_START:-}" == "yes" ]]; then
				local rm_storage="${MMTESTS_VMS_UNDEF_REMOVE_STORAGE:-no}"
				libvirt::vm_undefine "${VMS[v]}" "${rm_storage}" || die "Failed to forcefully undefine VM: ${VMS[v]}"
			fi

			libvirt::vm_define_if_missing "${VMS[v]}" "${VM_XML_DIRS[@]}" || die "Failed to define VM: ${VMS[v]}"

			 # If the VM is still missing, start (async) deployment.
			if ! libvirt::vm_is_defined "${VMS[v]}"; then
				libvirt::vm_deploy_start "${VMS[v]}" "${VM_AYAST_DIRS[@]}" || die "Failed to trigger deploy for VM: ${VMS[v]}"
				deploying_vms+=("${VMS[v]}")
			fi
		done

		# Sync barrier for the VMs that are being created and installed.
		for vm in "${deploying_vms[@]}"; do
			libvirt::vm_deploy_wait "${vm}" || die "Deployment failed for VM: ${vm}"
		done

		# Adjust the VM configuration and run all the hook scripts that can be run
		# with the VM offline. As it can be rather slow, we run multiple instances
		# in parallel (but not too many, or we'd saturate the host's IOPS).
		local max_io_jobs=4
		local running_jobs=0
		local pids=()
		for v in "${!VMS[@]}"; do
			local disk_path
			disk_path=$(libvirt::get_vm_disk_path "${VMS[v]}")

			if [[ -z "${disk_path}" ]]; then
				echo "WARNING: Could not determine disk path for ${VMS[v]}. Skipping offline hooks." >&2
				continue
			fi

			# Avvio asincrono della configurazione in background
			offline_configs_and_hooks "${VMS[v]}" "${disk_path}" &
			pids+=($!)
			((running_jobs++))

			# Controllo della concorrenza (Sliding Window)
			# Se raggiungiamo il limite, aspettiamo che termini il PRIMO job disponibile
			if (( running_jobs >= max_io_jobs )); then
				wait -n || die "FATAL: Offline hook failed for one of the concurrent VMs"
				((running_jobs--))
			fi
		done
		# Final sync barrier
		for pid in "${pids[@]}"; do
			wait "${pid}" || die "FATAL: Offline hook failed during final sync"
		done

		[[ "${host_logs}" == "yes" ]] &&
			vm_xml_backup_dir="${SHELLPACK_LOG}" ||
			vm_xml_backup_dir="/tmp/mmtests_vms_bckup"
		libvirt::backup_vms_definitions "${VMS[@]}"

		libvirt::tune_vms_offline "${VMS[@]}"

		# LEGACY: booting the current host kernel in VMs is, currently, only
		# supported if we are running inside Marvin, and with only one VM.
		if [[ "${keep_kernel:-}" != "yes" ]] &&
		    running_in_marvin &&
		    [ -e "${SCRIPTDIR}/bin-virt/kvm-boot" ]; then
			echo "Booting current kernel $(uname -r) ${MORE_BOOT_ARGS} on the guest"
			kvm-boot $(uname -r) "${MORE_BOOT_ARGS}" || die "Failed to boot $(uname -r)"
		else
			libvirt::vm_start "${VMS[@]}" || die "Failed to boot VM(s)"
		fi

		teststate_log "VMs up :: $(date +%s)"

		for v in "${!VMS[@]}"
		do
			VM_RUNNAME[v]="${RUNNAME}-${VMS[v]}"

			GUEST_IP[v]=$(libvirt::vm_ip_address "${VMS[v]}");

			libvirt::pin_vm_ip "${VMS[v]}" || echo "WARNING: Failed to pin IP ${GUEST_IP[v]} for ${VMS[v]}"

			echo "VM ready: ${VMS[v]} IP: ${GUEST_IP[v]}"
			activity_log "run-kvm: VM ${VMS[v]} IP ${GUEST_IP[v]}"
		done
	fi

	tune_vms_running
}

# Executes the payload on a single VM. Exported for GNU Parallel.
function _deploy_and_run_hook() {
	local ip="${1}"
	local hook_file="${2}"
	local hook_name
	hook_name=$(basename "${hook_file}")
	local remote_path="/tmp/mmtests_hook_${hook_name}"

	# 1. Transport payload to the VM
	scp ${MMTESTS_SSH_OPTIONS} "${hook_file}" "root@${ip}:${remote_path}" >/dev/null || {
		echo "ERROR: Failed to copy ${hook_name} to ${ip}" >&2
		return 1
	}

	# 2. Execute payload
	# Disable local set -e: if the script triggers a "reboot",
	# the SSH connection drops instantly, returning exit code 255.
	set +e
	ssh ${MMTESTS_SSH_OPTIONS} "root@${ip}" "bash ${remote_path}; rm -f ${remote_path}"
	local ret=$?
	set -e

	# 0 = Clean success
	# 255 = Connection dropped (expected if a reboot occurred either synchronously or asynchronously)
	if [[ ${ret} -ne 0 && ${ret} -ne 255 ]]; then
		echo "ERROR: Hook ${hook_name} on ${ip} failed with exit code ${ret}" >&2
		return 1
	fi

	return 0
}
export -f _deploy_and_run_hook

# Online hooks execution engine.
function execute_online_hooks() {
	local hook_list="${MMTESTS_VM_ONLINE_SCRIPTS:-}"
	[[ -z "${hook_list}" ]] && return "${SHELLPACK_SUCCESS}"

	local -a scripts
	IFS=',' read -r -a scripts <<< "${hook_list}"

	# Ensure Parallel has access to the orchestrator's SSH options
	export MMTESTS_SSH_OPTIONS

	local script payload
	for script in "${scripts[@]}"; do
		# Path resolution prioritizing the bin-virt directory
		if [[ -x "${SCRIPTDIR}/bin-virt/${script}" ]]; then
			payload="${SCRIPTDIR}/bin-virt/${script}"
		elif [[ -x "${SCRIPTDIR}/${script}" ]]; then
			payload="${SCRIPTDIR}/${script}"
		elif command -v "${script}" >/dev/null 2>&1; then
			payload="${script}"
		else
			echo "WARNING: Hook payload '${script}' not found or not executable. Skipping." >&2
			continue
		fi

		echo "Deploying and executing payload: ${payload} across ${vmcount} VMs..."
		activity_log "run-kvm: hook start :: ${script}"

		# Isolated and parallel payload execution on VMs
		parallel -j "${vmcount}" _deploy_and_run_hook {} "${payload}" ::: "${GUEST_IP[@]}" || die "ERROR: Payload ${script} failed on one or more VMs." >&2

		# Sync Barrier: blocks the orchestrator until all VMs are responsive again.
		# Vital if the executed hook rebooted the machines.
		echo "Payload ${script} completed. Enforcing Sync Barrier..."
		local v
		for v in "${!VMS[@]}"; do
			# 300 seconds timeout, check every 10 seconds
			if ! vm_wait_ssh "${GUEST_IP[v]}" 300 10; then
				die "ERROR: VM ${VMS[v]} (${GUEST_IP[v]}) did not return online after hook." >&2
			fi
		done

		activity_log "run-kvm: hook end :: ${script}"
	done
}

function setup_parallel() {
	# Try installing the package, but we have a copy in bin/, as a fallback.
	# For refreshing it:
	#   curl -sL "https://git.savannah.gnu.org/cgit/parallel.git/plain/src/parallel" -o bin/parallel
	#   chmod +x bin/parallel
	install-depends gnu_parallel || true
	# Make sure parallel works, even if it comes from our local copy in bin/
	mkdir -p ~/.parallel && touch ~/.parallel/will-cite

	# Create a clean array of SSH targets for GNU parallel
	declare -ga TARGET_HOSTS=()

	local i
	for i in "${!GUEST_IP[@]}"; do
		TARGET_HOSTS[i]="root@${GUEST_IP[i]}"
	done

	if [[ -n "${MMTESTS_PARALLEL_OUTDIR:-}" ]]; then
		mkdir -p "${MMTESTS_PARALLEL_OUTDIR}"
	fi

	teststate_log "vms ready :: $(date +%s)"
}

function deploy_mmtests() {
	echo "Synchronizing mmtests directory to ${vmcount} VMs via parallel rsync..."

	NAME="$(basename "${SCRIPTDIR}")"
	cd ..

	# Create target directories in parallel
	parallel -j "${vmcount}" ssh ${MMTESTS_SSH_OPTIONS} {} "'mkdir -p git-private/${NAME}'" ::: "${TARGET_HOSTS[@]}" || die "Failed to create remote dirs"

	# Rsync source code in parallel
	export RSYNC_RSH="ssh ${MMTESTS_SSH_OPTIONS}"
	parallel -j "${vmcount}" rsync -az --delete "--exclude='work*'" "--exclude='.git'" "--exclude '*.tar.gz'" "${NAME}/" "{}:git-private/${NAME}/" ::: "${TARGET_HOSTS[@]}" || die "Failed to rsync ${NAME} (via parallel)"

	parallel -j "${vmcount}" ssh ${MMTESTS_SSH_OPTIONS} {} "'cd git-private/${NAME} && rm -rf work/log/* work-*.tar.gz'" ::: "${TARGET_HOSTS[@]}" || true

	# Ensure automatic package installation flag is set
	parallel -j "${vmcount}" ssh ${MMTESTS_SSH_OPTIONS} {} "'touch ~/.mmtests-auto-package-install'" ::: "${TARGET_HOSTS[@]}" || die "Failed to set auto-package install flag"

	# Generate the variants of the config files for the benchmarks inside the guests
	parallel -j "${vmcount}" ssh ${MMTESTS_SSH_OPTIONS} {} "'cd git-private/${NAME} && ./bin/autogen-configs'" ::: "${TARGET_HOSTS[@]}" || die "Failed to generate MMTests config files on guests"

	# Update build flags if requested by the host configuration
	if [[ "${MMTESTS_UPDATE_BUILD_FLAGS:-}" == "yes" ]]; then
		parallel -j "${vmcount}" ssh ${MMTESTS_SSH_OPTIONS} {} "'cd git-private/${NAME} && ./bin/update-build-flags.sh'" ::: "${TARGET_HOSTS[@]}" || die "Failed to update build flags on guests"
	fi

	cd "${NAME}"
}

function tune_host() {
	start_numad
	start_tuned

	# Set performance governor on the host, if wanted
	if [[ "${force_host_performance}" == "yes" && -f "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor" ]]; then
		host_scalinggov_base="$(< /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
		if [[ -f "/sys/devices/system/cpu/intel_pstate/no_turbo" ]]; then
			host_noturbo_base="$(< "/sys/devices/system/cpu/intel_pstate/no_turbo")"
		fi
		force_performance_setup || true
	fi
}

function prepare_host_monitors() {
	RUN_MONITOR="${run_monitor:-${RUN_MONITOR:-}}"
	if [[ "${RUN_MONITOR:-}" == "no" ]]; then
		# Disable monitors (except MONITORS_ALWAYS)
		unset MONITORS_GZIP
		unset MONITORS_WITH_LATENCY
		unset MONITORS_TRACER
	else
		# Check at least one monitor is enabled
		if [[ -z "${MONITORS_ALWAYS:-}" &&
		      -z "${MONITORS_GZIP:-}" &&
		      -z "${MONITORS_WITH_LATENCY:-}" &&
		      -z "${MONITORS_TRACER:-}" ]]; then
			echo WARNING: Monitors enabled but none configured
		fi
	fi

	STAP_USED=""
	check_monitor_stap
	if [[ -n "${STAP_USED:-}" ]]; then
		fixup_stap
	fi
}

# This variable can be used to provide additional options to `nc`, as it is
# used both here and within the shellpacks. This is mostly intended for
# debugging, e.g., adding "-v" to have more output.
#export _NCV="-v"

# If MMTESTS_HOST_IP is defined, we need to coordinate run-mmtests.sh
# execution phases inside the various VMs.
#
# When each VM reach one of such phases, it will send a message, letting
# us know what state it has actually reached, and wait for a poke. What we
# need to do here, is making sure that all VMs have reached one state.
# As soon as we have collected as many tokens as there are VMs, it means
# we've reached that point, and we poke every VM so they can proceed.
#
# What the states are, and how transitioning between them occurs, is
# explained in the following diagram:
#
#  +-------+        +---------------+
#  | START +------->| mmtests_start |<-----+
#  +-------+        +-------+-------+      |
#                           |test_do/      |NO
#                           | tokens++     |
#                           v              |
#                 +-------------------+    |
#                 |tokens == vmcount ?+----+
#                 +---------+---------+
#                           |YES/
#                           | tokens=0
#                           v
#                      +---------+
#            +-------->| test_do |<--------+
#            |         +----+----+         |
#            |              |test_do/      |
#            |              | tokens++     |NO
#            |              v              |
#   test_do/ |    +-------------------+    |
#    tokens=1|    |tokens == vmcount ?+----+
#            |    +---------+---------+
#            |              |YES/
#            |              | tokens=0
#            |              v                mmtests_end/
#            +--------+-----------+           tokens=1
#      +------------->| test_do2  +----------------------+
#      |   +--------->+-----+-----+------------------+   |
#      |   |                |iteration_begin/        |   |
#      |   |                | tokens=1               |   |
#      |   |                v                        |   |
#      |   |       +-----------------+               |   |
#      |   |       | iteration_begin |<--------+     |   |
#      |   |       +--------+--------+         |     |   |
#      |   |                |iterations_begin/ |NO   |   |
#      |   |                | tokens++         |     |   |
#      |   |                v                  |     |   |
#      |   |      +-------------------+        |     |   |
#      |   |      |tokens == vmcount ?+--------+     |   |
#      |   |      +---------+---------+              |   |
#      |   |                |YES/           test_done|   |
#      |   |                | tokens=0       tokens=1|   |
#      |   |                v                        |   |
#      |   |        +---------------+                |   |
#      |   |        | iteration_end |<--------+      |   |
#      |   |        +-------+-------+         |      |   |
#      |   |YES/            |iterations_end/  |NO    |   |
#      |   | tokens=0       | tokens++        |      |   |
#      |   |                v                 |      |   |
#      |   |      +-------------------+       |      |   |
#      |   +------+tokens == vmcount ?+-------+      |   |
#      |          +-------------------+              |   |
#      |                                             |   |
#      |              +-----------+                  |   |
#      |              | test_done |<-----------------+   |
#      |              +-----+-----+<-------+             |
#      |YES/                |test_done/    |NO           |
#      | tokens=0           | tokens++     |             |
#      |                    v              |             |
#      |          +-------------------+    |             |
#      +----------+tokens == vmcount ?+----+             |
#                 +-------------------+                  |
#                                                        |
#                    +-------------+<--------------------+
#                    | mmtests_end |<------+
#                    +------+------+       |
#                           |mmtests_end/  |
#                           | tokens++     |NO
#                           v              |
#  +-------+      +-------------------+    |
#  | QUIT  |<-----+tokens == vmcount ?+----+
#  +-------+      +-------------------+
#
# For figuring out when VMs send the tokens for any give state,
# check run-mmtests.sh and the shellpacks rewriting code.
#
# Token exchanging happens (currently) over the network, via `nc`.
#
# TODO: likely, this can be re-implemented using, for instance, something
# like gRPC (either here, with https://github.com/fullstorydev/grpcurl) or
# by putting together some service program.
#
function log_state() {
	echo -ne "$(date +%H:%M:%S) ${1}"
	[ "${1}" == "test_do" ] && echo -ne "\t"
	echo -ne " "
}

function synchronize_vms() {
	if should_sync_host_and_guests ; then
		if (( vmcount != 1 )); then echo "TIME     STATE           VMs"; fi
		local STATE="mmtests_start"
		local tokens=0

		tail -f "${NCFILE}" | while [[ "${STATE}" != "QUIT" ]] && read -r TOKEN
		do
			teststate_log "recvd token :: \"${TOKEN}\" $(date +%s)"
			# With only 1 VM, there is not much to be synched. We just need
			# to reply with the very same token we receive, in order to
			# unblock each phase of run-mmtests.sh, inside the VM itself.
			if (( vmcount == 1 )); then
				case "${TOKEN}" in
					"mmtests_start"|"test_do"|"iteration_begin"|"iteration_end"|"test_done")
						mmtests_signal_token "${TOKEN}" "${GUEST_IP[@]}"
						teststate_log "sent token :: \"${TOKEN}\" $(date +%s)"
						;;
					"mmtests_end")
						mmtests_signal_token "mmtests_end" "${GUEST_IP[@]}"
						teststate_log "sent token :: \"${TOKEN}\" $(date +%s)"
						STATE="QUIT"
						;;
					*)
						echo "ERROR: unknown token (\'${TOKEN}\') received!"
						STATE="QUIT"
						[[ -n "${PARALLEL_PID:-}" ]] && kill "${PARALLEL_PID}"
						;;
				esac
			else
				case "${STATE}" in
					"mmtests_start"|"test_do"|"iteration_begin"|"iteration_end"|"test_done"|"mmtests_end")
						if (( tokens == 0 )); then
							# DEBUG: not very useful info to print, unless we're debugging
							#echo "run-kvm --> run-mmtests: state = ${STATE}"
							log_state ${STATE}
							teststate_log "enter state :: \"${STATE}\" $(date +%s)"
							activity_log "run-kvm: state \"${STATE}\""
						fi
						if [[ "${TOKEN}" != "${STATE}" ]]; then
							echo "ERROR: wrong token (\'${TOKEN}\') received while in state \'${STATE}\'!"
							STATE="QUIT"
							[[ -n "${PARALLEL_PID:-}" ]] && kill "${PARALLEL_PID}"
						else
							echo -n 'X'
							tokens=$(( tokens + 1 ))
						fi
						if (( tokens == vmcount )); then
							tokens=0
							if [[ "${STATE}" == "mmtests_start" ]]; then
								STATE="test_do"
							elif [[ "${STATE}" == "test_do" || "${STATE}" == "iteration_end" || "${STATE}" = "test_done" ]]; then
								STATE="test_do2"
							elif [[ "${STATE}" == "iteration_begin" ]]; then
								STATE="iteration_end"
							elif [[ "${STATE}" == "test_done" ]]; then
								STATE="test_do2"
							elif [[ "${STATE}" == "mmtests_end" ]]; then
								STATE="QUIT"
							fi
							echo " Done!"
							activity_log "run-kvm: sending token \"${TOKEN}\""
							mmtests_signal_token "${TOKEN}" "${GUEST_IP[@]}"
							teststate_log "sent token :: \"${TOKEN}\" $(date +%s)"
						fi
						;;
					"test_do2")
						tokens=1
						if [[ "${TOKEN}" == "test_do" ]]; then
							STATE="test_do"
						elif [[ "${TOKEN}" == "test_done" ]]; then
							STATE="test_done"
						elif [[ "${TOKEN}" == "iteration_begin" ]]; then
							STATE="iteration_begin"
						elif [[ "${TOKEN}" == "mmtests_end" ]]; then
							STATE="mmtests_end"
						else
							echo "ERROR: wrong token (\'${TOKEN}\') received while in state \'${STATE}\'!"
							STATE="QUIT"
							[[ -n "${PARALLEL_PID:-}" ]] && kill "${PARALLEL_PID}"
						fi
						# DEBUG: not very useful info to print, unless we're debugging
						#echo "run-kvm --> run-mmtests: state = ${STATE}"
						log_state ${STATE} ; echo -ne 'X'
						teststate_log "enter state :: \"${STATE}\" $(date +%s)"
						activity_log "run-kvm: state \"${STATE}\""
						;;
					*)
						echo "ERROR: unknown token (\'${TOKEN}\') received!"
						STATE="QUIT"
						[[ -n "${PARALLEL_PID:-}" ]] && kill "${PARALLEL_PID}"
						;;
				esac
			fi
		# TODO: We need this "|| true" due to the fragility of the
		# pipe (and the fact that we run with 'pipefail'). We need to
		# improve this (e.g., by using a fifo).
		done || true
		kill "${NCPID}" || true
		rm -f "${NCFILE}"
		NCPID=""
	fi

	# Wait for GNU parallel completion and capture its return value
	if [[ -n "${PARALLEL_PID}" ]]; then
		wait "${PARALLEL_PID}"
		EXIT_CODE=$?
	fi
}

function collect_results() {
	echo "Syncing ${SHELLPACK_LOG_BASE_SUBDIR} from ${vmcount} VMs"

	# Archive results remotely with parallel. We use parallel's multiple input
	# arrays (::: and :::+) to match IPs with their specific runnames.
	echo "Archiving results on guests"
	parallel -j "${vmcount}" ssh ${MMTESTS_SSH_OPTIONS} root@{1} "'cd git-private/${NAME} && tar -czf work-{2}.tar.gz ${SHELLPACK_LOG_BASE_SUBDIR}'" \
		::: "${GUEST_IP[@]}" :::+ "${VM_RUNNAME[@]}" || die "Failed to archive results remotely"

	# Now we can download all the archives, also in parallel.
	echo "Downloading archives"
	parallel -j "${vmcount}" scp ${MMTESTS_SSH_OPTIONS} "'root@{1}:git-private/${NAME}/work-{2}.tar.gz'" . \
		::: "${GUEST_IP[@]}" :::+ "${VM_RUNNAME[@]}" || die "Failed to download archives"

	# And, eventually, we extract and rename the directory in a way that's
	# familiar for other MMTests tools.
	echo "Extracting local archives"
	local v
	for v in ${!VMS[@]}; do
		local new_runname="${VM_RUNNAME[v]}"
		if running_in_marvin ; then
			# Marvin expects results in "${RUNNAME}", and we don't
			# want to break it, so let's reinstate the old name.
			new_runname="${RUNNAME}"
		fi

		# Store the results of benchmark named `FOO`, done in VM 'bar' in
		# a directory called 'bar-FOO (and cleanup the now unnecessary archive).
		local tar_file="work-${VM_RUNNAME[v]}.tar.gz"
		tar --transform="s|${RUNNAME}|${new_runname}|" -xf ${tar_file} || die "Failed to extract ${tar_file}"
		rm -f "${tar_file}"
	done
}

function stop_vms() {
	local v mac
	for v in "${!VMS[@]}"; do
		if [[ -n "${GUEST_IP[v]:-}" ]]; then
			# Discovers the MAC address directly from the active VM interface
			mac=$(virsh domiflist "${VMS[v]}" 2>/dev/null | awk 'NR>2 && $5!="" {print $5; exit}')
			
			if [[ -n "${mac}" ]]; then
				# Assumes 'default' network. Replace with a variable if your framework supports custom networks.
				libvirt::unpin_vm_ip "default" "${mac}" "${GUEST_IP[v]}" "${VMS[v]}"
			else
				echo "WARNING: Could not find MAC address for ${VMS[v]}, skipping IP unpin." >&2
			fi
		fi
	done

	if [ -n "${MMTESTS_VMS_IP:-}" ]; then
		echo "Leaving the VM(s) up"
	else
		echo "Shutting down the VM(s)"
		activity_log "run-kvm: Shutoff VMs"
		libvirt::vm_stop "${VMS[@]}" || echo "WARNING: Failed to cleanly stop all VMs" >&2
		teststate_log "VMs down :: $(date +%s)"
	fi
}


function execute_tests() {
	activity_log "run-kvm: Start"

	# For now, we do not support multiple iterations on the host-side. It is,
	# however, convenient to have a common structure of the activity log between
	# run-kvm and run-mmtests (that supports iterations), so we at least define
	# the counter and log its value, so comparing the output of the monitors
	# on the host, between different runs, will work.
	MMTEST_HOST_ITERATION=0

	# We only collect logs if the '-L' parameter was present.
	local timestamps="/dev/null"
	if [[ "${host_logs}" == "yes" ]]; then
		export SHELLPACK_LOG="${SHELLPACK_LOG_BASE}/${RUNNAME}-host/iter-${MMTEST_HOST_ITERATION}"
		# Delete old runs
		rm -rf "${SHELLPACK_LOG}" &>/dev/null
		mkdir -p "${SHELLPACK_LOG}"
		export SHELLPACK_ACTIVITY="${SHELLPACK_LOG}/tests-activity"
		export SHELLPACK_LOGFILE="${SHELLPACK_LOG}/tests-timestamp"
		export SHELLPACK_SYSSTATEFILE="${SHELLPACK_LOG}/tests-sysstate"
		timestamps="${SHELLPACK_LOG}/timestamp"
	fi


	activity_log "run-kvm: Iteration $((MMTEST_HOST_ITERATION+1)) start"

	teststate_log "start :: $(date +%s)"

	sysstate_log_basic_info
	collect_hardware_info
	collect_kernel_info
	collect_os_info
	collect_sysconfig_info

	prepare_and_start_vms

	adjust_firewall

	setup_parallel

	execute_online_hooks

	deploy_mmtests

	echo "Executing mmtests in ${vmcount} guest(s)"
	teststate_log "test begin :: $(date +%s)"
	activity_log "run-kvm: test start :: $(date +%s)"

	sysstate_log_proc_files "start"

	sync
	start_monitors

	activity_log "run-kvm: begin run-mmtests in VMs"
	teststate_log "test begin :: $(date +%s)"
	activity_log "run-kvm: begin ${CURRENT_TEST}"

	# XXX
	[[ -n "${NCPID:-}" ]] && kill "${NCPID}" 2>/dev/null || true
	local NCFILE="$(mktemp)"
	nc ${_NCV:-} -n -4 -l -k "${MMTESTS_HOST_IP}" "${MMTESTS_HOST_PORT}" > "${NCFILE}" &
	NCPID=$!

	local parallel_cmd="ssh ${MMTESTS_SSH_OPTIONS} {} 'cd git-private/${NAME} && ./run-mmtests.sh ${RUN_ARGS[*]}'"
	if [[ -n "${MMTESTS_PARALLEL_OUTDIR:-}" ]]; then
		parallel_cmd="${parallel_cmd} > ${MMTESTS_PARALLEL_OUTDIR}/{}.log 2>&1"
	fi

	/usr/bin/time -f "time :: ${CURRENT_TEST} %U user %S system %e elaps/ed" -o "${timestamps}" \
		parallel --line-buffer -j "${vmcount}" "${parallel_cmd}" ::: "${TARGET_HOSTS[@]}" &
	PARALLEL_PID=$!

	synchronize_vms

	sync
	stop_monitors

	sysstate_log_proc_files "end"

	echo "Execution in guest(s) ended. Status ${EXIT_CODE}"
	activity_log "run-kvm: test end :: $(date +%s) ${EXIT_CODE}"
	teststate_log "test end :: $(date +%s) ${EXIT_CODE}"
	if [[ -n "${SHELLPACK_LOG}" && -f "${SHELLPACK_LOG}/timestamp" ]]; then
		teststate_log "$(< "${SHELLPACK_LOG}/timestamp")"
		rm "${SHELLPACK_LOG}/timestamp"
	fi

	teststate_log "finish :: $(date +%s)"

	if [[ "${host_logs}" == "yes" ]]; then
		dmesg > "${SHELLPACK_LOG}/dmesg"
		gzip -f "${SHELLPACK_LOG}/dmesg"
		gzip -f "${SHELLPACK_SYSSTATEFILE}"
	fi

	activity_log "run-kvm: Iteration $((MMTEST_HOST_ITERATION+1)) end"

	collect_results
	stop_vms

	activity_log "run-kvm: End"
	teststate_log "status :: ${EXIT_CODE}"
}

function cleanup() {
	# Capture the status of the exit that brought us here (with $?),
	# but use it only if there's not a value in EXIT_CODE already.
	EXIT_CODE="${EXIT_CODE:-$?}"

	# Kill dangling sync processes if interrupted
	[[ -n "${NCPID:-}" ]] && kill "${NCPID}" 2>/dev/null || true

	shutdown_numad
	shutdown_tuned

	restore_performance_setup "${host_scalinggov_base:-}" "${host_noturbo_base:-}" || true

	reset_firewall

	libvirt::restore_vms_definitions "${VMS[@]}"

	command exit "${EXIT_CODE}"
}

function main() {
	# Setup trap for robust cleanup on exit or failure
	trap cleanup EXIT INT TERM ERR

	prologue
	parse_args "$@"
	parse_config
	prepare_host
	tune_host
	prepare_host_monitors
	execute_tests

	exit $EXIT_CODE
	# cleanup is executed automatically
}

main "$@"
