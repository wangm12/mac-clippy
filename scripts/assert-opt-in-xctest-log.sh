#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="${1:-}"
SUITE_NAME="${2:-}"

if [[ -z "${LOG_FILE}" || -z "${SUITE_NAME}" || ! -f "${LOG_FILE}" ]]; then
  echo "usage: $0 /path/to/test.log XCTestSuiteName" >&2
  exit 2
fi

counts="$(awk -v suite="${SUITE_NAME}" '
  index($0, suite) == 0 || index($0, "Test Case") == 0 { next }
  / started\./ { started++ }
  / passed \(/ { passed++ }
  tolower($0) ~ /skipped/ { skipped++ }
  END { printf "%d %d %d", started, passed, skipped }
' "${LOG_FILE}")"
read -r started passed skipped <<<"${counts}"

if (( started == 0 || passed == 0 || started != passed || skipped != 0 )); then
  echo "error: opt-in XCTest suite ${SUITE_NAME} did not execute successfully (started=${started}, passed=${passed}, skipped=${skipped})" >&2
  echo "       The suite may have been skipped because its opt-in fixture was not enabled." >&2
  exit 1
fi

echo "Opt-in XCTest suite ${SUITE_NAME} executed: ${passed} passed, 0 skipped."
