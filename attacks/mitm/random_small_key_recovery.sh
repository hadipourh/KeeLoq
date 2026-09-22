#!/usr/bin/env bash

set -u
set -o pipefail

usage() {
    cat <<'EOF'
Usage: ./random_small_key_recovery.sh [options]

Random small-key recovery regression for the KeeLoq Slide+MitM implementations.

The script generates random 64-bit keys whose low 16 bits are constrained to
[0, max_k0), so bounded scans remain fast while still exercising recovery of
full 64-bit keys. Every test run uses --inject-slid-pair to make success
probability deterministic for the reduced datasets.

Options:
  --pairs-log2 N         Dataset size exponent (default: 8)
  --max-k0 N             Scan range upper bound, exclusive (default: 64)
  --baseline-trials N    Trials for the 16/16/16 profile (default: 2)
  --kp1515-trials N      Trials for the 15/15/14 profile (default: 10)
  --cp2013-trials N      Trials for the 20/13/17 geometry (default: 6)
  --cpu-only             Run only mitm_generalized reference checks
  --gpu-only             Run only GPU binaries
  --no-build             Skip make before running tests
  --help                 Show this help

Examples:
  ./random_small_key_recovery.sh
  ./random_small_key_recovery.sh --max-k0 256 --kp1515-trials 20 --cp2013-trials 10
  ./random_small_key_recovery.sh --cpu-only --baseline-trials 5 --kp1515-trials 5 --cp2013-trials 5
EOF
}

PAIRS_LOG2=8
MAX_K0=64
BASELINE_TRIALS=2
KP1515_TRIALS=10
CP2013_TRIALS=6
CPU_ONLY=0
GPU_ONLY=0
DO_BUILD=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pairs-log2)
            PAIRS_LOG2="$2"
            shift 2
            ;;
        --max-k0)
            MAX_K0="$2"
            shift 2
            ;;
        --baseline-trials)
            BASELINE_TRIALS="$2"
            shift 2
            ;;
        --kp1515-trials)
            KP1515_TRIALS="$2"
            shift 2
            ;;
        --cp2013-trials)
            CP2013_TRIALS="$2"
            shift 2
            ;;
        --cpu-only)
            CPU_ONLY=1
            shift
            ;;
        --gpu-only)
            GPU_ONLY=1
            shift
            ;;
        --no-build)
            DO_BUILD=0
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ "$CPU_ONLY" -eq 1 && "$GPU_ONLY" -eq 1 ]]; then
    echo "--cpu-only and --gpu-only cannot be used together" >&2
    exit 2
fi

if (( PAIRS_LOG2 < 8 || PAIRS_LOG2 > 16 )); then
    echo "--pairs-log2 must be in [8,16]" >&2
    exit 2
fi

if (( MAX_K0 < 1 || MAX_K0 > 65536 )); then
    echo "--max-k0 must be in [1,65536]" >&2
    exit 2
fi

for n in "$BASELINE_TRIALS" "$KP1515_TRIALS" "$CP2013_TRIALS"; do
    if (( n < 0 )); then
        echo "trial counts must be non-negative" >&2
        exit 2
    fi
done

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"

rand_key() {
    local hi low
    hi=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
    low=$(( ((((RANDOM & 255) << 8) | (RANDOM & 255))) % MAX_K0 ))
    printf '%s%04x\n' "$hi" "$low"
}

parse_field() {
    local label="$1"
    local file="$2"
    awk -F: -v key="$label" '
        $0 ~ ("^" key) {
            gsub(/[[:space:]]/, "", $2)
            print tolower($2)
        }
    ' "$file" | tail -n 1
}

parse_match() {
    local file="$1"
    awk -F: '
        /^Match/ {
            gsub(/^[[:space:]]+/, "", $2)
            gsub(/[[:space:]]+$/, "", $2)
            print $2
        }
    ' "$file" | tail -n 1
}

parse_time() {
    local file="$1"
    awk -F: '
        /^Wall time/ {
            gsub(/^[[:space:]]+/, "", $2)
            print $2
        }
    ' "$file" | tail -n 1
}

run_checked() {
    local label="$1"
    local expected_key="$2"
    local cmd="$3"
    local tmp rc recovered true_key match wall

    tmp=$(mktemp)
    rc=0
    if eval "$cmd" >"$tmp" 2>&1; then
        rc=0
    else
        rc=$?
    fi

    recovered=$(parse_field "Recovered key" "$tmp")
    true_key=$(parse_field "True key" "$tmp")
    match=$(parse_match "$tmp")
    wall=$(parse_time "$tmp")

    if [[ "$rc" -ne 0 || -z "$recovered" || -z "$true_key" || "$recovered" != "$expected_key" || "$true_key" != "$expected_key" || "$match" != "YES" ]]; then
        echo "[FAIL] $label key=$expected_key" >&2
        echo "Command: $cmd" >&2
        cat "$tmp" >&2
        rm -f "$tmp"
        return 1
    fi

    if [[ -n "$wall" ]]; then
        echo "[PASS] $label key=$expected_key wall=$wall"
    else
        echo "[PASS] $label key=$expected_key"
    fi
    rm -f "$tmp"
    return 0
}

build_targets() {
    local make_args=()
    if [[ -n "${CUDA_ARCH:-}" ]]; then
        make_args+=("CUDA_ARCH=${CUDA_ARCH}")
    fi

    if [[ "$DO_BUILD" -eq 0 ]]; then
        return 0
    fi

    echo "[build] make -B generalized ${make_args[*]}"
    make -B generalized "${make_args[@]}" || return 1

    if [[ "$CPU_ONLY" -eq 0 ]]; then
        if (( BASELINE_TRIALS > 0 )); then
            echo "[build] make -B gpu-baseline ${make_args[*]}"
            make -B gpu-baseline "${make_args[@]}" || return 1
        fi
        if (( KP1515_TRIALS > 0 )); then
            echo "[build] make -B gpu-kp1515 ${make_args[*]} KP1515_OV_BATCH=1"
            make -B gpu-kp1515 "${make_args[@]}" KP1515_OV_BATCH=1 || return 1
        fi
        if (( CP2013_TRIALS > 0 )); then
            echo "[build] make -B gpu-cp2013 ${make_args[*]}"
            make -B gpu-cp2013 "${make_args[@]}" || return 1
        fi
    fi
}

run_profile_trials() {
    local profile_name="$1"
    local trials="$2"
    local cpu_cmd_prefix="$3"
    local gpu_cmd_prefix="$4"
    local i key

    if (( trials == 0 )); then
        return 0
    fi

    echo
    echo "== $profile_name : $trials trial(s) =="
    for ((i = 1; i <= trials; i++)); do
        key=$(rand_key)
        echo "[trial $i/$trials] key=$key"

        if [[ "$GPU_ONLY" -eq 0 ]]; then
            run_checked "$profile_name / cpu-ref" "$key" "$cpu_cmd_prefix --key $key --pairs-log2 $PAIRS_LOG2 --inject-slid-pair --max-k0 $MAX_K0" || return 1
        fi

        if [[ "$CPU_ONLY" -eq 0 ]]; then
            run_checked "$profile_name / gpu" "$key" "$gpu_cmd_prefix $key --pairs-log2 $PAIRS_LOG2 --inject-slid-pair --max-k0 $MAX_K0" || return 1
        fi
    done
}

build_targets || exit 1

START_TS=$(date +%s)

echo "Random small-key recovery regression"
echo "pairs-log2=$PAIRS_LOG2 max-k0=$MAX_K0 cpu_only=$CPU_ONLY gpu_only=$GPU_ONLY"

total_trials=$((BASELINE_TRIALS + KP1515_TRIALS + CP2013_TRIALS))
if (( total_trials == 0 )); then
    echo "No trials selected."
    exit 0
fi

run_profile_trials "baseline 16/16/16" "$BASELINE_TRIALS" \
    "./mitm_generalized --tp 16 --tc 16" \
    "./mitm_gpu_baseline" || exit 1

run_profile_trials "kp1515 15/15/14" "$KP1515_TRIALS" \
    "./mitm_generalized --tp 15 --tc 15" \
    "./mitm_gpu_kp1515" || exit 1

run_profile_trials "cp2013 geometry 20/13/17" "$CP2013_TRIALS" \
    "./mitm_generalized --tp 20 --tc 13" \
    "./mitm_gpu_cp2013" || exit 1

END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))

echo
echo "All selected random small-key recovery tests passed in ${ELAPSED}s."
if [[ "$GPU_ONLY" -eq 0 && "$CPU_ONLY" -eq 0 ]]; then
    echo "CPU reference and GPU outputs matched the expected full 64-bit keys for every selected trial."
fi
