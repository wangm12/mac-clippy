#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/assert-opt-in-xctest-log.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/macclippy-opt-in-log-test.XXXXXX")"

cleanup() {
  rm -rf "${WORK}"
}
trap cleanup EXIT

cat > "${WORK}/passed.log" <<'LOG'
Test Case 'ScaleSuite.testFirst' started.
Test Case 'ScaleSuite.testFirst' passed (0.010 seconds).
Test Case 'ScaleSuite.testSecond' started.
Test Case 'ScaleSuite.testSecond' passed (0.010 seconds).
LOG
"${SCRIPT}" "${WORK}/passed.log" ScaleSuite >"${WORK}/passed.out"
grep -q '2 passed, 0 skipped' "${WORK}/passed.out"

cat > "${WORK}/skipped.log" <<'LOG'
Test Case 'ScaleSuite.testFixture' started.
Test Case 'ScaleSuite.testFixture' skipped ("opt-in flag is missing")
LOG
if "${SCRIPT}" "${WORK}/skipped.log" ScaleSuite >"${WORK}/skipped.out" 2>"${WORK}/skipped.err"; then
  echo "error: opt-in log verifier accepted a skipped suite" >&2
  exit 1
fi
grep -q 'started=1, passed=0, skipped=1' "${WORK}/skipped.err"

cat > "${WORK}/mixed.log" <<'LOG'
Test Case 'ScaleSuite.testFixture' started.
Test Case 'ScaleSuite.testFixture' passed (0.010 seconds).
Test Case 'ScaleSuite.testMissingOptIn' started.
Test Case 'ScaleSuite.testMissingOptIn' skipped ("opt-in flag is missing")
LOG
if "${SCRIPT}" "${WORK}/mixed.log" ScaleSuite >"${WORK}/mixed.out" 2>"${WORK}/mixed.err"; then
  echo "error: opt-in log verifier accepted a partly skipped suite" >&2
  exit 1
fi
grep -q 'started=2, passed=1, skipped=1' "${WORK}/mixed.err"

echo "assert-opt-in-xctest-log tests passed"
