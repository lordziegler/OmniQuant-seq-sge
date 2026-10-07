#!/usr/bin/env bash
# bash test_sge.sh — no cluster, no bioinformatics tools.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
check() {
    if [[ "$2" == "$3" ]]; then
        echo "  ok    $1"
    else
        echo "  FAIL  $1: expected [$2], got [$3]"
        FAIL=1
    fi
}

# shellcheck disable=SC1091
source "${HERE}/omniquant_sge.sh"

echo "sample_row"
SAMPLES="${TMP}/samples.tsv"
printf '# a comment\nSRR\tSPECIES\tLAYOUT\nSRR1\tHelicoverpa_armigera\tPAIRED\n\nSRR2\tSpodoptera_frugiperda\tSINGLE\n' > "$SAMPLES"
check "first data row"    "SRR1	Helicoverpa_armigera	PAIRED" "$(sample_row 1 "$SAMPLES")"
check "blank line skipped" "SRR2	Spodoptera_frugiperda	SINGLE" "$(sample_row 2 "$SAMPLES")"
check "out of range"      ""                                    "$(sample_row 3 "$SAMPLES")"

echo "merge_trackers"
mkdir -p "${TMP}/tracker"
printf 'sample\tstatus\nSRR1\tOK\n' > "${TMP}/tracker/SRR1.tsv"
printf 'sample\tstatus\nSRR2\tOK\n' > "${TMP}/tracker/SRR2.tsv"
merge_trackers "${TMP}/tracker" "${TMP}/summary.tsv" >/dev/null
check "one header + two rows" "3" "$(wc -l < "${TMP}/summary.tsv" | tr -d ' ')"
check "header kept"           "sample	status" "$(head -n 1 "${TMP}/summary.tsv")"
merge_trackers "${TMP}/empty" "${TMP}/none.tsv" >/dev/null
check "no tracker dir is not fatal" "0" "$?"

echo "stage_sample"
tracker_init()        { :; }
tracker_is_complete() { return 1; }
process_sample()      { echo "$1|$2|$3"; }
SAMPLES_TSV="$SAMPLES"
RESULTS_DIR="$TMP"
LOG_DIR="$TMP"
check "task 2 processes the second sample" \
      "SRR2|Spodoptera_frugiperda|SINGLE" \
      "$(SGE_TASK_ID=2 stage_sample 2>/dev/null | tail -n 1)"

status=0; ( SGE_TASK_ID=undefined stage_sample ) >/dev/null 2>&1 || status=$?
check "non-numeric task id aborts" "1" "$status"
status=0; ( SGE_TASK_ID=99 stage_sample ) >/dev/null 2>&1 || status=$?
check "task id past the table aborts" "1" "$status"

echo "input validation"
status=0; ( cd "$TMP" && CONFIG="${TMP}/none.sh" bash "${HERE}/omniquant_sge.sh" ) >"${TMP}/out" 2>&1 || status=$?
check "missing PIPELINE_DIR aborts"  "1" "$status"
check "and says why" "1" "$(grep -c 'PIPELINE_DIR is not set' "${TMP}/out")"

echo "PIPELINE_DIR=${TMP}" > "${TMP}/bad.sh"
status=0; ( cd "$TMP" && CONFIG="${TMP}/bad.sh" bash "${HERE}/omniquant_sge.sh" ) >"${TMP}/out" 2>&1 || status=$?
check "PIPELINE_DIR without run.sh aborts" "1" "$status"

echo "PIPELINE_DIR=${TMP}" > "${TMP}/bad2.sh"
echo "WORKDIR=${TMP}/nope" >> "${TMP}/bad2.sh"
: > "${TMP}/run.sh"
status=0; ( cd "$TMP" && CONFIG="${TMP}/bad2.sh" bash "${HERE}/omniquant_sge.sh" ) >"${TMP}/out" 2>&1 || status=$?
check "missing WORKDIR aborts" "1" "$status"

printf 'PIPELINE_DIR=%s\nWORKDIR=%s\n' "$TMP" "$TMP" > "${TMP}/ok.sh"
status=0; ( cd "$TMP" && CONFIG="${TMP}/ok.sh" STAGE=nonsense bash "${HERE}/omniquant_sge.sh" ) >"${TMP}/out" 2>&1 || status=$?
check "unknown stage aborts" "1" "$status"
check "and names the stage" "1" "$(grep -c 'Unknown STAGE: nonsense' "${TMP}/out")"

# Empty stub: it only has to reach the API check, which prints PIPELINE_DIR.
mkdir -p "${TMP}/pipe"/{config,lib,steps} "${TMP}/work"
: > "${TMP}/pipe/run.sh"
for m in config/pipeline config/species lib/utils lib/species_config \
         lib/cleanup lib/sample_tracker steps/noop; do
    : > "${TMP}/pipe/${m}.sh"
done
printf 'PIPELINE_DIR=pipe\nWORKDIR=%s\n' "${TMP}/work" > "${TMP}/rel.sh"
( cd "$TMP" && CONFIG="${TMP}/rel.sh" bash "${HERE}/omniquant_sge.sh" ) >"${TMP}/out" 2>&1 || true
check "relative PIPELINE_DIR is made absolute" \
      "1" "$(grep -c "^\[ABORT\] ${TMP}/pipe (" "${TMP}/out")"

echo "require_pipeline_api"
status=0; ( require_pipeline_api sample_row merge_trackers ) >/dev/null 2>&1 || status=$?
check "every function present passes" "0" "$status"
out="$( ( PIPELINE_DIR="$TMP" require_pipeline_api sample_row no_such_pipeline_fn ) 2>&1 )" || true
check "a missing function is named" "1" "$(grep -c 'does not provide: no_such_pipeline_fn' <<< "$out")"
check "and the validated release is named" "1" "$(grep -c "validated against OmniQuant-seq ${PIPELINE_REV_TESTED}" <<< "$out")"

echo "submit_omniquant.sh"
mkdir -p "${TMP}/abs-results"
printf 'SRR\tSPECIES\tLAYOUT\nSRR1\tHelicoverpa_armigera\tPAIRED\nSRR2\tHelicoverpa_armigera\tSINGLE\n' \
    > "${TMP}/abs-results/samples.tsv"
printf 'PIPELINE_DIR=%s\nWORKDIR=%s\nRESULTS_DIR=%s\n' "$TMP" "$TMP" "${TMP}/abs-results" > "${TMP}/abs.sh"
out="$(bash "${HERE}/submit_omniquant.sh" -n -c "${TMP}/abs.sh" 2>&1)" || true
check "absolute RESULTS_DIR is not prefixed with WORKDIR" \
      "1" "$(grep -c "2 samples in ${TMP}/abs-results/samples.tsv" <<< "$out")"
check "the array is sized from the table" "1" "$(grep -c -- '-t 1-2' <<< "$out")"
check "jobs are submitted with -notify" "3" "$(grep -c -- '-notify' <<< "$out")"
check "nothing is executed on the submission host" "0" \
      "$(grep -c 'Building the sample table' <<< "$out")"

printf 'PIPELINE_DIR=%s\nWORKDIR=%s\nSAMPLES_FILE=%s\n' "$TMP" "$TMP" "${TMP}/absent.tsv" > "${TMP}/nosamples.sh"
out="$(bash "${HERE}/submit_omniquant.sh" -n -c "${TMP}/nosamples.sh" 2>&1)" || true
check "a missing table is refused, not built here" "1" \
      "$(grep -c 'The sample table does not exist yet' <<< "$out")"
check "and the compute-node command is given" "1" "$(grep -c 'STAGE=samples' <<< "$out")"

printf 'SRR\tSPECIES\tLAYOUT\tTISSUE\nSRR1\tHa\tPAIRED\tGut\nSRR2\tHa\tSINGLE\tHead\nSRR3\tHa\tPAIRED\tNA\n' \
    > "${TMP}/abs-results/samples.tsv"
out="$(bash "${HERE}/submit_omniquant.sh" -n -c "${TMP}/abs.sh" -m srr3 -m SRR1 2>&1)" || true
check "-m keeps only the named runs, header first" \
      "SRR,SRR1,SRR3," "$(cut -f1 "${TMP}/abs-results/samples.manual.tsv" | tr '\n' ',')"
check "-m keeps the metadata columns" "Gut" "$(awk -F'\t' '$1=="SRR1"{print $4}' "${TMP}/abs-results/samples.manual.tsv")"
check "-m sizes the array from the subset" "1" "$(grep -c -- '-t 1-2' <<< "$out")"
check "-m hands the subset to the array" "1" \
      "$(grep -c "STAGE=sample,MANUAL_SAMPLES_FILE=${TMP}/abs-results/samples.manual.tsv" <<< "$out")"
out="$(bash "${HERE}/submit_omniquant.sh" -n -s -c "${TMP}/abs.sh" -m SRR2 2>&1)" || true
check "-m reaches a serial job too" "1" "$(grep -c 'STAGE=all,MANUAL_SAMPLES_FILE=' <<< "$out")"
status=0; out="$(bash "${HERE}/submit_omniquant.sh" -n -c "${TMP}/abs.sh" -m SRR1,SRR9 2>&1)" || status=$?
check "-m with an unknown run aborts" "1" "$status"
check "and names it" "1" "$(grep -c 'Not in .*: SRR9' <<< "$out")"

echo "manual sample table in the job"
SAMPLES_TSV="${TMP}/abs-results/samples.manual.tsv"
check "task 1 of the subset is its first run" "SRR1|Ha|PAIRED" \
      "$(SGE_TASK_ID=1 stage_sample 2>/dev/null | tail -n 1)"

echo "no interactivity"
hits="$(grep -nE '(^|[^[:alnum:]_])(read[[:space:]]+-[a-z]*p|select[[:space:]]+[A-Za-z_]+[[:space:]]+in)' \
        "${HERE}"/*.sh || true)"
check "no prompts" "" "$hits"
hits="$(grep -n 'lib/\(prompt\|menu\)\.sh' "${HERE}"/*.sh || true)"
check "interactive modules never sourced" "" "$hits"

echo
if (( FAIL )); then echo "FAILED"; exit 1; fi
echo "All checks passed."
