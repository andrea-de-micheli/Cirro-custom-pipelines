#!/usr/bin/env nextflow
nextflow.enable.dsl = 2

/*
 * valinor-cellranger-solo
 *
 * Runs `cellranger count` (GEX-only, non-multiplexed) per sample. Samples are
 * auto-detected from the FASTQ filename convention
 *   <sample>.<libtype>.*_S<n>_L<n>_R<n>_001.fastq.gz
 * Only Gene Expression libraries are processed; VDJ/Antibody/Multiplexing
 * libraries are detected, logged, and skipped.
 *
 * Optional libraries_sheet (CSV: sample_id, fastq_id, library_type) overrides
 * the auto-detection on a per-fastq_id basis.
 */

params.input_dir         = null
params.outdir            = 'results'
params.gex_reference_url = 'https://cf.10xgenomics.com/supp/cell-exp/refdata-gex-GRCh38-2024-A.tar.gz'
params.libraries_sheet   = null
params.create_bam        = false
params.cpus              = 30
params.memory_gb         = 200
params.disk_gb           = 2000

if (!params.input_dir) error "input_dir is required (set by Cirro from input dataset, or via --input_dir)"

/*
 * Resolve params.input_dir into a list of glob patterns. Handles single string,
 * Groovy list, comma/space-separated string, and stringified array form.
 * Reused from BAM-to-FASTQ-cellranger.
 */
def input_globs() {
    def raw = params.input_dir
    def paths
    if (raw instanceof List) {
        paths = raw.collect { it.toString() }
    } else {
        def s = raw.toString().trim().replaceAll(/^\[|\]$/, '')
        paths = s.tokenize(' \t\n,').findAll { it }
    }
    return paths.collect { p -> "${p.replaceAll('/$', '')}/**/*.fastq.gz" }
}

/*
 * Library type detection table (markers compared in uppercase).
 */
LIBTYPE_GEX = ['GEX','5GEX','3GEX','RNA','MRNA'] as Set
LIBTYPE_BCR = ['BCR','IGH','IGK','IGL','VDJ_B','VDJB'] as Set
LIBTYPE_TCR = ['TCR','TRA','TRB','TRD','TRG','VDJ_T','VDJT'] as Set
LIBTYPE_HTO = ['HTO','HASH','HASHING'] as Set
LIBTYPE_ADT = ['ADT','CITE','SURFACE'] as Set
LIBTYPE_CMO = ['CMO','MULTI','MULTIPLEX'] as Set

def classify_marker(String marker) {
    if (marker == null || marker in LIBTYPE_GEX) return 'Gene Expression'
    if (marker in LIBTYPE_BCR) return 'VDJ-B'
    if (marker in LIBTYPE_TCR) return 'VDJ-T'
    if (marker in LIBTYPE_HTO || marker in LIBTYPE_ADT) return 'Antibody Capture'
    if (marker in LIBTYPE_CMO) return 'Multiplexing Capture'
    return "Unknown(${marker})"
}

/*
 * Parse a FASTQ filename into (sample, fastq_id, library_type).
 * Accepts both R1/R2 (cDNA reads) and I1/I2 (index reads), and any chunk
 * number — bamtofastq emits chunks _001, _002, _003... not just _001.
 * Returns null if the filename doesn't match the 10x naming convention.
 */
def parse_fastq(fastq_path) {
    def m = (fastq_path.name =~ /^(.+)_S\d+_L\d+_[RI]\d+_\d+\.fastq\.gz$/)
    if (!m.find()) return null
    def fastq_id = m.group(1)
    def parts    = fastq_id.tokenize('.')
    def sample   = parts[0]
    def marker   = parts.size() > 1 ? parts[1].toUpperCase() : null
    return [
        sample      : sample,
        fastq_id    : fastq_id,
        library_type: classify_marker(marker),
        path        : fastq_path
    ]
}

/*
 * Parse an optional libraries_sheet CSV. Expected columns: sample_id, fastq_id,
 * library_type. Returns a map keyed by fastq_id.
 */
def parse_libraries_sheet(csv_file) {
    def lines = csv_file.readLines().findAll { it.trim() && !it.startsWith('#') }
    if (lines.isEmpty()) return [:]
    def header   = lines[0].split(',').collect { it.trim() }
    def required = ['sample_id', 'fastq_id', 'library_type']
    def missing  = required.findAll { !header.contains(it) }
    if (missing) error "libraries_sheet missing required columns: ${missing}"
    def out = [:]
    lines.drop(1).each { line ->
        def cols = line.split(',', -1).collect { it.trim() }
        def row  = [header, cols].transpose().collectEntries { k, v -> [(k): v] }
        if (row.fastq_id) out[row.fastq_id] = row
    }
    return out
}

// cellranger 10 restricts --sample names to [A-Za-z0-9_-]. Map any other
// character to '_'. Idempotent on already-clean ids. Two distinct originals
// could in theory collapse (e.g. "A.B" and "A_B"); not realistic for the
// BAM-basename naming this pipeline consumes.
def sanitize_fastq_id(String id) {
    return id.replaceAll(/[^A-Za-z0-9_-]/, '_')
}

log.info """
    valinor-cellranger-solo
    =======================
    input_dir         : ${params.input_dir}
    input globs       : ${input_globs()}
    gex_reference_url : ${params.gex_reference_url}
    libraries_sheet   : ${params.libraries_sheet ?: '(auto-detect from filenames)'}
    create_bam        : ${params.create_bam}
    cpus              : ${params.cpus}
    memory_gb         : ${params.memory_gb}
    disk_gb           : ${params.disk_gb}
    outdir            : ${params.outdir}
""".stripIndent()

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

process CELLRANGER_COUNT {
    tag "${sample_id}"
    container 'quay.io/nf-core/cellranger:10.0.0'

    cpus   { params.cpus as Integer }
    memory "${params.memory_gb} GB"
    disk   "${params.disk_gb} GB"

    publishDir "${params.outdir}", mode: 'copy', pattern: "${sample_id}/outs/**"

    input:
    tuple val(sample_id), val(orig_fastq_ids), val(fastq_ids), path(fastqs)
    path  ref_dir

    output:
    path "${sample_id}/outs/**"

    script:
    def samples_csv = fastq_ids.join(',')
    def cb = (params.create_bam as String).toLowerCase() in ['1','true','yes'] ? 'true' : 'false'
    """
    set -euo pipefail
    mkdir fastqs

    # Sanitize the prefix portion of each FASTQ filename so it matches the
    # sanitized --sample= value below. cellranger 10 only allows [A-Za-z0-9_-]
    # in sample names; same character class as sanitize_fastq_id() in main.nf.
    shopt -s nullglob
    for f in *.fastq.gz; do
        if [[ "\$f" =~ ^(.+)(_S[0-9]+_L[0-9]+_[RI][0-9]+_[0-9]+\\.fastq\\.gz)\$ ]]; then
            prefix="\${BASH_REMATCH[1]}"
            suffix="\${BASH_REMATCH[2]}"
            clean=\$(printf '%s' "\$prefix" | sed 's/[^A-Za-z0-9_-]/_/g')
            mv "\$f" "fastqs/\${clean}\${suffix}"
        else
            echo "WARN: unexpected FASTQ filename (not 10x convention): \$f" >&2
            mv "\$f" "fastqs/\$f"
        fi
    done

    cellranger count \\
        --id=${sample_id} \\
        --transcriptome=\$(readlink -f ${ref_dir}) \\
        --fastqs=\$(readlink -f fastqs) \\
        --sample=${samples_csv} \\
        --create-bam=${cb} \\
        --localcores=${task.cpus} \\
        --localmem=${params.memory_gb} \\
        --disable-ui
    """
}

workflow {
    ref_ch = DOWNLOAD_REFERENCE(file(params.gex_reference_url))

    // 1. Glob all FASTQs across selected input datasets and classify
    def all_fastqs = Channel
        .fromPath(input_globs(), checkIfExists: false)
        .map { parse_fastq(it) }
        .filter { it != null }

    // 2. Optional libraries_sheet override
    def lib_map = params.libraries_sheet ? parse_libraries_sheet(file(params.libraries_sheet)) : [:]
    if (lib_map) log.info "libraries_sheet override active for ${lib_map.size()} fastq_id(s)"

    def classified = all_fastqs.map { rec ->
        def override = lib_map[rec.fastq_id]
        if (override) {
            if (override.library_type) rec.library_type = override.library_type
            if (override.sample_id)    rec.sample       = override.sample_id
        }
        rec
    }

    // 3. Log non-GEX (skipped) files
    classified
        .filter { it.library_type != 'Gene Expression' }
        .view { "Skipping (${it.library_type}): ${it.path.name}" }

    // 4. Group GEX FASTQs by sample and dispatch to cellranger count.
    // Sanitize fastq_id here (post libraries_sheet override) so the value passed
    // to cellranger --sample= is cellranger-safe. The original is carried
    // through for the log line only.
    sample_ch = classified
        .filter { it.library_type == 'Gene Expression' }
        .map { [it.sample, it.fastq_id, sanitize_fastq_id(it.fastq_id), it.path] }
        .groupTuple()
        .map { sample, orig_fids, clean_fids, paths ->
            tuple(sample, orig_fids.unique(), clean_fids.unique(), paths.unique())
        }
        .ifEmpty { error "No GEX FASTQ files found in ${params.input_dir}" }

    sample_ch.view { sample, orig, clean, _paths ->
        "Sample ${sample}: ${orig.size()} fastq_id(s) = ${orig} -> sanitized ${clean}"
    }

    CELLRANGER_COUNT(sample_ch, ref_ch)
}

workflow.onComplete {
    log.info "Pipeline completed at: ${workflow.complete}"
    log.info "Execution status: ${workflow.success ? 'OK' : 'Failed'}"
}
