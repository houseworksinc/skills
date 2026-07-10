# Runner Contract

The workflow expects a repo-checked-in executable at `.github/scripts/ai-review-run.mjs`.

The workflow also loads `.github/ai-review/config.yml` when present and exposes the normalized
override data to the script through environment variables.

## Required environment variables

- `PROVIDER`
- `AI_REVIEW_MODEL`
- `AI_REVIEW_CLAUDE_MODEL`
- `AI_REVIEW_CODEX_MODEL`
- `PR_NUMBER`
- `PR_TITLE`
- `ADDITIONS`
- `DELETIONS`
- `CHANGED_FILES`
- `CHANGED_FILES_LIST`
- `RISK_MODE`
- `HEAD_SHA`
- `HEAD_REF`
- `HEAD_REPO`
- `BASE_SHA`
- `BASE_REF`
- `BASE_REPO`
- `PR_AUTHOR`
- `COMMENTER`
- `REVIEW_WORKSPACE`
- `AI_REVIEW_ARTIFACT_DIR`
- `AI_REVIEW_REPO_CONFIG_JSON`
- `AI_REVIEW_REPO_REVIEWER_NOTES`
- `AI_REVIEW_REPO_IGNORED_PATHS_JSON`
- `AI_REVIEW_REPO_HIGH_PRIORITY_PATHS_JSON`
- `AI_REVIEW_REPO_PROMPT_FRAGMENTS_JSON`
- `AI_REVIEW_REPO_PROMPT_CONTEXT`
- `AI_REVIEW_REPO_REVIEW_MODE`
- `AI_REVIEW_REPO_INLINE_COMMENT_LIMIT`
- `AI_REVIEW_REPO_SUMMARY_FINDINGS_LIMIT`

## Required outputs

The script should write GitHub Actions outputs to `$GITHUB_OUTPUT` and, at minimum, provide:

- `provider`
- `pr_classification`
- `review_model_reported`
- `review_model_source`
- `review_input_tokens`
- `review_output_tokens`
- `review_cost_usd`
- `review_usage_source`
- `review_duration_seconds`
- `runner_name`
- `runner_os`
- `host`
- `workspace`
- `checked_out_sha`
- `checked_out_branch`
- `tool_path`
- `tool_ready`
- `tool_version`
- `tool_error`
- `command`
- `review_payload`
- `review_comment_body`

## Behavioral contract

- Exit non-zero when the review cannot be produced.
- Prefer structured outputs so the workflow can render a PR comment without guessing.
- Ensure the comment body includes `Review completed successfully. No Findings.` when there are zero findings.
- Populate usage and model metadata when available, even if the provider is a fallback or wrapper.
- Merge repo override values into the prompt or scoring logic when provided.
- Prefer `AI_REVIEW_REPO_PROMPT_CONTEXT` as the single merged prompt override input.
