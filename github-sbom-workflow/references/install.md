# Installation checklist

1. Confirm the repository's proposed row in the ops catalog.
2. Add the repository-specific OIDC role and scoped S3 prefix policy.
3. Add the GitHub variables listed in `dependencies.md`; do not add AWS access keys.
4. Add the workflow, config, and local generator script.
5. Run `workflow_dispatch` in report mode and inspect `sbom.cdx.json` plus `metadata.json`.
6. Verify the release BOM, checksum, metadata, and OSV result exist at the expected S3 prefix and
   that the manifest SHA matches.
7. Verify the central normalizer imports the release into ClickHouse and it appears in the Metabase
   coverage dashboard.
8. Enable branch protection's required `supply-chain-policy` check only after the pilot has no
   unresolved false positives.
