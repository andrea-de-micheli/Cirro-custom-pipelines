#!/usr/bin/env nextflow
nextflow.enable.dsl=2

/*
 * valinor-cellranger
 *
 * Runs `cellranger multi` across one or more pools driven by a samplesheet.
 * One CELLRANGER_MULTI task per run_id. The reference and FASTQs are staged
 * by Nextflow's native S3/HTTPS file system — nothing else needed in the
 * containers.
 */

params.pool_dir          = null
params.feature_reference = null
params.gex_reference_url = 'https://cf.10xgenomics.com/supp/cell-exp/refdata-gex-GRCh38-2024-A.tar.gz'
params.create_bam        = false
params.cpus              = 30
params.memory_gb         = 200
params.disk_gb           = 2000
params.input_dir         = null
params.outdir            = 'results'

if (!params.pool_dir)          { error "pool_dir is required (set by preprocess)" }
if (!params.feature_reference) { error "feature_reference is required" }
if (!params.input_dir)         { error "input_dir is required" }


process DOWNLOAD_REFERENCE {
    container 'quay.io/nf-core/cellranger:10.0.0'
    cpus 2
    memory '4 GB'
    disk '60 GB'

    input:
    path tarball

    output:
    path 'reference'

    script:
    """
    mkdir -p reference
    tar -xzf "${tarball}" -C reference --strip-components=1
    """
}


process CELLRANGER_MULTI {
    tag "${run_id}"
    container 'quay.io/nf-core/cellranger:10.0.0'

    cpus   { params.cpus }
    memory { "${params.memory_gb} GB" }
    disk   { "${params.disk_gb} GB" }

    publishDir "${params.outdir}", mode: 'copy', pattern: "${run_id}/outs/**"
    publishDir "${params.outdir}", mode: 'copy', pattern: "${run_id}.multi_config.resolved.csv"

    input:
    tuple val(run_id), path(config), path(fastqs)
    path  feature_ref
    path  ref_dir

    output:
    path "${run_id}/outs/**"
    path "${run_id}.multi_config.resolved.csv"

    script:
    """
    set -euo pipefail
    mkdir fastqs && mv *.fastq.gz fastqs/

    sed -e "s|__GEX_REF__|\$(readlink -f ${ref_dir})|g" \\
        -e "s|__FEATURE_REF__|\$(readlink -f ${feature_ref})|g" \\
        -e "s|__FASTQS__|\$(readlink -f fastqs)|g" \\
        ${config} > ${run_id}.multi_config.resolved.csv

    cellranger multi \\
        --id=${run_id} \\
        --csv=${run_id}.multi_config.resolved.csv \\
        --localcores=${task.cpus} \\
        --localmem=${params.memory_gb} \\
        --disable-ui
    """
}


workflow {
    // .first() makes the singleton ref broadcast to every pool task.
    ref_ch = DOWNLOAD_REFERENCE(file(params.gex_reference_url)).first()

    pools_ch = Channel
        .fromPath("${params.pool_dir}/pools.tsv")
        .splitCsv(header: true, sep: '\t')
        .map { row ->
            def fastqs = row.fastq_ids.tokenize('|').collectMany { fid ->
                def m = file("${params.input_dir}/**/${fid}*.fastq.gz", checkIfExists: false)
                m instanceof List ? m : (m ? [m] : [])
            }
            if (fastqs.isEmpty()) error "No FASTQ files matched '${row.fastq_ids}' under ${params.input_dir} (pool ${row.run_id})"
            tuple(row.run_id, file(row.config), fastqs)
        }

    CELLRANGER_MULTI(pools_ch, file(params.feature_reference), ref_ch)
}
