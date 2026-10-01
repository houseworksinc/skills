#!/usr/bin/env python3
"""Offline CycloneDX 1.5/1.6 schema validation against vendored upstream schemas."""

import json
import sys
from pathlib import Path
from jsonschema import Draft7Validator, FormatChecker
from referencing import Registry, Resource


def validate(path, schema_dir):
    bom = json.loads(Path(path).read_text())
    version = bom.get("specVersion")
    if version not in ("1.5", "1.6"):
        raise ValueError("Unsupported CycloneDX version: expected 1.5 or 1.6")
    resources = []
    for file in Path(schema_dir).glob("*.json"):
        data = json.loads(file.read_text())
        resource = Resource.from_contents(data)
        resources.append((data["$id"], resource))
        resources.append((file.name, resource))
    schema = json.loads((Path(schema_dir) / f"bom-{version}.schema.json").read_text())
    validator = Draft7Validator(
        schema,
        registry=Registry().with_resources(resources),
        format_checker=FormatChecker(),
    )
    errors = sorted(validator.iter_errors(bom), key=lambda e: str(list(e.path)))
    if errors:
        raise ValueError(
            "CycloneDX schema error at "
            + str(list(errors[0].path))
            + ": "
            + errors[0].message
        )
    if not bom.get("metadata", {}).get("component"):
        raise ValueError("HouseWorks release BOM must identify its root component")
    print("Valid CycloneDX " + version)


if __name__ == "__main__":
    validate(sys.argv[1], sys.argv[2])
