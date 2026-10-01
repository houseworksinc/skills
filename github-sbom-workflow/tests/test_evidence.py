import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

REF = Path(__file__).resolve().parents[1] / "references"


def test_evidence_prepare_validate_publish_and_partial_collision(tmp_path):
    bom = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "version": 1,
        "metadata": {"component": {"type": "application", "name": "candidate"}},
    }
    (tmp_path / "sbom.cdx.json").write_text(json.dumps(bom))
    (tmp_path / "osv-findings.json").write_text("{}")
    env = dict(
        os.environ,
        GITHUB_REPOSITORY="houseworksinc/arca-api",
        GITHUB_SHA="abc123",
        VERSION="v1",
        ARTIFACT_DIGEST="sha256:" + "a" * 64,
        BUCKET="test-bucket",
        PREFIX="sbom",
    )
    subprocess.run(
        [sys.executable, str(REF / "prepare-sbom-evidence.py")],
        cwd=tmp_path,
        env=env,
        check=True,
    )
    subprocess.run(
        [
            sys.executable,
            str(REF / "validate-sbom.py"),
            "sbom.cdx.json",
            str(REF / "schema"),
        ],
        cwd=tmp_path,
        check=True,
    )
    metadata = json.loads((tmp_path / "metadata.json").read_text())
    assert (
        metadata["sbom_sha256"]
        == hashlib.sha256((tmp_path / "sbom.cdx.json").read_bytes()).hexdigest()
    )
    assert metadata["artifact_digest"] == env["ARTIFACT_DIGEST"]
    fake = tmp_path / "bin"
    fake.mkdir()
    aws = fake / "aws"
    aws.write_text("""#!/usr/bin/env python3
import os, pathlib, sys
args=sys.argv[1:]
assert args[:2]==['s3api','put-object']
assert args[args.index('--if-none-match')+1]=='*'
key=args[args.index('--key')+1]
with open('calls','a') as log: log.write(key+'\\n')
if os.environ.get('FAIL_FILE') and key.endswith('/'+os.environ['FAIL_FILE']):sys.exit(12)
""")
    aws.chmod(0o755)
    env["PATH"] = str(fake) + os.pathsep + env["PATH"]
    subprocess.run(
        ["bash", str(REF / "publish-sbom-evidence.sh")],
        cwd=tmp_path,
        env=env,
        check=True,
    )
    names = [Path(x).name for x in (tmp_path / "calls").read_text().splitlines()]
    assert names == [
        "sbom.cdx.json",
        "sbom.cdx.json.sha256",
        "osv-findings.json",
        "metadata.json",
    ]
    (tmp_path / "calls").unlink()
    result = subprocess.run(
        ["bash", str(REF / "publish-sbom-evidence.sh")],
        cwd=tmp_path,
        env=dict(env, FAIL_FILE="osv-findings.json"),
    )
    assert result.returncode == 12
    assert "metadata.json" not in (tmp_path / "calls").read_text()


def test_full_schema_rejects_invalid_component_and_artifact(tmp_path):
    bom = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "version": 1,
        "metadata": {
            "component": {"type": "invalid-component-type", "name": "candidate"}
        },
    }
    path = tmp_path / "sbom.cdx.json"
    path.write_text(json.dumps(bom))
    result = subprocess.run(
        [sys.executable, str(REF / "validate-sbom.py"), str(path), str(REF / "schema")],
        capture_output=True,
    )
    assert result.returncode != 0
    env = dict(
        os.environ,
        GITHUB_REPOSITORY="houseworksinc/arca-api",
        GITHUB_SHA="abc",
        VERSION="v1",
        ARTIFACT_DIGEST="mutable:latest",
    )
    result = subprocess.run(
        [sys.executable, str(REF / "prepare-sbom-evidence.py")],
        cwd=tmp_path,
        env=env,
        capture_output=True,
    )
    assert result.returncode != 0
    assert not (tmp_path / "metadata.json").exists()
