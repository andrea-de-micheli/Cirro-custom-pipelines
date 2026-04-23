#!/usr/bin/env nextflow
nextflow.enable.dsl=2

/*
 * valinor-cellranger
 * Runs `cellranger multi` on an input FASTQ dataset using a user-supplied
 * multi_config.csv and feature reference CSV. One invocation = one pool.
 */

// Parameters (populated by Cirro via .cirro/process-input.json)
params.multi_config        = null
params.feature_reference   = null
params.gex_reference_url   = 'https://cf.10xgenomics.com/supp/cell-exp/refdata-gex-GRCh38-2024-A.tar.gz'
params.run_id              = null
params.fastq_pattern       = '*.fastq.gz'
params.create_bam          = false
params.cpus                = 16
params.memory_gb           = 128
params.disk_gb             = 2000
params.input_dir           = null
params.outdir              = 'results'

log.info """
    valinor-cellranger
    ==================
    run_id            : ${params.run_id}
    multi_config      : ${params.multi_config}
    feature_reference : ${params.feature_reference}
    gex_reference_url : ${params.gex_reference_url}
    input_dir         : ${params.input_dir}
    fastq_pattern     : ${params.fastq_pattern}
    create_bam        : ${params.create_bam}
    cpus              : ${params.cpus}
    memory_gb         : ${params.memory_gb}
    disk_gb           : ${params.disk_gb}
    outdir            : ${params.outdir}
    """
    .stripIndent()

if (!params.multi_config)      { error "multi_config is required" }
if (!params.feature_reference) { error "feature_reference is required" }
if (!params.run_id)            { error "run_id is required" }
if (!params.input_dir)         { error "input_dir is required" }

/*
 * Download and extract the 10x GEX reference fresh each run (self-contained).
 */
process DOWNLOAD_REFERENCE {
    tag "${url.tokenize('/').last()}"

    container 'quay.io/biocontainers/curl:7.80.0'

    cpus 2
    memory '4 GB'
    disk '60 GB'

    input:
    val url

    output:
    path 'reference', emit: ref_dir

    script:
    """
    set -euo pipefail
    mkdir -p reference
    if [[ "${url}" == s3://* ]]; then
        aws s3 cp "${url}" reference.tar.gz
    else
        curl -fsSL "${url}" -o reference.tar.gz
    fi
    tar -xzf reference.tar.gz -C reference --strip-components=1
    rm -f reference.tar.gz
    """
}

/*
 * Run cellranger multi.
 *
 * Stages a subset of FASTQs from the input dataset, rewrites the user's
 * multi_config.csv to point at staged paths, then invokes cellranger.
 */
process CELLRANGER_MULTI {
    tag "${run_id}"

    container 'quay.io/nf-core/cellranger:10.0.0'

    cpus   { params.cpus }
    memory { "${params.memory_gb} GB" }
    disk   { "${params.disk_gb} GB" }

    publishDir "${params.outdir}", mode: 'copy', pattern: "${run_id}/outs/**"
    publishDir "${params.outdir}", mode: 'copy', pattern: "${run_id}/_log"
    publishDir "${params.outdir}", mode: 'copy', pattern: "${run_id}/*.mri.tgz"
    publishDir "${params.outdir}", mode: 'copy', pattern: "multi_config.rewritten.csv"

    input:
    path config
    path feature_ref
    path ref_dir
    val  input_dir
    val  run_id
    val  fastq_pattern
    val  create_bam

    output:
    path "${run_id}/outs/**",      emit: outs
    path "${run_id}/_log",         emit: run_log, optional: true
    path "${run_id}/*.mri.tgz",    emit: mri,     optional: true
    path "multi_config.rewritten.csv", emit: rewritten_config

    script:
    """
    set -euo pipefail

    echo "=== Staging FASTQs from ${input_dir} matching '${fastq_pattern}' ==="
    mkdir -p fastqs
    aws s3 cp --recursive --exclude '*' --include '${fastq_pattern}' \\
        "${input_dir}" fastqs/
    echo "Staged \$(ls fastqs | wc -l) FASTQ files."

    echo "=== Rewriting multi_config paths ==="
    # Absolute paths for cellranger (it resolves paths relative to pwd otherwise).
    REF_ABS="\$(readlink -f ${ref_dir})"
    FEAT_ABS="\$(readlink -f ${feature_ref})"
    FQ_ABS="\$(readlink -f fastqs)"

    python3 - <<PY
import re, pathlib
src = pathlib.Path("${config}").read_text()
ref_abs  = "\${REF_ABS}"
feat_abs = "\${FEAT_ABS}"
fq_abs   = "\${FQ_ABS}"
create_bam = "${create_bam}".lower()

lines = src.splitlines()
out, section = [], None
for line in lines:
    s = line.strip()
    if s.startswith("[") and s.endswith("]"):
        section = s.strip("[]").lower()
        out.append(line); continue
    if section == "gene-expression":
        if line.lower().startswith("reference,"):
            line = f"reference,{ref_abs}"
        elif line.lower().startswith("create-bam,"):
            line = f"create-bam,{create_bam}"
    elif section == "feature":
        if line.lower().startswith("reference,"):
            line = f"reference,{feat_abs}"
    elif section == "libraries":
        # Header row: fastq_id,fastqs,feature_types
        parts = line.split(",")
        if len(parts) >= 3 and parts[0].strip() and parts[0].strip().lower() != "fastq_id":
            parts[1] = fq_abs
            line = ",".join(parts)
    out.append(line)

# Ensure create-bam present
if not any(l.lower().startswith("create-bam,") for l in out):
    # Insert under [gene-expression] section
    new = []
    inserted = False
    for l in out:
        new.append(l)
        if not inserted and l.strip().lower() == "[gene-expression]":
            inserted = True
        elif inserted and (l.strip().startswith("[") or l.strip() == "") and not l.strip().lower() == "[gene-expression]":
            if not inserted:
                pass
    out = new

pathlib.Path("multi_config.rewritten.csv").write_text("\\n".join(out) + "\\n")
print("Rewritten config:")
print(pathlib.Path("multi_config.rewritten.csv").read_text())
PY

    echo "=== Running cellranger multi ==="
    cellranger multi \\
        --id=${run_id} \\
        --csv=multi_config.rewritten.csv \\
        --localcores=${task.cpus} \\
        --localmem=${params.memory_gb} \\
        --disable-ui

    echo "=== Done ==="
    ls -la ${run_id}/outs/ || true
    """
}

workflow {
    ref_ch = DOWNLOAD_REFERENCE(Channel.value(params.gex_reference_url)).ref_dir

    CELLRANGER_MULTI(
        file(params.multi_config),
        file(params.feature_reference),
        ref_ch,
        params.input_dir,
        params.run_id,
        params.fastq_pattern,
        params.create_bam
    )
}

workflow.onComplete {
    log.info "Pipeline completed at: ${workflow.complete}"
    log.info "Execution status: ${workflow.success ? 'OK' : 'Failed'}"
}
