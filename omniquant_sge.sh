#!/bin/bash
# OmniQuant-seq on Sun Grid Engine. One job script; the stage is chosen with
# $STAGE, so a bare `qsub omniquant_sge.sh` runs the whole pipeline serially
# and submit_omniquant.sh splits it into refs -> per-sample array -> merge.
#
#   STAGE=all      everything in one job (default)
#   STAGE=refs     download genomes, build the STAR and RSEM indexes
#   STAGE=samples  write the sample table from the SRA RunTable
#   STAGE=sample   one sample, picked by $SGE_TASK_ID (array jobs)
#   STAGE=merge    join the per-sample trackers, build the matrices and MultiQC
#
# Everything else comes from config.sh (see config.example.sh).

#$ -S /bin/bash
#$ -N OmniQuant
#$ -cwd
#$ -j y
#$ -l h_rt=24:00:00

# Parallel environments, queues and mail are cluster-specific: submit_omniquant.sh
# passes them on the qsub command line. Uncomment and adjust for a bare qsub.
##$ -pe smp 8
##$ -q all.q
##$ -m abe
##$ -M you@example.edu

set -euo pipefail
trap 'echo "[ERROR] line ${LINENO} exited with status $?" >&2' ERR

# Overridden by lib/utils.sh once the pipeline is sourced; same behaviour.
die() { echo "[ABORT] $*" >&2; exit 1; }

# Nth data row of a sample table, skipping the header, comments and blank lines.
sample_row() {
    local n="$1" file="$2"
    awk -v n="$n" 'NF==0 || $1=="SRR" || $1 ~ /^#/ { next } ++i==n { print; exit }' "$file"
}

# Array tasks each write their own tracker file; this joins them into one table.
merge_trackers() {
    local dir="$1" out="$2" parts=()
    mapfile -t parts < <(find "$dir" -maxdepth 1 -name '*.tsv' 2>/dev/null | sort)
    (( ${#parts[@]} )) || { echo "[WARN] No tracker files in ${dir}."; return 0; }
    { head -n 1 "${parts[0]}"; tail -q -n +2 "${parts[@]}"; } > "${out}.tmp"
    mv "${out}.tmp" "$out"
    echo "[OK] Sample summary: ${out} (${#parts[@]} samples)"
}

# `module load` lines and/or a conda environment, both optional.
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
    IFS=$'\t' read -r srr species layout <<< "$row"
    [[ -n "$srr" && -n "$species" && -n "$layout" ]] \
        || die "Malformed row ${id}: expected SRR<TAB>SPECIES<TAB>LAYOUT, got: ${row}"

    # One tracker per task: concurrent tasks rewriting the single summary table
    # would drop each other's rows. STAGE=merge joins them at the end.
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

    # config.sh is read twice on purpose: first for PIPELINE_DIR and WORKDIR,
    # which are needed to load the pipeline at all, and again afterwards so its
    # values win over the defaults in the pipeline's own config/pipeline.sh.
    # shellcheck disable=SC1090
    [[ -f "$config" ]] && source "$config"

    : "${PIPELINE_DIR:=}"
    : "${WORKDIR:=$PWD}"
    : "${STAGE:=all}"
    : "${JOB_ID:=local$$}"

    [[ -n "$PIPELINE_DIR" ]] || die "PIPELINE_DIR is not set. Copy config.example.sh to config.sh and edit it, or submit with: qsub -v PIPELINE_DIR=/path/to/OmniQuant-seq omniquant_sge.sh"
    [[ -f "${PIPELINE_DIR}/run.sh" ]] || die "PIPELINE_DIR is not an OmniQuant-seq checkout: ${PIPELINE_DIR}"
    [[ -d "$WORKDIR" ]] || die "WORKDIR does not exist: ${WORKDIR}"
    case "$STAGE" in
        all|refs|samples|sample|merge) ;;
        *) die "Unknown STAGE: ${STAGE} (all|refs|samples|sample|merge)" ;;
    esac

    local mod
    source "${PIPELINE_DIR}/config/pipeline.sh"
    source "${PIPELINE_DIR}/config/species.sh"
    for mod in "${PIPELINE_DIR}"/lib/{utils,species_config,cleanup,sample_tracker}.sh \
               "${PIPELINE_DIR}"/steps/*.sh; do
        # shellcheck disable=SC1090
        source "$mod"
    done

    # shellcheck disable=SC1090
    [[ -f "$config" ]] && source "$config"
    # shellcheck disable=SC1090
    [[ -n "${SPECIES_FILE:-}" ]] && source "$SPECIES_FILE"

    # Derived from values config.sh may have just changed.
    : "${THREADS:=${NSLOTS:-1}}"
    [[ "$THREADS" =~ ^[1-9][0-9]*$ ]] || die "THREADS must be a positive integer: ${THREADS}"
    THREADS_DOWNLOAD="$THREADS"; THREADS_FASTQC="$THREADS"; THREADS_TRIM="$THREADS"
    THREADS_STAR="$THREADS";     THREADS_RSEM="$THREADS"
    SAMPLES_TSV="${SAMPLES_FILE:-${RESULTS_DIR}/samples.tsv}"
    SUMMARY_FILE="${RESULTS_DIR}/pipeline_sample_summary.tsv"
    TMP_DIR="${TMP_DIR}/job_${JOB_ID}"

    local task=""
    [[ "${SGE_TASK_ID:-}" =~ ^[0-9]+$ ]] && task="_${SGE_TASK_ID}"

    cd "$WORKDIR"
    mkdir -p "$LOG_DIR" "$TMP_DIR" "$RESULTS_DIR/rsem" "$RESULTS_DIR/tracker" \
             "$REFERENCES_DIR" sra fastq clean_fastq fastqc_out

    [[ "${CLEANUP:-true}" == true ]] && trap 'rm -rf "$TMP_DIR"' EXIT
    trap on_interrupt SIGINT SIGTERM

    exec > >(tee -a "${LOG_DIR}/omniquant_${JOB_ID}${task}.log") 2>&1

    echo "============================================================"
    echo " OmniQuant-seq — SGE job"
    echo " Stage     : ${STAGE}${task:+ (task ${SGE_TASK_ID})}"
    echo " Job ID    : ${JOB_ID}"
    echo " Started   : $(date '+%Y-%m-%d %H:%M:%S')"
    echo " Workdir   : ${WORKDIR}"
    echo " Pipeline  : ${PIPELINE_DIR}"
    echo " Threads   : ${THREADS}"
    echo " Test mode : ${TEST_MODE} (${TEST_READS} reads)"
    echo " Species   : $(species_config_active_keys | paste -sd, -)"
    echo "============================================================"

    setup_environment

    # Only the tools the stage actually runs, so the cheap stages stay usable
    # on a login node.
    case "$STAGE" in
        samples) check_tools python3 ;;
        merge)   check_tools python3 multiqc ;;
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

# Sourceable for the tests; runs only when executed.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
