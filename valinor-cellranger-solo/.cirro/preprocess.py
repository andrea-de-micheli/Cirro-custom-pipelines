#!/usr/bin/env python3
"""
Preprocess for valinor-cellranger-solo.

Minimal. The only optional form input is `libraries_sheet` (a data-URL CSV).
If provided, decode it to a local file and update params; main.nf will read
it and use it as an override for filename-based auto-detection.
"""
import base64
import os

from cirro.helpers.preprocess_dataset import PreprocessDataset


def decode_data_url(value, out_name):
    if not value or not value.startswith("data:"):
        return None
    _, encoded = value.split(",", 1)
    path = os.path.abspath(out_name)
    with open(path, "wb") as fh:
        fh.write(base64.b64decode(encoded))
    return path


def main() -> None:
    ds = PreprocessDataset.from_running()
    ds.logger.info(f"Parameters: {ds.params}")

    libs_path = decode_data_url(ds.params.get("libraries_sheet"), "libraries.csv")
    if libs_path:
        ds.add_param("libraries_sheet", libs_path, overwrite=True)
        ds.logger.info(f"libraries_sheet override active: {libs_path}")
    else:
        ds.remove_param("libraries_sheet")
        ds.logger.info("No libraries_sheet — main.nf will auto-detect samples from filenames")

    ds.logger.info(f"Input dir(s) from params: {ds.params.get('input_dir')!r}")


if __name__ == "__main__":
    main()
