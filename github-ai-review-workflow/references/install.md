# Apply Checklist

Use this when porting the workflow into a new repository.

## Files to copy

- `.github/workflows/ai-review.yml`
- `.github/scripts/ai-review-run.mjs`
- `.github/ai-review/config.yml` if the repo wants overrides

## Repo configuration

- Make sure the repo-local script satisfies [runner contract](runner-contract.md).
- Add `.github/ai-review/config.yml` if the repo wants custom reviewer behavior.
- Add any model variables you want to support:
  - `AI_REVIEW_MODEL`
  - `AI_REVIEW_CLAUDE_MODEL`
  - `AI_REVIEW_CODEX_MODEL`
- Add Slack secrets if you want failure alerts:
  - `SLACK_BOT_TOKEN`
  - `SLACK_CHANNEL_ID`
- Make sure the `ai-review` label exists, or leave the workflow’s create-if-missing logic in place.
- Update `runs-on` labels to match the target runner pool.
- Make sure the runner has Node available, since the workflow invokes the checked-in script with `node`.

## Validation

- Trigger `/ai-review`, `/ai-review claude`, and `/ai-review codex` in a PR comment.
- Confirm the workflow posts a PR comment.
- Confirm failures send a Slack alert when the Slack secrets are present.
