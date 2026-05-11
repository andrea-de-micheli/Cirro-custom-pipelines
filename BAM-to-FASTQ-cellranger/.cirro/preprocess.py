#!/usr/bin/env python3
"""
Preprocess script for BAM-to-FASTQ-cellranger.

Runs BEFORE the Nextflow workflow starts. Lightweight:
  - Logs each input dataset path and its BAM file count
  - Warns (does not fail) if no BAMs are visible — Nextflow re-globs S3 at runtime
  - Does not mutate parameters; main.nf handles single-vs-multi input_dir
"""
from cirro.helpers.preprocess_dataset import PreprocessDataset


def main():
    ds = PreprocessDataset.from_running()
    ds.logger.info(f"Parameters: {ds.params}")

    input_dir = ds.params.get("input_dir")
    ds.logger.info(f"Input dir(s) from params: {input_dir!r}")

    if len(ds.files) > 0:
        bam_files = ds.files[ds.files["file"].str.endswith(".bam")]
        ds.logger.info(f"Found {len(bam_files)} BAM file(s) in ds.files DataFrame")
        if len(bam_files) == 0:
            ds.logger.warning(
                "No .bam files visible in ds.files — Nextflow will still try the S3 glob."
            )
        else:
            for path in bam_files["file"].tolist()[:20]:
                ds.logger.info(f"  BAM: {path}")
            if len(bam_files) > 20:
                ds.logger.info(f"  ... and {len(bam_files) - 20} more")
    else:
        ds.logger.warning(
            "ds.files is empty — input dataset metadata not registered. "
            "Nextflow will validate at runtime via S3 glob."
        )


if __name__ == "__main__":
    main()
