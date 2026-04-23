# SRA to FASTQ Pipeline for Cirro

A minimal Nextflow pipeline to convert SRA files to compressed FASTQ format using `fasterq-dump`.

## What This Pipeline Does

1. Finds all `.sra` files in your input dataset (including subdirectories)
2. Converts each to FASTQ using `fasterq-dump --split-files`
3. Compresses outputs with gzip
4. Outputs all FASTQs to a single results directory

## Repository Structure

```
sra-to-fastq/
├── main.nf                        # The Nextflow pipeline
├── nextflow.config                # Base Nextflow configuration
├── README.md                      # This file
├── CIRRO_GUIDE.md                 # Detailed guide on how Cirro pipelines work
└── .cirro/
    ├── process-form.json          # Defines the web UI form
    ├── process-input.json         # Maps form values → Nextflow params
    ├── process-output.json        # Dashboard visualization config
    ├── process-compute.config     # Nextflow overrides for AWS
    └── preprocess.py              # Pre-workflow validation script
```

## Setup Instructions

### Step 1: Push to GitHub

```bash
# Clone or download this repository
cd sra-to-fastq

# Initialize git (if not already)
git init
git add .
git commit -m "Initial commit"

# Create GitHub repo and push
# Option A: GitHub CLI
gh repo create sra-to-fastq --public --push

# Option B: Manual
# Create repo on github.com, then:
git remote add origin https://github.com/YOUR_USERNAME/sra-to-fastq.git
git push -u origin main
```

### Step 2: Add Pipeline in Cirro

1. Go to **Pipelines** → **Custom Pipelines** → **Add Pipeline**

2. Fill in the form:

| Field | Value |
|-------|-------|
| **Process Type** | `Nextflow` |
| **Name** | `SRA to FASTQ` |
| **Description** | `Convert SRA files to compressed FASTQ format` |
| **Configuration Repository Name** | `YOUR_USERNAME/sra-to-fastq` |
| **Configuration Repository Type** | `GitHub Public` |
| **Configuration Repository Version** | `main` |
| **Configuration Repository Folder** | `.cirro` |
| **Pipeline Entrypoint File** | `main.nf` |
| **Available to Projects** | Select your project (e.g., `Cell2Patient`) |

3. Leave **"Pipeline code is in separate repository"** unchecked
4. Click **Create**

### Step 3: Run the Pipeline

1. Go to your project's **Datasets** page
2. Select your SRA dataset (e.g., `phs002498.v1.p1`)
3. Go to **Pipelines** and find **SRA to FASTQ**
4. Set the number of threads (4-8 recommended)
5. Click **Run**

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `threads` | CPU threads for fasterq-dump | 4 |

## Expected Output

For paired-end data, each SRA file produces:
- `{SRR_ID}_1.fastq.gz` - Read 1
- `{SRR_ID}_2.fastq.gz` - Read 2

For single-end data:
- `{SRR_ID}.fastq.gz`

## How the Files Work Together

```
User clicks "Run Pipeline"
         ↓
┌─────────────────────────────────────┐
│  process-form.json                  │  User sees form with "CPU Threads" slider
└─────────────────────────────────────┘
         ↓
┌─────────────────────────────────────┐
│  process-input.json                 │  Maps user input → Nextflow params:
│                                     │  - threads: 4 (from form)
│                                     │  - input_dir: s3://project/.../data
│                                     │  - outdir: s3://project/.../output
└─────────────────────────────────────┘
         ↓
┌─────────────────────────────────────┐
│  preprocess.py                      │  Validates inputs, logs file count
└─────────────────────────────────────┘
         ↓
┌─────────────────────────────────────┐
│  main.nf + nextflow.config          │  Runs fasterq-dump on each .sra file
│  + process-compute.config           │  (with memory retry logic)
└─────────────────────────────────────┘
         ↓
    Output Dataset with .fastq.gz files
```

## Troubleshooting

### Pipeline fails immediately
- Check that your SRA dataset was uploaded correctly
- Verify the files end with `.sra` extension

### Out of memory errors
- The pipeline auto-retries with more memory (up to 2x)
- For very large files, consider reducing parallel jobs

### No output files
- Check the Nextflow logs in Cirro
- Verify fasterq-dump completed successfully

## Resources

- [Cirro Documentation](https://docs.cirro.bio/)
- [Nextflow Documentation](https://www.nextflow.io/docs/latest/)
- [fasterq-dump Guide](https://github.com/ncbi/sra-tools/wiki/HowTo:-fasterq-dump)
- [BioContainers](https://biocontainers.pro/)
