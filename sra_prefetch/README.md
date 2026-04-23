# SRA Prefetch Pipeline for Cirro

A simple Nextflow pipeline to download SRA files using `prefetch` with NGC key authentication.

## What This Pipeline Does

1. Accepts an NGC key file upload
2. Accepts a list of SRA IDs (one per line)
3. Downloads each SRA file using `prefetch --ngc KEY.ngc`
4. Outputs all downloaded SRA files to the results directory

## Repository Structure

```
sra_prefetch/
├── main.nf                        # The Nextflow pipeline
├── nextflow.config                # Base Nextflow configuration
├── README.md                      # This file
└── .cirro/
    ├── process-form.json          # Defines the web UI form
    ├── process-input.json         # Maps form values → Nextflow params
    └── preprocess.py              # Handles NGC file and SRA list processing
```

## Usage

### Step 1: Prepare Your Inputs

1. **NGC Key File**: Download your NGC key file from the NCBI dbGaP authorized access portal
2. **SRA IDs**: Prepare a list of SRA IDs you want to download, one per line:
   ```
   SRR12345678
   SRR87654321
   SRR11111111
   ```

### Step 2: Run in Cirro

1. Go to your project's **Datasets** page
2. Select an input dataset (or create an empty one - the pipeline doesn't require input files)
3. Go to **Pipelines** and find **SRA Prefetch**
4. Upload your NGC key file
5. Paste your list of SRA IDs in the text area
6. Click **Run**

## How It Works

```
User uploads NGC file + pastes SRA list
           ↓
┌─────────────────────────────────────┐
│  preprocess.py                      │  Extracts NGC file from data URL
│                                     │  Writes SRA list to file
└─────────────────────────────────────┘
           ↓
┌─────────────────────────────────────┐
│  main.nf                            │  Runs prefetch for each SRA ID
│                                     │  with the NGC key
└─────────────────────────────────────┘
           ↓
    Output Dataset with .sra files
```

## Output Structure

Each SRA file is downloaded into its own directory:
```
results/
├── SRR12345678/
│   └── SRR12345678.sra
├── SRR87654321/
│   └── SRR87654321.sra
└── ...
```

## Requirements

- NGC key file (.ngc) from NCBI dbGaP authorized access
- Valid SRA IDs for controlled-access datasets
- Sufficient storage space (SRA files can be large)

## Troubleshooting

### Pipeline fails with authentication error
- Verify your NGC key file is valid and not expired
- Ensure you have authorized access to the SRA datasets you're requesting

### Some SRAs fail to download
- Check that the SRA IDs are correct
- Verify you have access permissions for those specific datasets
- Check the Nextflow logs in Cirro for specific error messages

### Out of disk space
- SRA files can be very large (hundreds of GB)
- Consider downloading in smaller batches
- Adjust the disk allocation in `process-compute.config` if needed

## Resources

- [Cirro Documentation](https://docs.cirro.bio/)
- [NCBI SRA Tools Documentation](https://github.com/ncbi/sra-tools)
- [NCBI dbGaP](https://www.ncbi.nlm.nih.gov/gap/) - For obtaining NGC keys

