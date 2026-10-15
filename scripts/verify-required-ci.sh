#!/usr/bin/env bash
set -euo pipefail

EXPECTED_WORKFLOW_PATH=".github/workflows/ci.yml"
TARGET_SHA="${1:-}"
REPOSITORY="${GITHUB_REPOSITORY:-}"
WAIT_SECONDS="${REQUIRED_CI_WAIT_SECONDS:-0}"
POLL_SECONDS="${REQUIRED_CI_POLL_SECONDS:-15}"

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ "${TARGET_SHA}" =~ ^[0-9a-fA-F]{40}$ ]] || fail "expected a full 40-character source SHA"
[[ "${REPOSITORY}" =~ ^[^/]+/[^/]+$ ]] || fail "GITHUB_REPOSITORY must be owner/repository"
[[ "${WAIT_SECONDS}" =~ ^[0-9]+$ ]] || fail "REQUIRED_CI_WAIT_SECONDS must be a nonnegative integer"
[[ "${POLL_SECONDS}" =~ ^[0-9]+$ ]] || fail "REQUIRED_CI_POLL_SECONDS must be a nonnegative integer"
command -v gh >/dev/null 2>&1 || fail "gh CLI is required to read the Actions API"
command -v jq >/dev/null 2>&1 || fail "jq is required to validate Actions API responses"

workflow_json="$(gh api "repos/${REPOSITORY}/actions/workflows/ci.yml")" \
  || fail "could not read the required CI workflow from the GitHub Actions API"
workflow_id="$(jq -er --arg path "${EXPECTED_WORKFLOW_PATH}" '
  select(.path == $path) | .id | select(type == "number" and . > 0)
' <<<"${workflow_json}")" \
  || fail "the CI workflow identity/path did not match ${EXPECTED_WORKFLOW_PATH}"

deadline=$(( $(date +%s) + WAIT_SECONDS ))
while :; do
  runs_json="$(gh api --paginate --slurp "repos/${REPOSITORY}/actions/workflows/${workflow_id}/runs?head_sha=${TARGET_SHA}&per_page=100")" \
    || fail "could not read CI runs for ${TARGET_SHA}"

  total_run_count="$(jq -er '
    if type == "array" and length > 0 and all(.[]; (.total_count | type) == "number")
    then [.[].total_count] | max
    else error("invalid paginated workflow-runs response")
    end
  ' <<<"${runs_json}")" \
    || fail "the Actions API returned an invalid paginated runs response"
  observed_run_count="$(jq -er '[.[] | (.workflow_runs // [])[]] | length' <<<"${runs_json}")" \
    || fail "the Actions API returned an invalid workflow-runs page"
  if (( observed_run_count != total_run_count )); then
    fail "the Actions API reported ${total_run_count} runs but returned ${observed_run_count} for ${TARGET_SHA}; refusing an incomplete or unstable latest-run decision"
  fi

  selected_run="$(jq -c \
    --arg sha "${TARGET_SHA}" \
    --arg path "${EXPECTED_WORKFLOW_PATH}" \
    --argjson workflow_id "${workflow_id}" '
      [.[] | (.workflow_runs // [])[]
        | select(.workflow_id == $workflow_id)
        | select(.head_sha == $sha)
        | select(((.path // "") | split("@")[0]) == $path)]
      | sort_by([
          (.run_started_at // .updated_at // .created_at // ""),
          (.run_number // 0),
          (.run_attempt // 0),
          (.created_at // "")
        ])
      | last // empty
    ' <<<"${runs_json}")"

  if [[ -n "${selected_run}" ]]; then
    run_number="$(jq -r '.run_number // "unknown"' <<<"${selected_run}")"
    run_attempt="$(jq -r '.run_attempt // "unknown"' <<<"${selected_run}")"
    run_id="$(jq -r '.id // "unknown"' <<<"${selected_run}")"
    status="$(jq -r '.status // ""' <<<"${selected_run}")"
    conclusion="$(jq -r '.conclusion // ""' <<<"${selected_run}")"

    if [[ "${status}" == "completed" ]]; then
      if [[ "${conclusion}" == "success" ]]; then
        echo "Required CI passed for ${TARGET_SHA}: ${EXPECTED_WORKFLOW_PATH}, run ${run_number}, attempt ${run_attempt} (${run_id})."
        exit 0
      fi
      fail "latest CI run for ${TARGET_SHA} is completed with conclusion '${conclusion:-missing}' (run ${run_number}, attempt ${run_attempt}); refusing to use an older success"
    fi
    echo "Waiting for required CI run ${run_number}, attempt ${run_attempt} on ${TARGET_SHA} (status: ${status:-unknown})."
  else
    echo "Waiting for required CI run ${EXPECTED_WORKFLOW_PATH} on ${TARGET_SHA}."
  fi

  now="$(date +%s)"
  if (( now >= deadline )); then
    fail "no completed successful ${EXPECTED_WORKFLOW_PATH} run for exact SHA ${TARGET_SHA} within ${WAIT_SECONDS}s"
  fi
  if (( POLL_SECONDS > 0 )); then
    sleep "${POLL_SECONDS}"
  fi
done
