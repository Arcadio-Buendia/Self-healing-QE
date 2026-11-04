#!/bin/bash
set -eu
SCRIPT_HOME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$PWD/autonomous_dft.log"
nohup bash "$SCRIPT_HOME/run_scf_soc_autonomous.sh" "$@" >> "$LOG_FILE" 2>&1 < /dev/null &
echo "Runner started (PID $!). Log: $LOG_FILE"
