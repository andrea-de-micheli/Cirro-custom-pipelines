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

Each `run_id` must include exactly one `Gene Expression` row plus the library that carries the demux tags (`Antibody Capture` for cell-hashing mode, `Multiplexing Capture` for CMO mode). Same `fastq_id` may appear under two `library_type`s (one library, multiple feature classes).

### `samples_sheet`

One row per demultiplexed sample. The third column name selects the cellranger demux flow — use exactly one of `hashtag_ids` (cell-hashing) or `cmo_ids` (CMO / Multiplexing Capture). Whichever you pick is passed through verbatim to the generated `[samples]` section, which is exactly how cellranger picks the mode.

**Cell-hashing mode** (HTO antibodies; produces `tag_calls_summary.csv`):

```csv
run_id,sample_id,hashtag_ids
MIX1_Prep1,Patient_001_T1,HTO1
MIX1_Prep1,Patient_001_T2,HTO2
MIX1_Prep1,Patient_002_T1,HTO3
MIX1_Prep1,Patient_002_T2,HTO4
```

**CMO / Multiplexing Capture mode** (cellranger-managed CMO library):

```csv
run_id,sample_id,cmo_ids
MIX1_Prep1,Patient_001_T1,CMO301
MIX1_Prep1,Patient_001_T2,CMO302
```

| Column | Meaning |
|---|---|
| `run_id` | Must match a `run_id` in `libraries_sheet`. |
| `sample_id` | Becomes a `per_sample_outs/<sample_id>/` directory. |
| `hashtag_ids` *or* `cmo_ids` | One HTO/CMO `id` from `feature_reference`. For multi-tagged samples, pipe-separate: `HTO1\|HTO2`. |

Every tag id is checked against the `feature_reference` upfront — typos fail in the control plane, not after Batch boot.

## Feature reference format

Standard 10x feature reference CSV. The pipeline doesn't enforce a particular `feature_type` for the HTO/CMO rows — it just checks that every id you reference in `samples_sheet` is present here. **Use the `feature_type` value that matches your demux mode**, since cellranger reads it:

| Demux mode | HTO `feature_type` | HTO library `library_type` |
|---|---|---|
| Cell hashing (`hashtag_ids`) | `Antibody Capture` | `Antibody Capture` |
| CMO (`cmo_ids`) | `Multiplexing Capture` | `Multiplexing Capture` |

**Example — cell-hashing mode** (HTO antibodies + CITE-seq panel in one CSV):

```csv
id,name,read,pattern,sequence,feature_type
HTO1,HTO1,R2,5PNNNNNNNNNN(BC),GTCAACTCTTTAGCG,Antibody Capture
HTO2,HTO2,R2,5PNNNNNNNNNN(BC),TGATGGCCTATTGGG,Antibody Capture
HTO3,HTO3,R2,5PNNNNNNNNNN(BC),TTCCGCCTCTCTTTG,Antibody Capture
HTO4,HTO4,R2,5PNNNNNNNNNN(BC),AGTAAGTTCAGCGTA,Antibody Capture
CD3,CD3_TotalSeqC,R2,5PNNNNNNNNNN(BC),CTCATTGTAACTCCT,Antibody Capture
CD4,CD4_TotalSeqC,R2,5PNNNNNNNNNN(BC),TGTTCCCGCTCAACT,Antibody Capture
```

**Example — CMO mode**:

```csv
id,name,read,pattern,sequence,feature_type
CMO301,CMO301,R2,5P(BC),ATGAGGAATTCCTGC,Multiplexing Capture
CMO302,CMO302,R2,5P(BC),CATGCCAATAGAGCG,Multiplexing Capture
CD3,CD3_TotalSeqC,R2,5PNNNNNNNNNN(BC),CTCATTGTAACTCCT,Antibody Capture
```

Constraints (validated in preprocess):
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
