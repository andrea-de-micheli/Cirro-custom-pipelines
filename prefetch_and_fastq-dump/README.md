# SRA Prefetch and FASTQ Conversion Pipeline

Combined pipeline that downloads SRA files using prefetch and optionally converts them to FASTQ format.

## Features

- Downloads SRA files using `prefetch` with NGC key authentication
- Optionally converts SRA files to compressed FASTQ format using `fasterq-dump`
- Unified resource allocation (disk size and CPU threads configurable)
- Simple checkbox UI to enable/disable FASTQ conversion

## Usage

1. Upload your NGC key file (.ngc)
2. Upload a text file with SRA IDs (one per line)
3. Check "Convert to FASTQ" if you want FASTQ conversion
4. Set CPU threads (for fasterq-dump, if converting)
5. Set disk size (500-1000 GB, default: 500 GB)
6. Click Run

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `convert_to_fastq` | Convert downloaded SRA files to FASTQ | false |
| `threads` | CPU threads for fasterq-dump | 4 |
| `disk_size` | Disk space per file (GB) | 500 |

## Output

**If FASTQ conversion is disabled:**
- SRA files in directories: `SRR_ID/SRR_ID.sra`

**If FASTQ conversion is enabled:**
- SRA files (as above)
- FASTQ files: `SRR_ID_1.fastq.gz`, `SRR_ID_2.fastq.gz` (paired-end) or `SRR_ID.fastq.gz` (single-end)

