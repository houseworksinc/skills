---
name: github-ai-review-workflow
description: >
  Installs a reusable GitHub Actions AI review workflow for pull request comments. Use when a repo
  needs /ai-review, artifact capture, and failure notifications, and the same control plane should
  be portable across multiple repositories later.
---

# GitHub AI Review Workflow

Reusable control plane for comment-triggered AI PR review.

## What this skill packages

- A portable GitHub Actions workflow template
- A repo-local review script contract it depends on
- The variable, secret, and runner-label contract needed to apply it in another repo
- A repo override layer for repo-specific reviewer behavior

## How to use it

> **Source-of-truth rule:** This directory is the canonical source for the AI-review
> workflow and runner contract. After installation, sync workflow changes from here;
> do not modify a repository's copied workflow or runner implementation locally.
> Repository-specific custom reviewer skills belong in `.github/ai-review/config.yml`.

1. Copy the workflow template from [references/workflow.yml](references/workflow.yml) into the target repo at `.github/workflows/ai-review.yml`.
2. Add a repo-local executable that satisfies [references/runner-contract.md](references/runner-contract.md) at `.github/scripts/ai-review-run.mjs`.
3. Add an optional repo override file from [references/repo-overrides.example.yml](references/repo-overrides.example.yml) at `.github/ai-review/config.yml`.
4. Configure the required variables and secrets listed in [references/dependencies.md](references/dependencies.md).
5. Adjust runner labels, Slack configuration, or command policy in the copied workflow if the target repo differs from the default HouseWorks setup.

## Reusable structure

Keep the same split everywhere:

- `workflow.yml` owns GitHub event handling, permission checks, PR metadata collection, artifact upload, comment posting, and Slack failure alerts.
- The repo-local runner script owns the actual review execution and output formatting.
- The repo override file owns repo-specific guidance, exclusions, and reviewer behavior knobs.
- The workflow normalizes the override file and passes it to the runner as JSON, env values, and a merged prompt context string.

That separation is what makes the workflow independently applyable across repos.

## References

- [Workflow template](references/workflow.yml)
- [Runner contract](references/runner-contract.md)
- [Repo overrides example](references/repo-overrides.example.yml)
- [Dependencies and config](references/dependencies.md)
- [Apply checklist](references/install.md)
