#!/bin/bash
# STAGE=all|refs|samples|sample|merge (default all); settings from config.sh.

#$ -S /bin/bash
#$ -N OmniQuant
#$ -cwd
#$ -j y
#$ -l h_rt=24:00:00

# Cluster-specific; submit_omniquant.sh passes them. Uncomment for a bare qsub.
##$ -pe smp 8
##$ -q all.q
##$ -m abe
##$ -M you@example.edu

set -euo pipefail
trap 'echo "[ERROR] line ${LINENO} exited with status $?" >&2' ERR

die() { echo "[ABORT] $*" >&2; exit 1; }

PIPELINE_REV_TESTED="v2.4.0"

pipeline_revision() {
    git -C "$PIPELINE_DIR" describe --always --dirty 2>/dev/null || echo "unknown"
}

# Fail at startup, not mid-job after the walltime, if the pipeline API changed.
require_pipeline_api() {
    local fn missing=()
    for fn in "$@"; do
        declare -F "$fn" >/dev/null 2>&1 || missing+=( "$fn" )
    done
    (( ${#missing[@]} == 0 )) || die "${PIPELINE_DIR} ($(pipeline_revision)) does not provide: ${missing[*]}
        This SGE layer was validated against OmniQuant-seq ${PIPELINE_REV_TESTED}.
        Update OmniQuant-seq-sge, or check out a matching OmniQuant-seq."
}

# Skips the header, comments and blank lines.
sample_row() {
    local n="$1" file="$2"
    awk -v n="$n" 'NF==0 || $1=="SRR" || $1 ~ /^#/ { next } ++i==n { print; exit }' "$file"
}

merge_trackers() {
    local dir="$1" out="$2" parts=()
    mapfile -t parts < <(find "$dir" -maxdepth 1 -name '*.tsv' 2>/dev/null | sort)
    (( ${#parts[@]} )) || { echo "[WARN] No tracker files in ${dir}."; return 0; }
    { head -n 1 "${parts[0]}"; tail -q -n +2 "${parts[@]}"; } > "${out}.tmp"
    mv "${out}.tmp" "$out"
    echo "[OK] Sample summary: ${out} (${#parts[@]} samples)"
}

setup_environment() {
    if [[ -n "${MODULES+x}" && ${#MODULES[@]} -gt 0 ]]; then
        if ! command -v module >/dev/null 2>&1 && [[ -f /etc/profile.d/modules.sh ]]; then
            # shellcheck disable=SC1091
            source /etc/profile.d/modules.sh
        fi
        local m
        for m in "${MODULES[@]}"; do
            echo "[MODULE] ${m}"
            module load "$m" || die "module load ${m} failed."
        done
    fi

    if [[ -n "${CONDA_ENV:-}" ]]; then
        local base="${CONDA_BASE:-$(conda info --base 2>/dev/null || true)}"
        [[ -n "$base" ]] || die "CONDA_ENV is set but conda was not found; set CONDA_BASE in config.sh."
        # shellcheck disable=SC1091
        source "${base}/etc/profile.d/conda.sh"
        set +u; conda activate "$CONDA_ENV"; set -u
        echo "[CONDA] ${CONDA_ENV}"
    fi
}

stage_refs() {
    detect_local_references "."
    build_all_references
    echo "[DONE] References ready in ${REFERENCES_DIR}"
}

stage_samples() {
    if [[ -s "$SAMPLES_TSV" ]]; then
        echo "[SKIP] Sample table already exists: ${SAMPLES_TSV}"
        return 0
    fi
    detect_run_table "."
    parse_samples
}

stage_sample() {
    local id="${SGE_TASK_ID:-}"
    [[ "$id" =~ ^[0-9]+$ ]] || die "STAGE=sample needs a numeric \$SGE_TASK_ID (submit with qsub -t 1-N)."
    [[ -s "$SAMPLES_TSV" ]] || die "Sample table not found: ${SAMPLES_TSV} — run STAGE=samples first."

    local row srr species layout
    row="$(sample_row "$id" "$SAMPLES_TSV")"
    [[ -n "$row" ]] || die "No sample at index ${id} in ${SAMPLES_TSV}."
    # `_` takes the metadata columns, which would otherwise land in $layout.
    IFS=$'\t' read -r srr species layout _ <<< "$row"
    [[ -n "$srr" && -n "$species" && -n "$layout" ]] \
        || die "Malformed row ${id}: expected SRR<TAB>SPECIES<TAB>LAYOUT[<TAB>metadata...], got: ${row}"

    # One tracker per task: concurrent writes to one table would drop rows.
    SUMMARY_FILE="${RESULTS_DIR}/tracker/${srr}.tsv"
    tracker_init

    if tracker_is_complete "$srr"; then
        echo "[SKIP] ${srr} already complete."
        return 0
    fi

    echo "--- ${srr} | ${species} | ${layout} ---"
    process_sample "$srr" "$species" "$layout"
    tracker_is_complete "$srr" || die "${srr} failed — see ${LOG_DIR}/${srr}.log"
}

stage_merge() {
    merge_trackers "${RESULTS_DIR}/tracker" "$SUMMARY_FILE"
    postprocess_all
}

stage_all() {
    stage_refs
    stage_samples
    tracker_init
    run_sample_loop
    postprocess_all
}

main() {
    local config="${CONFIG:-${PWD}/config.sh}"
    [[ "$config" == /* ]] || config="${PWD}/${config}"

    # Sourced twice: first for PIPELINE_DIR/WORKDIR, then to override the
    # pipeline's defaults.
    # shellcheck disable=SC1090
    [[ -f "$config" ]] && source "$config"

    : "${PIPELINE_DIR:=}"
    : "${WORKDIR:=$PWD}"
    : "${STAGE:=all}"
    : "${JOB_ID:=local$$}"

    [[ -n "$PIPELINE_DIR" ]] || die "PIPELINE_DIR is not set. Copy config.example.sh to config.sh and edit it, or submit with: qsub -v PIPELINE_DIR=/path/to/OmniQuant-seq omniquant_sge.sh"
    [[ -f "${PIPELINE_DIR}/run.sh" ]] || die "PIPELINE_DIR is not an OmniQuant-seq checkout: ${PIPELINE_DIR}"
    # Absolute before the cd below.
    [[ "$PIPELINE_DIR" == /* ]] || PIPELINE_DIR="$(cd "$PIPELINE_DIR" && pwd)"
    [[ -d "$WORKDIR" ]] || die "WORKDIR does not exist: ${WORKDIR}"
    case "$STAGE" in
        all|refs|samples|sample|merge) ;;
        *) die "Unknown STAGE: ${STAGE} (all|refs|samples|sample|merge)" ;;
    esac

    local mod
    # shellcheck source=/dev/null
    source "${PIPELINE_DIR}/config/pipeline.sh"
    # shellcheck source=/dev/null
    source "${PIPELINE_DIR}/config/species.sh"
    for mod in "${PIPELINE_DIR}"/lib/{utils,species_config,cleanup,sample_tracker}.sh \
               "${PIPELINE_DIR}"/steps/*.sh; do
        # shellcheck disable=SC1090
        source "$mod"
    done

    require_pipeline_api \
        detect_local_references build_all_references detect_run_table \
        parse_samples tracker_init tracker_is_complete process_sample \
        run_sample_loop postprocess_all on_interrupt \
        check_tools disk_usage species_config_active_keys

    # shellcheck disable=SC1090
    [[ -f "$config" ]] && source "$config"
    # shellcheck disable=SC1090
    [[ -n "${SPECIES_FILE:-}" ]] && source "$SPECIES_FILE"

    : "${THREADS:=${NSLOTS:-1}}"
    [[ "$THREADS" =~ ^[1-9][0-9]*$ ]] || die "THREADS must be a positive integer: ${THREADS}"
    # shellcheck disable=SC2034  # read by the sourced pipeline
    {
        THREADS_DOWNLOAD="$THREADS"
        THREADS_FASTQC="$THREADS"
        THREADS_TRIM="$THREADS"
        THREADS_STAR="$THREADS"
        THREADS_RSEM="$THREADS"
    }
    # From submit_omniquant.sh -m; wins over a SAMPLES_FILE set in config.sh.
    SAMPLES_TSV="${MANUAL_SAMPLES_FILE:-${SAMPLES_FILE:-${RESULTS_DIR}/samples.tsv}}"
    SUMMARY_FILE="${RESULTS_DIR}/pipeline_sample_summary.tsv"
    TMP_DIR="${TMP_DIR}/job_${JOB_ID}"

    local PIPELINE_REV task=""
    PIPELINE_REV="$(pipeline_revision)"
    [[ "${SGE_TASK_ID:-}" =~ ^[0-9]+$ ]] && task="_${SGE_TASK_ID}"

    cd "$WORKDIR"
    mkdir -p "$LOG_DIR" "$TMP_DIR" "$RESULTS_DIR/rsem" "$RESULTS_DIR/tracker" \
             "$REFERENCES_DIR" sra fastq clean_fastq fastqc_out

    [[ "${CLEANUP:-true}" == true ]] && trap 'rm -rf "$TMP_DIR"' EXIT
    # qsub -notify sends SIGUSR1/2 before an h_rt/h_vmem kill.
    trap on_interrupt SIGINT SIGTERM SIGUSR1 SIGUSR2

    exec > >(tee -a "${LOG_DIR}/omniquant_${JOB_ID}${task}.log") 2>&1

    echo "============================================================"
    echo " OmniQuant-seq — SGE job"
    echo " Stage     : ${STAGE}${task:+ (task ${SGE_TASK_ID})}"
    echo " Job ID    : ${JOB_ID}"
    echo " Started   : $(date '+%Y-%m-%d %H:%M:%S')"
    echo " Workdir   : ${WORKDIR}"
    echo " Pipeline  : ${PIPELINE_DIR} (${PIPELINE_REV}, validated: ${PIPELINE_REV_TESTED})"
    echo " Threads   : ${THREADS}"
    echo " Test mode : ${TEST_MODE} (${TEST_READS} reads)"
    echo " Species   : $(species_config_active_keys | paste -sd, -)"
    echo "============================================================"

    setup_environment

    # Only this stage's tools, so the cheap stages work on a login node.
    case "$STAGE" in
        samples) check_tools python3 ;;
        merge)   check_tools python3 multiqc ;;
        refs)    check_tools STAR rsem-prepare-reference ;;
        *)       check_tools prefetch fastq-dump fasterq-dump fastqc multiqc \
                             bbduk.sh STAR rsem-prepare-reference rsem-calculate-expression ;;
    esac
    disk_usage "stage-start"

    case "$STAGE" in
        all)     stage_all ;;
        refs)    stage_refs ;;
        samples) stage_samples ;;
        sample)  stage_sample ;;
        merge)   stage_merge ;;
        *)       die "Stage ${STAGE} has no implementation." ;;
    esac

    echo "[DONE] Stage ${STAGE} finished at $(date '+%Y-%m-%d %H:%M:%S')."
}

# Sourceable by the tests.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
