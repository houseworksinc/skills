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

## Provider credentials

A runner that starts each job with an empty HOME, such as the b450 ephemeral pool, has no CLI login. Set these as repository or organization secrets:

- `secrets.ANTHROPIC_API_KEY` or `secrets.CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) for `/ai-review` and `/ai-review claude`
- `secrets.OPENAI_API_KEY` for `/ai-review codex`

A runner that already has a logged-in CLI needs none of them. An absent secret is unset before the runner starts, so it does not replace that login.

## Optional Slack secrets

- `secrets.SLACK_BOT_TOKEN`
- `secrets.SLACK_CHANNEL_ID`

If either Slack secret is missing, the workflow should skip the notification rather than fail the job.

## Runner contract

- The workflow assumes a self-hosted runner pool.
- Update the `runs-on` label list when applying to another repo.
- The runner must have `node` available so it can execute the checked-in script.
- The workflow installs the pinned `claude` or `codex` CLI with npm in every job.
- The workflow runs the runner scripts from the default branch, never from the PR head. Changes to `.github/scripts/` take effect only after they merge.
