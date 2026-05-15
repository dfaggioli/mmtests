#!/bin/bash

# Usciamo subito se qualcosa va in crash critico a livello di script
set -euo pipefail

# =========================================================
# CONFIGURAZIONE MATRICE DI TEST
# =========================================================
# Se messo a "yes", salta i benchmark che hanno già una cartella in work/log/
RESUME_MODE="yes"

# Ho sostituito LAYERED e SIMPLE con LAVD e BPFLAND
SCHEDULERS=("EEVDF" "RUSTY" "LAVD" "BPFLAND" "RUSTLAND")
SCENARIOS=("S1" "S2" "S3" "S4")
BENCHMARKS=(
    "scheduler-schbench-default"
    "scheduler-hackbench"
    "workload-cyclictest-histogram-none"
    "workload-kernbench"
)

# Assicuriamoci di essere nel posto giusto prima di cominciare
cd /root/mmtests || { echo "ERRORE: Directory /root/mmtests non trovata!"; exit 1; }

# =========================================================
# FUNZIONI DI SUPPORTO
# =========================================================
format_time() {
    local T=$1
    local H=$((T / 3600))
    local M=$(((T / 60) % 60))
    local S=$((T % 60))
    printf "%02d:%02d:%02d" $H $M $S
}

kill_scx() {
    # Elimina brutalmente qualsiasi scheduler ext-bpf in esecuzione
    pkill -f "^scx_" >/dev/null 2>&1 || true
    sleep 3 # Diamo tempo al kernel di sganciare il programma BPF e tornare a EEVDF
}

set_scheduler() {
    local sched=$1
    local log_out="/tmp/${sched}_daemon.log"
    
    kill_scx
    
    case "$sched" in
        "EEVDF")
            # Nessun demone scx da lanciare, il kernel è già tornato al default
            ;;
        "BPFLAND")
            nohup scx_bpfland > "$log_out" 2>&1 &
            sleep 3
            ;;
        "LAVD")
            nohup scx_lavd > "$log_out" 2>&1 &
            sleep 3
            ;;
        "RUSTY")
            nohup scx_rusty > "$log_out" 2>&1 &
            sleep 3
            ;;
        "RUSTLAND")
            nohup scx_rustland > "$log_out" 2>&1 &
            sleep 3
            ;;
        *)
            echo "ERRORE FATALE: Scheduler $sched non riconosciuto!"
            exit 1
            ;;
    esac
    
    # Check di sicurezza per vedere se il demone SCX è andato in crash all'avvio
    if [[ "$sched" != "EEVDF" ]]; then
        if ! pgrep -f "^scx_" >/dev/null; then
            echo "ERRORE FATALE: Impossibile avviare lo scheduler $sched. Controlla $log_out"
            exit 1
        fi
    fi
}


# =========================================================
# ESECUZIONE BATCH
# =========================================================
START_TOTAL=$(date +%s)
echo "==================================================="
echo "INIZIO BATCH TOTALE SCX/MMTESTS: $(date)"
echo "==================================================="

for SCHED in "${SCHEDULERS[@]}"; do
    LOGFILE="/root/${SCHED}.log"
    
    echo "===================================================" | tee -a "${LOGFILE}"
    echo "Inizio batteria per Scheduler: ${SCHED}" | tee -a "${LOGFILE}"
    echo "Data: $(date)" | tee -a "${LOGFILE}"
    echo "===================================================" | tee -a "${LOGFILE}"

    # Applica lo scheduler a livello di host
    echo "=> Configurazione host per lo scheduler ${SCHED}..." | tee -a "${LOGFILE}"
    set_scheduler "${SCHED}"
    START_SCHED=$(date +%s)

    for SCENARIO in "${SCENARIOS[@]}"; do
        for BENCHMARK in "${BENCHMARKS[@]}"; do
            
            RUNNAME="${SCHED}-${SCENARIO}-${BENCHMARK}"
            
            # --- LOGICA DI RESUME ---
            if [[ "${RESUME_MODE}" == "yes" && -d "work/log/${RUNNAME}" ]]; then
                echo "" | tee -a "${LOGFILE}"
                echo "+++ SKIP: La cartella work/log/${RUNNAME} esiste già." | tee -a "${LOGFILE}"
                echo "+++ Passaggio al prossimo test per risparmiare tempo." | tee -a "${LOGFILE}"
                continue
            fi

            echo "" | tee -a "${LOGFILE}"
            echo "=== INIZIO ${RUNNAME} ===" | tee -a "${LOGFILE}"
            
            START_BENCH=$(date +%s)
            
            # Esecuzione tollerante agli errori per il singolo benchmark
            set +e
            ./run-kvm.sh -L -P -C "config-${SCENARIO}" -n -c "configs/config-${BENCHMARK}" "${RUNNAME}"
            EXIT_CODE=$?
            set -e

            END_BENCH=$(date +%s)
            ELAPSED_BENCH=$((END_BENCH - START_BENCH))

            if [ $EXIT_CODE -ne 0 ]; then
                echo "!!! ATTENZIONE: Il benchmark ${RUNNAME} è fallito con codice ${EXIT_CODE}" | tee -a "${LOGFILE}"
            fi

            echo "=== FINE ${RUNNAME} (Durata: $(format_time $ELAPSED_BENCH)) ===" | tee -a "${LOGFILE}"
        done
    done
    
    END_SCHED=$(date +%s)
    ELAPSED_SCHED=$((END_SCHED - START_SCHED))
    echo "===================================================" | tee -a "${LOGFILE}"
    echo "Batteria per ${SCHED} completata. (Durata: $(format_time $ELAPSED_SCHED))" | tee -a "${LOGFILE}"
    echo "===================================================" | tee -a "${LOGFILE}"
done

# Pulizia finale (riporta il sistema a EEVDF al termine di tutto)
kill_scx

END_TOTAL=$(date +%s)
ELAPSED_TOTAL=$((END_TOTAL - START_TOTAL))

echo ""
echo "==================================================="
echo "TUTTI I TEST COMPLETATI CON SUCCESSO: $(date)"
echo "Tempo totale di esecuzione dell'intera matrice: $(format_time $ELAPSED_TOTAL)"
echo "==================================================="
