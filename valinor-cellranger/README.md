# valinor-cellranger

Run `cellranger multi` (GEX + CITE-seq + HTO demultiplexing) on AWS Batch via Cirro. One pool per invocation.

## Form inputs

| field | required | default | notes |
|---|---|---|---|
| `multi_config` | yes | — | cellranger multi config CSV (one pool) |
| `feature_reference` | yes | — | merged HTO + antibody feature reference CSV |
| `gex_reference_url` | yes | GRCh38 2024-A | URL or `s3://` URI to 10x reference tarball |
| `run_id` | yes | — | becomes `--id` and the output subdir name |
| `fastq_pattern` | no | `*.fastq.gz` | filter for which dataset files to stage |
| `create_bam` | no | `false` | adds BAM outputs if true |
| `cpus` | no | 16 | `--localcores` |
| `memory_gb` | no | 128 | `--localmem` |
| `disk_gb` | no | 2000 | scratch space per worker |

## Input dataset

Selected in the Cirro UI. The pipeline copies matching files onto the Batch worker with `aws s3 cp --recursive --include '${fastq_pattern}'` and rewrites `[libraries] fastqs` in the uploaded config to the staged path.

## Pipeline flow

```
DOWNLOAD_REFERENCE  ──▶  ref_dir
                                  ╲
                                   ─▶  CELLRANGER_MULTI  ──▶  ${outdir}/${run_id}/outs/**
input_dataset (S3)  ──(aws s3 cp)─▶
```

Outputs published to the Cirro output dataset:
- `${run_id}/outs/per_sample_outs/<sample>/` — one per HTO-demultiplexed sample
- `${run_id}/outs/multi/multiplexing_analysis/tag_calls_summary.csv`
- `${run_id}/outs/per_sample_outs/<sample>/web_summary.html`
- `multi_config.rewritten.csv` — the effective config that was run

## Config rewriting

At runtime, `CELLRANGER_MULTI` rewrites the uploaded `multi_config.csv`:
- `[gene-expression] reference` → the freshly-extracted GEX reference dir
- `[gene-expression] create-bam` → the form value
- `[feature] reference` → the staged feature reference CSV
- Every `[libraries]` row's `fastqs` column → the staged FASTQ dir

## Caveats

- **Container**: defaults to `quay.io/nf-core/cellranger:10.0.0`. If Cirro can't pull that image, override `process.container` in `.cirro/process-compute.config`.
- **Reference download**: ~20 GB pulled every run. A future version could mount a Cirro-shared reference dataset.
- **Feature reference IDs**: must not contain whitespace or parentheses; preprocess rejects these up front.

## Deploy to Cirro

```bash
cd /home/cirro/work/sra-to-fastq
git add valinor-cellranger && git commit -m "Add valinor-cellranger pipeline"
git push
# Then register the pipeline in Cirro pointing at this directory.
```
