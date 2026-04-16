#!/usr/bin/env python3
"""
Preprocess script for valinor-cellranger.

- Decodes the uploaded multi_config.csv and feature_reference.csv data-URLs
  to local files and replaces the params with absolute paths.
- Validates the two CSVs up front so bad inputs fail in the control plane,
  not an hour into the Batch job.
"""

import base64
import os
import re
from cirro.helpers.preprocess_dataset import PreprocessDataset


def extract_file_from_data_url(data_url: str, output_path: str) -> str:
    if not data_url or not data_url.startswith("data:"):
        raise ValueError(f"Expected data URL, got: {str(data_url)[:40]}...")
    _, encoded = data_url.split(",", 1)
    with open(output_path, "wb") as fh:
        fh.write(base64.b64decode(encoded))
    return os.path.abspath(output_path)


def validate_multi_config(path: str) -> dict:
    text = open(path).read()
    sections = {m.group(1).lower() for m in re.finditer(r"^\[([^\]]+)\]", text, re.M)}
    for required in ("gene-expression", "libraries", "samples"):
        if required not in sections:
            raise ValueError(f"multi_config missing required [{required}] section")

    # Parse [libraries] for fastq_id count
    lib_rows = []
    in_libs = False
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            in_libs = s.lower() == "[libraries]"
            continue
        if in_libs and s and not s.lower().startswith("fastq_id"):
            lib_rows.append(s)

    # Parse [samples] for hashtag count
    sample_rows = []
    in_samples = False
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            in_samples = s.lower() == "[samples]"
            continue
        if in_samples and s and not s.lower().startswith("sample_id"):
            sample_rows.append(s)

    if not lib_rows:
        raise ValueError("multi_config [libraries] section has no rows")
    if not sample_rows:
        raise ValueError("multi_config [samples] section has no rows")

    return {"libraries": len(lib_rows), "samples": len(sample_rows)}


def validate_feature_reference(path: str) -> int:
    with open(path) as fh:
        lines = [l.rstrip("\n") for l in fh]
    if not lines:
        raise ValueError("feature_reference is empty")
    header = [c.strip().lower() for c in lines[0].split(",")]
    if header[0] != "id":
        raise ValueError(f"feature_reference first column must be 'id', got {header[0]!r}")
    bad = []
    for i, line in enumerate(lines[1:], start=2):
        if not line.strip():
            continue
        feat_id = line.split(",", 1)[0]
        if re.search(r"\s", feat_id) or "(" in feat_id or ")" in feat_id:
            bad.append((i, feat_id))
    if bad:
        preview = ", ".join(f"line {ln}: {fid!r}" for ln, fid in bad[:5])
        raise ValueError(
            f"feature_reference has {len(bad)} id(s) with whitespace or parens "
            f"(cellranger will reject these): {preview}"
        )
    return len(lines) - 1


def main() -> None:
    ds = PreprocessDataset.from_running()
    ds.logger.info(f"Parameters: {ds.params}")

    cfg_url = ds.params.get("multi_config")
    if not cfg_url:
        raise ValueError("multi_config is required")
    cfg_path = extract_file_from_data_url(cfg_url, "multi_config.csv")
    cfg_stats = validate_multi_config(cfg_path)
    ds.remove_param("multi_config")
    ds.add_param("multi_config", cfg_path, overwrite=True)

    feat_url = ds.params.get("feature_reference")
    if not feat_url:
        raise ValueError("feature_reference is required")
    feat_path = extract_file_from_data_url(feat_url, "feature_reference.csv")
    feat_count = validate_feature_reference(feat_path)
    ds.remove_param("feature_reference")
    ds.add_param("feature_reference", feat_path, overwrite=True)

    if not ds.params.get("run_id"):
        raise ValueError("run_id is required")

    ds.logger.info(
        f"Preprocess OK — {cfg_stats['libraries']} library rows, "
        f"{cfg_stats['samples']} sample (HTO) rows, "
        f"{feat_count} feature reference entries"
    )


if __name__ == "__main__":
    main()
