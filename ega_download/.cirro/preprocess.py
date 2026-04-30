#!/usr/bin/env python3
"""
Preprocess script for EGA Download pipeline.

Builds the pyega3 credentials JSON from the username/password form fields,
extracts the uploaded accession list from its data URL, and rewrites the
params so that the Nextflow workflow receives file paths instead of secrets.

Reads/writes params.json directly instead of using
PreprocessDataset.from_running(), which requires a config/files.csv that is
not staged on resume runs (causes FileNotFoundError on resume).
"""

import os
import json
import base64

PARAMS_PATH = "params.json"


def extract_file_from_data_url(data_url, output_path):
    """Extract file content from data URL and write to disk."""
    if not data_url or not data_url.startswith('data:'):
        raise ValueError("Invalid data URL format")

    header, encoded = data_url.split(',', 1)
    content = base64.b64decode(encoded)

    with open(output_path, 'wb') as f:
        f.write(content)

    return os.path.abspath(output_path)


def main():
    with open(PARAMS_PATH) as f:
        params = json.load(f)

    username = params.get('ega_username')
    password = params.get('ega_password')
    if not username or not password:
        raise ValueError("EGA username and password are both required")

    credentials_path = os.path.abspath("ega_credentials.json")
    with open(credentials_path, 'w') as f:
        json.dump({"username": username, "password": password}, f)
    os.chmod(credentials_path, 0o600)

    accession_data_url = params.get('accession_list_file')
    if not accession_data_url:
        raise ValueError("Accession list file is required")

    accession_list_path = extract_file_from_data_url(
        accession_data_url, "accession_list.txt"
    )

    # Drop the plaintext credentials from the run params so they don't end up
    # in the Nextflow params log, then hand the workflow file paths instead.
    params.pop("ega_username", None)
    params.pop("ega_password", None)
    params["credentials_file"] = credentials_path
    params["accession_list_file"] = accession_list_path

    with open(PARAMS_PATH, "w") as f:
        json.dump(params, f, indent=2)

    with open(accession_list_path, 'r') as f:
        accession_count = len([
            line.strip() for line in f
            if line.strip() and not line.strip().startswith('#')
        ])

    print(f"Preprocessing complete: {accession_count} EGA accession(s) found")


if __name__ == "__main__":
    main()
