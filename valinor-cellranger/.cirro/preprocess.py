#!/usr/bin/env python3
"""
Preprocess for valinor-cellranger.

Inputs from the form (all data-URLs):
  - libraries_sheet:   CSV with columns run_id, fastq_id, library_type
  - samples_sheet:     CSV with columns run_id, sample_id, and either
                       'hashtag_ids' (cell-hashing demux) or 'cmo_ids'
                       (CMO / Multiplexing Capture demux). The chosen column
                       name is passed through to cellranger's [samples] section
                       — that is exactly how cellranger picks the demux mode.
  - feature_reference: 10x feature_reference.csv
                       (id, name, read, pattern, sequence, feature_type).

For each unique run_id this script generates a multi_config CSV with three
runtime placeholders (__GEX_REF__, __FEATURE_REF__, __FASTQS__) that main.nf
substitutes on the worker after staging.

Validation done here (so failures land in the control plane, not after an
hour of Batch boot):
  - feature_reference is non-empty and ids contain no whitespace or parens.
  - Every value in samples_sheet's hashtag_ids/cmo_ids column exists as an
    id in feature_reference.
  - Every run_id present in libraries_sheet is also present in samples_sheet
    and contains a 'Gene Expression' library row.
  - Every fastq_id prefix matches at least one file in the input dataset.
"""

import base64
import csv
import os
import re
from collections import defaultdict

from cirro.helpers.preprocess_dataset import PreprocessDataset


VALID_LIBRARY_TYPES = {
    "Gene Expression",
    "Antibody Capture",
    "Multiplexing Capture",
    "CRISPR Guide Capture",
    "VDJ",
    "VDJ-T",
    "VDJ-B",
}

# Cellranger multi accepts either column name in [samples]; whichever the
# user chose in samples_sheet is what we pass through.
SAMPLE_TAG_COLUMNS = ("hashtag_ids", "cmo_ids")


def decode_data_url(data_url: str, output_path: str) -> str:
    if not data_url or not data_url.startswith("data:"):
        raise ValueError(f"Expected data URL, got: {str(data_url)[:40]}...")
    _, encoded = data_url.split(",", 1)
    with open(output_path, "wb") as fh:
        fh.write(base64.b64decode(encoded))
    return os.path.abspath(output_path)


def read_csv_rows(path: str) -> list:
    with open(path, newline="") as fh:
        return [
            {k.strip(): (v.strip() if isinstance(v, str) else v) for k, v in row.items()}
            for row in csv.DictReader(fh)
        ]


def require_columns(rows: list, required: set, sheet_name: str) -> None:
    if not rows:
        raise ValueError(f"{sheet_name} is empty")
    missing = required - set(rows[0].keys())
    if missing:
        raise ValueError(f"{sheet_name} missing columns: {sorted(missing)}")


def validate_feature_reference(rows: list) -> set:
    """Return the set of all feature ids."""
    require_columns(rows, {"id", "feature_type"}, "feature_reference")
    feature_ids = set()
    bad_ids = []
    for r in rows:
        fid = r.get("id") or ""
        if not fid:
            continue
        if re.search(r"\s", fid) or "(" in fid or ")" in fid:
            bad_ids.append(fid)
        feature_ids.add(fid)
    if bad_ids:
        preview = ", ".join(repr(x) for x in bad_ids[:5])
        raise ValueError(
            f"feature_reference has {len(bad_ids)} id(s) with whitespace or parens "
            f"(cellranger will reject these): {preview}"
        )
    if not feature_ids:
        raise ValueError("feature_reference is empty")
    return feature_ids


def validate_libraries(rows: list) -> list:
    require_columns(rows, {"run_id", "fastq_id", "library_type"}, "libraries sheet")
    for r in rows:
        lt = r.get("library_type") or ""
        if lt not in VALID_LIBRARY_TYPES:
            raise ValueError(
                f"libraries sheet: unknown library_type {lt!r} "
                f"(run_id={r.get('run_id')!r}, fastq_id={r.get('fastq_id')!r}). "
                f"Allowed: {sorted(VALID_LIBRARY_TYPES)}"
            )
        if not (r.get("run_id") and r.get("fastq_id")):
            raise ValueError(f"libraries sheet has a row missing run_id or fastq_id: {r}")
    return rows


def validate_samples(rows: list, feature_ids: set) -> tuple:
    """Return (rows, tag_column_name) where tag_column_name is whichever of
    'hashtag_ids' or 'cmo_ids' the user used (cellranger picks the demux
    mode by that column name)."""
    if not rows:
        raise ValueError("samples sheet is empty")
    headers = set(rows[0].keys())
    base_required = {"run_id", "sample_id"}
    missing = base_required - headers
    if missing:
        raise ValueError(f"samples sheet missing columns: {sorted(missing)}")

    present = [c for c in SAMPLE_TAG_COLUMNS if c in headers]
    if len(present) == 0:
        raise ValueError(
            f"samples sheet must contain one of: {list(SAMPLE_TAG_COLUMNS)} "
            f"(found columns: {sorted(headers)})"
        )
    if len(present) > 1:
        raise ValueError(
            f"samples sheet must contain exactly one of {list(SAMPLE_TAG_COLUMNS)}, "
            f"got both: {present}"
        )
    tag_col = present[0]

    for r in rows:
        if not (r.get("run_id") and r.get("sample_id")):
            raise ValueError(f"samples sheet has a row missing run_id or sample_id: {r}")
        tags = [h.strip() for h in (r.get(tag_col) or "").split("|") if h.strip()]
        if not tags:
            raise ValueError(
                f"samples sheet row has empty {tag_col} "
                f"(run_id={r['run_id']}, sample_id={r['sample_id']})"
            )
        unknown = [h for h in tags if h not in feature_ids]
        if unknown:
            raise ValueError(
                f"samples sheet {tag_col} {unknown} (run_id={r['run_id']}, "
                f"sample_id={r['sample_id']}) are not present as ids in feature_reference."
            )
    return rows, tag_col


def write_multi_config(out_path: str, libs: list, samples: list,
                       tag_col: str, create_bam: bool) -> None:
    cb = "true" if str(create_bam).lower() in ("1", "true", "yes") else "false"
    lines = [
        "[gene-expression]",
        "reference,__GEX_REF__",
        f"create-bam,{cb}",
        "",
        "[feature]",
        "reference,__FEATURE_REF__",
        "",
        "[libraries]",
        "fastq_id,fastqs,feature_types",
    ]
    for r in libs:
        lines.append(f"{r['fastq_id']},__FASTQS__,{r['library_type']}")
    lines += ["", "[samples]", f"sample_id,{tag_col}"]
    for r in samples:
        ids = "|".join(h.strip() for h in (r[tag_col] or "").split("|") if h.strip())
        lines.append(f"{r['sample_id']},{ids}")
    with open(out_path, "w") as fh:
        fh.write("\n".join(lines) + "\n")


def main() -> None:
    ds = PreprocessDataset.from_running()
    ds.logger.info(f"Parameters: {ds.params}")

    libs_path = decode_data_url(ds.params.get("libraries_sheet"), "libraries.csv")
    samples_path = decode_data_url(ds.params.get("samples_sheet"), "samples.csv")
    feat_path = decode_data_url(ds.params.get("feature_reference"), "feature_reference.csv")

    feature_ids = validate_feature_reference(read_csv_rows(feat_path))
    ds.logger.info(f"feature_reference: {len(feature_ids)} feature id(s)")

    lib_rows = validate_libraries(read_csv_rows(libs_path))
    sam_rows, tag_col = validate_samples(read_csv_rows(samples_path), feature_ids)
    ds.logger.info(f"samples_sheet uses {tag_col!r} -> cellranger demux mode follows that column")

    # Cross-check fastq_id prefixes against the actual input dataset so a typo
    # fails here, not after Batch boot. Tolerant to ds.files API variants.
    try:
        files_df = ds.files
        if files_df is not None and hasattr(files_df, "iterrows"):
            cols = list(files_df.columns)
            name_col = next((c for c in ("name", "file", "path", "key") if c in cols), cols[0] if cols else None)
            if name_col:
                names = [os.path.basename(str(v)) for v in files_df[name_col].tolist()]
                missing = sorted({
                    r["fastq_id"] for r in lib_rows
                    if not any(n.startswith(r["fastq_id"]) for n in names)
                })
                if missing:
                    raise ValueError(
                        f"fastq_id prefixes have no matching files in the input dataset: "
                        f"{missing}. Check spelling and that the right input dataset was selected."
                    )
                ds.logger.info(
                    f"Verified all {len({r['fastq_id'] for r in lib_rows})} fastq_id prefix(es) "
                    f"match files in the input dataset."
                )
    except ValueError:
        raise
    except Exception as e:
        ds.logger.warning(f"Skipped fastq_id existence check (ds.files unavailable): {e}")

    libs_by_run = defaultdict(list)
    for r in lib_rows:
        libs_by_run[r["run_id"]].append(r)
    sams_by_run = defaultdict(list)
    for r in sam_rows:
        sams_by_run[r["run_id"]].append(r)

    run_ids = sorted(set(libs_by_run) | set(sams_by_run))
    if not run_ids:
        raise ValueError("No run_id rows found in either samplesheet")

    for rid in run_ids:
        if rid not in libs_by_run:
            raise ValueError(f"run_id {rid!r} appears in samples_sheet but not libraries_sheet")
        if rid not in sams_by_run:
            raise ValueError(f"run_id {rid!r} appears in libraries_sheet but not samples_sheet")
        types = {r["library_type"] for r in libs_by_run[rid]}
        if "Gene Expression" not in types:
            raise ValueError(
                f"run_id {rid!r}: libraries_sheet must contain a 'Gene Expression' row"
            )

    out_dir = os.path.abspath("generated_configs")
    os.makedirs(out_dir, exist_ok=True)
    create_bam = ds.params.get("create_bam", False)

    pools_tsv = os.path.join(out_dir, "pools.tsv")
    with open(pools_tsv, "w") as fh:
        fh.write("run_id\tconfig\tfastq_ids\n")
        for rid in run_ids:
            cfg_path = os.path.join(out_dir, f"{rid}.multi_config.csv")
            write_multi_config(cfg_path, libs_by_run[rid], sams_by_run[rid], tag_col, create_bam)
            fastq_ids = sorted({r["fastq_id"] for r in libs_by_run[rid]})
            fh.write(f"{rid}\t{cfg_path}\t{'|'.join(fastq_ids)}\n")
            ds.logger.info(
                f"  pool {rid}: {len(libs_by_run[rid])} library row(s), "
                f"{len(sams_by_run[rid])} sample(s), fastq_ids={fastq_ids}"
            )

    ds.add_param("pool_dir", out_dir, overwrite=True)
    ds.add_param("feature_reference", feat_path, overwrite=True)
    ds.remove_param("libraries_sheet")
    ds.remove_param("samples_sheet")

    ds.logger.info(f"Generated {len(run_ids)} pool config(s) in {out_dir}")


if __name__ == "__main__":
    main()
