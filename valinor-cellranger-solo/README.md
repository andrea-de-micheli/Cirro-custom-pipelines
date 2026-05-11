# valinor-cellranger-solo

Run **`cellranger count`** (GEX-only, non-multiplexed) per sample, on AWS Batch
via Cirro. Samples and library types are auto-detected from FASTQ filenames —
no samplesheet required.

Pairs with [`BAM-to-FASTQ-cellranger`](../BAM-to-FASTQ-cellranger/) as a
downstream consumer: BAM → FASTQ (flatten=true) → `cellranger count`.

## What it does

1. Globs `**/*.fastq.gz` across one or more selected input datasets.
2. Parses each filename `<sample>.<libtype>.*_S<n>_L<n>_R<n>_001.fastq.gz`:
   - `<sample>` = first dot-separated token
   - `<libtype>` = second token, mapped to a Cell Ranger library_type
   - `<fastq_id>` = the full prefix before `_S<n>_L<n>_R<n>_001`
3. Keeps only **Gene Expression** libraries; logs and skips VDJ / Antibody Capture / Multiplexing Capture.
4. Groups remaining FASTQs by sample. If the same sample has multiple `fastq_id`
   prefixes (e.g. resequenced on multiple flowcells), they're passed as
   comma-separated values to `cellranger count --sample=`.
5. Runs one `cellranger count` task per sample on AWS Batch.

## Filename convention

| Suffix marker (uppercase) | library_type | Behavior |
|---|---|---|
| `GEX`, `5GEX`, `3GEX`, `RNA`, `MRNA` | Gene Expression | **Processed** |
| (no suffix) | Gene Expression | **Processed** (fallback) |
| `BCR`, `IGH`, `IGK`, `IGL`, `VDJ_B`, `VDJB` | VDJ-B | Skipped (logged) |
| `TCR`, `TRA`, `TRB`, `TRD`, `TRG`, `VDJ_T`, `VDJT` | VDJ-T | Skipped (logged) |
| `HTO`, `HASH`, `HASHING` | Antibody Capture | Skipped (logged) |
| `ADT`, `CITE`, `SURFACE` | Antibody Capture | Skipped (logged) |
| `CMO`, `MULTI`, `MULTIPLEX` | Multiplexing Capture | Skipped (logged) |
| anything else | `Unknown(...)` | Skipped (logged) |

### Examples

```
nBM01s.5GEX.possorted_genome_bam_S1_L001_R1_001.fastq.gz
└─sample: nBM01s   libtype: 5GEX → Gene Expression   fastq_id: nBM01s.5GEX.possorted_genome_bam   ✓ processed

MGUS01s.BCR.all_contig_S1_L001_R1_001.fastq.gz
└─sample: MGUS01s  libtype: BCR  → VDJ-B             ✗ skipped (not GEX)

PatientA_S1_L001_R1_001.fastq.gz
└─sample: PatientA libtype: (none) → Gene Expression  ✓ processed (fallback)
```

## Form parameters

| Field | Required | Default | Notes |
|---|---|---|---|
| `gex_reference_url` | yes | GRCh38 2024-A | URL or `s3://` URI to the 10x GEX reference tarball |
| `libraries_sheet` | no | — | Optional CSV override. See below. |
| `create_bam` | no | `false` | Position-sorted BAM output (large) |
| `cpus` | no | 30 | `cellranger --localcores` per sample |
| `memory_gb` | no | 200 | `cellranger --localmem` per sample |
| `disk_gb` | no | 2000 | Worker scratch per sample |

## Auto-detection vs `libraries_sheet` override

For files that don't follow the filename convention, you can supply an
optional `libraries_sheet` CSV. Rows in the sheet override the auto-detected
values for matching `fastq_id`s; everything not in the sheet is still
auto-detected.

```csv
sample_id,fastq_id,library_type
PatientA,weird_filename_prefix,Gene Expression
PatientB,another_one,Gene Expression
```

Any row with `library_type != "Gene Expression"` is processed but then
skipped by the GEX filter — i.e. you can use the sheet to *exclude* files by
relabeling them as non-GEX.

## Multi-dataset input

`allowMultipleSources: true` is set in [.cirro/process-definition.json](.cirro/process-definition.json).
In the Cirro launch UI you can select multiple input datasets — every selected
dataset's S3 path is globbed for FASTQs and the results are combined into one
output dataset.

## Output

```
${outdir}/
├── ${sample_id_1}/
│   └── outs/
│       ├── web_summary.html
│       ├── metrics_summary.csv
│       ├── filtered_feature_bc_matrix/
│       ├── raw_feature_bc_matrix/
│       └── ... (cellranger count outputs)
├── ${sample_id_2}/
│   └── outs/...
└── pipeline_info/
    ├── timeline.html
    ├── report.html
    └── trace.txt
```

`${sample_id}` is the auto-detected sample name (the first dot-separated
token of the FASTQ filename), e.g. `nBM01s`, `MGUS04s`, `PatientA`.

## Repository structure

```
valinor-cellranger-solo/
├── README.md
├── main.nf                       # Workflow + filename auto-detect logic
├── nextflow.config               # Base config (params, manifest, reports)
└── .cirro/
    ├── process-definition.json   # Pipeline manifest (allowMultipleSources: true)
    ├── process-form.json         # Web UI form
    ├── process-input.json        # Form → Nextflow params mapping
    ├── process-compute.config    # AWS Batch overrides (retry-then-ignore)
    └── preprocess.py             # Decodes optional libraries_sheet data-URL
```

## Local test

```bash
cd valinor-cellranger-solo
nextflow run main.nf \
    --input_dir /path/to/flat_fastqs \
    --outdir test_out
```

Then verify per-sample outputs:

```bash
ls test_out/nBM01s/outs/web_summary.html
```

## Out of scope

- **VDJ / Antibody Capture / Multiplexing** — files are detected and skipped.
  For VDJ use a separate `cellranger vdj` pipeline; for multiplexed runs use
  the original `valinor-cellranger`.
- **CITE-seq combined GEX + Antibody** via `cellranger count --libraries=...`.
- Cross-sample QC reports — each sample is its own `cellranger count` run.

## Container

`quay.io/nf-core/cellranger:10.0.0`
