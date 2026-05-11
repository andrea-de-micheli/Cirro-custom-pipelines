# BAM-to-FASTQ-cellranger

Convert **10x Cell Ranger BAM** files back to FASTQ using
[10x Genomics `bamtofastq`](https://github.com/10XGenomics/bamtofastq).
Accepts one or more input datasets, discovers all `.bam` files recursively,
and emits a single combined output dataset.

## What it does

1. For every selected input dataset, recursively finds every `*.bam` file.
2. Runs `bamtofastq` on each BAM — the tool reads the `@CO 10x_bam_to_fastq:`
   header comments and automatically reproduces the original FASTQ layout
   (paired-end `R1`/`R2`, optional index `I1`/`I2`, cell barcodes preserved).
3. Renames outputs from `bamtofastq_*` to `<bam_basename>_*` so each file
   carries its sample identity.
4. Publishes either:
   - One folder per BAM (`results/<bam_basename>/...`) — default
   - All FASTQs flattened into `results/` root — when `flatten=true`

The flattened layout is directly consumable by `valinor-cellranger`.

## Scope

**This pipeline is only safe for 10x / Cell Ranger BAMs.** Running it on a
generic DNA-/RNA-seq BAM will either fail (no `@CO 10x_bam_to_fastq` header)
or silently produce malformed FASTQs that downstream cellranger steps cannot
consume.

For non-10x BAMs use a separate pipeline based on `samtools fastq`.

## Paired-end vs single-end

`bamtofastq` infers this from the BAM header — no user input required.
For reference, a 10x BAM header contains lines like:

```
@CO 10x_bam_to_fastq:R1(CR:CY,UR:UY)
@CO 10x_bam_to_fastq:R2(SEQ:QUAL)
@CO 10x_bam_to_fastq:I1(BC:QT)
```

(For non-10x BAMs you would check `samtools view -c -f 1 <bam>` — count of
reads with the paired flag.)

## Form parameters

| Field | Default | Description |
|---|---|---|
| `threads` | 8 | CPU threads per BAM conversion (2-32). |
| `reads_per_fastq` | 50,000,000 | Max reads per output FASTQ chunk. |
| `flatten` | false | Place all FASTQs in `results/` root, prefixed with BAM name. |
| `memory_gb` | 16 | RAM per task (8-128). |
| `disk_gb` | 1000 | Worker disk per task (100-8000). |

## Input

One or more input datasets containing BAM files. The pipeline globs each
selected dataset's S3 path for `**/*.bam`.

Multi-dataset selection is enabled via `allowMultipleSources: true` in
[.cirro/process-definition.json](.cirro/process-definition.json) and
`$.inputs[*].dataPath` in [.cirro/process-input.json](.cirro/process-input.json).

### Selecting datasets that Cirro flagged as FAILED

Dataset status filtering (showing/hiding `FAILED`, `INCOMPLETE`, etc. in the
launch picker) is **not configured in this pipeline's files** — there is no
field for it in the Cirro process-definition schema. Status visibility is
controlled at launch time in the Cirro web UI: in the dataset picker, expand
the status filter and tick the statuses you want to be selectable
(e.g. include `FAILED` alongside `COMPLETED`). If you don't see the option,
you may need to ask your tenant admin or Cirro support to surface failed
datasets in the picker.

## Output structure

### `flatten = false` (default)

```
results/
├── sampleA/
│   ├── sampleA_S1_L001_R1_001.fastq.gz
│   ├── sampleA_S1_L001_R2_001.fastq.gz
│   └── sampleA_S1_L001_I1_001.fastq.gz
├── sampleB/
│   └── ...
└── pipeline_info/
```

### `flatten = true`

```
results/
├── sampleA_S1_L001_R1_001.fastq.gz
├── sampleA_S1_L001_R2_001.fastq.gz
├── sampleA_S1_L001_I1_001.fastq.gz
├── sampleB_S1_L001_R1_001.fastq.gz
├── ...
└── pipeline_info/
```

Use `flatten=true` when feeding straight into `valinor-cellranger`, which
expects FASTQs reachable by glob `${input_dir}/**/<fastq_id>_*.fastq.gz`.

## Repository structure

```
BAM-to-FASTQ-cellranger/
├── README.md
├── main.nf                       # Nextflow workflow
├── nextflow.config               # Base config (params, container, manifest)
└── .cirro/
    ├── process-definition.json   # Pipeline manifest (allowMultipleSources: true)
    ├── process-form.json         # Web UI form
    ├── process-input.json        # Form → Nextflow params mapping
    ├── process-compute.config    # AWS Batch overrides (retry, resources)
    └── preprocess.py             # Lightweight input logging
```

## Local test

```bash
cd BAM-to-FASTQ-cellranger
nextflow run main.nf \
    --input_dir /path/to/dir_with_bams \
    --outdir test_out \
    --flatten true
```

To sanity-check paired-end output:

```bash
zcat test_out/sampleA_S1_L001_R1_001.fastq.gz | wc -l
zcat test_out/sampleA_S1_L001_R2_001.fastq.gz | wc -l
# both should be equal and divisible by 4
```

## Container

`quay.io/biocontainers/10x_bamtofastq:1.4.1--h3ab6199_4`
