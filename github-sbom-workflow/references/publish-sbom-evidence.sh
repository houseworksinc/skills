#!/usr/bin/env bash
# Copy to .github/scripts/publish-sbom-evidence.sh. Fail closed on collisions.
set -euo pipefail
: "${BUCKET:?Missing evidence bucket}"
: "${PREFIX:?Missing evidence prefix}"
: "${VERSION:?Missing release version}"
: "${GITHUB_REPOSITORY:?Missing repository identity}"
[[ "$PREFIX" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo 'Invalid evidence prefix' >&2; exit 1; }
[[ "$VERSION" =~ ^[a-zA-Z0-9._-]+$ ]] || { echo 'Invalid release version' >&2; exit 1; }
[[ "$GITHUB_REPOSITORY" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] || exit 1
for file in sbom.cdx.json sbom.cdx.json.sha256 osv-findings.json metadata.json; do
  test -s "$file"
done
jq -e --arg repository "$GITHUB_REPOSITORY" --arg version "$VERSION" \
  '.repository == $repository and .version == $version' metadata.json >/dev/null
actual_sha="$(sha256sum sbom.cdx.json | awk '{print $1}')"
[[ "$actual_sha" == "$(awk '{print $1}' sbom.cdx.json.sha256)" ]]
[[ "$actual_sha" == "$(jq -r .sbom_sha256 metadata.json)" ]]
jq -e . osv-findings.json >/dev/null
key="$PREFIX/$GITHUB_REPOSITORY/releases/$VERSION"
# Metadata is the commit marker: discoverers never see a complete release until
# all required evidence was written. Bucket-default SSE-KMS selects the approved
# dedicated key; do not override it with the AWS-managed default KMS key.
for file in sbom.cdx.json sbom.cdx.json.sha256 osv-findings.json metadata.json; do
  aws s3api put-object --bucket "$BUCKET" --key "$key/$file" \
    --body "$file" --if-none-match '*' >/dev/null
done
