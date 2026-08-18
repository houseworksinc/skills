#!/usr/bin/env bash
#
# Canonical repo-local AI review runner implementation.
# Keep this file synchronized from houseworksinc/skills/github-ai-review-workflow.
# The checked-in ai-review-run.mjs wrapper invokes this script with bash.
# Optional model variables:
# - AI_REVIEW_CLAUDE_MODEL for Claude runs
# - AI_REVIEW_CODEX_MODEL for Codex runs
# - AI_REVIEW_MODEL as a legacy fallback for both providers

set -euo pipefail
umask 077

provider="${PROVIDER:-claude}"
provider_timeout_seconds="${AI_REVIEW_TIMEOUT_SECONDS:-900}"
repo_review_prompt_context="${AI_REVIEW_REPO_PROMPT_CONTEXT:-}"
repo_instruction_files_json="${AI_REVIEW_REPO_INSTRUCTION_FILES_JSON:-[]}"
review_model_requested="${AI_REVIEW_MODEL:-}"
review_model_requested_source="AI_REVIEW_MODEL"
if [[ "${provider}" == "claude" && -n "${AI_REVIEW_CLAUDE_MODEL:-}" ]]; then
  review_model_requested="${AI_REVIEW_CLAUDE_MODEL}"
  review_model_requested_source="AI_REVIEW_CLAUDE_MODEL"
elif [[ "${provider}" == "codex" && -n "${AI_REVIEW_CODEX_MODEL:-}" ]]; then
  review_model_requested="${AI_REVIEW_CODEX_MODEL}"
  review_model_requested_source="AI_REVIEW_CODEX_MODEL"
fi
review_model_reported=""
review_model_source=""
review_input_tokens=""
review_output_tokens=""
review_cost_usd=""
review_usage_source=""
review_started_at="$(date +%s)"
review_duration_seconds=""
pr_classification="mixed"
runner_name="${RUNNER_NAME:-unknown}"
runner_os="${RUNNER_OS:-unknown}"
host="$(hostname)"
workspace="${REVIEW_WORKSPACE:-$(pwd)}"
checked_out_sha="$(git -C "${workspace}" rev-parse HEAD 2>/dev/null || printf 'unknown')"
checked_out_branch="$(git -C "${workspace}" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'unknown')"
github_repository="${GITHUB_REPOSITORY:-unknown}"
pr_number="${PR_NUMBER:-0}"
pr_title="${PR_TITLE:-}"
additions="${ADDITIONS:-0}"
deletions="${DELETIONS:-0}"
changed_files="${CHANGED_FILES:-0}"
risk_mode="${RISK_MODE:-line-review}"
changed_files_list="${CHANGED_FILES_LIST:-}"
command="./review-runner run --repo ${github_repository} --pr ${pr_number}"
base_sha="${BASE_SHA:-}"
base_ref="${BASE_REF:-}"
base_repo="${BASE_REPO:-}"
head_sha="${HEAD_SHA:-}"
head_ref="${HEAD_REF:-}"
head_repo="${HEAD_REPO:-}"
pr_author="${PR_AUTHOR:-}"
commenter="${COMMENTER:-}"

tool_path=""
tool_ready="no"
tool_version=""
tool_error=""
review_status="failure"
review_payload=""
review_comment_body=""
context_bundle=""
context_bundle_line_count="0"
local_diff_available="no"
provider_timed_out="no"
scratch_dir="${AI_REVIEW_SCRATCH_DIR:-}"
if [[ -n "${scratch_dir}" ]]; then
  if [[ ! -d "${scratch_dir}" || ! -O "${scratch_dir}" || -L "${scratch_dir}" ]]; then
    printf 'AI review scratch directory is missing, unsafe, or not owned by the runner user: %s\n' "${scratch_dir}" >&2
    exit 1
  fi
  work_tmp_dir="$(mktemp -d "${scratch_dir}/runner.XXXXXX")"
else
  work_tmp_dir="$(mktemp -d)"
fi

prompt_file=""
output_file=""
context_bundle_file=""
codex_events_file=""
evidence_file=""

mktemp_workfile() {
  mktemp -p "${work_tmp_dir}"
}

prompt_file="$(mktemp_workfile)"
output_file="$(mktemp_workfile)"
context_bundle_file="$(mktemp_workfile)"
codex_events_file="$(mktemp_workfile)"
evidence_file="$(mktemp_workfile)"

cleanup() {
  rm -f "${prompt_file}" "${output_file}" "${context_bundle_file}" "${codex_events_file}" "${evidence_file}"
  rm -rf "${work_tmp_dir}"
}

trap cleanup EXIT

emit_output() {
  local key="$1"
  local value="${2:-}"
  local delimiter="ghadelim-$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"

  if printf '%s' "${value}" | grep -qF "${delimiter}"; then
    value=""
  fi

  printf '%s<<%s\n' "${key}" "${delimiter}"
  printf '%s\n' "${value}"
  printf '%s\n' "${delimiter}"
}

append_file_excerpt() {
  local title="$1"
  local path="$2"
  local max_lines="$3"

  if [[ ! -f "${path}" ]]; then
    return
  fi

  {
    printf '\n## %s\n' "${title}"
    printf 'Path: %s\n\n' "${path#"${workspace}/"}"
    sed -n "1,${max_lines}p" "${path}"
    local line_count
    line_count="$(wc -l < "${path}" | tr -d ' ')"
    if [[ "${line_count}" -gt "${max_lines}" ]]; then
      printf '\n[truncated after %s lines]\n' "${max_lines}"
    fi
  } >> "${context_bundle_file}"
}

append_repository_instruction_files() {
  local instruction_files
  local instruction_path

  instruction_files="$(
    node -e '
      try {
        const values = JSON.parse(process.argv[1] || "[]");
        if (Array.isArray(values)) {
          for (const value of values) {
            if (typeof value === "string" && value.trim()) console.log(value.trim());
          }
        }
      } catch {
        process.exit(1);
      }
    ' "${repo_instruction_files_json}" 2>/dev/null || true
  )"

  while IFS= read -r instruction_path; do
    [[ -z "${instruction_path}" ]] && continue
    if [[ "${instruction_path}" == /* || "${instruction_path}" == ../* || "${instruction_path}" == */../* || "${instruction_path}" == *"/.." ]]; then
      printf '\n## Repository Guidance\nSkipped unsafe configured instruction path: %s\n' "${instruction_path}" >> "${context_bundle_file}"
      continue
    fi

    local instruction_file="${workspace}/${instruction_path}"
    if [[ -L "${instruction_file}" ]]; then
      printf '\n## Repository Guidance\nSkipped symlinked configured instruction file: %s\n' "${instruction_path}" >> "${context_bundle_file}"
      continue
    fi

    append_file_excerpt "Repository Guidance" "${instruction_file}" 220
  done <<< "${instruction_files}"
}

is_large_generated_context_file() {
  case "$1" in
    uv.lock|poetry.lock|package-lock.json|pnpm-lock.yaml|yarn.lock|Cargo.lock)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

classify_changed_file() {
  local path="$1"

  case "${path}" in
    pyproject.toml|uv.lock|poetry.lock|requirements*.txt|package.json|package-lock.json|pnpm-lock.yaml|yarn.lock|Cargo.lock|go.mod|go.sum)
      printf 'dependency'
      ;;
    .github/*|github/*|Makefile|makefile|Dockerfile|docker-compose*.yml|compose/*|deploy_scripts/*|scripts/*|*.tf|*.tfvars)
      printf 'workflow'
      ;;
    docs/*|*.md|*.rst|*.txt)
      printf 'docs'
      ;;
    *.ts|*.tsx|*.js|*.jsx|*.css|*.scss|*.html|templates/*|static/*|frontend/*|web/*|app/*)
      printf 'frontend'
      ;;
    *.py|*.pyi|*.sql|*.zed|*.zaml|*.yaml|*.yml|config/*|core/*|accounts/*|boards/*|cases/*|middleware/*|org_sites/*|patients/*|referrals/*|scheduling/*|tasks/*|work/*|arca_api/*)
      printf 'backend'
      ;;
    *)
      printf 'backend'
      ;;
  esac
}

classify_pr() {
  local categories=""
  local category=""
  local unique_count=0

  while IFS= read -r changed_file; do
    [[ -z "${changed_file}" ]] && continue
    category="$(classify_changed_file "${changed_file}")"
    case " ${categories} " in
      *" ${category} "*)
        ;;
      *)
        categories="${categories} ${category}"
        unique_count=$((unique_count + 1))
        ;;
    esac
  done <<< "${CHANGED_FILES_LIST:-}"

  if [[ "${unique_count}" -eq 1 ]]; then
    printf '%s' "${categories# }"
  elif [[ "${unique_count}" -eq 0 ]]; then
    printf 'mixed'
  else
    printf 'mixed'
  fi
}

append_grouped_changed_files() {
  printf '\n## Changed Files By Category\n' >> "${context_bundle_file}"

  for category in dependency backend frontend workflow docs other; do
    local printed_header="no"
    while IFS= read -r changed_file; do
      [[ -z "${changed_file}" ]] && continue
      local changed_category
      changed_category="$(classify_changed_file "${changed_file}")"
      [[ "${changed_category}" == "${category}" ]] || continue
      if [[ "${printed_header}" == "no" ]]; then
        printf '\n### %s\n' "${category}" >> "${context_bundle_file}"
        printed_header="yes"
      fi
      printf -- '- %s\n' "${changed_file}" >> "${context_bundle_file}"
    done <<< "${CHANGED_FILES_LIST:-}"
  done
}

append_changed_hunks() {
  {
    printf '\n## Changed Hunks With Nearby Code\n\n'
    if [[ "${local_diff_available}" != "yes" ]]; then
      printf 'Base commit is not available locally; changed hunks could not be generated.\n'
      return
    fi
  } >> "${context_bundle_file}"

  git -C "${workspace}" diff --unified=20 "${base_sha}...${checked_out_sha}" 2>/dev/null \
    | node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8").split(/\r?\n/);
const maxFiles = Number(process.env.AI_REVIEW_MAX_HUNK_FILES || 20);
const maxHunks = Number(process.env.AI_REVIEW_MAX_HUNKS || 60);
const maxLinesPerHunk = Number(process.env.AI_REVIEW_MAX_HUNK_LINES || 90);
let file = "";
let hunk = null;
let fileCount = 0;
let hunkCount = 0;
let output = [];
const flush = () => {
  if (!hunk || !file || hunkCount >= maxHunks) return;
  hunkCount += 1;
  output.push(`### ${file} ${hunk.header}`);
  output.push(...hunk.lines.slice(0, maxLinesPerHunk));
  if (hunk.lines.length > maxLinesPerHunk) output.push(`[hunk truncated after ${maxLinesPerHunk} lines]`);
  output.push("");
};
for (const line of input) {
  if (line.startsWith("diff --git ")) {
    flush();
    hunk = null;
    const match = line.match(/^diff --git a\/(.+?) b\/(.+)$/);
    file = match ? match[2] : "";
    fileCount += file ? 1 : 0;
    if (fileCount > maxFiles) break;
    continue;
  }
  if (!file) continue;
  if (line.startsWith("@@ ")) {
    flush();
    hunk = { header: line, lines: [] };
    continue;
  }
  if (hunk && !line.startsWith("index ") && !line.startsWith("--- ") && !line.startsWith("+++ ")) {
    hunk.lines.push(line);
  }
}
flush();
if (output.length === 0) output.push("No changed hunks were available.");
if (hunkCount >= maxHunks) output.push(`[truncated after ${maxHunks} hunks]`);
process.stdout.write(output.join("\n"));
' >> "${context_bundle_file}" || printf 'Changed hunk extraction failed.\n' >> "${context_bundle_file}"
}

append_related_tests() {
  {
    printf '\n## Touched And Related Tests\n\n'
    CHANGED_FILES_LIST="${CHANGED_FILES_LIST:-}" node -e '
const fs = require("fs");
const changed = (process.env.CHANGED_FILES_LIST || "").split(/\r?\n/).filter(Boolean);
const allFiles = fs.readFileSync(0, "utf8").split(/\r?\n/).filter(Boolean);
const testFiles = allFiles.filter((path) => /(^|\/)(tests?)(\/|$)|(^|\/)test_|_test\.|\.spec\.|\.test\./.test(path));
const touched = changed.filter((path) => testFiles.includes(path));
const related = new Set();
for (const file of changed) {
  if (testFiles.includes(file)) continue;
  const parts = file.split("/");
  const top = parts[0] || "";
  const base = (parts[parts.length - 1] || "").replace(/\.[^.]+$/, "");
  for (const test of testFiles) {
    if (top && test.startsWith(`${top}/tests/`)) related.add(test);
    if (base && (test.includes(`test_${base}`) || test.includes(`${base}_test`) || test.includes(`${base}.test`) || test.includes(`${base}.spec`))) related.add(test);
  }
}
function printList(title, values, empty) {
  console.log(`### ${title}`);
  if (values.length === 0) {
    console.log(empty);
  } else {
    for (const value of values.slice(0, 40)) console.log(`- ${value}`);
    if (values.length > 40) console.log(`[truncated after 40 entries]`);
  }
  console.log("");
}
printList("Touched tests", touched, "No changed test files.");
printList("Related tests by path/name proximity", Array.from(related).sort(), "No nearby tests found.");
'
  } >> "${context_bundle_file}" < <(git -C "${workspace}" ls-files)
}

append_dependency_metadata() {
  {
    printf '\n## Dependency Metadata\n\n'
    if ! printf '%s\n' "${CHANGED_FILES_LIST:-}" | grep -Eq '(^|/)(pyproject.toml|uv.lock|poetry.lock|package.json|package-lock.json|pnpm-lock.yaml|yarn.lock)$'; then
      printf 'No recognized dependency manifest or lockfile changed.\n'
      return
    fi

    printf 'Recognized changed dependency files:\n'
    printf '%s\n' "${CHANGED_FILES_LIST:-}" | grep -E '(^|/)(pyproject.toml|uv.lock|poetry.lock|package.json|package-lock.json|pnpm-lock.yaml|yarn.lock)$' | sed 's/^/- /'
    printf '\n'

    if [[ -f "${workspace}/pyproject.toml" ]]; then
      printf '### pyproject.toml dependency sections\n'
      awk '
        /^\[(project|dependency-groups)\]$/ { keep = 1; print; next }
        /^\[/ { keep = 0 }
        keep { print }
      ' "${workspace}/pyproject.toml" | sed -n '1,180p'
      printf '\n'
    fi

    if [[ -f "${workspace}/package.json" ]]; then
      printf '### package.json dependency keys\n'
      node -e '
const fs = require("fs");
const pkg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
for (const key of ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"]) {
  const deps = pkg[key] || {};
  console.log(`${key}: ${Object.keys(deps).length}`);
}
' "${workspace}/package.json" 2>/dev/null || printf 'Could not parse package.json.\n'
      printf '\n'
    fi
  } >> "${context_bundle_file}"
}

run_evidence_command() {
  local title="$1"
  local timeout_seconds="$2"
  shift 2
  local tmp_output
  tmp_output="$(mktemp_workfile)"

  {
    printf '\n## %s\n\n' "${title}"
    printf 'Command: `%s`\n\n' "$*"
  } >> "${evidence_file}"

  if run_with_timeout "${timeout_seconds}" "$@" > "${tmp_output}" 2>&1; then
    printf 'Exit code: 0\n\n' >> "${evidence_file}"
  else
    local status=$?
    printf 'Exit code: %s\n\n' "${status}" >> "${evidence_file}"
  fi

  sed -n "1,${AI_REVIEW_MAX_OUTPUT_LINES:-120}p" "${tmp_output}" >> "${evidence_file}"
  local line_count
  line_count="$(wc -l < "${tmp_output}" | tr -d ' ')"
  if [[ "${line_count}" -gt "${AI_REVIEW_MAX_OUTPUT_LINES:-120}" ]]; then
    printf '\n[truncated after %s lines]\n' "${AI_REVIEW_MAX_OUTPUT_LINES:-120}" >> "${evidence_file}"
  fi
  rm -f "${tmp_output}"
}

build_evidence() {
  {
    printf '# AI Review Evidence\n\n'
    printf 'Checks enabled: %s\n' "${AI_REVIEW_RUN_CHECKS:-true}"
    printf 'Classification: %s\n' "${pr_classification}"
    printf 'Evidence timeout per command: %s seconds\n' "${AI_REVIEW_MAX_CHECK_SECONDS:-180}"
  } > "${evidence_file}"

  if [[ "${AI_REVIEW_RUN_CHECKS:-true}" != "true" ]]; then
    printf '\nChecks disabled by AI_REVIEW_RUN_CHECKS.\n' >> "${evidence_file}"
    return
  fi

  run_evidence_command "Repository status" "${AI_REVIEW_MAX_CHECK_SECONDS:-180}" git -C "${workspace}" status --short
  run_evidence_command "Changed file summary" "${AI_REVIEW_MAX_CHECK_SECONDS:-180}" git -C "${workspace}" diff --name-status "${base_sha}...${checked_out_sha}"

  if [[ "${pr_classification}" == "dependency" || "${pr_classification}" == "backend" || "${pr_classification}" == "mixed" ]]; then
    if command -v uv >/dev/null 2>&1 && [[ -f "${workspace}/pyproject.toml" ]]; then
      run_evidence_command "uv lock consistency check" "${AI_REVIEW_MAX_CHECK_SECONDS:-180}" bash -lc "cd \"${workspace}\" && uv lock --check --offline"
    else
      printf '\n## uv lock consistency check\n\nSkipped: uv is not available or pyproject.toml is absent.\n' >> "${evidence_file}"
    fi
  fi
}

run_with_timeout() {
  local timeout_seconds="$1"
  shift
  local timeout_marker
  local child_status
  timeout_marker="$(mktemp_workfile)"

  local child_pid
  start_in_process_group "$@"
  child_pid="${started_child_pid}"

  run_timeout_watcher "${timeout_seconds}" "${child_pid}" "${timeout_marker}" &
  local watcher_pid=$!

  set +e
  wait "${child_pid}"
  child_status=$?
  set -e

  kill "${watcher_pid}" 2>/dev/null || true
  wait "${watcher_pid}" 2>/dev/null || true

  if [[ -s "${timeout_marker}" ]]; then
    rm -f "${timeout_marker}"
    return 124
  fi

  rm -f "${timeout_marker}"
  return "${child_status}"
}

run_with_timeout_from_file() {
  local timeout_seconds="$1"
  local stdin_file="$2"
  shift 2
  local timeout_marker
  local child_status
  timeout_marker="$(mktemp_workfile)"

  local child_pid
  start_in_process_group "$@" < "${stdin_file}"
  child_pid="${started_child_pid}"

  run_timeout_watcher "${timeout_seconds}" "${child_pid}" "${timeout_marker}" &
  local watcher_pid=$!

  set +e
  wait "${child_pid}"
  child_status=$?
  set -e

  kill "${watcher_pid}" 2>/dev/null || true
  wait "${watcher_pid}" 2>/dev/null || true

  if [[ -s "${timeout_marker}" ]]; then
    rm -f "${timeout_marker}"
    return 124
  fi

  rm -f "${timeout_marker}"
  return "${child_status}"
}

run_timeout_watcher() {
  local timeout_seconds="$1"
  local child_pid="$2"
  local timeout_marker="$3"

  sleep "${timeout_seconds}"
  if kill -0 "${child_pid}" 2>/dev/null; then
    printf 'timeout\n' > "${timeout_marker}"
    terminate_process_group "${child_pid}" TERM
    sleep 10
    terminate_process_group "${child_pid}" KILL
  fi
}

started_child_pid=""

start_in_process_group() {
  set -m
  "$@" &
  started_child_pid=$!
  set +m
}

terminate_process_tree() {
  local pid="$1"
  local signal="$2"
  local child_pid

  while IFS= read -r child_pid; do
    [[ -n "${child_pid}" ]] && terminate_process_tree "${child_pid}" "${signal}"
  done < <(pgrep -P "${pid}" 2>/dev/null || true)

  kill "-${signal}" "${pid}" 2>/dev/null || true
}

terminate_process_group() {
  local pid="$1"
  local signal="$2"
  local script_group
  local child_group

  script_group="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ' || true)"
  child_group="$(ps -o pgid= -p "${pid}" 2>/dev/null | tr -d ' ' || true)"

  if [[ -n "${child_group}" && "${child_group}" != "${script_group}" ]]; then
    kill "-${signal}" "-${child_group}" 2>/dev/null || true
  fi
  terminate_process_tree "${pid}" "${signal}"
}

read_codex_config_model() {
  local config_home="${CODEX_HOME:-${HOME}/.codex}"
  local config_file="${config_home}/config.toml"

  if [[ ! -f "${config_file}" ]]; then
    return
  fi

  awk -F '=' '
    /^[[:space:]]*model[[:space:]]*=/ {
      value = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "${config_file}"
}

compact_claude_error() {
  local source_file="$1"
  local fallback="${2:-claude failed}"
  local compact=""

  if compact="$(
    node - "${source_file}" 2>/dev/null <<'EOF'
const fs = require("fs");
const sourceFile = process.argv[2];
const text = fs.readFileSync(sourceFile, "utf8").trim();
if (!text) process.exit(1);

const payload = JSON.parse(text);
const status = payload.api_error_status ? `API ${payload.api_error_status}` : "";
const message = payload.result || payload.error?.message || payload.message || "";
const reason = payload.terminal_reason || payload.stop_reason || "";
const parts = [status, message, reason].filter(Boolean);
if (parts.length === 0) process.exit(1);
process.stdout.write(parts.join(" - ").slice(0, 500));
EOF
  )"; then
    printf '%s' "${compact}"
    return
  fi

  sed -n '1p' "${source_file}" | cut -c 1-500
  if [[ -z "$(sed -n '1p' "${source_file}")" ]]; then
    printf '%s' "${fallback}"
  fi
}

claude_reported_error() {
  local source_file="$1"

  node - "${source_file}" 2>/dev/null <<'EOF'
const fs = require("fs");
const sourceFile = process.argv[2];
const text = fs.readFileSync(sourceFile, "utf8").trim();
if (!text) process.exit(1);
const payload = JSON.parse(text);
process.exit(payload && payload.is_error === true ? 0 : 1);
EOF
}

capture_claude_model_usage() {
  local source_file="$1"
  local model_usage=""

  if ! model_usage="$(
    node - "${source_file}" 2>/dev/null <<'EOF'
const fs = require("fs");
const sourceFile = process.argv[2];
const payload = JSON.parse(fs.readFileSync(sourceFile, "utf8"));
const models = Object.keys(payload.modelUsage || {});
process.stdout.write(models.join(", "));
EOF
  )"; then
    model_usage=""
  fi

  if [[ -n "${model_usage}" ]]; then
    review_model_reported="${model_usage}"
    review_model_source="claude modelUsage"
  elif [[ -n "${review_model_requested}" ]]; then
    review_model_reported="${review_model_requested}"
    review_model_source="requested via ${review_model_requested_source}"
  else
    review_model_reported="default"
    review_model_source="claude default; exact model not reported"
  fi
}

capture_claude_usage() {
  local source_file="$1"
  local usage_payload=""

  if ! usage_payload="$(
    node - "${source_file}" 2>/dev/null <<'EOF'
const fs = require("fs");
const sourceFile = process.argv[2];
const payload = JSON.parse(fs.readFileSync(sourceFile, "utf8"));
const usage = payload.usage || {};
const result = {
  inputTokens: usage.input_tokens ?? "",
  outputTokens: usage.output_tokens ?? "",
  costUSD: payload.total_cost_usd ?? "",
};
process.stdout.write(JSON.stringify(result));
EOF
  )"; then
    usage_payload=""
  fi

  if [[ -n "${usage_payload}" ]]; then
    review_input_tokens="$(node -e 'const p=JSON.parse(process.argv[1]); process.stdout.write(String(p.inputTokens ?? ""));' "${usage_payload}")"
    review_output_tokens="$(node -e 'const p=JSON.parse(process.argv[1]); process.stdout.write(String(p.outputTokens ?? ""));' "${usage_payload}")"
    review_cost_usd="$(node -e 'const p=JSON.parse(process.argv[1]); process.stdout.write(p.costUSD === "" ? "" : String(p.costUSD));' "${usage_payload}")"
    review_usage_source="claude json usage"
  fi
}

capture_codex_usage() {
  local source_file="$1"
  local usage_payload=""

  if ! usage_payload="$(
    node - "${source_file}" 2>/dev/null <<'EOF'
const fs = require("fs");
const sourceFile = process.argv[2];
const lines = fs.readFileSync(sourceFile, "utf8")
  .split(/\r?\n/)
  .map((line) => line.trim())
  .filter(Boolean);

let usage = null;
for (const line of lines) {
  if (!line.startsWith("{")) {
    continue;
  }
  try {
    const event = JSON.parse(line);
    if (event.type === "turn.completed" && event.usage) {
      usage = event.usage;
    }
  } catch {
    // Ignore non-JSON log lines emitted by the CLI.
  }
}

if (!usage) {
  process.exit(1);
}

process.stdout.write(JSON.stringify({
  inputTokens: usage.input_tokens ?? "",
  outputTokens: usage.output_tokens ?? "",
}));
EOF
  )"; then
    usage_payload=""
  fi

  if [[ -n "${usage_payload}" ]]; then
    review_input_tokens="$(node -e 'const p=JSON.parse(process.argv[1]); process.stdout.write(String(p.inputTokens ?? ""));' "${usage_payload}")"
    review_output_tokens="$(node -e 'const p=JSON.parse(process.argv[1]); process.stdout.write(String(p.outputTokens ?? ""));' "${usage_payload}")"
    review_cost_usd="unavailable"
    review_usage_source="codex json usage; cost not reported by CLI"
  fi
}

build_context_bundle() {
  local changed_file_count=0
  pr_classification="$(classify_pr)"

  {
    printf '# AI Review Context Bundle\n\n'
    printf 'Repository: %s\n' "${github_repository}"
    printf 'PR: #%s\n' "${PR_NUMBER}"
    printf 'Title: %s\n' "${PR_TITLE}"
    printf 'Author: %s\n' "${pr_author}"
    printf 'Requested by: %s\n' "${commenter}"
    printf 'Base: %s %s %s\n' "${base_repo}" "${base_ref}" "${base_sha}"
    printf 'Head: %s %s %s\n' "${head_repo}" "${head_ref}" "${head_sha}"
    printf 'Changed files: %s\n' "${CHANGED_FILES}"
    printf 'Additions: %s\n' "${ADDITIONS}"
    printf 'Deletions: %s\n' "${DELETIONS}"
    printf 'Review mode: %s\n' "${RISK_MODE}"
    printf 'PR classification: %s\n' "${pr_classification}"
  } > "${context_bundle_file}"

append_file_excerpt "Repository Guidance" "${workspace}/CLAUDE.md" 140
append_repository_instruction_files

  {
    printf '\n## Changed Files\n\n'
    printf '%s\n' "${CHANGED_FILES_LIST:-}"
  } >> "${context_bundle_file}"

  append_grouped_changed_files

  {
    printf '\n## Diff Stat\n\n'
    if [[ -n "${base_sha}" ]] && git -C "${workspace}" cat-file -e "${base_sha}^{commit}" 2>/dev/null; then
      local_diff_available="yes"
      git -C "${workspace}" diff --stat "${base_sha}...${checked_out_sha}" || true
    else
      printf 'Base commit is not available locally; diff stat could not be generated.\n'
    fi
  } >> "${context_bundle_file}"

  {
    printf '\n## Unified Diff\n\n'
    if [[ -n "${base_sha}" ]] && git -C "${workspace}" cat-file -e "${base_sha}^{commit}" 2>/dev/null; then
      git -C "${workspace}" diff --unified=25 "${base_sha}...${checked_out_sha}" | sed -n '1,1200p'
    else
      printf 'Base commit is not available locally; unified diff could not be generated.\n'
    fi
  } >> "${context_bundle_file}"

  append_changed_hunks
  append_related_tests
  append_dependency_metadata

  {
    printf '\n## Changed File Snapshots\n'
    while IFS= read -r changed_file; do
      [[ -z "${changed_file}" ]] && continue
      changed_file_count=$((changed_file_count + 1))
      if [[ "${changed_file_count}" -gt 20 ]]; then
        printf '\n[truncated after 20 changed file snapshots]\n'
        break
      fi

      local absolute_path="${workspace}/${changed_file}"
      if [[ ! -f "${absolute_path}" ]]; then
        printf '\n### %s\nFile not present in head checkout.\n' "${changed_file}"
        continue
      fi

      printf '\n### %s\n\n' "${changed_file}"
      if is_large_generated_context_file "${changed_file}"; then
        printf '[snapshot skipped for generated/lock file; use the diff stat and unified diff above]\n'
        continue
      fi

      sed -n '1,160p' "${absolute_path}"
      local line_count
      line_count="$(wc -l < "${absolute_path}" | tr -d ' ')"
      if [[ "${line_count}" -gt 160 ]]; then
        printf '\n[truncated after 160 lines]\n'
      fi
    done <<< "${CHANGED_FILES_LIST:-}"
  } >> "${context_bundle_file}"

  context_bundle="$(cat "${context_bundle_file}")"
  context_bundle_line_count="$(wc -l < "${context_bundle_file}" | tr -d ' ')"
}

capture_review_payload() {
  local source_file="$1"
  local normalized_payload=""

  if ! normalized_payload="$(
    node - "${source_file}" 2>&1 <<'EOF'
const fs = require("fs");

const sourceFile = process.argv[2];
let text = fs.readFileSync(sourceFile, "utf8").trim();

function normalizeJsonText(value) {
  return (value || "")
    .trim()
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```$/, "");
}

text = normalizeJsonText(text);

let payload = JSON.parse(text);

if (payload && typeof payload.result === "string") {
  payload = JSON.parse(normalizeJsonText(payload.result));
}

if (!Array.isArray(payload.summary)) {
  throw new Error("summary must be an array");
}

if (!Array.isArray(payload.findings)) {
  throw new Error("findings must be an array");
}

if (!Array.isArray(payload.checks)) {
  payload.checks = [];
}

if (!Array.isArray(payload.handoff_notes)) {
  payload.handoff_notes = [];
}

process.stdout.write(JSON.stringify(payload, null, 2));
EOF
  )"; then
    tool_ready="no"
    tool_error="$(printf '%s' "${normalized_payload}" | sed -n '1p')"
    return
  fi

  review_payload="${normalized_payload}"

  if [[ -z "${review_payload//[[:space:]]/}" ]]; then
    tool_ready="no"
    tool_error="empty review payload returned by ${provider}"
  fi
}

run_self_test() {
  local failures=0

  assert_equal() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    if [[ "${expected}" != "${actual}" ]]; then
      printf 'FAIL %s: expected "%s", got "%s"\n' "${name}" "${expected}" "${actual}" >&2
      failures=$((failures + 1))
    else
      printf 'PASS %s\n' "${name}"
    fi
  }

  CHANGED_FILES_LIST=$'pyproject.toml\nuv.lock'
  assert_equal "dependency classification" "dependency" "$(classify_pr)"

  CHANGED_FILES_LIST=$'accounts/api/views.py\naccounts/tests/test_views.py'
  assert_equal "backend classification" "backend" "$(classify_pr)"

  CHANGED_FILES_LIST=$'docs/review.md\nREADME.md'
  assert_equal "docs classification" "docs" "$(classify_pr)"

  CHANGED_FILES_LIST=$'pyproject.toml\naccounts/api/views.py'
  assert_equal "mixed classification" "mixed" "$(classify_pr)"

  local temp_repo
  temp_repo="$(mktemp -d)"
  git -C "${temp_repo}" init -q
  mkdir -p "${temp_repo}/accounts/api" "${temp_repo}/accounts/tests"
  printf 'def old_value():\n    return 1\n' > "${temp_repo}/accounts/api/views.py"
  printf 'def test_old_value():\n    assert True\n' > "${temp_repo}/accounts/tests/test_views.py"
  git -C "${temp_repo}" add .
  git -C "${temp_repo}" -c user.email=ai-review@example.test -c user.name=ai-review commit -q -m initial
  local test_base_sha
  test_base_sha="$(git -C "${temp_repo}" rev-parse HEAD)"
  printf 'def old_value():\n    return 2\n' > "${temp_repo}/accounts/api/views.py"
  git -C "${temp_repo}" add .
  git -C "${temp_repo}" -c user.email=ai-review@example.test -c user.name=ai-review commit -q -m change

  local previous_workspace="${workspace}"
  local previous_base_sha="${base_sha}"
  local previous_checked_out_sha="${checked_out_sha}"
  local previous_local_diff_available="${local_diff_available}"
  local previous_changed_files="${CHANGED_FILES_LIST}"
  local previous_context_bundle_file="${context_bundle_file}"
  local previous_instruction_files_json="${repo_instruction_files_json}"

  workspace="${temp_repo}"
  base_sha="${test_base_sha}"
  checked_out_sha="$(git -C "${temp_repo}" rev-parse HEAD)"
  local_diff_available="yes"
  CHANGED_FILES_LIST="accounts/api/views.py"
  context_bundle_file="$(mktemp_workfile)"

  append_changed_hunks
  if grep -q 'accounts/api/views.py' "${context_bundle_file}" && grep -q 'return 2' "${context_bundle_file}"; then
    printf 'PASS changed hunk extraction\n'
  else
    printf 'FAIL changed hunk extraction\n' >&2
    failures=$((failures + 1))
  fi

  : > "${context_bundle_file}"
  append_related_tests
  if grep -q 'accounts/tests/test_views.py' "${context_bundle_file}"; then
    printf 'PASS related test discovery\n'
  else
    printf 'FAIL related test discovery\n' >&2
    failures=$((failures + 1))
  fi

  mkdir -p "${temp_repo}/.claude/agents"
  printf 'Use the custom reviewer guardrails.\n' > "${temp_repo}/.claude/agents/review-guardrails.md"
  : > "${context_bundle_file}"
  repo_instruction_files_json='[".claude/agents/review-guardrails.md", "../unsafe.md"]'
  append_repository_instruction_files
  if grep -q 'Use the custom reviewer guardrails.' "${context_bundle_file}" && grep -q 'Skipped unsafe configured instruction path' "${context_bundle_file}"; then
    printf 'PASS configured instruction file handling\n'
  else
    printf 'FAIL configured instruction file handling\n' >&2
    failures=$((failures + 1))
  fi

  rm -f "${context_bundle_file}"
  context_bundle_file="${previous_context_bundle_file}"
  workspace="${previous_workspace}"
  base_sha="${previous_base_sha}"
  checked_out_sha="${previous_checked_out_sha}"
  local_diff_available="${previous_local_diff_available}"
  CHANGED_FILES_LIST="${previous_changed_files}"
  repo_instruction_files_json="${previous_instruction_files_json}"

  local payload_file
  payload_file="$(mktemp_workfile)"
  printf '{"summary":["ok"],"findings":[]}' > "${payload_file}"
  review_payload=""
  tool_ready="yes"
  tool_error=""
  capture_review_payload "${payload_file}"
  if printf '%s' "${review_payload}" | grep -q '"checks": \[\]' && printf '%s' "${review_payload}" | grep -q '"handoff_notes": \[\]'; then
    printf 'PASS payload normalization\n'
  else
    printf 'FAIL payload normalization\n' >&2
    failures=$((failures + 1))
  fi

  printf 'not json' > "${payload_file}"
  tool_error=""
  capture_review_payload "${payload_file}"
  if [[ -n "${tool_error}" ]]; then
    printf 'PASS malformed payload handling\n'
  else
    printf 'FAIL malformed payload handling\n' >&2
    failures=$((failures + 1))
  fi
  rm -f "${payload_file}"
  rm -rf "${temp_repo}"

  if [[ "${failures}" -gt 0 ]]; then
    printf '%s self-test failure(s)\n' "${failures}" >&2
    return 1
  fi

  printf 'All self-tests passed.\n'
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit $?
fi

render_review_comment_body() {
  local rendered_body=""

  if ! rendered_body="$(
    REVIEW_PAYLOAD="${review_payload}" \
    PROVIDER="${provider}" \
    RUNNER_NAME="${runner_name}" \
    RUNNER_OS="${runner_os}" \
    HOST="${host}" \
    WORKSPACE="${workspace}" \
    CHECKED_OUT_SHA="${checked_out_sha}" \
    CHECKED_OUT_BRANCH="${checked_out_branch}" \
    COMMAND="${command}" \
    TOOL_PATH="${tool_path}" \
    TOOL_READY="${tool_ready}" \
    TOOL_VERSION="${tool_version}" \
    TOOL_ERROR="${tool_error}" \
    REVIEW_MODEL_REPORTED="${review_model_reported}" \
    REVIEW_MODEL_SOURCE="${review_model_source}" \
    REVIEW_INPUT_TOKENS="${review_input_tokens}" \
    REVIEW_OUTPUT_TOKENS="${review_output_tokens}" \
    REVIEW_COST_USD="${review_cost_usd}" \
    REVIEW_USAGE_SOURCE="${review_usage_source}" \
    REVIEW_DURATION_SECONDS="${review_duration_seconds}" \
    PR_CLASSIFICATION="${pr_classification}" \
    PR_NUMBER="${PR_NUMBER}" \
    PR_TITLE="${PR_TITLE}" \
    PR_AUTHOR="${pr_author}" \
    COMMENTER="${commenter}" \
    ADDITIONS="${ADDITIONS}" \
    DELETIONS="${DELETIONS}" \
    CHANGED_FILES="${CHANGED_FILES}" \
    RISK_MODE="${RISK_MODE}" \
    BASE_SHA="${base_sha}" \
    BASE_REF="${base_ref}" \
    BASE_REPO="${base_repo}" \
    HEAD_SHA="${head_sha}" \
    HEAD_REF="${head_ref}" \
    HEAD_REPO="${head_repo}" \
    node - <<'EOF'
function normalizeJsonText(text) {
  return (text || "")
    .trim()
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```$/, "");
}

function formatFindings(findings) {
  if (!Array.isArray(findings) || findings.length === 0) {
    return ["_No structured findings._"];
  }

  return findings.slice(0, 10).flatMap((finding, index) => {
    const severity = (finding.severity || "unknown").toUpperCase();
    const confidence = (finding.confidence || "unknown").toUpperCase();
    const title = finding.title || "Untitled finding";
    const hasLine = Number.isInteger(finding.line);
    const location = finding.file
      ? hasLine
        ? ` \`${finding.file}:${finding.line}\``
        : ` \`${finding.file}\``
      : "";
    const body = finding.body || "_No detail provided._";

    return [
      `${index + 1}. [${severity}/${confidence}] ${title}${location}`,
      body,
      "",
    ];
  });
}

function formatChecks(checks) {
  if (!Array.isArray(checks) || checks.length === 0) {
    return ["_No checks reported._"];
  }

  return checks.slice(0, 8).map((check) => {
    const name = check.name || "Unnamed check";
    const status = (check.status || "unknown").toUpperCase();
    const detail = check.detail ? ` - ${check.detail}` : "";
    return `- [${status}] ${name}${detail}`;
  });
}

function formatHandoffNotes(notes) {
  if (!Array.isArray(notes) || notes.length === 0) {
    return ["_No handoff notes._"];
  }

  return notes.slice(0, 6).map((note) => `- ${note}`);
}

let parsedReview = null;
let reviewPayloadError = "";

if ((process.env.REVIEW_PAYLOAD || "").trim()) {
  try {
    parsedReview = JSON.parse(normalizeJsonText(process.env.REVIEW_PAYLOAD));
  } catch (error) {
    reviewPayloadError = error.message;
  }
}

const summaryLines = Array.isArray(parsedReview?.summary) && parsedReview.summary.length > 0
  ? parsedReview.summary.slice(0, 8).map((line) => `- ${line}`)
  : ["_No summary produced._"];
const findingsLines = formatFindings(parsedReview?.findings || []);
const checkLines = formatChecks(parsedReview?.checks || []);
const handoffLines = formatHandoffNotes(parsedReview?.handoff_notes || []);
const structuredFindingCount = Array.isArray(parsedReview?.findings)
  ? parsedReview.findings.length.toString()
  : "0";

const body = [
  "AI review command accepted.",
  process.env.REVIEW_STATUS !== "success"
    ? "AI review failed. No review findings were produced."
    : structuredFindingCount === "0"
    ? "Review completed successfully. No Findings."
    : "Review completed successfully.",
  "",
  `- PR: #${process.env.PR_NUMBER}`,
  `- Title: ${process.env.PR_TITLE}`,
  process.env.PR_AUTHOR ? `- Author: @${process.env.PR_AUTHOR}` : null,
  process.env.COMMENTER ? `- Requested by: @${process.env.COMMENTER}` : null,
  `- Changed files: ${process.env.CHANGED_FILES}`,
  `- Additions / deletions: ${process.env.ADDITIONS} / ${process.env.DELETIONS}`,
  `- Review mode: ${process.env.RISK_MODE}`,
  `- PR classification: \`${process.env.PR_CLASSIFICATION || "mixed"}\``,
  `- Provider: \`${process.env.PROVIDER}\``,
  `- Model: \`${process.env.REVIEW_MODEL_REPORTED || "unknown"}\` (${process.env.REVIEW_MODEL_SOURCE || "not reported"})`,
  `- Usage: input \`${process.env.REVIEW_INPUT_TOKENS || "unknown"}\`, output \`${process.env.REVIEW_OUTPUT_TOKENS || "unknown"}\`, cost \`${process.env.REVIEW_COST_USD || "unknown"}\` (${process.env.REVIEW_USAGE_SOURCE || "not reported"})`,
  `- Runtime: \`${process.env.REVIEW_DURATION_SECONDS || "unknown"}s\``,
  `- Base: \`${process.env.BASE_REPO || "unknown"}\` @ \`${process.env.BASE_REF || "unknown"}\``,
  `- Base SHA: \`${process.env.BASE_SHA || "unknown"}\``,
  `- Head: \`${process.env.HEAD_REPO || "unknown"}\` @ \`${process.env.HEAD_REF || "unknown"}\``,
  `- Head SHA: \`${process.env.HEAD_SHA}\``,
  `- Runner: \`${process.env.RUNNER_NAME}\` (${process.env.RUNNER_OS})`,
  `- Host: \`${process.env.HOST}\``,
  `- Workspace: \`${process.env.WORKSPACE}\``,
  `- Checked out SHA: \`${process.env.CHECKED_OUT_SHA}\``,
  `- Checked out branch: \`${process.env.CHECKED_OUT_BRANCH}\``,
  `- CLI path: \`${process.env.TOOL_PATH || "not found"}\``,
  `- CLI ready: ${process.env.TOOL_READY}`,
  process.env.TOOL_READY === "yes"
    ? `- CLI version: \`${process.env.TOOL_VERSION}\``
    : `- CLI error: \`${process.env.TOOL_ERROR || "unknown"}\``,
  `- Structured findings: ${structuredFindingCount}`,
  `- Runner command: \`${process.env.COMMAND}\``,
  reviewPayloadError ? `- Review payload error: \`${reviewPayloadError}\`` : null,
  "",
  "### AI Summary",
  ...summaryLines,
  "",
  "### Checks",
  ...checkLines,
  "",
  "### Findings",
  ...findingsLines,
  "",
  "### Reviewer Notes",
  ...handoffLines,
].filter((line) => line !== null).join("\n");

process.stdout.write(body);
EOF
  )"; then
    rendered_body="AI review completed, but failed to render the review comment body."
  fi

  review_comment_body="${rendered_body}"
}

write_artifacts() {
  local artifact_dir="${AI_REVIEW_ARTIFACT_DIR:-}"

  if [[ -z "${artifact_dir}" ]]; then
    return
  fi

  mkdir -p "${artifact_dir}"
  cp "${prompt_file}" "${artifact_dir}/prompt.txt"
  cp "${context_bundle_file}" "${artifact_dir}/context-bundle.md"
  cp "${evidence_file}" "${artifact_dir}/evidence.md"

  if [[ -f "${output_file}" ]]; then
    cp "${output_file}" "${artifact_dir}/raw-output.txt"
  fi

  if [[ "${provider}" == "codex" && -f "${codex_events_file}" ]]; then
    cp "${codex_events_file}" "${artifact_dir}/codex-events.jsonl"
  fi

  printf '%s\n' "${review_payload}" > "${artifact_dir}/review-payload.json"
  printf '%s\n' "${review_comment_body}" > "${artifact_dir}/review-comment.md"
  {
    printf 'provider=%s\n' "${provider}"
    printf 'review_model_reported=%s\n' "${review_model_reported}"
    printf 'review_model_source=%s\n' "${review_model_source}"
    printf 'review_model_requested=%s\n' "${review_model_requested}"
    printf 'review_model_requested_source=%s\n' "${review_model_requested_source}"
    printf 'review_input_tokens=%s\n' "${review_input_tokens}"
    printf 'review_output_tokens=%s\n' "${review_output_tokens}"
    printf 'review_cost_usd=%s\n' "${review_cost_usd}"
    printf 'review_usage_source=%s\n' "${review_usage_source}"
    printf 'review_duration_seconds=%s\n' "${review_duration_seconds}"
    printf 'pr_classification=%s\n' "${pr_classification}"
    printf 'tool_ready=%s\n' "${tool_ready}"
    printf 'tool_path=%s\n' "${tool_path}"
    printf 'tool_error=%s\n' "${tool_error}"
    printf 'workspace=%s\n' "${workspace}"
    printf 'checked_out_sha=%s\n' "${checked_out_sha}"
    printf 'base_sha=%s\n' "${base_sha}"
    printf 'base_ref=%s\n' "${base_ref}"
    printf 'base_repo=%s\n' "${base_repo}"
    printf 'head_sha=%s\n' "${head_sha}"
    printf 'head_ref=%s\n' "${head_ref}"
    printf 'head_repo=%s\n' "${head_repo}"
    printf 'pr_author=%s\n' "${pr_author}"
    printf 'commenter=%s\n' "${commenter}"
    printf 'context_bundle_line_count=%s\n' "${context_bundle_line_count}"
    printf 'local_diff_available=%s\n' "${local_diff_available}"
  } > "${artifact_dir}/metadata.txt"
}

write_pre_provider_artifacts() {
  local artifact_dir="${AI_REVIEW_ARTIFACT_DIR:-}"

  if [[ -z "${artifact_dir}" ]]; then
    return
  fi

  mkdir -p "${artifact_dir}"
  cp "${prompt_file}" "${artifact_dir}/prompt.txt"
  cp "${context_bundle_file}" "${artifact_dir}/context-bundle.md"
  cp "${evidence_file}" "${artifact_dir}/evidence.md"
}

build_context_bundle
build_evidence

cat > "${prompt_file}" <<EOF
Review this pull request for a code review kickoff.

Return valid JSON only. Do not use markdown fences. Use this exact schema:
{
  "summary": ["bullet 1", "bullet 2"],
  "checks": [
    {
      "name": "Check name",
      "status": "passed|failed|skipped|unknown",
      "detail": "One short sentence. Only say passed when evidence proves it."
    }
  ],
  "findings": [
    {
      "severity": "high|medium|low",
      "confidence": "high|medium|low",
      "file": "relative/path.py",
      "line": 123,
      "title": "Short finding title",
      "body": "One paragraph explaining the risk and what the reviewer should inspect."
    }
  ],
  "handoff_notes": ["short note for the human reviewer"]
}

Rules:
- summary must contain at most 8 concise bullets
- checks must summarize only checks present in the evidence section; use "unknown" or "skipped" when evidence is absent
- findings must contain at most 10 items
- only include high-confidence findings with genuine correctness, security, migration, dependency, runtime, or testing risk
- do not include style nits or speculative points
- if there are no concrete findings, return "findings": []
- cite exact changed right-side lines only; set "line" to null when you do not have a confident changed-line reference
- keep file paths relative to the repo root
- body must be plain text
- do not claim tests, checks, imports, or runtime behavior were verified unless the evidence section proves it
- adapt the review focus to the PR classification

Repository-specific review guidance:
${repo_review_prompt_context:-No repository-specific reviewer guidance was provided.}

Review context:
${context_bundle}

Evidence:
$(cat "${evidence_file}")
EOF

write_pre_provider_artifacts

run_codex() {
  if ! command -v codex >/dev/null 2>&1; then
    tool_error="codex command not found"
    return
  fi

  tool_path="$(command -v codex)"

  if ! codex_output="$(codex --version 2>&1)"; then
    tool_error="$(printf '%s' "${codex_output}" | sed -n '1p')"
    return
  fi

  tool_ready="yes"
  tool_version="$(printf '%s' "${codex_output}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
  if [[ -n "${review_model_requested}" ]]; then
    review_model_reported="${review_model_requested}"
    review_model_source="requested via ${review_model_requested_source}"
  else
    review_model_reported="$(read_codex_config_model || true)"
    if [[ -n "${review_model_reported}" ]]; then
      review_model_source="codex config"
    else
      review_model_reported="default"
      review_model_source="codex default; exact model not reported"
    fi
  fi

  if ! codex_login_status="$(codex login status 2>&1)"; then
    tool_ready="no"
    tool_error="$(printf '%s' "${codex_login_status}" | sed -n '1p')"
    return
  fi

  local codex_args=(-a never -s read-only exec --json)
  if [[ -n "${review_model_requested}" ]]; then
    codex_args+=(-m "${review_model_requested}")
  fi
  codex_args+=(-C "${workspace}" -o "${output_file}" -)

  if run_with_timeout_from_file "${provider_timeout_seconds}" "${prompt_file}" \
    codex "${codex_args[@]}" > "${codex_events_file}" 2>&1; then
    capture_codex_usage "${codex_events_file}"
    capture_review_payload "${output_file}"
  else
    local status=$?
    if [[ "${status}" -eq 124 ]]; then
      provider_timed_out="yes"
      tool_error="codex exec timed out after ${provider_timeout_seconds}s"
    else
      tool_error="codex exec failed"
    fi
  fi
}

run_claude() {
  if ! command -v claude >/dev/null 2>&1; then
    tool_error="claude command not found"
    return
  fi

  tool_path="$(command -v claude)"

  if ! claude_version_output="$(claude --version 2>&1)"; then
    tool_error="$(printf '%s' "${claude_version_output}" | sed -n '1p')"
    return
  fi

  tool_ready="yes"
  tool_version="$(printf '%s' "${claude_version_output}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
  if [[ -n "${review_model_requested}" ]]; then
    review_model_reported="${review_model_requested}"
    review_model_source="requested via ${review_model_requested_source}"
  else
    review_model_reported="pending"
    review_model_source="pending claude modelUsage"
  fi

  local claude_args=(
    claude -p
    --input-format text
    --output-format json
    --allowedTools ""
    --permission-mode bypassPermissions
    --add-dir "${workspace}"
  )
  if [[ -n "${review_model_requested}" ]]; then
    claude_args+=(--model "${review_model_requested}")
  fi

  if (
    cd "${workspace}" && \
    run_with_timeout_from_file "${provider_timeout_seconds}" "${prompt_file}" \
      "${claude_args[@]}"
  ) > "${output_file}" 2>&1; then
    if claude_reported_error "${output_file}"; then
      tool_ready="no"
      tool_error="$(compact_claude_error "${output_file}" "claude returned an error result")"
      return
    fi

    capture_claude_model_usage "${output_file}"
    capture_claude_usage "${output_file}"
    capture_review_payload "${output_file}"
  else
    local status=$?
    tool_ready="no"
    if [[ "${status}" -eq 124 ]]; then
      provider_timed_out="yes"
      tool_error="claude timed out after ${provider_timeout_seconds}s"
    else
      tool_error="$(compact_claude_error "${output_file}" "claude failed")"
    fi
  fi
}

case "${provider}" in
  claude)
    run_claude
    ;;
  codex)
    run_codex
    ;;
  *)
    tool_error="unsupported provider: ${provider}"
    ;;
esac

if [[ -z "${tool_error}" && -n "${review_payload//[[:space:]]/}" ]]; then
  review_status="success"
fi

review_duration_seconds="$(( $(date +%s) - review_started_at ))"
render_review_comment_body
write_artifacts

{
  emit_output "provider" "${provider}"
  emit_output "runner_name" "${runner_name}"
  emit_output "runner_os" "${runner_os}"
  emit_output "host" "${host}"
  emit_output "workspace" "${workspace}"
  emit_output "checked_out_sha" "${checked_out_sha}"
  emit_output "checked_out_branch" "${checked_out_branch}"
  emit_output "command" "${command}"
  emit_output "tool_path" "${tool_path}"
  emit_output "tool_ready" "${tool_ready}"
  emit_output "tool_version" "${tool_version}"
  emit_output "tool_error" "${tool_error}"
  emit_output "review_status" "${review_status}"
  emit_output "review_model_reported" "${review_model_reported}"
  emit_output "review_model_source" "${review_model_source}"
  emit_output "review_input_tokens" "${review_input_tokens}"
  emit_output "review_output_tokens" "${review_output_tokens}"
  emit_output "review_cost_usd" "${review_cost_usd}"
  emit_output "review_usage_source" "${review_usage_source}"
  emit_output "pr_classification" "${pr_classification}"
  emit_output "review_duration_seconds" "${review_duration_seconds}"
  emit_output "review_payload" "${review_payload}"
  emit_output "review_comment_body" "${review_comment_body}"
}
