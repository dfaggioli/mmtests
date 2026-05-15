#!/bin/bash

# Usciamo subito se qualcosa va in crash critico a livello di script
set -euo pipefail

SCHEDULER="EEVDF"
LOGFILE="/root/${SCHEDULER}.log"

# Array di configurazione
SCENARIOS=("S1" "S2" "S3" "S4")
BENCHMARKS=(
    "scheduler-schbench-default"
    "scheduler-hackbench"
    "workload-cyclictest-histogram-none"
    "workload-kernbench"
)

# Funzione per formattare i secondi in HH:MM:SS
format_time() {
    local T=$1
    local H=$((T / 3600))
    local M=$(((T / 60) % 60))
    local S=$((T % 60))
    printf "%02d:%02d:%02d" $H $M $S
}

# Assicuriamoci di essere nel posto giusto prima di cominciare
cd /root/mmtests || { echo "ERRORE: Directory /root/mmtests non trovata!"; exit 1; }

# Timestamp globale di inizio
START_TOTAL=$(date +%s)

# Inizializza il file di log
echo "===================================================" | tee -a "${LOGFILE}"
echo "Inizio batch di test MMTests: $(date)" | tee -a "${LOGFILE}"
echo "Scheduler: ${SCHEDULER}" | tee -a "${LOGFILE}"
echo "===================================================" | tee -a "${LOGFILE}"

for SCENARIO in "${SCENARIOS[@]}"; do
    for BENCHMARK in "${BENCHMARKS[@]}"; do
        
        RUNNAME="${SCHEDULER}-${SCENARIO}-${BENCHMARK}"

        echo "" | tee -a "${LOGFILE}"
        echo "=== INIZIO ${RUNNAME} ===" | tee -a "${LOGFILE}"
        
        # Timestamp locale per il singolo benchmark
        START_BENCH=$(date +%s)
        
        # Esecuzione tollerante agli errori
        set +e
        ./run-kvm.sh -L -P -C "config-${SCENARIO}" -n -c "configs/config-${BENCHMARK}" "${RUNNAME}"
        EXIT_CODE=$?
        set -e

        # Timestamp locale di fine e calcolo durata
        END_BENCH=$(date +%s)
        ELAPSED_BENCH=$((END_BENCH - START_BENCH))

        if [ $EXIT_CODE -ne 0 ]; then
            echo "!!! ATTENZIONE: Il benchmark ${RUNNAME} è fallito con codice ${EXIT_CODE}" | tee -a "${LOGFILE}"
        fi

        echo "=== FINE ${RUNNAME} (Durata: $(format_time $ELAPSED_BENCH)) ===" | tee -a "${LOGFILE}"
    done
done

# Timestamp globale di fine e calcolo durata totale
END_TOTAL=$(date +%s)
ELAPSED_TOTAL=$((END_TOTAL - START_TOTAL))

echo "" | tee -a "${LOGFILE}"
echo "===================================================" | tee -a "${LOGFILE}"
echo "Tutti i test completati: $(date)" | tee -a "${LOGFILE}"
echo "Tempo totale di esecuzione: $(format_time $ELAPSED_TOTAL)" | tee -a "${LOGFILE}"
echo "===================================================" | tee -a "${LOGFILE}"
