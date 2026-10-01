# SBOM generator contract

The target repository supplies `.github/scripts/generate-sbom.sh`. The workflow calls it with no
arguments from the repository root. It must:

1. Exit non-zero on generation failure.
2. Write exactly `sbom.cdx.json` in the repository root.
3. Write `.github/sbom/artifact-digest` containing `sha256:<64 lowercase hex>` or an
   immutable image reference ending `@sha256:<64 lowercase hex>`. Hash the exact built
   artifact; source-only profiles hash a reproducible source/package manifest.
4. Emit full-schema-valid CycloneDX 1.5 or 1.6 JSON describing the deliverable being released.
5. Use an immutable image digest or built release bundle for deployable software whenever one
   exists. A source-tree scan is acceptable only for source-only libraries, experiments, and IaC.
6. Exclude secrets, build caches, `node_modules`, virtual environments, and PHI-bearing runtime
   data from the scan target.

Examples:

```bash
# Container release: image digest was built earlier in the workflow.
syft "$IMAGE_DIGEST" -o cyclonedx-json > sbom.cdx.json

# Python library or source-only service, after installing the locked production environment.
cyclonedx-py environment --of JSON -o sbom.cdx.json

# Node package built from its locked production dependency tree.
npx --yes @cyclonedx/cyclonedx-npm@6 --output-format JSON --output-file sbom.cdx.json --omit dev
```

The template intentionally does not impose one generator: package-native generators preserve
dependency scope, while Syft is the preferred image and cross-ecosystem fallback.

The actual production deployment workflow must generate from the pushed image or built bundle
that it deploys, publish evidence before rollout, and append a create-only deployment marker
after successful deployment. A tag scan by itself does not prove the deployed artifact.
