# Reporting and normalization contract

The product workflow publishes immutable evidence only. The central SBOM normalizer reads this
contract and creates the rebuildable ClickHouse inventory used by Metabase.

## Release evidence layout

```text
s3://<bucket>/<prefix>/houseworksinc/<repo>/releases/<version>/
  sbom.cdx.json
  sbom.cdx.json.sha256
  metadata.json
  osv-findings.json
```

`metadata.json` identifies the repository, Git revision, release version, generation timestamp,
format, and BOM SHA-256. `osv-findings.json` is the OSV scanner's machine-readable output for the
same BOM checksum.

## Rescan evidence layout

The normalizer re-queries OSV against the latest retained SBOM of each repository daily. Each run
writes a distinct, immutable object — never overwriting a prior day's scan — so historical evidence
can always be reconstructed:

```text
s3://<bucket>/<prefix>/houseworksinc/<repo>/releases/<version>/rescans/<date>/<scan_id>.json
```

The `<scan_id>` is a per-run UUID. The normalizer persists that S3 key in the corresponding
`scan_runs.evidence_key` column alongside its status and timestamps, giving Metabase and auditors a
stable link from each scan record back to its raw OSV output. Failed runs record `status=failed`
with an empty `evidence_key` and still produce a `scan_runs` row so partial runs are visible.

## Central responsibilities

The central normalizer, not a product workflow:

1. Discovers release `metadata.json` objects and verifies the referenced checksum.
2. Parses CycloneDX components (including nested components) and dependency edges into the
   documented ClickHouse tables.
3. Imports OSV findings and creates a reproducible `scan_runs` record linking to its evidence key.
4. Rescans the latest retained SBOM for each applicable repository daily, retaining both raw output
   in S3 (one immutable object per scan) and normalized findings in ClickHouse.
5. Never overwrites human-owned `finding_triage` fields.

The normalizer is the only workload with S3 read and ClickHouse write permissions. Metabase has
read-only access to the derived tables.
