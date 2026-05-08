# valinor-cellranger

Run `cellranger multi` (5' or 3' GEX + CITE-seq antibodies + HTO sample demultiplexing) on AWS Batch via Cirro. Batched: one form submission fans out to N parallel `cellranger multi` invocations, one per `run_id` in the samplesheet.

## What you upload

| Field | Required | Default | Notes |
|---|---|---|---|
| `libraries_sheet` | yes | — | CSV mapping each library FASTQ prefix to a pool |
| `samples_sheet` | yes | — | CSV mapping each demultiplexed sample to its hashtag(s) |
| `feature_reference` | yes | — | One 10x feature reference CSV — HTOs and antibodies in the same file, distinguished by `feature_type` |
| `gex_reference_url` | yes | GRCh38 2024-A | URL or `s3://` URI to the 10x GEX reference tarball |
| `create_bam` | no | `false` | Adds position-sorted BAMs (large) |
| `cpus` | no | 30 | `--localcores` per pool |
| `memory_gb` | no | 200 | `--localmem` per pool |
| `disk_gb` | no | 2000 | Worker scratch per pool |

The selected Cirro **input dataset** is the FASTQ source. The pipeline pulls only the FASTQs whose object names start with the `fastq_id` values listed for each pool (it does not stage the whole dataset).

## Samplesheet formats

### `libraries_sheet`

One row per `(pool, library)`. A pool with GEX + a CITE/HTO library is two rows; a pool sequenced as separate antibody and CMO libraries is three rows.

```csv
run_id,fastq_id,library_type
MIX1_Prep1,Mix102-10-21-Prep1,Gene Expression
MIX1_Prep1,Mix102-10-21-Prep1-CS,Multiplexing Capture
MIX1_Prep1,Mix102-10-21-Prep1-CS,Antibody Capture
MIX2_Prep1,Mix102-11-X-Prep1,Gene Expression
MIX2_Prep1,Mix102-11-X-Prep1-CS,Multiplexing Capture
MIX2_Prep1,Mix102-11-X-Prep1-CS,Antibody Capture
```

| Column | Meaning |
|---|---|
| `run_id` | Output directory / cellranger `--id`. Must be unique per pool and a valid filename. |
| `fastq_id` | The library prefix in the FASTQ filenames (`<fastq_id>_S?_L00?_R?_001.fastq.gz`). The pipeline copies any object whose key starts with `<fastq_id>` from the input dataset onto the worker. |
| `library_type` | One of: `Gene Expression`, `Antibody Capture`, `Multiplexing Capture`, `CRISPR Guide Capture`, `VDJ`, `VDJ-T`, `VDJ-B`. |

Each `run_id` must include exactly one `Gene Expression` row and at least one `Multiplexing Capture` row (HTO library). Same `fastq_id` may appear under two `library_type`s (one library, multiple feature classes).

### `samples_sheet`

One row per demultiplexed sample.

```csv
run_id,sample_id,hashtag_ids
MIX1_Prep1,Patient_001_T1,HTO1
MIX1_Prep1,Patient_001_T2,HTO2
MIX1_Prep1,Patient_002_T1,HTO3
MIX1_Prep1,Patient_002_T2,HTO4
MIX2_Prep1,Patient_003_T1,HTO1
MIX2_Prep1,Patient_003_T2,HTO2
```

| Column | Meaning |
|---|---|
| `run_id` | Must match a `run_id` in `libraries_sheet`. |
| `sample_id` | Becomes a `per_sample_outs/<sample_id>/` directory. |
| `hashtag_ids` | One HTO `id` from `feature_reference` (with `feature_type=Multiplexing Capture`). For multi-tagged samples, pipe-separate: `HTO1\|HTO2`. |

Every value in `hashtag_ids` is checked against the `feature_reference` upfront — typos fail in the control plane, not after Batch boot.

## Feature reference format

Standard 10x feature reference CSV. **HTO rows must use `feature_type=Multiplexing Capture`; antibody (CITE-seq) rows must use `feature_type=Antibody Capture`.** This is how the pipeline tells them apart and is also what cellranger consumes — HTO ids referenced in the `samples_sheet` are matched to `Multiplexing Capture` rows here.

```csv
id,name,read,pattern,sequence,feature_type
HTO1,HTO1,R2,5P(BC),GTCAACTCTTTAGCG,Multiplexing Capture
HTO2,HTO2,R2,5P(BC),TGATGGCCTATTGGG,Multiplexing Capture
HTO3,HTO3,R2,5P(BC),TTCCGCCTCTCTTTG,Multiplexing Capture
HTO4,HTO4,R2,5P(BC),AGTAAGTTCAGCGTA,Multiplexing Capture
CD3,CD3_TotalSeqC,R2,5P(BC),CTCATTGTAACTCCT,Antibody Capture
CD4,CD4_TotalSeqC,R2,5P(BC),TGTTCCCGCTCAACT,Antibody Capture
CD8a,CD8a_TotalSeqC,R2,5P(BC),GCGCAACTTGATGAT,Antibody Capture
```

Constraints (validated in preprocess):
- At least one row with `feature_type=Multiplexing Capture` (HTO).
- No `id` may contain whitespace or parentheses.
- Sequences and `pattern` follow 10x conventions — pipeline does not transform them.

If you have separate HTO and antibody CSVs locally, concatenate them into one file before upload (drop the duplicate header row).

## Pipeline flow

```
DOWNLOAD_REFERENCE  ──────▶  ref_dir
                                    ╲
samplesheet ──preprocess──▶ pools.tsv ─▶  CELLRANGER_MULTI  ──▶  ${outdir}/${run_id}/outs/**
                            (per-pool                ▲
                            multi_config.csv)        │
input_dataset (S3)  ───(aws s3 cp --include 'fastq_id*')─┘
```

Per pool, `CELLRANGER_MULTI`:
1. Pulls only the FASTQs whose names start with this pool's `fastq_id` values.
2. Substitutes the absolute paths of the staged ref / feature ref / FASTQ dir into the per-pool multi_config CSV.
3. Runs `cellranger multi --id=<run_id>`.

Outputs published per pool:
- `${run_id}/outs/per_sample_outs/<sample_id>/` — per demultiplexed sample
- `${run_id}/outs/per_sample_outs/<sample_id>/web_summary.html`
- `${run_id}/outs/multi/multiplexing_analysis/tag_calls_summary.csv`
- `${run_id}.multi_config.resolved.csv` — the effective config that ran

## Caveats

- **Default container** is `quay.io/nf-core/cellranger:10.0.0`. Override `process.container` in `.cirro/process-compute.config` if the Batch environment can't pull it.
- **GEX reference** is downloaded once per pipeline invocation (~20 GB). Use an `s3://` URI inside Cirro storage to avoid the public CDN pull on every run.
- **Same `fastq_id` across pools is not supported.** Each `fastq_id` value is the FASTQ-prefix glob for staging, so two pools sharing a prefix would stage and demultiplex each other's reads. If your sequencing layout shares prefixes, rename or move FASTQs before uploading the input dataset.
- **One `feature_reference` per submission.** All pools in one form submission share the same HTO + antibody panel. If panels differ across pools, run separate submissions.

## Deploy to Cirro

```bash
cd /home/cirro/work/Cirro-custom-pipelines
git add valinor-cellranger && git commit -m "Update valinor-cellranger to samplesheet-driven batched mode"
git push
# Then register the pipeline in Cirro pointing at this directory.
```
