#!/usr/bin/env nextflow
nextflow.enable.dsl = 2

/*
 * BAM-to-FASTQ-cellranger
 *
 * Converts 10x Cell Ranger BAM files back to FASTQ using 10x Genomics
 * bamtofastq. Auto-detects paired-end vs single-end vs index reads from
 * the BAM's @CO 10x_bam_to_fastq header comments. Discovers BAMs
 * recursively across one or more input datasets.
 */

// Parameters (populated by Cirro via process-input.json, or via --flag locally)
params.input_dir       = null            // S3 path(s) to input dataset(s) — string or list
params.outdir          = "results"
params.threads         = 8
params.reads_per_fastq = 50000000        // bamtofastq chunk size
params.flatten         = false           // true → all FASTQs in outdir root, prefixed with BAM name
params.memory_gb       = 16
params.disk_gb         = 1000
params.exclude_pattern = null            // comma-sep globs of BAM filenames to skip (e.g. "*.all_contig.bam")

/*
 * Resolve params.input_dir into a list of glob patterns. Handles:
 *   - Groovy List (Cirro $.inputs[*].dataPath multi-input case)
 *   - Single string
 *   - Space/comma-separated string
 *   - Stringified array form: "[s3://a, s3://b]"
 */
def input_globs() {
    if (params.input_dir == null) {
        error "params.input_dir is required (S3 path or local directory containing BAM files)"
    }
    def raw = params.input_dir
    def paths
    if (raw instanceof List) {
        paths = raw.collect { it.toString() }
    } else {
        // Strip surrounding brackets if Cirro stringified the array
        def s = raw.toString().trim().replaceAll(/^\[|\]$/, '')
        paths = s.tokenize(' \t\n,').findAll { it }
    }
    return paths.collect { p -> "${p.replaceAll('/$', '')}/**/*.bam" }
}

def exclude_patterns() {
    if (!params.exclude_pattern) return []
    return params.exclude_pattern
        .toString()
        .split(/[,\n\r]+/)
        .collect { it.trim() }
        .findAll { it.length() > 0 }
}

def glob_to_regex(String glob) {
    // Minimal glob → regex: . → \., * → .*, ? → .
    return '^' + glob.replace('.', '\\.').replace('*', '.*').replace('?', '.') + '$'
}

log.info """
    BAM-to-FASTQ-cellranger
    =======================
    input_dir       : ${params.input_dir}
    input globs     : ${input_globs()}
    threads         : ${params.threads}
    reads_per_fastq : ${params.reads_per_fastq}
    flatten         : ${params.flatten}
    exclude_pattern : ${exclude_patterns() ?: '(none)'}
    outdir          : ${params.outdir}
""".stripIndent()

process BAM_TO_FASTQ {
    tag "${bam.baseName}"

    container "quay.io/biocontainers/10x_bamtofastq:1.4.1--h3ab6199_4"

    cpus   params.threads as Integer
    memory "${params.memory_gb} GB"

    publishDir "${params.outdir}",
        mode: 'copy',
        pattern: "${bam.baseName}/**.fastq.gz",
        saveAs: { fname ->
            params.flatten ? file(fname).name : fname
        }

    input:
    path bam

    output:
    path "${bam.baseName}/*.fastq.gz", emit: fastqs

    script:
    def sample = bam.baseName
    """
    set -euo pipefail

    # 10x bamtofastq writes into <out>/<gem_well>/<chunks>.fastq.gz
    bamtofastq \\
        --nthreads ${task.cpus} \\
        --reads-per-fastq ${params.reads_per_fastq} \\
        ${bam} \\
        ${sample}_tmp

    # Collapse the gem_well subdir(s) into a single per-BAM folder and rename
    # the "bamtofastq_" prefix to the BAM basename so files carry sample identity.
    mkdir -p ${sample}
    find ${sample}_tmp -name '*.fastq.gz' -print0 | while IFS= read -r -d '' f; do
        base=\$(basename "\$f")
        # base looks like: bamtofastq_S1_L001_R1_001.fastq.gz
        new="${sample}_\${base#bamtofastq_}"
        mv "\$f" "${sample}/\$new"
    done

    rm -rf ${sample}_tmp
    """
}

workflow {
    def excludes = exclude_patterns()
    def exclude_regexes = excludes.collect { glob_to_regex(it) }

    bam_ch = Channel
        .fromPath(input_globs(), checkIfExists: false)
        .filter { it.name.endsWith('.bam') }
        .filter { bam ->
            def name = bam.name
            def matched = exclude_regexes.find { rx -> name ==~ rx }
            if (matched) {
                log.info "Excluding BAM ${name} (matches pattern)"
                return false
            }
            return true
        }
        .ifEmpty { error "No BAM files found under ${params.input_dir} (after exclude_pattern filter)" }

    bam_ch.view { "Found BAM: ${it}" }

    BAM_TO_FASTQ(bam_ch)
}

workflow.onComplete {
    log.info "Pipeline completed at: ${workflow.complete}"
    log.info "Execution status: ${workflow.success ? 'OK' : 'Failed'}"
}
