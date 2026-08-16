# OmniQuant-seq-sge

Non-interactive, batch-oriented layer that runs
[OmniQuant-seq](https://github.com/lordziegler/OmniQuant-seq) on Sun Grid
Engine clusters: references, one array task per sample, and a merge job.

```bash
cp config.example.sh /scratch/$USER/analysis/config.sh   # set PIPELINE_DIR and WORKDIR
cd /scratch/$USER/analysis && /path/to/submit_omniquant.sh
```

Full documentation: **[README_SGE.md](README_SGE.md)**.
