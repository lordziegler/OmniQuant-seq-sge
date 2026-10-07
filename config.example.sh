#!/usr/bin/env bash
# Copy to config.sh. Overrides $PIPELINE_DIR/config/pipeline.sh; STAGE comes
# from qsub -v.
# shellcheck disable=SC2034

PIPELINE_DIR="/path/to/OmniQuant-seq"   # OmniQuant-seq checkout
WORKDIR="/path/to/analysis"             # inputs are read here, outputs written here

# MODULES=( star/2.7.10a rsem/1.3.3 sra-tools/3.4.1 fastqc/0.12.1 bbmap/39.81 )
CONDA_ENV="omniquant-seq"
# CONDA_BASE="/opt/miniconda3"          # only if `conda` is not on PATH

JOB_NAME="OmniQuant"
SGE_PE="smp"                            # parallel environment name (qconf -spl)
SGE_SLOTS=8
SGE_RESOURCES="h_rt=24:00:00,h_vmem=8G"
SGE_ARRAY_RESOURCES="h_rt=12:00:00,h_vmem=8G"
# SGE_QUEUE="all.q"
# SGE_EMAIL="you@example.edu"           # adds -M <addr> -m abe
# SGE_MAX_TASKS=10                      # concurrent array tasks (qsub -tc)

# THREADS defaults to $NSLOTS; set it only off-cluster.
# THREADS=8
MAX_MEMORY_GB=32                        # STAR index RAM limit
TEST_MODE=false                         # true: stop after TEST_READS reads
TEST_READS=100000

# RUN_TABLE="${WORKDIR}/SraRunTable.csv"  # default: the one *RunTable*.csv in WORKDIR
# SAMPLES_FILE="${WORKDIR}/samples.txt"   # default: ${WORKDIR}/results/samples.tsv
# SPECIES_FILE="${WORKDIR}/species.sh"    # replaces $PIPELINE_DIR/config/species.sh
# SPECIES_FALLBACK="Helicoverpa_armigera" # species for RunTable rows with no Organism

# REFERENCES_DIR="/shared/references"     # default: ${WORKDIR}/references
TMP_DIR="${WORKDIR}/tmp"                # a per-job subdirectory is created inside
CLEANUP=true                            # remove that subdirectory when the job ends
