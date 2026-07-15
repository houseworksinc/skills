# SBOM generator contract

The target repository supplies `.github/scripts/generate-sbom.sh`. The workflow calls it with no
arguments from the repository root. It must:

1. Exit non-zero on generation failure.
2. Write exactly `sbom.cdx.json` in the repository root.
3. Emit valid CycloneDX JSON describing the deliverable being released.
4. Use an immutable image digest or built release bundle for deployable software whenever one
   exists. A source-tree scan is acceptable only for source-only libraries, experiments, and IaC.
5. Exclude secrets, build caches, `node_modules`, virtual environments, and PHI-bearing runtime
   data from the scan target.

Examples:

```bash
# Container release: image digest was built earlier in the workflow.
syft "$IMAGE_DIGEST" -o cyclonedx-json > sbom.cdx.json

# Python library or source-only service, after installing the locked production environment.
cyclonedx-py environment --of JSON -o sbom.cdx.json

# Node package built from its locked production dependency tree.
npx --yes @cyclonedx/cyclonedx-npm@5 --output-format JSON --output-file sbom.cdx.json --omit dev
```

The template intentionally does not impose one generator: package-native generators preserve
dependency scope, while Syft is the preferred image and cross-ecosystem fallback.
