#!/usr/bin/env python3
"""
Preprocess for valinor-cellranger.

Inputs from the form (all data-URLs):
  - libraries_sheet:   CSV with columns run_id, fastq_id, library_type
  - samples_sheet:     CSV with columns run_id, sample_id, hashtag_ids
  - feature_reference: 10x feature_reference.csv
                       (id, name, read, pattern, sequence, feature_type)

For each unique run_id this script generates a multi_config CSV with three
runtime placeholders (__GEX_REF__, __FEATURE_REF__, __FASTQS__) that main.nf
substitutes on the worker after staging.

Validation done here (so failures land in the control plane, not after an
hour of Batch boot):
  - feature_reference contains at least one row with
    feature_type='Multiplexing Capture' (HTO rows for cellranger demux).
  - Every hashtag_ids value referenced in samples_sheet exists as an HTO id
    in feature_reference.
  - Every run_id present in libraries_sheet is also present in samples_sheet
    and contains a 'Gene Expression' library row.
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


def validate_feature_reference(rows: list) -> tuple:
    require_columns(rows, {"id", "feature_type"}, "feature_reference")
    by_type = defaultdict(set)
    bad_ids = []
    for r in rows:
        fid = r.get("id") or ""
        ftype = r.get("feature_type") or ""
        if not fid:
            continue
        if re.search(r"\s", fid) or "(" in fid or ")" in fid:
            bad_ids.append(fid)
        by_type[ftype].add(fid)

    if bad_ids:
        preview = ", ".join(repr(x) for x in bad_ids[:5])
        raise ValueError(
            f"feature_reference has {len(bad_ids)} id(s) with whitespace or parens "
            f"(cellranger will reject these): {preview}"
        )

    htos = by_type.get("Multiplexing Capture", set())
    adts = by_type.get("Antibody Capture", set())
    if not htos:
        raise ValueError(
            "feature_reference must contain at least one row with "
            "feature_type='Multiplexing Capture' (HTOs for cellranger sample demux)"
        )
    return htos, adts


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


def validate_samples(rows: list, htos: set) -> list:
    require_columns(rows, {"run_id", "sample_id", "hashtag_ids"}, "samples sheet")
    for r in rows:
        if not (r.get("run_id") and r.get("sample_id")):
            raise ValueError(f"samples sheet has a row missing run_id or sample_id: {r}")
        tags = [h.strip() for h in (r.get("hashtag_ids") or "").split("|") if h.strip()]
        if not tags:
            raise ValueError(
                f"samples sheet row has empty hashtag_ids "
                f"(run_id={r['run_id']}, sample_id={r['sample_id']})"
            )
        unknown = [h for h in tags if h not in htos]
        if unknown:
            raise ValueError(
                f"samples sheet hashtag_ids {unknown} (run_id={r['run_id']}, "
                f"sample_id={r['sample_id']}) are not declared as Multiplexing Capture "
                f"in feature_reference. Known HTOs: {sorted(htos)}"
            )
    return rows


def write_multi_config(out_path: str, libs: list, samples: list, create_bam: bool) -> None:
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
    lines += ["", "[samples]", "sample_id,cmo_ids"]
    for r in samples:
        cmo = "|".join(h.strip() for h in (r["hashtag_ids"] or "").split("|") if h.strip())
        lines.append(f"{r['sample_id']},{cmo}")
    with open(out_path, "w") as fh:
        fh.write("\n".join(lines) + "\n")


def main() -> None:
    ds = PreprocessDataset.from_running()
    ds.logger.info(f"Parameters: {ds.params}")

    libs_path = decode_data_url(ds.params.get("libraries_sheet"), "libraries.csv")
    samples_path = decode_data_url(ds.params.get("samples_sheet"), "samples.csv")
    feat_path = decode_data_url(ds.params.get("feature_reference"), "feature_reference.csv")

    htos, adts = validate_feature_reference(read_csv_rows(feat_path))
    ds.logger.info(
        f"feature_reference: {len(htos)} HTO (Multiplexing Capture), "
        f"{len(adts)} ADT (Antibody Capture)"
    )

    lib_rows = validate_libraries(read_csv_rows(libs_path))
    sam_rows = validate_samples(read_csv_rows(samples_path), htos)

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
        if "Multiplexing Capture" not in types:
            raise ValueError(
                f"run_id {rid!r}: libraries_sheet must contain a 'Multiplexing Capture' row "
                f"(HTO library) — HTO demux requires it"
            )

    out_dir = os.path.abspath("generated_configs")
    os.makedirs(out_dir, exist_ok=True)
    create_bam = ds.params.get("create_bam", False)

    pools_tsv = os.path.join(out_dir, "pools.tsv")
    with open(pools_tsv, "w") as fh:
        fh.write("run_id\tconfig\tfastq_ids\n")
        for rid in run_ids:
            cfg_path = os.path.join(out_dir, f"{rid}.multi_config.csv")
            write_multi_config(cfg_path, libs_by_run[rid], sams_by_run[rid], create_bam)
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
