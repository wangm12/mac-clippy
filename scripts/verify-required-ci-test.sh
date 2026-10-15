#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/verify-required-ci.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/macclippy-required-ci-test.XXXXXX")"
SHA="0123456789abcdef0123456789abcdef01234567"

cleanup() {
  rm -rf "${WORK}"
}
trap cleanup EXIT

mkdir -p "${WORK}/bin" "${WORK}/fixtures"
cat > "${WORK}/bin/gh" <<'MOCK_GH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "api" ]] || { echo "unexpected gh command" >&2; exit 2; }
shift
if [[ "${1:-}" == "--paginate" ]]; then
  [[ "${2:-}" == "--slurp" ]] || { echo "missing --slurp" >&2; exit 2; }
  endpoint="${3:-}"
  case "${endpoint}" in
    repos/*/actions/workflows/*/runs\?head_sha=*) cat "${GH_FIXTURE_DIR}/runs.json" ;;
    *) echo "unexpected paginated Actions API request: ${endpoint:-missing}" >&2; exit 2 ;;
  esac
else
  case "${1:-}" in
    repos/*/actions/workflows/ci.yml) cat "${GH_FIXTURE_DIR}/workflow.json" ;;
    *) echo "unexpected Actions API request: ${1:-missing}" >&2; exit 2 ;;
  esac
fi
MOCK_GH
chmod +x "${WORK}/bin/gh"

cat > "${WORK}/fixtures/workflow.json" <<'JSON'
{"id":42,"path":".github/workflows/ci.yml","state":"active"}
JSON

write_runs() {
  cat > "${WORK}/fixtures/runs.json"
}

run_accepts() {
  local label="$1"
  if ! GH_FIXTURE_DIR="${WORK}/fixtures" \
      GITHUB_REPOSITORY="example/mac-clippy" \
      REQUIRED_CI_WAIT_SECONDS=0 \
      PATH="${WORK}/bin:${PATH}" \
      "${SCRIPT}" "${SHA}" >"${WORK}/${label}.out" 2>"${WORK}/${label}.err"; then
    echo "error: expected valid required-CI fixture '${label}' to pass" >&2
    cat "${WORK}/${label}.out" "${WORK}/${label}.err" >&2
    exit 1
  fi
}

run_rejects() {
  local label="$1"
  if GH_FIXTURE_DIR="${WORK}/fixtures" \
      GITHUB_REPOSITORY="example/mac-clippy" \
      REQUIRED_CI_WAIT_SECONDS=0 \
      PATH="${WORK}/bin:${PATH}" \
      "${SCRIPT}" "${SHA}" >"${WORK}/${label}.out" 2>"${WORK}/${label}.err"; then
    echo "error: expected required-CI fixture '${label}' to fail" >&2
    cat "${WORK}/${label}.out" >&2
    exit 1
  fi
}

# A green check from a different workflow id/path is not the required check.
write_runs <<JSON
[{"total_count":1,"workflow_runs":[{"id":1,"workflow_id":99,"path":".github/workflows/other.yml@refs/heads/main","head_sha":"${SHA}","run_number":99,"run_attempt":1,"status":"completed","conclusion":"success"}]}]
JSON
run_rejects wrong_workflow_or_path

write_runs <<JSON
[{"total_count":1,"workflow_runs":[{"id":10,"workflow_id":42,"path":".github/workflows/other.yml@refs/heads/main","head_sha":"${SHA}","run_number":100,"run_attempt":1,"status":"completed","conclusion":"success"}]}]
JSON
run_rejects wrong_path

write_runs <<JSON
[{"total_count":1,"workflow_runs":[{"id":11,"workflow_id":99,"path":".github/workflows/ci.yml@refs/heads/main","head_sha":"${SHA}","run_number":101,"run_attempt":1,"status":"completed","conclusion":"success"}]}]
JSON
run_rejects wrong_workflow_id

# The correct workflow on a different SHA does not authorize this build.
write_runs <<'JSON'
[{"total_count":1,"workflow_runs":[{"id":2,"workflow_id":42,"path":".github/workflows/ci.yml@refs/heads/main","head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","run_number":100,"run_attempt":1,"status":"completed","conclusion":"success"}]}]
JSON
run_rejects different_sha

# Missing run, in-progress run, canceled run, and failed run all fail closed.
write_runs <<'JSON'
[{"total_count":0,"workflow_runs":[]}]
JSON
run_rejects missing_required_run

write_runs <<JSON
[{"total_count":1,"workflow_runs":[{"id":3,"workflow_id":42,"path":".github/workflows/ci.yml@refs/heads/main","head_sha":"${SHA}","run_number":101,"run_attempt":1,"status":"in_progress","conclusion":null}]}]
JSON
run_rejects non_completed_run

write_runs <<JSON
[{"total_count":1,"workflow_runs":[{"id":4,"workflow_id":42,"path":".github/workflows/ci.yml@refs/heads/main","head_sha":"${SHA}","run_number":102,"run_attempt":1,"status":"completed","conclusion":"cancelled"}]}]
JSON
run_rejects canceled_run

write_runs <<JSON
[{"total_count":1,"workflow_runs":[{"id":5,"workflow_id":42,"path":".github/workflows/ci.yml@refs/heads/main","head_sha":"${SHA}","run_number":103,"run_attempt":1,"status":"completed","conclusion":"failure"}]}]
JSON
run_rejects failed_run

# A newer failed CI run must beat an older success for the same SHA.
write_runs <<JSON
[{"total_count":2,"workflow_runs":[{"id":6,"workflow_id":42,"path":".github/workflows/ci.yml@refs/heads/main","head_sha":"${SHA}","run_number":104,"run_attempt":1,"status":"completed","conclusion":"success"},{"id":7,"workflow_id":42,"path":".github/workflows/ci.yml@refs/heads/main","head_sha":"${SHA}","run_number":105,"run_attempt":1,"status":"completed","conclusion":"failure"}]}]
JSON
run_rejects newer_failed_run

# A failed rerun attempt must beat the earlier success from that same run.
write_runs <<JSON
[{"total_count":2,"workflow_runs":[{"id":8,"workflow_id":42,"path":".github/workflows/ci.yml@refs/heads/main","head_sha":"${SHA}","run_number":106,"run_attempt":1,"status":"completed","conclusion":"success"},{"id":8,"workflow_id":42,"path":".github/workflows/ci.yml@refs/heads/main","head_sha":"${SHA}","run_number":106,"run_attempt":2,"status":"completed","conclusion":"failure"}]}]
JSON
run_rejects newer_failed_attempt

# A rerun of an older workflow run can be newer than a higher-numbered run.
# Its attempt timestamp must still be considered instead of reusing that
# higher-numbered run's earlier success.
write_runs <<JSON
[{"total_count":2,"workflow_runs":[{"id":12,"workflow_id":42,"path":".github/workflows/ci.yml@refs/heads/main","head_sha":"${SHA}","run_number":107,"run_attempt":2,"run_started_at":"2026-01-03T12:00:00Z","status":"completed","conclusion":"failure"},{"id":13,"workflow_id":42,"path":".github/workflows/ci.yml@refs/heads/main","head_sha":"${SHA}","run_number":108,"run_attempt":1,"run_started_at":"2026-01-02T12:00:00Z","status":"completed","conclusion":"success"}]}]
JSON
run_rejects newer_rerun_of_older_run

# Pagination must include an older-created run whose latest rerun attempt is newer.
write_runs <<JSON
[{"total_count":2,"workflow_runs":[{"id":23,"workflow_id":42,"path":".github/workflows/ci.yml@refs/heads/main","head_sha":"${SHA}","run_number":108,"run_attempt":1,"run_started_at":"2026-01-02T12:00:00Z","status":"completed","conclusion":"success"}]},{"total_count":2,"workflow_runs":[{"id":22,"workflow_id":42,"path":".github/workflows/ci.yml@refs/heads/main","head_sha":"${SHA}","run_number":107,"run_attempt":2,"run_started_at":"2026-01-03T12:00:00Z","status":"completed","conclusion":"cancelled"}]}]
JSON
run_rejects newer_rerun_on_later_page

# If the API reports more runs than gh returned, fail closed instead of choosing
# from an incomplete result set.
write_runs <<JSON
[{"total_count":101,"workflow_runs":[{"id":24,"workflow_id":42,"path":".github/workflows/ci.yml@refs/heads/main","head_sha":"${SHA}","run_number":109,"run_attempt":1,"status":"completed","conclusion":"success"}]}]
JSON
run_rejects incomplete_run_listing

# The exact workflow and SHA pass only when the latest attempt is successful.
write_runs <<JSON
[{"total_count":1,"workflow_runs":[{"id":9,"workflow_id":42,"path":".github/workflows/ci.yml@refs/heads/main","head_sha":"${SHA}","run_number":107,"run_attempt":2,"status":"completed","conclusion":"success"}]}]
JSON
run_accepts valid_same_sha
grep -q "attempt 2" "${WORK}/valid_same_sha.out"

echo "verify-required-ci tests passed"
