#!/bin/bash
# shellcheck enable=require-variable-braces

# Author: Dario Faggioli <dfaggioli@suse.com>
# script for running mmtests in one or multiple VMs

set "${MMTESTS_SH_DEBUG:-+x}"
#set -euo pipefail

# Global defaults
DEFAULT_CONFIG=config
export MARVIN_KVM_DOMAIN=${MARVIN_KVM_DOMAIN:-"marvin-mmtests"}

function usage() {
	echo "$0 [-pkonmh] [-C CONFIG_HOST] [--vm VMNAME[,VMNAME][,...]]  run-mmtests-options"
	echo
	echo "-h|--help              Prints this help."
	echo "-p|--performance       Force performance CPUFreq governor on the host before starting the tests"
	echo "-L|--host-logs         Collect logs and hardware info about the host"
	echo "-k|--keep-kernel       Use whatever kernel the VM currently has."
	echo "-o|--offline-iothreads Take down some VM's CPUs and use for IOthreads."
	echo "-m|--run-monitor       Force enable monitoring on the host."
	echo "-n|--no-monitor        Force disable monitoring on the host."
	echo "-C|--config-host CFG   Use CFG as config file for the host."
	echo "--vm VMNAME[,VMNAME]   Name(s) of existing, and already known to 'virsh', VM(s)."
	echo "                       If not specified, use \${MARVIN_KVM_DOMAIN} as VM name."
	echo "                       If that is not defined, use 'marvin-mmtests'."
	echo "run-mmtests-options    Parameters for run-mmtests.sh inside the VM (check them"
	echo "                       with ./run-mmtests.sh -h)."
	echo ""
	echo "NOTE that 'run-mmtests-options', i.e., the parameters that will be used to execute"
	echo "run-mmtests.sh inside the VMs, must always follow all the parameters intended for"
	echo "run-kvm.sh itself."
}

# Parameters handling. Note that our own parmeters (i.e., run-kvm.sh
# parameters) must always come *before* the parameters we want MMTests
# inside the VM to use.
#
# There may be params that are valid arguments for both run-kvm.sh and
# run-mmtests.sh. We need to make sure that they are parsed only once.
# In fact, if we any of them is actually present twice, and we parse both
# the occurrences in here, then run-mmtests.sh, when run inside the VMs(s),
# will not see them.
#
# This is why this code looks different than "traditional" parameter handling,
# but it is either this, or we mandate that there can't be parameters with the
# same names in run-kvm.sh and run-mmtests.sh.
function parse_args() {
	declare -ga RUN_ARGS=()
	declare -ga CONFIGS=()

	while true; do
		case "${1:-}" in
			-p|--performance)
				if [ -z "${FORCE_HOST_PERFORMANCE_SETUP:-}" ]; then
					FORCE_HOST_PERFORMANCE_SETUP="yes"
					shift
				else
					break
				fi
				;;
			-L|--host-logs)
				HOST_LOGS="yes"
				shift
				;;
			-k|--keep-kernel)
				KEEP_KERNEL="yes"
				shift
				;;
			-o|--offline-iothreads)
				OFFLINE_IOTHREADS="yes"
				shift
				;;
			-m|--run-monitor)
				if [ -z "${FORCE_RUN_MONITOR:-}" ]; then
					FORCE_RUN_MONITOR="yes"
					shift
				else
					break
				fi
				;;
			-n|--no-monitor)
				if [ -z "${FORCE_RUN_MONITOR:-}" ]; then
					FORCE_RUN_MONITOR="no"
					shift
				else
					break
				fi
				;;
			-C|--config-host)
				shift
				CONFIGS+=( "${1}" )
				shift
				;;
			--vm|--vms)
				shift
				VMS_LIST="yes"
				VMS=${1}
				shift
				;;
			-h|--help)
				usage
				exit "${SHELLPACK_SUCCESS}"
				;;
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

	export PATH="${SCRIPTDIR}/bin:${PATH}:${SCRIPTDIR}/bin-virt"

	declare -ga MMTESTS_CONFIGS
	declare -ga GUEST_IP
	declare -ga VM_RUNNAME

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

	# No config file specified for guests, so they'll use the default.
	[ ${#MMTESTS_CONFIGS[@]} -gt 0 ] || MMTESTS_CONFIGS=( "${DEFAULT_CONFIG}" )

	# If we have an host config, we use that one here. That's rather handy if,
	# for instance, we want different monitors or topology related tuning
	# on the host and in the guests.
	#
	# If, OTOH, we don't have an host config file, let's import the config
	# file(s) of the guests and use them for the host as well.
	[ ${#CONFIGS[@]} -gt 0 ] || CONFIGS=( "${MMTESTS_CONFIGS[@]}" )

	import_configs

	# Command line has priority. However, if there wasn't any `--vm` param, check
	# if we have a list of VMs to use in the config files. If there's nothing
	# there either, default to ${MARVIN_KVM_DOMAIN}
	if [ -z "${VMS:-}" ] && [ "${MMTESTS_VMS:-}" != "" ]; then
		VMS_LIST=yes
		# MMTESTS_VMS is space separated, we want VMS to be comma separated
		VMS=$(echo "${MMTESTS_VMS// /,}")
	fi
	if [ -z "${VMS:-}" ]; then
		VMS="${MARVIN_KVM_DOMAIN}"
	fi

	MMTESTS_SSH_OPTIONS=" ${MMTESTS_SSH_CONFIG_OPTIONS:-} -o StrictHostKeyChecking=no -o ForwardAgent=no -o ForwardX11=no"
}

function prepare_host() {
	# If MMTESTS_HOST_IP is defined, we are running as a standalone
	# virtualization bench suite and we need to install some additional packages.
	if [ -n "${MMTESTS_HOST_IP:-}" ]; then
		install-depends expect netcat-openbsd iputils

		# We also need to check that MMTESTS_HOST_IP is defined in the
		# guests' configs too, or we'll get stuck (as guests tells from
		# this that they need to contact the host for coordination).
		# So, we add it (and while there, AUTO_PACKAGE_INSTALL too).
		local c
		for c in "${MMTESTS_CONFIGS[@]}"; do
			if [ "$(grep MMTESTS_HOST_IP "${c}")" = "" ] ; then
				echo "export MMTESTS_HOST_IP=${MMTESTS_HOST_IP}" >> "${c}"
			fi
			if [ "$(grep AUTO_PACKAGE_INSTALL "${c}")" = "" ] ; then
				echo "export AUTO_PACKAGE_INSTALL=\"yes\"" >> "${c}"
			fi
		done
	fi

	install-depends time openssh-clients rsync

	install_numad
	install_tuned
}

# We need to be able to reach the guest at the port we use for guest-host
# communication, even if a firewall is up. This should work fine if with
# firewalld/firewall-cmd.
function firewall_whitelist_ip() {
	local IP=${1}
	if command -v firewall-cmd &> /dev/null && [ "$(firewall-cmd --state)" = "running" ]; then
		firewall-cmd --zone=trusted --add-source="${IP}"
	fi
}

function tune_vms_running() {
	# LEGACY: This is only supported if we are running inside Marvin,
	# and with only one VM.
	if [ "${OFFLINE_IOTHREADS:-}" = "yes" ] &&
	    [ "$VMS" = "$MARVIN_KVM_DOMAIN" ]; then
		local offline_cpus=$(virsh dumpxml marvin-mmtests | grep -c iothreadpin)
		if [ "${offline_cpus}" != "0" ]; then
			echo Taking "${offline_cpus}" offline for pinned io threads
			for PHYS_CPU in $(virsh dumpxml marvin-mmtests | grep iothreadpin | sed -e "s/.* cpuset='\([0-9]\+\)'.*/\1/"); do
				local VIRT_CPU="$(virsh dumpxml marvin-mmtests | grep vcpupin | grep "cpuset='${PHYS_CPU}'" | sed -e "s/.* vcpu='\([0-9]\+\)'.*/\1/")"
				ssh "root@${GUEST_IP[1]}" "echo 0 > /sys/devices/system/cpu/cpu${VIRT_CPU}/online"
				echo "o Virt ${VIRT_CPU} phys ${PHYS_CPU}"
			done
		fi
	fi
}

function prepare_and_start_vms() {
	# Arrays where we store, for each VM, the IP and a VM-specific
	# runname. The latter, in particular, is necessary because otherwise,
	# when running the same benchmark in several VMs with different names,
	# results would overwrite each other.
	if [ "${MMTESTS_VMS_IP:-}" != "" ]; then
		# MMTESTS_VMS_IP is space separated, we want it to be comma separated
		IPS=$(echo "${MMTESTS_VMS_IP// /,}")

		local i=1
		for IP in $(tr ',' '\n' <<< "${IPS}")
		do
			GUEST_IP[${i}]=${IP}
			i=$(( ${i} + 1 ))
		done

		local v=1
		for VM in $(tr ',' '\n' <<< "${VMS}")
		do
			echo "checking VM: ${VM} at IP: ${GUEST_IP[${v}]}"
			wait_ssh_available "${GUEST_IP[${v}]}"
			echo "VM ready: ${VM} IP: ${GUEST_IP[${v}]}"
			firewall_whitelist_ip "${GUEST_IP[${v}]}"
			activity_log "run-kvm: VM ${VM} IP ${GUEST_IP[${v}]}"

			VM_RUNNAME[${v}]="${RUNNAME}-${VM}"
			v=$(( ${v} + 1 ))
		done

		[ ${v} -eq ${i} ] || die "MMTESTS_VMS and MMTESTS_VMS_IP mismatch"
	else
		echo "Booting the VM(s)"
		activity_log "run-kvm: Booting VMs"

		# LEGACY: booting the current host kernel in VMs is, currently, only
		# supported if we are running inside Marvin, and with only one VM.
		if [ "${KEEP_KERNEL:-}" != "yes" ] &&
		    [ "$VMS" = "$MARVIN_KVM_DOMAIN" ] &&
		    [ -e "${SCRIPTDIR}/bin-virt/kvm-boot" ]; then
			echo "Booting current kernel $(uname -r) ${MORE_BOOT_ARGS} on the guest"
			kvm-boot $(uname -r) "${MORE_BOOT_ARGS}" || die "Failed to boot $(uname -r)"
		else
			kvm-start --vm "${VMS}" || die "Failed to boot VM(s)"
		fi

		teststate_log "VMs up :: $(date +%s)"

		local v=1
		for VM in $(tr ',' '\n' <<< "${VMS}")
		do
			GUEST_IP[${v}]=$(kvm-ip-address --vm "${VM}")
			echo "VM ready: ${VM} IP: ${GUEST_IP[${v}]}"
			if [ "${HOST_LOGS:-}" = "yes" ]; then
				virsh dumpxml "${VM}" > "${SHELLPACK_LOG}/${VM}".xml
			fi
			firewall_whitelist_ip "${GUEST_IP[${v}]}"
			activity_log "run-kvm: VM ${VM} IP ${GUEST_IP[${v}]}"

			VM_RUNNAME[${v}]="${RUNNAME}-${VM}"
			v=$(( ${v} + 1 ))
		done
	fi
	VMCOUNT=$(( v - 1 ))

	tune_vms_running

	# if we're not using firewall-cmd, let's just (desperately) try something with
	# iptables, but I can't be sure it'll work equally well.
	if [ -n "${MMTESTS_HOST_IP:-}" ] && ! command -v firewall-cmd &> /dev/null; then
		iptables -A INPUT -p tcp --dport "${MMTESTS_HOST_PORT:-1234}" -j ACCEPT || true
	fi

	[ ${VMCOUNT} -lt 1 ] && die "ERROR: No VM specified?"
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
	for (( v=1; v<=VMCOUNT; v++ )); do
		TARGET_HOSTS+=( "root@${GUEST_IP[${v}]}" )
	done

	if [[ -n "${MMTESTS_PARALLEL_OUTDIR:-}" ]]; then
		mkdir -p "${MMTESTS_PARALLEL_OUTDIR}"
	fi

	teststate_log "vms ready :: $(date +%s)"
}

function deploy_mmtests() {
	echo "Synchronizing mmtests directory to ${VMCOUNT} VMs via parallel rsync..."

	NAME="$(basename "${SCRIPTDIR}")"
	cd ..

	# Create target directories in parallel
	parallel -j "${VMCOUNT}" ssh ${MMTESTS_SSH_OPTIONS} {} "'mkdir -p git-private/${NAME}'" ::: "${TARGET_HOSTS[@]}" || die "Failed to create remote dirs"

	# Rsync source code in parallel
	export RSYNC_RSH="ssh ${MMTESTS_SSH_OPTIONS}"
	parallel -j "${VMCOUNT}" rsync -az --delete "--exclude='work*'" "--exclude='.git'" "--exclude '*.tar.gz'" "${NAME}/" "{}:git-private/${NAME}/" ::: "${TARGET_HOSTS[@]}" || die "Failed to rsync ${NAME} (via parallel)"

	parallel -j "${VMCOUNT}" ssh ${MMTESTS_SSH_OPTIONS} {} "'cd git-private/${NAME} && rm -rf work/log/* work-*.tar.gz'" ::: "${TARGET_HOSTS[@]}" || true

	# Ensure automatic package installation flag is set
	parallel -j "${VMCOUNT}" ssh ${MMTESTS_SSH_OPTIONS} {} "'touch ~/.mmtests-auto-package-install'" ::: "${TARGET_HOSTS[@]}" || die "Failed to set auto-package install flag"

	cd "${NAME}"
}

function tune_host() {
	start_numad
	start_tuned

	# Set performance governor on the host, if wanted
	if [ "${FORCE_HOST_PERFORMANCE_SETUP:-}" = "yes" ]; then
		FORCE_HOST_PERFORMANCE_SCALINGGOV_BASE="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
		local NOTURBO="/sys/devices/system/cpu/intel_pstate/no_turbo"
		[ -f ${NOTURBO} ] && FORCE_HOST_PERFORMANCE_NOTURBO_BASE="$(cat ${NOTURBO})"
		force_performance_setup || true
	fi
}

function prepare_host_monitors() {
	# Check host monitors
	if [ "${FORCE_RUN_MONITOR:-}" != "" ]; then
		RUN_MONITOR="${FORCE_RUN_MONITOR}"
	fi
	if [ "${RUN_MONITOR:-}" = "no" ] || [ "${HOST_LOGS:-}" != "yes" ]; then
		# Disable monitor
		unset MONITORS_GZIP
		unset MONITORS_WITH_LATENCY
		unset MONITORS_TRACER
		# If we don't collect host logs, we don't want to monitor it either,
		# not even with 'always on' monitors. In fact, we don't have a place
		# where we could store the data!
		[ "${HOST_LOGS:-}" != "yes" ] && unset MONITORS_ALWAYS
	else
		# Check at least one monitor is enabled
		if [ -z "${MONITORS_ALWAYS:-}" ] && [ -z "${MONITORS_GZIP:-}" ] && [ -z "${MONITORS_WITH_LATENCY:-}" ] && [ -z "${MONITORS_TRACER:-}" ]; then
			echo WARNING: Monitors enabled but none configured
		fi
	fi

	STAP_USED=
	MONITOR_STAP=
	check_monitor_stap
	if [ "${STAP_USED}" != "" ]; then
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
#                 |tokens == VMCOUNT ?+----+
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
#    tokens=1|    |tokens == VMCOUNT ?+----+
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
#      |   |      |tokens == VMCOUNT ?+--------+     |   |
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
#      |   +------+tokens == VMCOUNT ?+-------+      |   |
#      |          +-------------------+              |   |
#      |                                             |   |
#      |              +-----------+                  |   |
#      |              | test_done |<-----------------+   |
#      |              +-----+-----+<-------+             |
#      |YES/                |test_done/    |NO           |
#      | tokens=0           | tokens++     |             |
#      |                    v              |             |
#      |          +-------------------+    |             |
#      +----------+tokens == VMCOUNT ?+----+             |
#                 +-------------------+                  |
#                                                        |
#                    +-------------+<--------------------+
#                    | mmtests_end |<------+
#                    +------+------+       |
#                           |mmtests_end/  |
#                           | tokens++     |NO
#                           v              |
#  +-------+      +-------------------+    |
#  | QUIT  |<-----+tokens == VMCOUNT ?+----+
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
	if [ -n "${MMTESTS_HOST_IP:-}" ]; then
		[ ${VMCOUNT} -ne 1 ] && echo "TIME     STATE           VMs"
		local STATE="mmtests_start"
		local tokens=0
		local NCFILE="$(mktemp)"
		nc ${_NCV:-} -n -4 -l -k "${MMTESTS_HOST_IP}" "${MMTESTS_HOST_PORT}" > "${NCFILE}" &
		NCPID=$!

		tail -f "${NCFILE}" | while [[ "${STATE}" != "QUIT" ]] && read -r TOKEN
		do
			teststate_log "recvd token :: \"${TOKEN}\" $(date +%s)"
			# With only 1 VM, there is not much to be synched. We just need
			# to reply with the very same token we receive, in order to
			# unblock each phase of run-mmtests.sh, inside the VM itself.
			if (( VMCOUNT == 1 )); then
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
						if (( tokens == VMCOUNT )); then
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
	fi

	# Wait for GNU parallel completion and capture its return value
	if [[ -n "${PARALLEL_PID}" ]]; then
		wait "${PARALLEL_PID}"
		EXIT_CODE=$?
	fi
}

function collect_results() {
	echo "Syncing ${SHELLPACK_LOG_BASE_SUBDIR} from ${VMCOUNT} VMs"

	# Archive results remotely with parallel. We use parallel's multiple input
	# arrays (::: and :::+) to match IPs with their specific runnames.
	echo "Archiving results on guests"
	parallel -j "${VMCOUNT}" ssh ${MMTESTS_SSH_OPTIONS} root@{1} "'cd git-private/${NAME} && tar -czf work-{2}.tar.gz ${SHELLPACK_LOG_BASE_SUBDIR}'" \
		::: "${GUEST_IP[@]}" :::+ "${VM_RUNNAME[@]}" || die "Failed to archive results remotely"

	# Now we can download all the archives, also in parallel.
	echo "Downloading archives"
	parallel -j "${VMCOUNT}" scp ${MMTESTS_SSH_OPTIONS} "'root@{1}:git-private/${NAME}/work-{2}.tar.gz'" . \
		::: "${GUEST_IP[@]}" :::+ "${VM_RUNNAME[@]}" || die "Failed to download archives"

	# And, eventually, we extract and rename the directory in a way that's
	# familiar for other MMTests tools.
	echo "Extracting local archives"
	local v
	for (( v=1; v<=VMCOUNT; v++ )); do
		# Do not change behavior, file names, etc, if no VM list is specified.
		# That, in fact, is how currently Marvin works, and we don't want to break it.
		local new_runname="${RUNNAME}"
		if [ "${VMS_LIST:-}" = "yes" ]; then
			new_runname="${VM_RUNNAME[${v}]}"
		fi

		# Store the results of benchmark named `FOO`, done in VM 'bar' in
		# a directory called 'bar-FOO (and cleanup the now unnecessary archive).
		local tar_file="work-${VM_RUNNAME[${v}]}.tar.gz"
		tar --transform="s|${RUNNAME}|${new_runname}|" -xf ${tar_file} || die "Failed to extract ${tar_file}"
		rm -f "${tar_file}"
	done
}

function stop_vms() {
	if [ -n "${MMTESTS_VMS_IP:-}" ]; then
		echo "Leaving the VM(s) up"
	else
		echo "Shutting down the VM(s)"
		activity_log "run-kvm: Shutoff VMs"
		kvm-stop --vm "${VMS}"
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
	if [ "${HOST_LOGS:-}" = "yes" ]; then
		export SHELLPACK_LOG="${SHELLPACK_LOG_BASE}/${RUNNAME}-host/iter-${MMTEST_HOST_ITERATION}"
		# Delete old runs
		rm -rf "${SHELLPACK_LOG}" &>/dev/null
		mkdir -p "${SHELLPACK_LOG}"
		export SHELLPACK_ACTIVITY="${SHELLPACK_LOG}/tests-activity"
		export SHELLPACK_LOGFILE="${SHELLPACK_LOG}/tests-timestamp"
		export SHELLPACK_SYSSTATEFILE="${SHELLPACK_LOG}/tests-sysstate"
		rm -f "${SHELLPACK_ACTIVITY}" "${SHELLPACK_LOGFILE}" "${SHELLPACK_SYSSTATEFILE}"
	fi

	activity_log "run-kvm: Iteration $((MMTEST_HOST_ITERATION+1)) start"

	teststate_log "start :: $(date +%s)"

	sysstate_log_basic_info
	collect_hardware_info
	collect_kernel_info
	collect_os_info
	collect_sysconfig_info

	prepare_and_start_vms
	setup_parallel
	deploy_mmtests

	echo "Executing mmtests in $VMCOUNT guest(s)"
	teststate_log "test begin :: $(date +%s)"
	activity_log "run-kvm: test start :: $(date +%s)"

	sysstate_log_proc_files "start"

	sync
	start_monitors

	activity_log "run-kvm: begin run-mmtests in VMs"
	teststate_log "test begin :: $(date +%s)"
	activity_log "run-kvm: begin ${CURRENT_TEST}"

	local parallel_cmd="ssh ${MMTESTS_SSH_OPTIONS} {} 'cd git-private/${NAME} && ./run-mmtests.sh ${RUN_ARGS[*]}'"
	if [[ -n "${MMTESTS_PARALLEL_OUTDIR:-}" ]]; then
		parallel_cmd="${parallel_cmd} > ${MMTESTS_PARALLEL_OUTDIR}/{}.log 2>&1"
	fi

	/usr/bin/time -f "time :: ${CURRENT_TEST} %U user %S system %e elapsed" -o "${SHELLPACK_LOG}/timestamp" \
		parallel --line-buffer -j "${VMCOUNT}" "${parallel_cmd}" ::: "${TARGET_HOSTS[@]}" &
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

	if [ "${HOST_LOGS:-}" = "yes" ]; then
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

	if [ "${FORCE_HOST_PERFORMANCE_SETUP:-}" = "yes" ] && [ -n "${FORCE_HOST_PERFORMANCE_SCALINGGOV_BASE:-}" ]; then
		restore_performance_setup "${FORCE_HOST_PERFORMANCE_SCALINGGOV_BASE}" "${FORCE_HOST_PERFORMANCE_NOTURBO_BASE:-}" || true
	fi

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
