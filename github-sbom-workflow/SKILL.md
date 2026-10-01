---
name: github-sbom-workflow
description: >
  Installs the HouseWorks reusable GitHub Actions SBOM workflow. Use when a repository needs
  CycloneDX evidence, dependency-change PR checks, durable S3 retention, and Dependency-Track
  inventory/triage without a paid SCA platform.
---

# GitHub SBOM Workflow

Reusable supply-chain control plane for HouseWorks repositories.

## What this skill packages

- A PR and release GitHub Actions workflow template
- A repo-local SBOM generation contract so each product scans its actual deliverable
- A small repository configuration file
- S3 evidence-publishing and normalized inventory reporting contracts
- Installation and security-configuration guidance

## How to use it

1. Copy [references/workflow.yml](references/workflow.yml) to the target repository as
   `.github/workflows/sbom.yml`.
2. Copy [references/repo-config.example.yml](references/repo-config.example.yml) to
   `.github/sbom/config.yml` and set the proposed catalog identifiers.
3. Add an executable `.github/scripts/generate-sbom.sh` implementing the
   [generator contract](references/generator-contract.md). It must produce
   `sbom.cdx.json` for the built release artifact or image and the matching
   `.github/sbom/artifact-digest` file.
4. Copy `validate-sbom.py` and `prepare-sbom-evidence.py` to `.github/scripts/`, copy
   `publish-sbom-evidence.sh` there as an executable, and copy the entire `schema/` directory
   (including its license) to `.github/sbom/schema/`.
5. Configure the GitHub variables and OIDC role described in [dependencies](references/dependencies.md).
6. Start with `enforcement: report`; change it to `required` only after the pilot is accepted.

## Lifecycle

- **Dependency-relevant PR:** generate and validate a candidate BOM, run OSV scanning, and
  publish short-lived reviewer evidence. No PR is uploaded to the central inventory.
- **Release tag:** generate the authoritative BOM from the release artifact, scan it, and publish
  the BOM, checksum, metadata, and machine-readable OSV result to S3.
- **Scheduled organization inventory:** the central worker validates S3 evidence and imports
  every committed release into Dependency-Track. PostgreSQL retains analysis history; Linear
  owns remediation and exceptions. ClickHouse/Metabase are optional reporting. Application
  workflows receive no central API or database credentials.

The canonical policy and repository classifications live in
`common-houseworks-ops`, not in each product repository.

## References

- [Workflow template](references/workflow.yml)
- [Repository configuration example](references/repo-config.example.yml)
- [Generator contract](references/generator-contract.md)
- [Dependencies and permissions](references/dependencies.md)
- [Reporting and normalization contract](references/reporting-contract.md)
- [Installation checklist](references/install.md)
