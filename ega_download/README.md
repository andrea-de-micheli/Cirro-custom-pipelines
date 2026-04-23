# EGA Download Pipeline for Cirro

A minimal Nextflow pipeline to download data from the European Genome-phenome Archive (EGA) using [pyega3](https://github.com/EGA-archive/ega-download-client) with username/password authentication.

## What This Pipeline Does

1. Accepts EGA account credentials (username + password) via the web form
2. Accepts a list of EGA accessions (one per line) — dataset IDs (`EGAD*`) and/or file IDs (`EGAF*`)
3. Runs `pyega3 fetch` for each accession and downloads the data
4. Outputs all downloaded files to the results dataset

## Repository Structure

```
ega_download/
├── main.nf                        # The Nextflow pipeline
├── nextflow.config                # Base Nextflow configuration
├── README.md                      # This file
└── .cirro/
    ├── process-form.json          # Defines the web UI form
    ├── process-input.json         # Maps form values → Nextflow params
    ├── process-compute.config     # Compute overrides (retry, maxForks)
    └── preprocess.py              # Builds credentials JSON; decodes accession list
```

## Usage

### Step 1: Prepare Your Inputs

1. **EGA Account**: Register at [ega-archive.org](https://ega-archive.org/) and ensure you have authorized access to the datasets you intend to download.
2. **Accession List**: Create a text file with one EGA accession per line. You can mix dataset and file accessions:
   ```
   EGAD00001003338
   EGAF00001234567
   EGAF00001234568
   # lines starting with '#' are ignored
   ```

### Step 2: Run in Cirro

1. Go to your project's **Datasets** page
2. Select (or create) an input dataset
3. Go to **Pipelines** and find **EGA Download**
4. Enter your EGA username (email) and password
5. Upload your accession list file
6. (Optional) Adjust parallel connections and max file size
7. Click **Run**

## How It Works

```
User submits username + password + accession list
           ↓
┌─────────────────────────────────────┐
│  preprocess.py                      │  Builds ega_credentials.json from
│                                     │  username/password, then removes
│                                     │  them from the run params.
│                                     │  Decodes accession list to file.
└─────────────────────────────────────┘
           ↓
┌─────────────────────────────────────┐
│  main.nf                            │  Runs `pyega3 -cf creds.json fetch`
│                                     │  for each accession (parallelized,
│                                     │  capped at maxForks = 4).
└─────────────────────────────────────┘
           ↓
    Output Dataset with downloaded files
```

## Output Structure

Each accession is downloaded into its own directory:

```
results/
├── EGAD00001003338/
│   └── ... (per-file subdirectories with decrypted data + md5)
├── EGAF00001234567/
│   └── ...
└── ...
```

pyega3 performs MD5 verification on each downloaded file automatically.

## Credentials & Security

- Username and password are collected via the form, used by `preprocess.py` to build a local `ega_credentials.json`, and then **removed from the Nextflow params log** before the workflow runs.
- The credentials file is written with mode `0600` and staged into each task workdir by Nextflow — same security posture as the NGC key in the `sra_prefetch` pipeline.
- EGA has not migrated to an API-key / OAuth model; pyega3 requires username + password.

## Requirements

- A registered EGA account with authorized access to the target datasets
- Valid EGA accession IDs (`EGAD*` or `EGAF*`)
- Sufficient storage space — EGA files can be large

## Troubleshooting

### Authentication error
- Verify username and password at [ega-archive.org](https://ega-archive.org/) by logging in to the web portal.
- Confirm your account has authorized access to the specific dataset(s) you're requesting.

### Some accessions fail but others succeed
- Check that the accession IDs are correct and that you have access to each one.
- EGA throttles per account — the pipeline caps concurrent downloads at `maxForks = 4`, but on very large lists you may still hit rate limits. Failed tasks retry up to twice automatically.

### Out of disk space
- Increase **Max Expected File Size (GB)** in the form.
- Retries double the allocated disk on each attempt (up to 3× the configured max).

## Resources

- [Cirro Documentation](https://docs.cirro.bio/)
- [pyega3 (EGA download client)](https://github.com/EGA-archive/ega-download-client)
- [European Genome-phenome Archive](https://ega-archive.org/)
