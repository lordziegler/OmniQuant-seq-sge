# Changelog

This layer carries no pipeline code of its own: it sources
[OmniQuant-seq](https://github.com/lordziegler/OmniQuant-seq) from
`$PIPELINE_DIR`. Each release therefore names the pipeline release it was
validated against, and every job prints both at startup.

## v1.1.0 — 2026-09-14

Validated against **OmniQuant-seq v2.4.0** (previously v2.3.0).

### Added

- **Startup check of the pipeline API.** After sourcing the pipeline's modules
  the job verifies that all thirteen functions it calls are defined, and aborts
  naming the missing ones and the pipeline release this layer expects. Before,
  a function renamed upstream surfaced as `command not found` in the middle of a
  queued job, after the walltime had been spent.
- **Pipeline revision in the job header** (`git describe` in `$PIPELINE_DIR`,
  next to the validated release), so a set of results can be traced to the code
  that produced it without reconstructing which checkout was in `PIPELINE_DIR`
  that week.
- **`-notify` on every submitted job**, and `SIGUSR1`/`SIGUSR2` added to the
  cleanup trap. SGE sends those before the `h_rt` or `h_vmem` kill, so a job
  stopped by the queue now removes the half-written FASTQ or BAM of the sample
  it was on, exactly as it already did for `qdel` and Ctrl-C. A job cut off at
  its walltime used to leave those files for the resubmission to read as
  complete.

### Fixed

- **An absolute `RESULTS_DIR` is no longer prefixed with `WORKDIR`** when
  `submit_omniquant.sh` looks for the sample table. Pointing results at a
  scratch filesystem (`RESULTS_DIR=/scratch/$USER/results`) made the wrapper
  look under `$WORKDIR/scratch/$USER/results`, not find the table, and rebuild
  it on the submit host on every submission.
- **A relative `PIPELINE_DIR` is resolved to an absolute path** before the job
  changes into `WORKDIR`. It passed the startup check and then broke every
  `$PIPELINE_DIR/helpers/*.py` call made after the `cd` — `parse_samples` and
  `postprocess_all` — which is a failure two stages into a queued job.
- **`STAGE=refs` no longer demands the SRA-Toolkit, FastQC, MultiQC or BBDuk.**
  It runs `STAR` and `rsem-prepare-reference` and now checks only those, as the
  cheap stages already did — building references on a node or login host
  without the download and QC stack installed no longer aborts.

### Documentation

- New *Pipeline version* section: what the header line means, what the API
  check prints on a mismatch, and how to pin a matching pair.
- v2.4.0 changed the RunTable parser to stop guessing: runs with an unreadable
  `LibraryLayout` and runs with `LibrarySource=GENOMIC` are now dropped rather
  than processed on an assumption. Documented, with the `--assume-layout` /
  `--allow-genomic-source` overrides driven through `SAMPLES_FILE`, plus the
  `--star-overhang` read-length warning.
- v2.4.0 verifies downloaded references against NCBI's `md5checksums.txt`:
  a troubleshooting entry covers the outbound-HTTPS requirement this places on
  whichever host runs `STAGE=refs`, and the two ways around it.
- v2.4.0 infers strandedness from STAR and passes `--forward-prob` to RSEM;
  nothing to configure here, but the strand ratio is now a row of
  `STAR_mapping_QC_matrix.tsv` and the output layout says so.
- `environment.lock.txt` (274 exact builds) documented next to
  `environment.yml` as the reproducible way to create the environment.

### Testing

`test_sge.sh` grows from 17 to 24 checks, covering the API guard and its
message, the relative-`PIPELINE_DIR` resolution, the absolute-`RESULTS_DIR`
path, the array sizing and `-notify`.
`shellcheck -x` is clean on all four scripts.

## v1.0.0 — 2026-08-17

Initial SGE layer (`8b910ce`), validated against OmniQuant-seq v2.3.0:
`omniquant_sge.sh` (stages `all` / `refs` / `samples` / `sample` / `merge`),
`submit_omniquant.sh` (references → per-sample array → merge, chained with
`-hold_jid`), `config.example.sh`, `samples.txt.example` and `test_sge.sh`.
