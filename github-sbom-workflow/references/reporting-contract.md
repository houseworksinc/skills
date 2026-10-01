# Release evidence and central ingestion contract

Product workflows publish immutable evidence. The central worker validates and imports it into
Dependency-Track; PostgreSQL owns inventory and analysis history. Linear owns remediation and
exception approvals. Optional ClickHouse/Metabase consumers never become a second triage authority.

```text
s3://<bucket>/<prefix>/houseworksinc/<repo>/releases/<version>/
  sbom.cdx.json
  sbom.cdx.json.sha256
  osv-findings.json
  metadata.json
  deployment.json       # actual deployment workflow only, after successful rollout
```

Publish the first four files in this order with If-None-Match: *. Metadata is the commit marker
and includes repository, Git revision, immutable version, timestamp, BOM SHA-256, actual artifact
digest and scanner outcome. A failed scanner still leaves reviewer artifacts and explicit failure
evidence. Required policy failure prevents release publication; report mode does not mean clean.
The deployment marker copies matching metadata and adds environment and UTC deployment time.
Never reuse a release identity. Partial publication or collision fails visibly for operator review.

The central worker validates manifest/path identity, checksum, scan JSON and the full offline
CycloneDX schema. Persistent tokens survive restart; imported projects/components are verified
before the receipt completes. Upload/import success is separate from analysis completion.

Every committed release remains in inventory. Coverage combines latest successful deployment
per environment with explicitly supported older versions, checks evidence and analysis freshness,
and reports missing/incomplete results. Advisory refresh and exception review do not depend on
a new release. PostgreSQL and adapter/action state are backed up separately from S3 evidence.

Legacy ClickHouse rescan/normalizer contracts are optional reporting only. Their human triage
records must be preserved if migrated; scanner imports must not overwrite decisions.
