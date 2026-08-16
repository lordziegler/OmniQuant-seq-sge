#!/usr/bin/env bash
# Submits OmniQuant-seq to SGE as three chained jobs:
#
#   references  ->  one array task per sample  ->  merge + matrices
#
# Usage: ./submit_omniquant.sh [-c CONFIG] [-w WORKDIR] [-s] [-n]
#   -c  configuration file          (default: ./config.sh)
#   -w  working directory           (default: WORKDIR from the configuration)
#   -s  serial: a single job that runs every stage, no array
#   -n  dry run: print the qsub commands instead of submitting them

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOB="${HERE}/omniquant_sge.sh"

die() { echo "[ABORT] $*" >&2; exit 1; }

usage() { sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; }

CONFIG="${PWD}/config.sh"
WORKDIR_ARG=""
SERIAL=false
DRY=false

while getopts ":c:w:snh" opt; do
    case "$opt" in
        c) CONFIG="$OPTARG" ;;
        w) WORKDIR_ARG="$OPTARG" ;;
        s) SERIAL=true ;;
        n) DRY=true ;;
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

COMMON=( -wd "$WORKDIR" -o "${WORKDIR}/logs/sge/" -j y )
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

# Echoes the job id, or DRYRUN under -n.
submit() {
    if [[ "$DRY" == true ]]; then
        echo "qsub $*" >&2
        echo "DRYRUN"
        return 0
    fi
    qsub -terse "$@"
}

if [[ "$SERIAL" == true ]]; then
    id="$(submit "${COMMON[@]}" "${PARALLEL[@]}" -N "$JOB_NAME" \
          "${RES[@]}" -v "CONFIG=${CONFIG},STAGE=all" "$JOB")"
    echo "[SUBMITTED] ${JOB_NAME} (all stages): ${id}"
    exit 0
fi

# The array size has to be known at submission time, so the sample table is
# built here rather than in a job. It only needs python3 and the RunTable.
SAMPLES="${SAMPLES_FILE:-${WORKDIR}/${RESULTS_DIR:-results}/samples.tsv}"
if [[ ! -s "$SAMPLES" ]]; then
    echo "[INFO] Building the sample table ..."
    CONFIG="$CONFIG" STAGE=samples bash "$JOB" \
        || die "Could not build ${SAMPLES}. Submit it as a job instead:
        qsub -v CONFIG=${CONFIG},STAGE=samples ${JOB}"
fi

N="$(awk 'NF==0 || $1=="SRR" || $1 ~ /^#/ { next } { c++ } END { print c+0 }' "$SAMPLES")"
(( N > 0 )) || die "No samples in ${SAMPLES}"
echo "[INFO] ${N} samples in ${SAMPLES}"

refs="$(submit "${COMMON[@]}" "${PARALLEL[@]}" -N "${JOB_NAME}Refs" \
        "${RES[@]}" -v "CONFIG=${CONFIG},STAGE=refs" "$JOB")"
echo "[SUBMITTED] references: ${refs}"

array="$(submit "${COMMON[@]}" "${PARALLEL[@]}" -N "${JOB_NAME}Sample" \
         -hold_jid "$refs" -t "1-${N}" "${MAX_TASKS[@]}" "${ARRAY_RES[@]}" \
         -v "CONFIG=${CONFIG},STAGE=sample" "$JOB")"
array="${array%%.*}"   # -terse prints "<id>.<first>-<last>:<step>" for arrays
echo "[SUBMITTED] samples 1-${N}: ${array}"

merge="$(submit "${COMMON[@]}" -N "${JOB_NAME}Merge" -hold_jid "$array" \
         "${ARRAY_RES[@]}" -v "CONFIG=${CONFIG},STAGE=merge" "$JOB")"
echo "[SUBMITTED] merge: ${merge}"
echo
echo "Watch with: qstat -u \$USER    Cancel with: qdel ${refs} ${array} ${merge}"
