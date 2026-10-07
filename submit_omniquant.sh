#!/usr/bin/env bash
# Submits OmniQuant-seq to SGE as three chained jobs:
#
#   references  ->  one array task per sample  ->  merge + matrices
#
# Usage: ./submit_omniquant.sh [-c CONFIG] [-w WORKDIR] [-m SRR,...] [-s] [-n] [-b]
#   -c  configuration file          (default: ./config.sh)
#   -w  working directory           (default: WORKDIR from the configuration)
#   -m  manual: only these accessions of the sample table (comma-separated,
#       repeatable), e.g. to retry a failed sample or analyse one on its own
#   -s  serial: a single job that runs every stage, no array
#   -n  dry run: print the qsub commands instead of submitting them
#   -b  build a missing sample table here instead of refusing to

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOB="${HERE}/omniquant_sge.sh"

die() { echo "[ABORT] $*" >&2; exit 1; }

usage() { sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; }

CONFIG="${PWD}/config.sh"
WORKDIR_ARG=""
SERIAL=false
DRY=false
BUILD_HERE=false
MANUAL=""

while getopts ":c:w:m:snbh" opt; do
    case "$opt" in
        c) CONFIG="$OPTARG" ;;
        w) WORKDIR_ARG="$OPTARG" ;;
        m) MANUAL+="${MANUAL:+,}${OPTARG}" ;;
        s) SERIAL=true ;;
        n) DRY=true ;;
        b) BUILD_HERE=true ;;
        h) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done

[[ "$CONFIG" == /* ]] || CONFIG="${PWD}/${CONFIG}"
[[ -f "$CONFIG" ]] || die "Configuration not found: ${CONFIG} (copy config.example.sh to config.sh)"
# shellcheck disable=SC1090
source "$CONFIG"

[[ -n "$WORKDIR_ARG" ]] && WORKDIR="$WORKDIR_ARG"
: "${WORKDIR:=$PWD}"
: "${JOB_NAME:=OmniQuant}"

[[ -f "$JOB" ]] || die "Job script not found: ${JOB}"
[[ -n "${PIPELINE_DIR:-}" ]] || die "PIPELINE_DIR is not set in ${CONFIG}"
[[ -f "${PIPELINE_DIR}/run.sh" ]] || die "PIPELINE_DIR is not an OmniQuant-seq checkout: ${PIPELINE_DIR}"
[[ -d "$WORKDIR" ]] || die "WORKDIR does not exist: ${WORKDIR}"
[[ "$DRY" == true ]] || command -v qsub >/dev/null \
    || die "qsub not found — this must run on an SGE submission host."

mkdir -p "${WORKDIR}/logs/sge"

# -notify: the job traps SIGUSR1 to clean up before an h_rt/h_vmem kill.
COMMON=( -wd "$WORKDIR" -o "${WORKDIR}/logs/sge/" -j y -notify )
[[ -n "${SGE_QUEUE:-}" ]] && COMMON+=( -q "$SGE_QUEUE" )
[[ -n "${SGE_EMAIL:-}" ]] && COMMON+=( -M "$SGE_EMAIL" -m abe )

PARALLEL=()
[[ -n "${SGE_PE:-}" ]] && PARALLEL=( -pe "$SGE_PE" "${SGE_SLOTS:-1}" )
RES=()
[[ -n "${SGE_RESOURCES:-}" ]] && RES=( -l "$SGE_RESOURCES" )
ARRAY_RES=( "${RES[@]}" )
[[ -n "${SGE_ARRAY_RESOURCES:-}" ]] && ARRAY_RES=( -l "$SGE_ARRAY_RESOURCES" )
MAX_TASKS=()
[[ -n "${SGE_MAX_TASKS:-}" ]] && MAX_TASKS=( -tc "$SGE_MAX_TASKS" )

submit() {
    if [[ "$DRY" == true ]]; then
        echo "qsub $*" >&2
        echo "DRYRUN"
        return 0
    fi
    qsub -terse "$@"
}

# The array is sized from the table, so it must exist. Building it here, on a
# possibly shared login node, needs -b.
RESULTS="${RESULTS_DIR:-results}"
[[ "$RESULTS" == /* ]] || RESULTS="${WORKDIR}/${RESULTS}"
SAMPLES="${SAMPLES_FILE:-${RESULTS}/samples.tsv}"
require_samples() {
    [[ -s "$SAMPLES" ]] && return 0
    [[ "$BUILD_HERE" == true ]] || die "The sample table does not exist yet: ${SAMPLES}
        Build it on a compute node, then run this again:
            qsub -v CONFIG=${CONFIG},STAGE=samples ${JOB}
        Or pass -b to build it here, on this submission host."
    echo "[INFO] Building the sample table here (-b) ..."
    CONFIG="$CONFIG" STAGE=samples bash "$JOB" \
        || die "Could not build ${SAMPLES}. Submit it as a job instead:
        qsub -v CONFIG=${CONFIG},STAGE=samples ${JOB}"
}

# -m: cut on this host to size the array, and passed as MANUAL_SAMPLES_FILE:
# config.sh may set SAMPLES_FILE, and qsub -v splits a list on commas.
EXTRA_VARS=""
if [[ -n "$MANUAL" ]]; then
    require_samples
    subset="${RESULTS}/samples.manual.tsv"
    mkdir -p "${subset%/*}"
    missing="$(awk -F'\t' -v runs="$MANUAL" '
        BEGIN {
            n = split(toupper(runs), r, ",")
            for (i = 1; i <= n; i++) { gsub(/[[:space:]]/, "", r[i]); if (r[i] != "") want[r[i]] = 1 }
        }
        $1 == "SRR"                 { print > out; next }
        ($1 in want) && !seen[$1]++ { print > out }
        END { for (k in want) if (!(k in seen)) printf "%s ", k }
    ' out="$subset" "$SAMPLES")"
    [[ -z "$missing" ]] || die "Not in ${SAMPLES}: ${missing}
        They are absent from the RunTable or were filtered out when the table was built."
    SAMPLES="$subset"
    EXTRA_VARS=",MANUAL_SAMPLES_FILE=${subset}"
    echo "[INFO] Manual selection written to ${subset}"
fi

if [[ "$SERIAL" == true ]]; then
    id="$(submit "${COMMON[@]}" "${PARALLEL[@]}" -N "$JOB_NAME" \
          "${RES[@]}" -v "CONFIG=${CONFIG},STAGE=all${EXTRA_VARS}" "$JOB")"
    echo "[SUBMITTED] ${JOB_NAME} (all stages): ${id}"
    exit 0
fi

require_samples

N="$(awk 'NF==0 || $1=="SRR" || $1 ~ /^#/ { next } { c++ } END { print c+0 }' "$SAMPLES")"
(( N > 0 )) || die "No samples in ${SAMPLES}"
echo "[INFO] ${N} samples in ${SAMPLES}"

refs="$(submit "${COMMON[@]}" "${PARALLEL[@]}" -N "${JOB_NAME}Refs" \
        "${RES[@]}" -v "CONFIG=${CONFIG},STAGE=refs" "$JOB")"
echo "[SUBMITTED] references: ${refs}"

array="$(submit "${COMMON[@]}" "${PARALLEL[@]}" -N "${JOB_NAME}Sample" \
         -hold_jid "$refs" -t "1-${N}" "${MAX_TASKS[@]}" "${ARRAY_RES[@]}" \
         -v "CONFIG=${CONFIG},STAGE=sample${EXTRA_VARS}" "$JOB")"
array="${array%%.*}"   # -terse prints "<id>.<first>-<last>:<step>" for arrays
echo "[SUBMITTED] samples 1-${N}: ${array}"

merge="$(submit "${COMMON[@]}" -N "${JOB_NAME}Merge" -hold_jid "$array" \
         "${ARRAY_RES[@]}" -v "CONFIG=${CONFIG},STAGE=merge" "$JOB")"
echo "[SUBMITTED] merge: ${merge}"
echo
echo "Watch with: qstat -u \$USER    Cancel with: qdel ${refs} ${array} ${merge}"
