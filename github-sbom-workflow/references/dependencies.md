# Dependencies and permissions

## GitHub variables

Set these non-secret repository or environment variables:

| Variable | Purpose |
|---|---|
| `SBOM_AWS_ROLE_ARN` | Per-repository OIDC role, limited to writing that repository's S3 prefix. |
| `SBOM_AWS_REGION` | Region containing the evidence bucket. |
| `SBOM_S3_BUCKET` | Private S3 evidence bucket name. |
| `SBOM_S3_PREFIX` | Common prefix, normally `sbom`. |

Optional variables:

| Variable | Purpose |
|---|---|
| `DEPENDENCY_TRACK_URL` | HTTPS base URL for the self-hosted Dependency-Track service. |

## Secrets

| Secret | Purpose |
|---|---|
| `DEPENDENCY_TRACK_API_KEY` | Team-scoped Dependency-Track API key; configure only when central upload is enabled. |

## Required permissions

The workflow needs `contents: read`, `actions: read`, and `id-token: write`. The AWS role trust
policy must restrict the GitHub OIDC `sub` claim to the intended repository and release/branch
contexts. Its S3 policy must only allow writes under
`s3://$SBOM_S3_BUCKET/$SBOM_S3_PREFIX/<owner>/<repo>/` and must deny reads, deletes, and bucket
listing. Use SSE-KMS and grant the role only the required KMS encrypt/data-key permissions.

Do not give the workflow static AWS credentials or broad account access.
