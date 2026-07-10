# Dependencies and Contract

## GitHub Actions dependencies

- `actions/github-script@v9`
- `actions/checkout@v6`
- `actions/upload-artifact@v7`

## Required workflow inputs

- `.github/scripts/ai-review-run.mjs`
  - Repo-checked-in executable script invoked by the workflow with `node`

## Optional repo override file

- `.github/ai-review/config.yml`
  - Repo-specific guidance and tuning knobs
  - Safe to omit
  - Loaded by the workflow and passed to the runner as normalized JSON/env values
  - Also merged into `AI_REVIEW_REPO_PROMPT_CONTEXT` for prompt injection

## Optional workflow inputs

- `vars.AI_REVIEW_MODEL`
- `vars.AI_REVIEW_CLAUDE_MODEL`
- `vars.AI_REVIEW_CODEX_MODEL`

## Optional Slack secrets

- `secrets.SLACK_BOT_TOKEN`
- `secrets.SLACK_CHANNEL_ID`

If either Slack secret is missing, the workflow should skip the notification rather than fail the job.

## Runner contract

- The workflow assumes a self-hosted runner pool.
- Update the `runs-on` label list when applying to another repo.
- The runner must have `node` available so it can execute the checked-in script.
