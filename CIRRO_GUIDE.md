# Understanding Cirro Custom Pipelines

## How Cirro Pipelines Work

When you run a pipeline in Cirro, here's what happens:

```
1. User fills out web form (process-form.json)
           ↓
2. Form values mapped to parameters (process-input.json)
           ↓
3. Preprocess script runs (preprocess.py)
   - Can modify parameters
   - Can create samplesheets
   - Has access to input dataset info
           ↓
4. Nextflow/Cromwell workflow executes (main.nf)
           ↓
5. Output files saved to new dataset
```

## The 6 Configuration Files

Your GitHub repo needs a `.cirro/` folder with these files:

```
your-repo/
├── main.nf                      # Your Nextflow pipeline
├── nextflow.config              # Nextflow configuration
└── .cirro/
    ├── process-form.json        # REQUIRED: Defines the web form UI
    ├── process-input.json       # REQUIRED: Maps form → Nextflow params
    ├── process-output.json      # OPTIONAL: For dashboard visualizations
    ├── process-compute.config   # OPTIONAL: Override Nextflow settings
    └── preprocess.py            # OPTIONAL: Pre-workflow Python logic
```

### 1. process-form.json
Defines what the user sees in the web interface. Uses JSON Schema format.

```json
{
    "ui": {},
    "form": {
        "title": "My Pipeline",
        "type": "object",
        "properties": {
            "my_param": {
                "title": "Human Readable Name",
                "description": "Help text for user",
                "type": "integer",
                "default": 4
            }
        }
    }
}
```

### 2. process-input.json
Maps form values to Nextflow parameters. This is how user inputs get to your pipeline.

```json
{
    "my_param": "$.dataset.params.my_param",
    "input_dir": "$.inputs[*].dataPath"
}
```

Key paths:
- `$.dataset.params.X` → User form values
- `$.inputs[*].dataPath` → S3 path(s) to input dataset(s)
- `$.dataset.dataPath` → S3 path for output

### 3. preprocess.py
Runs BEFORE Nextflow. Use it to:
- Create samplesheets dynamically
- Modify parameters
- Validate inputs

```python
from cirro.helpers.preprocess_dataset import PreprocessDataset

ds = PreprocessDataset.from_running()

# Access dataset info:
ds.files        # DataFrame of files in input dataset
ds.samplesheet  # Sample metadata from samplesheet.csv
ds.params       # User form parameters
ds.dataset      # Full dataset object (includes S3 paths)

# Modify parameters:
ds.add_param("input_files", "/path/to/files")
ds.remove_param("unwanted_param")

# Write files (e.g., samplesheet for Nextflow):
df.to_csv("samplesheet.csv", index=False)
```

### 4. process-compute.config
Override Nextflow settings (memory, containers, etc.)

```groovy
params {
    my_container = "quay.io/biocontainers/sra-tools:3.0.3--h87f3376_0"
}

process {
    withName: 'MY_PROCESS' {
        memory = '32 GB'
        cpus = 8
    }
}
```

## Your Dataset Structure

Looking at your screenshot, your SRA files are organized like:
```
Dataset: phs002498.v1.p1/
├── SRR16576717/
│   └── SRR16576717.sra
├── SRR16576718/
│   └── SRR16576718.sra
├── SRR16576719/
│   └── SRR16576719.sra
...
```

The preprocess script can find these with `ds.files` or we can use
Nextflow's `fromPath` with glob patterns.

## Nextflow Basics for Your Pipeline

```groovy
#!/usr/bin/env nextflow
nextflow.enable.dsl=2

// Parameters come from process-input.json
params.input_dir = null   // S3 path to input dataset
params.threads = 4        // From user form

// A "process" is a single step
process MY_STEP {
    container 'quay.io/biocontainers/tool:version'
    cpus params.threads
    memory '16 GB'
    
    publishDir "results", mode: 'copy'  // Where outputs go
    
    input:
    path input_file
    
    output:
    path "*.fastq.gz"
    
    script:
    """
    my_tool ${input_file}
    """
}

// The workflow connects processes
workflow {
    // Create a channel (stream of data)
    input_ch = Channel.fromPath("${params.input_dir}/**/*.sra")
    
    // Run the process on each item
    MY_STEP(input_ch)
}
```

## Key Concepts

1. **Channels**: Streams of data that flow through your pipeline
2. **Processes**: Individual steps (each runs in its own container)
3. **publishDir**: Where output files are saved
4. **Containers**: Each process runs in a Docker container (use BioContainers!)

## Finding Containers

Use BioContainers for pre-built bioinformatics tools:
- Browse: https://biocontainers.pro/
- Direct: `quay.io/biocontainers/<tool>:<version>`

For sra-tools: `quay.io/biocontainers/sra-tools:3.0.3--h87f3376_0`
