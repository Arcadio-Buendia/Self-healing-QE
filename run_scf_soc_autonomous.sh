#!/bin/bash
# ==============================================================================
# Script: run_scf_soc_autonomous.sh
# Purpose: Fully autonomous SCF + SOC master runner executing natively on host.
#          Does NOT depend on any local machine connection.
#          Features dynamic 32/64 core allocation, scratch cleanup, charge density
#          preservation, and external TypeSafe self-healing with persistent history.
# ==============================================================================

set -u

SCRIPT_HOME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(pwd)"
if [ "${1:-}" = "--help" ]; then
    echo "Usage: run_scf_soc_autonomous.sh [input.in ...] (default: all *.in in current folder)"
    exit 0
fi

export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
if [ -n "${QE_ENV_FILE:-}" ]; then source "$QE_ENV_FILE" || exit 1; fi
for tool in python3 curl "${PW_BIN:-pw.x}"; do
    command -v "$tool" >/dev/null || { echo "Missing dependency: $tool" >&2; exit 1; }
done
if [ "${EXEC_CORES:-1}" -gt 1 ]; then
    command -v "${MPI_BIN:-mpirun}" >/dev/null || exit 1
fi

PID_FILE="$SCRIPT_DIR/host_typesafe.pid"
LOG_FILE="$SCRIPT_DIR/host_typesafe.log"
RULES_FILE="${RULES_FILE:-$SCRIPT_HOME/soc_remediation_rules.json}"
HELP_FILE="$SCRIPT_DIR/soc_dft_help.md"
TYPESAFE_LOG="$SCRIPT_DIR/typesafe_api.log"
DECISION_FILE="$SCRIPT_DIR/decision.tmp"
HISTORY_FILE="$SCRIPT_DIR/soc_typesafe_history.json"
# QE owns outdir/prefix from each input. Never delete shared scratch.
EXEC_CORES="${EXEC_CORES:-1}"
POOLS="${POOLS:-1}"
[[ "$EXEC_CORES" =~ ^[1-9][0-9]*$ && "$POOLS" =~ ^[1-9][0-9]*$ ]] || exit 1
(( EXEC_CORES % POOLS == 0 )) || { echo "POOLS must divide EXEC_CORES" >&2; exit 1; }

LOAD_THRESHOLD=100
MAX_HEAL_ATTEMPTS="${MAX_HEAL_ATTEMPTS:-15}"
[[ "$MAX_HEAL_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || exit 1

# Atomic directory lock prevents overlapping runs in one working folder.
LOCK_DIR="$SCRIPT_DIR/.self_healing_dft.lock"
mkdir "$LOCK_DIR" 2>/dev/null || { echo "Runner lock exists: $LOCK_DIR" >&2; exit 1; }
trap 'rm -f "$PID_FILE" "$DECISION_FILE"; rmdir "$LOCK_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo $$ > "$PID_FILE"

# Load TYPESAFE_API_KEY from .env
if [ -z "${TYPESAFE_API_KEY:-}" ] && [ -f "$SCRIPT_DIR/.env" ]; then
    TYPESAFE_API_KEY=$(grep -E '^TYPESAFE_API_KEY=' "$SCRIPT_DIR/.env" | cut -d '=' -f2- | tr -d '"' | tr -d "'")
fi

if [ -z "${TYPESAFE_API_KEY:-}" ]; then
    echo "[$(date)] ERROR: TYPESAFE_API_KEY is not set in environment or $SCRIPT_DIR/.env." >&2
    exit 1
fi

if [ ! -f "$RULES_FILE" ]; then
    echo "[$(date)] ERROR: Rules file not found: $RULES_FILE" >&2
    exit 1
fi

# Initialize history file if absent
if [ ! -f "$HISTORY_FILE" ]; then
    echo "{}" > "$HISTORY_FILE"
fi

touch "$HELP_FILE"

STRUCTURES=()
if [ "$#" -eq 0 ]; then
    shopt -s nullglob
    set -- *.in
fi
for input in "$@"; do
    if [[ "$input" == */* || "$input" != *.in || ! -f "$input" ]]; then
        echo "Input must be a local *.in file: $input" >&2; exit 1
    fi
    STRUCTURES+=("${input%.in}")
done
[ "${#STRUCTURES[@]}" -gt 0 ] || { echo "No *.in input files found in $SCRIPT_DIR" >&2; exit 1; }
OVERALL_STATUS=0

# Run calculation locally on host with dynamic core scaling
run_calculation() {
    local struct="$1"
    local pools="$2"

    echo "[$(date)] Launching $struct (cores: $EXEC_CORES, pools: $pools)"
    if [ "$EXEC_CORES" -eq 1 ]; then
        "${PW_BIN:-pw.x}" -nk "$pools" -in "${struct}.in" > "${struct}.out" 2>&1
    else
        "${MPI_BIN:-mpirun}" -np "$EXEC_CORES" "${PW_BIN:-pw.x}" -nk "$pools" -in "${struct}.in" > "${struct}.out" 2>&1
    fi
    local exit_code=$?

    # Check for clean convergence
    if [ $exit_code -eq 0 ] && grep -q "JOB DONE" "${struct}.out" && ! grep -q "convergence NOT achieved" "${struct}.out"; then
        echo "[$(date)] $struct SUCCESS: SCF + SOC calculation converged cleanly."

        # Retain the complete QE save directory, including charge density,
        # at the outdir/prefix configured in the supplied input.
        return 0
    else
        echo "[$(date)] $struct FAILED: Exit code $exit_code or convergence not achieved."
        return 1
    fi
}

# TypeSafe self-healing logic
heal_with_typesafe() {
    local struct="$1"
    local attempt_num="$2"
    local in_path="$3"
    local err_path="$4"
    local help_path="$5"
    local dec_path="$6"
    local rules_path="$7"
    local hist_path="$8"

    echo "[$(date)] Querying TypeSafe API for $struct (Attempt $attempt_num)..."

    payload=$(python3 -c '
import sys, json, os

struct = sys.argv[1]
err_file = sys.argv[2]
in_file = sys.argv[3]
rules_file = sys.argv[4]
hist_file = sys.argv[5]

with open(rules_file) as f:
    rules = json.load(f)

history_data = {}
if os.path.exists(hist_file):
    try:
        with open(hist_file) as f:
            history_data = json.load(f)
    except Exception:
        history_data = {}

struct_history = history_data.get(struct, [])

err_text = open(err_file).read() if os.path.exists(err_file) else ""
in_text = open(in_file).read() if os.path.exists(in_file) else ""

state = {
    "structure": struct,
    "current_input": in_text,
    "problem_catalog": rules.get("problem_catalog", []),
    "error_log_tail": err_text,
    "previous_remediation_history": struct_history
}

body = {
    "model": "jev-latest",
    "state": state,
    "questions": rules.get("questions", {})
}
print(json.dumps(body))
' "$struct" "$err_path" "$in_path" "$rules_path" "$hist_path")

    response=$(curl --connect-timeout 15 --max-time 120 -sS -w "\n%{http_code}" -X POST "https://api.typesafe.ai/v1/systemone" \
        -H "Authorization: Bearer ${TYPESAFE_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$payload")

    http_code=$(echo "$response" | tail -n1)
    json_response=$(echo "$response" | sed '$d')

    echo "[$(date)] [$struct Attempt $attempt_num] TypeSafe HTTP $http_code" >> "$TYPESAFE_LOG"
    echo "$json_response" >> "$TYPESAFE_LOG"

    if [ "$http_code" -ne 200 ]; then
        echo "[$(date)] TypeSafe API error (HTTP $http_code)."
        echo "FAIL" > "$dec_path"
        return 1
    fi

    python3 -c '
import sys, json, re, os
from datetime import datetime

resp_str = sys.argv[1]
in_path = sys.argv[2]
help_file = sys.argv[3]
decision_file = sys.argv[4]
struct = sys.argv[5]
rules_file = sys.argv[6]
hist_file = sys.argv[7]
attempt_num = int(sys.argv[8])
err_path = sys.argv[9]

try:
    with open(rules_file) as f:
        rules = json.load(f)
    actions = rules.get("actions", {})
except Exception as e:
    print(f"Error loading rules file: {e}")
    open(decision_file, "w").write("FAIL\n")
    sys.exit(0)

history_data = {}
if os.path.exists(hist_file):
    try:
        with open(hist_file) as f:
            history_data = json.load(f)
    except Exception:
        history_data = {}

err_snippet = open(err_path).read() if os.path.exists(err_path) else ""
err_lines = [l.strip() for l in err_snippet.splitlines() if l.strip()]
last_error_summary = "; ".join(err_lines[-3:]) if err_lines else "Unknown error"

try:
    data = json.loads(resp_str)
    answers = data.get("answers", {})
    is_rec = answers.get("is_recoverable", {}).get("noul", 0.0)
    strategy = answers.get("strategy", {}).get("choice", "abort")
except Exception as e:
    print(f"Error parsing TypeSafe response: {e}")
    open(decision_file, "w").write("FAIL\n")
    sys.exit(0)

new_record = {
    "attempt": attempt_num,
    "timestamp": datetime.now().isoformat(),
    "problem_encountered": last_error_summary,
    "is_recoverable": round(is_rec, 3),
    "strategy_selected": strategy,
    "action_applied": None,
    "status": "FAIL" if (is_rec < 0.4 or strategy == "abort" or strategy not in actions) else "RETRY"
}

if is_rec < 0.4 or strategy == "abort" or strategy not in actions:
    with open(help_file, "a") as f:
        f.write(f"\n[{struct}] Marked FAIL by TypeSafe (Attempt {attempt_num}): is_recoverable={is_rec:.2f}, strategy={strategy}\n")
    new_record["action_applied"] = "None (Aborted)"
    history_data.setdefault(struct, []).append(new_record)
    with open(hist_file, "w") as f:
        json.dump(history_data, f, indent=2)
    open(decision_file, "w").write("FAIL\n")
    sys.exit(0)

action = actions[strategy]
namelist = action.get("namelist", "ELECTRONS")
param = action.get("param")
act_type = action.get("type")

content = open(in_path).read()
block = re.search(rf"(&{re.escape(namelist)}\b)(.*?)(^\s*/)", content, re.IGNORECASE | re.DOTALL | re.MULTILINE)
if not block:
    raise ValueError(f"Missing namelist: {namelist}")
pattern = rf"(?<![\w!])\b{re.escape(param)}\s*=\s*(?:\x27[^\x27]*\x27|\x22[^\x22]*\x22|[^\s,!/]+)"
# Ignore assignments in full-line and trailing comments.
body = block.group(2)
m = None
for line in body.splitlines():
    match = re.search(pattern, line.split("!", 1)[0], re.IGNORECASE)
    if match:
        m = re.search(r"=\s*(.*)", match.group(0))
        break
note = ""

if act_type == "string":
    new_val = action["value"]
    note = f"{param} set to {new_val}"
elif act_type == "float_multiply":
    curr = float(m.group(1).strip("\x27\x22").replace("D", "e").replace("d", "e")) if m else action.get("default", 0.3)
    val = curr * action["factor"]
    if "min_val" in action:
        val = max(val, action["min_val"])
    if "max_val" in action:
        val = min(val, action["max_val"])
    new_val = str(round(val, 4))
    note = f"{param}: {curr} -> {new_val}"
elif act_type == "int_add":
    curr = int(m.group(1).strip("\x27\x22")) if m else action.get("default", 100)
    new_val = str(curr + action["value"])
    note = f"{param}: {curr} -> {new_val}"
else:
    print(f"Unknown action type: {act_type}")
    open(decision_file, "w").write("FAIL\n")
    sys.exit(0)

if m:
    lines = []
    for line in body.splitlines(keepends=True):
        code, sep, comment = line.partition("!")
        code = re.sub(pattern, lambda _: f"{param} = {new_val}", code, flags=re.IGNORECASE)
        lines.append(code + sep + comment)
    body = "".join(lines)
else:
    body += f"    {param} = {new_val}\n"
content = content[:block.start(2)] + body + content[block.end(2):]

open(in_path, "w").write(content)

new_record["action_applied"] = note
history_data.setdefault(struct, []).append(new_record)
with open(hist_file, "w") as f:
    json.dump(history_data, f, indent=2)

with open(help_file, "a") as f:
    f.write(f"\n[{struct}] TypeSafe Attempt {attempt_num} ({strategy}): {note}\n  Problem: {last_error_summary}\n")

open(decision_file, "w").write("RETRY\n")
' "$json_response" "$in_path" "$help_path" "$dec_path" "$struct" "$rules_path" "$hist_path" "$attempt_num" "$err_path"
}

# TypeSafe pre-flight inspection: proactively inspects and optimizes input using cumulative history before Attempt 1
preflight_heal_with_typesafe() {
    local struct="$1"
    local in_path="$2"
    local help_path="$3"
    local rules_path="$4"
    local hist_path="$5"

    echo "[$(date)] Running TypeSafe pre-flight inspection for $struct using prior history..."

    local max_preflight_steps=4
    local step=1

    while [ $step -le $max_preflight_steps ]; do
        payload=$(python3 -c '
import sys, json, os

struct = sys.argv[1]
in_file = sys.argv[2]
rules_file = sys.argv[3]
hist_file = sys.argv[4]

with open(rules_file) as f:
    rules = json.load(f)

history_data = {}
if os.path.exists(hist_file):
    try:
        with open(hist_file) as f:
            history_data = json.load(f)
    except Exception:
        history_data = {}

in_text = open(in_file).read() if os.path.exists(in_file) else ""

state = {
    "structure": struct,
    "current_input": in_text,
    "problem_catalog": rules.get("problem_catalog", []),
    "context": "Proactive pre-flight inspection before Attempt 1",
    "previous_remediation_history": history_data.get(struct, [])
}

body = {
    "model": "jev-latest",
    "state": state,
    "questions": rules.get("preflight_questions", {})
}
print(json.dumps(body))
' "$struct" "$in_path" "$rules_path" "$hist_path")

        response=$(curl --connect-timeout 15 --max-time 120 -sS -w "\n%{http_code}" -X POST "https://api.typesafe.ai/v1/systemone" \
            -H "Authorization: Bearer ${TYPESAFE_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "$payload")

        http_code=$(echo "$response" | tail -n1)
        json_response=$(echo "$response" | sed '$d')

        echo "[$(date)] [$struct Pre-flight Step $step] TypeSafe HTTP $http_code" >> "$TYPESAFE_LOG"

        if [ "$http_code" -ne 200 ]; then
            echo "[$(date)] Pre-flight TypeSafe query returned HTTP $http_code. Proceeding to launch."
            break
        fi

        action_result=$(python3 -c '
import sys, json, re, os
from datetime import datetime

resp_str = sys.argv[1]
in_path = sys.argv[2]
help_file = sys.argv[3]
struct = sys.argv[4]
rules_file = sys.argv[5]
hist_file = sys.argv[6]

try:
    with open(rules_file) as f:
        rules = json.load(f)
    actions = rules.get("actions", {})
except Exception as e:
    print(f"ERROR: {e}")
    sys.exit(0)

try:
    data = json.loads(resp_str)
    answers = data.get("answers", {})
    needs_rec = answers.get("needs_remediation", {}).get("noul", 0.0)
    strategy = answers.get("strategy", {}).get("choice", "none")
except Exception as e:
    print(f"PARSE_ERROR: {e}")
    sys.exit(0)

if needs_rec < 0.4 or strategy == "none" or strategy not in actions:
    print("DONE")
    sys.exit(0)

action = actions[strategy]
namelist = action.get("namelist", "ELECTRONS")
param = action.get("param")
act_type = action.get("type")

content = open(in_path).read()
block = re.search(rf"(&{re.escape(namelist)}\b)(.*?)(^\s*/)", content, re.IGNORECASE | re.DOTALL | re.MULTILINE)
if not block:
    raise ValueError(f"Missing namelist: {namelist}")
pattern = rf"(?<![\w!])\b{re.escape(param)}\s*=\s*(?:\x27[^\x27]*\x27|\x22[^\x22]*\x22|[^\s,!/]+)"
# Ignore assignments in full-line and trailing comments.
body = block.group(2)
m = None
for line in body.splitlines():
    match = re.search(pattern, line.split("!", 1)[0], re.IGNORECASE)
    if match:
        m = re.search(r"=\s*(.*)", match.group(0))
        break
note = ""

if act_type == "string":
    new_val = action["value"]
    note = f"{param} set to {new_val}"
elif act_type == "float_multiply":
    curr = float(m.group(1).strip("\x27\x22").replace("D", "e").replace("d", "e")) if m else action.get("default", 0.3)
    val = curr * action["factor"]
    if "min_val" in action:
        val = max(val, action["min_val"])
    if "max_val" in action:
        val = min(val, action["max_val"])
    new_val = str(round(val, 4))
    note = f"{param}: {curr} -> {new_val}"
elif act_type == "int_add":
    curr = int(m.group(1).strip("\x27\x22")) if m else action.get("default", 100)
    new_val = str(curr + action["value"])
    note = f"{param}: {curr} -> {new_val}"

if m:
    lines = []
    for line in body.splitlines(keepends=True):
        code, sep, comment = line.partition("!")
        code = re.sub(pattern, lambda _: f"{param} = {new_val}", code, flags=re.IGNORECASE)
        lines.append(code + sep + comment)
    body = "".join(lines)
else:
    body += f"    {param} = {new_val}\n"
content = content[:block.start(2)] + body + content[block.end(2):]

open(in_path, "w").write(content)

if os.path.exists(hist_file):
    try:
        with open(hist_file) as f:
            hdata = json.load(f)
    except Exception:
        hdata = {}
    hdata.setdefault(struct, []).append({
        "attempt": 0,
        "type": "PRE-FLIGHT",
        "timestamp": datetime.now().isoformat(),
        "strategy_selected": strategy,
        "action_applied": note
    })
    with open(hist_file, "w") as f:
        json.dump(hdata, f, indent=2)

with open(help_file, "a") as f:
    f.write(f"\n[{struct}] [PRE-FLIGHT] Proactively applied ({strategy}): {note}\n")

print(f"APPLIED:{strategy}")
' "$json_response" "$in_path" "$help_path" "$struct" "$rules_path" "$hist_path")

        echo "[$(date)] Pre-flight action for $struct: $action_result"
        if [ "$action_result" == "DONE" ] || [[ "$action_result" != APPLIED* ]]; then
            break
        fi
        step=$((step + 1))
    done
}

echo "================================================================="
echo "[$(date)] Starting autonomous SCF + SOC master runner on host (PID: $$)"
echo "================================================================="

for struct in "${STRUCTURES[@]}"; do
    echo ""
    echo "================================================================="
    echo "[$(date)] Processing structure: $struct"
    echo "================================================================="

    # Skip if already converged cleanly
    if [ -f "${struct}.out" ] && grep -q "JOB DONE" "${struct}.out" && ! grep -q "convergence NOT achieved" "${struct}.out"; then
        echo "[$(date)] $struct is already successfully converged. Skipping."
        continue
    fi

    # Optional: proactive edits can change accuracy requirements.
    if [ "${PREFLIGHT:-0}" = 1 ]; then
        preflight_heal_with_typesafe "$struct" "${struct}.in" "$HELP_FILE" "$RULES_FILE" "$HISTORY_FILE"
    fi

    attempt=1
    success=false

    while [ $attempt -le $MAX_HEAL_ATTEMPTS ]; do
        echo "[$(date)] Running $struct (Attempt $attempt of $MAX_HEAL_ATTEMPTS)..."

        if run_calculation "$struct" "$POOLS"; then
            echo "[$(date)] $struct completed successfully on attempt $attempt."
            success=true

            python3 -c '
import sys, json, os
from datetime import datetime
hist_file, struct, attempt = sys.argv[1], sys.argv[2], int(sys.argv[3])
if os.path.exists(hist_file):
    with open(hist_file) as f:
        data = json.load(f)
    data.setdefault(struct, []).append({
        "attempt": attempt,
        "timestamp": datetime.now().isoformat(),
        "status": "SUCCESS",
        "action_applied": "Calculation converged cleanly."
    })
    with open(hist_file, "w") as f:
        json.dump(data, f, indent=2)
' "$HISTORY_FILE" "$struct" "$attempt"
            break
        else
            echo "[$(date)] $struct encountered failure on attempt $attempt."

            if [ $attempt -ge $MAX_HEAL_ATTEMPTS ]; then
                echo "[$(date)] Max healing attempts ($MAX_HEAL_ATTEMPTS) reached for $struct. Proceeding to next."
                break
            fi

            echo "[$(date)] Triggering TypeSafe self-healing loop for $struct..."
            > "$DECISION_FILE"

            ERR_SNIPPET="$SCRIPT_DIR/snippet_${struct}.err"
            tail -n 150 "${struct}.out" > "$ERR_SNIPPET" 2>/dev/null || true

            heal_with_typesafe "$struct" "$attempt" "${struct}.in" "$ERR_SNIPPET" "$HELP_FILE" "$DECISION_FILE" "$RULES_FILE" "$HISTORY_FILE"

            sleep 2
            rm -f "$ERR_SNIPPET"

            if [ -f "$DECISION_FILE" ]; then
                decision=$(tr -d '[:space:]' < "$DECISION_FILE")
                if [ "$decision" == "RETRY" ]; then
                    echo "[$(date)] TypeSafe updated parameters for $struct. Retrying calculation..."
                    attempt=$((attempt + 1))
                else
                    echo "[$(date)] TypeSafe marked $struct as '$decision'. Skipping further attempts."
                    break
                fi
            else
                echo "[$(date)] Decision file not found. Retrying..."
                attempt=$((attempt + 1))
            fi
        fi
    done

    if [ "$success" = false ]; then
        OVERALL_STATUS=1
        echo "[$(date)] WARNING: $struct did NOT complete successfully."
    fi
done

echo ""
echo "================================================================="
echo "[$(date)] All structures processed for SCF + SOC."
echo "================================================================="

rm -f "$PID_FILE"
rm -f "$DECISION_FILE"

exit "$OVERALL_STATUS"
