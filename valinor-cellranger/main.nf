#!/usr/bin/env nextflow
nextflow.enable.dsl=2

/*
 * valinor-cellranger
 *
 * Runs `cellranger multi` across one or more pools driven by a samplesheet.
 * One CELLRANGER_MULTI task per run_id. Reference is downloaded once and
 * fanned out as a value channel.
 */

// Parameters (populated by Cirro via .cirro/process-input.json + preprocess.py)
params.pool_dir          = null      // Directory containing pools.tsv + per-pool multi_config CSVs (preprocess output)
params.feature_reference = null      // Decoded feature_reference.csv
params.gex_reference_url = 'https://cf.10xgenomics.com/supp/cell-exp/refdata-gex-GRCh38-2024-A.tar.gz'
params.create_bam        = false
params.cpus              = 30
params.memory_gb         = 200
params.disk_gb           = 2000
params.input_dir         = null      // S3 path to the FASTQ input dataset
params.outdir            = 'results'

if (!params.pool_dir)          { error "pool_dir is required (set by preprocess)" }
if (!params.feature_reference) { error "feature_reference is required" }
if (!params.input_dir)         { error "input_dir is required" }

log.info """
    valinor-cellranger
    ==================
    pool_dir          : ${params.pool_dir}
    feature_reference : ${params.feature_reference}
    gex_reference_url : ${params.gex_reference_url}
    input_dir         : ${params.input_dir}
    create_bam        : ${params.create_bam}
    cpus              : ${params.cpus}
    memory_gb         : ${params.memory_gb}
    disk_gb           : ${params.disk_gb}
    outdir            : ${params.outdir}
    """
    .stripIndent()


/*
 * Download and extract the 10x GEX reference once per pipeline run.
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
 * Run cellranger multi for one pool.
 *
 *  - Stages just the FASTQs whose object names start with this pool's
 *    fastq_id values, via repeated `aws s3 cp --include`.
 *  - Substitutes the three placeholders left by preprocess
 *    (__GEX_REF__, __FEATURE_REF__, __FASTQS__) into the multi_config.
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
    publishDir "${params.outdir}", mode: 'copy', pattern: "${run_id}.multi_config.resolved.csv"

    input:
    tuple val(run_id), path(config), val(fastq_ids)
    path  feature_ref
    path  ref_dir
    val   input_dir

    output:
    path "${run_id}/outs/**",                    emit: outs
    path "${run_id}/_log",                       emit: run_log,  optional: true
    path "${run_id}/*.mri.tgz",                  emit: mri,      optional: true
    path "${run_id}.multi_config.resolved.csv",  emit: resolved_config

    script:
    def includes = fastq_ids.tokenize('|').collect { "--include '${it}*'" }.join(' ')
    """
    set -euo pipefail

    echo "=== Staging FASTQs from ${input_dir} for pool ${run_id} ==="
    echo "fastq_id prefixes: ${fastq_ids}"
    mkdir -p fastqs
    aws s3 cp --recursive --exclude '*' ${includes} \\
        "${input_dir}" fastqs/
    n_fq=\$(find fastqs -type f -name '*.fastq.gz' | wc -l)
    echo "Staged \${n_fq} FASTQ files."
    if [ "\${n_fq}" -eq 0 ]; then
        echo "ERROR: no FASTQ files matched fastq_id prefixes ${fastq_ids}" >&2
        exit 1
    fi

    REF_ABS="\$(readlink -f ${ref_dir})"
    FEAT_ABS="\$(readlink -f ${feature_ref})"
    FQ_ABS="\$(readlink -f fastqs)"

    sed -e "s|__GEX_REF__|\${REF_ABS}|g" \\
        -e "s|__FEATURE_REF__|\${FEAT_ABS}|g" \\
        -e "s|__FASTQS__|\${FQ_ABS}|g" \\
        "${config}" > "${run_id}.multi_config.resolved.csv"

    echo "=== Resolved multi_config ==="
    cat "${run_id}.multi_config.resolved.csv"

    echo "=== Running cellranger multi ==="
    cellranger multi \\
        --id=${run_id} \\
        --csv=${run_id}.multi_config.resolved.csv \\
        --localcores=${task.cpus} \\
        --localmem=${params.memory_gb} \\
        --disable-ui

    echo "=== Done ${run_id} ==="
    ls -la ${run_id}/outs/ || true
    """
}


workflow {
    ref_ch = DOWNLOAD_REFERENCE(Channel.value(params.gex_reference_url)).ref_dir

    pools_ch = Channel
        .fromPath("${params.pool_dir}/pools.tsv")
        .splitCsv(header: true, sep: '\t')
        .map { row -> tuple(row.run_id, file(row.config), row.fastq_ids) }

    CELLRANGER_MULTI(
        pools_ch,
        file(params.feature_reference),
        ref_ch,
        params.input_dir
    )
}

workflow.onComplete {
    log.info "Pipeline completed at: ${workflow.complete}"
    log.info "Execution status: ${workflow.success ? 'OK' : 'Failed'}"
}
