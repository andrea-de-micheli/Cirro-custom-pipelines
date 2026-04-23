#!/usr/bin/env nextflow
nextflow.enable.dsl=2

/*
 * EGA Download Pipeline
 * Downloads controlled-access data from the European Genome-phenome Archive
 * using pyega3 with username/password authentication.
 */

params.credentials_file = null      // Path to pyega3 credentials JSON (built by preprocess.py)
params.accession_list_file = null   // Path to file containing EGA accessions (EGAD*/EGAF*), one per line
params.connections = 5              // Parallel connections per pyega3 fetch
params.max_file_size = 500          // Max expected file size in GB (default: 500 GB)
params.outdir = "results"           // Output directory

log.info """
    EGA Download Pipeline
    =====================
    credentials_file    : ${params.credentials_file}
    accession_list_file : ${params.accession_list_file}
    connections         : ${params.connections}
    max_file_size       : ${params.max_file_size} GB
    outdir              : ${params.outdir}
    """
    .stripIndent()

/*
 * Process: Download one EGA accession (dataset or file)
 */
process FETCH_EGA {
    tag "${acc_id}"

    container "quay.io/biocontainers/pyega3:5.2.0--pyhdfd78af_0"

    cpus 2
    memory '4 GB'
    disk "${params.max_file_size} GB"

    publishDir "${params.outdir}", mode: 'copy'

    input:
    val acc_id
    path credentials_file

    output:
    path "${acc_id}", emit: downloads

    script:
    """
    mkdir -p ${acc_id}
    pyega3 -cf ${credentials_file} -c ${params.connections} fetch ${acc_id} --output-dir ${acc_id}
    """
}

/*
 * Main workflow
 */
workflow {
    if (!params.credentials_file) {
        error "credentials_file is not set. Did preprocess.py run?"
    }
    if (!params.accession_list_file) {
        error "accession_list_file is not set."
    }

    accession_list = file(params.accession_list_file)
    acc_ch = Channel
        .fromPath(accession_list)
        .splitText()
        .map { it.trim() }
        .filter { it && !it.startsWith('#') }
        .ifEmpty { error "No EGA accessions found in ${params.accession_list_file}" }

    credentials_file = file(params.credentials_file)

    acc_ch.view { "Fetching EGA accession: ${it}" }

    FETCH_EGA(acc_ch, credentials_file)
}

workflow.onComplete {
    log.info "Pipeline completed at: ${workflow.complete}"
    log.info "Execution status: ${workflow.success ? 'OK' : 'Failed'}"
}
