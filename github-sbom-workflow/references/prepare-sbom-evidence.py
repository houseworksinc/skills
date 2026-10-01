#!/usr/bin/env python3
"""Bind BOM evidence to the exact release artifact selected by the producer."""

import hashlib
import json
import os
import re
from datetime import UTC, datetime
from pathlib import Path

repo, revision, version = (
    os.environ[name] for name in ("GITHUB_REPOSITORY", "GITHUB_SHA", "VERSION")
)
artifact = os.environ["ARTIFACT_DIGEST"]
if not re.fullmatch(r"(?:.+@)?sha256:[a-f0-9]{64}", artifact):
    raise ValueError("Immutable artifact digest is required")
bom = json.loads(Path("sbom.cdx.json").read_text())
root = bom["metadata"]["component"]
root["name"], root["version"] = repo, version
root["properties"] = [
    item
    for item in root.get("properties", [])
    if item["name"] not in ("houseworks:artifact-digest", "houseworks:revision")
]
root["properties"].extend(
    [
        {"name": "houseworks:artifact-digest", "value": artifact},
        {"name": "houseworks:revision", "value": revision},
    ]
)
raw = (json.dumps(bom, sort_keys=True) + "\n").encode()
Path("sbom.cdx.json").write_bytes(raw)
sha = hashlib.sha256(raw).hexdigest()
Path("sbom.cdx.json.sha256").write_text(sha + "\n")
Path("metadata.json").write_text(
    json.dumps(
        {
            "repository": repo,
            "revision": revision,
            "version": version,
            "generated_at": datetime.now(UTC).isoformat(),
            "format": "CycloneDX JSON",
            "sbom_sha256": sha,
            "artifact_digest": artifact,
            "scan_outcome": os.environ.get("SCAN_OUTCOME", "unknown"),
        },
        indent=2,
    )
    + "\n"
)
