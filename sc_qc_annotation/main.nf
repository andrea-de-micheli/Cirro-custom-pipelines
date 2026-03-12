#!/usr/bin/env nextflow
nextflow.enable.dsl=2

/*
 * H5AD single-cell QC preprocessing pipeline
 * Scans an input dataset recursively for .h5ad files and runs
 * single_cell_preprocessing_pipeline.py (from bin/) on each file.
 */

// Parameters (populated by Cirro via process-input.json)
params.input_dir = null
params.outdir = "results"
params.threads = 4
params.min_genes = 200
params.min_counts = 500
params.n_mads = 3.0
params.mt_cutoff = null
params.expected_doublet_rate = 0.06
params.skip_doublets = false

log.info([
    "H5AD Single-Cell QC Pipeline",
    "============================",
    "input_dir             : ${params.input_dir}",
    "outdir                : ${params.outdir}",
    "threads               : ${params.threads}",
    "min_genes             : ${params.min_genes}",
    "min_counts            : ${params.min_counts}",
    "n_mads                : ${params.n_mads}",
    "mt_cutoff             : ${params.mt_cutoff}",
    "expected_doublet_rate : ${params.expected_doublet_rate}",
    "skip_doublets         : ${params.skip_doublets}",
].join('\n'))

process RUN_SC_QC {
    tag "${sample_name}"

    container "getwilds/scanpy:1.10.2"
    cpus params.threads
    memory "16 GB"

    publishDir "${params.outdir}", mode: "copy"

    input:
    tuple val(sample_name), path(h5ad_file)

    output:
    path "${sample_name}", emit: qc_results

    script:
    def mt_cutoff_value = params.mt_cutoff == null ? "" : params.mt_cutoff.toString().trim()
    def skip_doublets_arg = params.skip_doublets ? "--skip-doublets" : ""
    """
    set -euo pipefail

    mkdir -p "${sample_name}"

    python -m pip install --no-cache-dir scrublet==0.2.3

    args=(
      --input "${h5ad_file}"
      --output "${sample_name}/${sample_name}.cleaned.h5ad"
      --plot-output "${sample_name}/${sample_name}.qc_plots.png"
      --stats-output "${sample_name}/${sample_name}.qc_stats.txt"
      --min-genes ${params.min_genes}
      --min-counts ${params.min_counts}
      --n-mads ${params.n_mads}
      --expected-doublet-rate ${params.expected_doublet_rate}
    )

    mt_cutoff_value="${mt_cutoff_value}"
    if [[ -n "${mt_cutoff_value}" && "${mt_cutoff_value}" != "null" ]]; then
      args+=( --mt-cutoff "${mt_cutoff_value}" )
    fi

    if [[ -n "${skip_doublets_arg}" ]]; then
      args+=( ${skip_doublets_arg} )
    fi

    single_cell_preprocessing_pipeline.py "${args[@]}"
    """
}

workflow {
    h5ad_ch = Channel
        .fromPath("${params.input_dir}/**/*.h5ad", checkIfExists: true)
        .ifEmpty { error "No .h5ad files found in ${params.input_dir}" }
        .map { h5ad_file -> tuple(h5ad_file.simpleName, h5ad_file) }

    h5ad_ch.view { sample_name, h5ad_file -> "Found H5AD: ${sample_name} (${h5ad_file})" }

    RUN_SC_QC(h5ad_ch)
}

workflow.onComplete {
    log.info "Pipeline completed at: ${workflow.complete}"
    log.info "Execution status: ${workflow.success ? 'OK' : 'Failed'}"
}
