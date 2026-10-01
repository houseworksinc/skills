# Installation checklist

1. Confirm the repository's proposed row in the ops catalog.
2. Add the repository-specific OIDC role and scoped S3 prefix policy.
3. Add the GitHub variables listed in `dependencies.md`; do not add AWS access keys.
4. Add the workflow, config, local generator, validation/preparation/publication helpers and
   offline schema directory. Make both shell helpers executable.
5. Run `workflow_dispatch` in report mode and inspect `sbom.cdx.json` plus `metadata.json`.
6. Verify the release BOM, checksum, metadata, and OSV result exist at the expected S3 prefix and
   that the manifest SHA matches.
7. Verify the central ingestion worker imports the release into Dependency-Track and the
   coverage report includes its immutable evidence and deployed/supported version.
8. Enable branch protection's required `supply-chain-policy` check only after the pilot has no
   unresolved false positives.

The scan job has no OIDC permission. Its artifacts are uploaded before a required gate fails.
Only the separate tag publisher requests OIDC. Actual deployment workflows must explicitly
wire the same helpers to the exact artifact and write deployment.json after successful rollout.
Test collision/partial publication: metadata is last and every write uses If-None-Match: *.
