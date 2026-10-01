# Dependencies and permissions

## GitHub variables

Set these non-secret repository or environment variables:

| Variable | Purpose |
|---|---|
| `SBOM_AWS_ROLE_ARN` | Per-repository OIDC role, limited to writing that repository's S3 prefix. |
| `SBOM_AWS_REGION` | Region containing the evidence bucket. |
| `SBOM_S3_BUCKET` | Private S3 evidence bucket name. |
| `SBOM_S3_PREFIX` | Common prefix, normally `sbom`. |

## Required permissions

The scan job needs `contents: read`. Only the separate release publisher needs `actions: read`
and `id-token: write`. The AWS role trust
policy must restrict the GitHub OIDC `sub` claim to the intended repository and release/branch
contexts. Its S3 policy must only allow writes under
`s3://$SBOM_S3_BUCKET/$SBOM_S3_PREFIX/<owner>/<repo>/releases/*` and must deny reads, deletes, and bucket
listing. Require create-only conditional writes, use the bucket's dedicated default SSE-KMS key and grant the role only the required KMS encrypt/data-key permissions.

Do not give the workflow static AWS credentials or broad account access.

Dependency-Track, PostgreSQL, Linear and optional reporting credentials belong only to the
central service.
Product-repository workflows publish evidence to S3 and have no path to query or modify either
system.
