# OmniQuant-seq on Sun Grid Engine

Batch layer for [OmniQuant-seq](https://github.com/lordziegler/OmniQuant-seq):
the same RNA-seq quantification (prefetch → fastq-dump → FastQC → BBDuk → STAR
→ RSEM → matrices), driven by `qsub` instead of a menu.

Nothing is reimplemented here. The pipeline stays in its own repository and is
sourced from `$PIPELINE_DIR`; this repository only adds the job script, the
submission wrapper and the configuration. Updating the pipeline is a `git pull`
in its checkout.

## Pipeline version

This layer is validated against **OmniQuant-seq v2.4.0**. Every job prints what
it is actually running against, so a result can be traced back to the code that
produced it:

```
 Pipeline  : /apps/OmniQuant-seq (v2.4.0, validated: v2.4.0)
```

The revision comes from `git describe` in `$PIPELINE_DIR` (`unknown` if that
checkout is not a git repository, which changes nothing else). Immediately
after loading the pipeline's modules the job checks that every function it
calls exists, and aborts before spending any walltime if one does not:

```
[ABORT] /apps/OmniQuant-seq (v2.5.0) does not provide: postprocess_all
        This SGE layer was validated against OmniQuant-seq v2.4.0.
        Update OmniQuant-seq-sge, or check out a matching OmniQuant-seq.
```

`git -C $PIPELINE_DIR checkout v2.4.0` restores a known-good pair; the
alternative is to update this repository.

## Requirements

| Tool | Used by |
|------|---------|
| `prefetch`, `fastq-dump`, `fasterq-dump` (SRA-Toolkit 3.x) | download and FASTQ extraction |
| `fastqc` 0.12.x, `multiqc` 1.14+ | quality control |
| `bbduk.sh` (BBMap 39.x) | trimming |
| `STAR` 2.7.x | alignment and genome index |
| `rsem-prepare-reference`, `rsem-calculate-expression` (RSEM 1.3.x) | quantification |
| `python3` 3.9+ (`openpyxl` only for `.xlsx` RunTables) | RunTable parsing, matrix building |

Provide them either way, or both:

```bash
# Conda (versions pinned by the pipeline's environment.yml)
conda env create -f /path/to/OmniQuant-seq/environment.yml
# -> config.sh: CONDA_ENV="omniquant-seq"

# Or the exact environment the pipeline was validated in, builds and channels
# included (conda list --explicit); use this one to reproduce published numbers
conda create --name omniquant-seq --file /path/to/OmniQuant-seq/environment.lock.txt

# Environment modules
module avail star rsem sra
# -> config.sh: MODULES=( star/2.7.10a rsem/1.3.3 sra-tools/3.4.1 fastqc/0.12.1 bbmap/39.81 )
```

The job aborts before doing any work if a tool is missing, naming each one.

## Install

```bash
git clone https://github.com/lordziegler/OmniQuant-seq.git
git clone https://github.com/lordziegler/OmniQuant-seq-sge.git

mkdir -p /scratch/$USER/analysis
cp OmniQuant-seq-sge/config.example.sh /scratch/$USER/analysis/config.sh
$EDITOR /scratch/$USER/analysis/config.sh          # PIPELINE_DIR and WORKDIR are required
```

Put the SRA RunTable (`*RunTable*.csv`) in `WORKDIR`, and check that the
organisms you need are listed and `active` in
`$PIPELINE_DIR/config/species.sh` (or in your own `SPECIES_FILE`).

## Submit

```bash
cd /scratch/$USER/analysis
/path/to/OmniQuant-seq-sge/submit_omniquant.sh          # references -> array -> merge
```

Three chained jobs, each waiting for the previous one with `-hold_jid`:

| Job | Stage | What it does |
|-----|-------|--------------|
| `OmniQuantRefs` | `refs` | downloads genome + GTF, builds the STAR and RSEM indexes |
| `OmniQuantSample` | `sample` | array, one task per sample: prefetch → FASTQ → QC → trim → STAR → RSEM |
| `OmniQuantMerge` | `merge` | joins the per-sample trackers, builds the expression and QC matrices, global MultiQC |

Other ways to run it:

```bash
./submit_omniquant.sh -n                    # dry run: print the qsub commands
./submit_omniquant.sh -s                    # serial: one job, samples one after another
./submit_omniquant.sh -c /path/config.sh    # configuration somewhere else
./submit_omniquant.sh -w /scratch/other     # override WORKDIR

# One stage on its own
qsub -v CONFIG=$PWD/config.sh,STAGE=refs  /path/to/omniquant_sge.sh
qsub -v CONFIG=$PWD/config.sh,STAGE=merge /path/to/omniquant_sge.sh

# The array by hand (N = number of data rows in the sample table)
qsub -t 1-12 -v CONFIG=$PWD/config.sh,STAGE=sample /path/to/omniquant_sge.sh

# No configuration file, everything from the environment
qsub -v PIPELINE_DIR=/apps/OmniQuant-seq,WORKDIR=$PWD /path/to/omniquant_sge.sh
```

`qsub omniquant_sge.sh` with a `config.sh` in the current directory runs
`STAGE=all`: every stage in a single job.

### Multiple samples

The sample table is `SRR<TAB>SPECIES<TAB>LAYOUT`, one line per run
(see `samples.txt.example`). `submit_omniquant.sh` generates it from the
RunTable into `results/samples.tsv` when it is missing, and sizes the array
from it. Array task *N* takes the *N*-th data line; the header, comments and
blank lines do not count.

To run a subset, write the table by hand and point `SAMPLES_FILE` at it:

```bash
printf 'SRR29271587\tHelicoverpa_armigera\tPAIRED\n' > subset.txt
# config.sh: SAMPLES_FILE="${WORKDIR}/subset.txt"
```

Since v2.4.0 the parser refuses to guess: a run whose `LibraryLayout` is
unreadable is dropped instead of being assumed `PAIRED`, and a
`LibrarySource=GENOMIC` run is dropped instead of being quantified as if it
were RNA. Both are named in the parser's output, and both have an override that
`STAGE=samples` does not pass. When the layout really is known from elsewhere,
build the table by hand once and point `SAMPLES_FILE` at it:

```bash
python3 $PIPELINE_DIR/helpers/parse_runtable.py \
    --input SraRunTable.csv --output samples.tsv \
    --species Helicoverpa_armigera --assume-layout PAIRED
# config.sh: SAMPLES_FILE="${WORKDIR}/samples.tsv"
```

`--star-overhang $STAR_OVERHANG` is passed on every run and warns when a run's
`AvgSpotLen` is far from `STAR_OVERHANG + 1`. One STAR index is shared by every
run of a species, so a batch of mixed read lengths gets one `sjdbOverhang`;
the warning is where that shows up.

## Configuration

Every value lives in `config.sh` (see `config.example.sh`). Required:
`PIPELINE_DIR` and `WORKDIR`. Anything defined in
`$PIPELINE_DIR/config/pipeline.sh` can be overridden there as well —
`TEST_MODE`, `TEST_READS`, `MAX_MEMORY_GB`, `REFERENCES_DIR`, the BBDuk and
STAR parameters, the cleanup switches.

`THREADS` defaults to `$NSLOTS`, the slots SGE actually granted, and is passed
to STAR, RSEM, BBDuk, FastQC and `fasterq-dump`. Requesting `-pe smp 8` is
therefore enough; there is no second number to keep in sync.

`STAGE` and `CONFIG` come from `qsub -v` and must not be set in `config.sh`.

### Output layout, all under `WORKDIR`

```
references/<species>/     genome, GTF, STAR index, RSEM reference (reusable)
results/samples.tsv       the sample table
results/rsem/<species>/   per-sample RSEM results
results/tracker/          one status file per array task
results/pipeline_sample_summary.tsv   merged status table
results/tables/           gene_expression_matrix.tsv + STAR/BBDuk QC matrices
                          (STAR matrix carries the per-sample strand ratio)
results/qc/multiqc/       MultiQC reports
logs/                     per-sample and per-tool logs, plus omniquant_<jobid>.log
logs/sge/                 stdout/stderr of each job (-o is set by the wrapper)
sra/ fastq/ clean_fastq/  intermediates, removed as each sample completes
tmp/job_<jobid>/          scratch, removed on exit unless CLEANUP=false
```

Point `REFERENCES_DIR` at a shared path to build the indexes once for the
whole group.

## Monitor

```bash
qstat -u $USER                 # everything you have queued or running
qstat -t -u $USER              # array jobs task by task
qstat -j <job_id>              # why a job is still waiting, and its resources
qacct -j <job_id>              # after it finished: exit status, wallclock, max memory

tail -f logs/omniquant_<job_id>.log      # the pipeline's own log
tail -f logs/sge/OmniQuantSample.o<job_id>.<task_id>
tail -f logs/<SRR>.log                   # one sample, all stages
column -t results/pipeline_sample_summary.tsv
```

## Cancel

```bash
qdel <job_id>                  # one job, or a whole array
qdel <job_id> -t 3-5           # only those tasks
qdel -u $USER                  # everything of yours
```

On `qdel` the job removes the partial files of the sample it was processing,
so the next run does not read a truncated FASTQ or BAM as if it were complete.

The same applies when the queue itself stops the job. `submit_omniquant.sh`
submits with `-notify`, so SGE sends `SIGUSR1` before the `h_rt` or `h_vmem`
kill and the job gets to clean up; a bare `qsub` without `-notify` is killed
outright and leaves those files behind for the resubmission to trip over.

## Re-running and resuming

Every stage is idempotent, so resuming is just resubmitting:

- built references are detected and skipped;
- an existing sample table is not rebuilt;
- a sample whose tracker says `rsem_status=OK` is skipped;
- half-written outputs from a failed or cancelled sample are deleted, not reused.

After a partial run, `submit_omniquant.sh` again picks up where it stopped.
To force a rebuild, delete the relevant directory (`references/<species>`,
`results/rsem/<species>`, `results/tracker/<SRR>.tsv`).

## Troubleshooting

**The job stays in `qw`.** `qstat -j <job_id>` prints the reason at the bottom.
Usually the request cannot be satisfied: a parallel environment that does not
exist (`qconf -spl` lists them), more slots than any queue offers
(`qconf -sq <queue>`), or an `h_vmem` no host has. Lower `SGE_SLOTS` or
`SGE_RESOURCES` in `config.sh`.

**`Unable to run job: unknown parallel environment smp`.** Set `SGE_PE` to a
name from `qconf -spl`, or leave it empty to run on a single slot.

**The job dies during the STAR index.** Building an index needs roughly as much
RAM as `MAX_MEMORY_GB`; the default is 32 GB. On most clusters `h_vmem` is *per
slot*, so 8 slots × `h_vmem=8G` = 64 GB total. Keep `MAX_MEMORY_GB` below that
product, and lower it if the queue cannot offer it.

**`STAGE=refs` fails with a download or checksum error.** The references are
downloaded on the execution node, not the submit host, and since v2.4.0 each
one is verified against NCBI's `md5checksums.txt` from the same directory. The
node therefore needs outbound HTTPS. A source that publishes no checksums file
degrades to a warning; a checksum that does not match deletes the file and
fails the stage, which is the intended behaviour — rerun it. On a cluster with
no internet on the compute nodes, build the references on the submit host
(`CONFIG=$PWD/config.sh STAGE=refs bash omniquant_sge.sh`) or point
`REFERENCES_DIR` at an already-built shared copy.

**`Killed` or exit status 137.** The queue's memory limit. Raise `h_vmem` in
`SGE_RESOURCES` / `SGE_ARRAY_RESOURCES`, or reduce `THREADS` — STAR's footprint
grows with the number of threads.

**The job is cut off after N hours.** `h_rt` was too low. Full RNA-seq samples
take hours each; the array default is `h_rt=12:00:00` per sample, the serial
default 24 h for *all* of them. Prefer the array, raise `SGE_ARRAY_RESOURCES`,
and re-submit: completed samples are skipped.

**`[MISSING] STAR` and friends.** The environment is not loaded inside the job.
SGE does not inherit your login shell, so `CONDA_ENV` or `MODULES` in
`config.sh` is the only thing that sets it up. Test with
`qsub -v CONFIG=$PWD/config.sh,STAGE=samples omniquant_sge.sh`, which is cheap
and checks the environment the same way.

**`prefetch` fails on some samples.** Usually the network or an NCBI rate
limit. The stage retries `PREFETCH_RETRIES` times; a sample that still fails is
recorded as `FAILED` in the tracker and the rest of the array continues.
Resubmit later for those tasks: `qsub -t 4,7 ... STAGE=sample`.

**`No sample at index N`.** The array is larger than the sample table. Count
the data lines (`grep -vcE '^(#|SRR\s|$)' samples.tsv`) and submit `-t 1-N`
with that number, or let `submit_omniquant.sh` size it.

**The expression matrix is empty or has too few genes.** It is the *inner join*
of every sample, so a single failed sample can empty it. Check
`results/pipeline_sample_summary.tsv` first, fix or drop that sample, and rerun
`STAGE=merge`.

## Files

| File | Purpose |
|------|---------|
| `omniquant_sge.sh` | the job script; one stage per invocation |
| `submit_omniquant.sh` | submits references → array → merge with `qsub` |
| `config.example.sh` | configuration template |
| `samples.txt.example` | sample-table format for array jobs |
| `test_sge.sh` | self-check: indexing, merging, validation, no interactivity |
| `CHANGELOG.md` | what changed in this layer, and against which pipeline release |

`bash test_sge.sh` runs everything that does not need a cluster: 24 checks, no
bioinformatics tools, no `qsub`. `shellcheck -x omniquant_sge.sh
submit_omniquant.sh test_sge.sh config.example.sh` is clean.

## License

MIT, same as OmniQuant-seq.
