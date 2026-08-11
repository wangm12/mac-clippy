#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/.." && pwd)"
swiftlint_bin="${SWIFTLINT_BIN:-}"
baseline_file="${project_root}/.swiftlint-baseline.yml"

if [[ -z "${swiftlint_bin}" ]]; then
	swiftlint_bin="$(command -v swiftlint || true)"
fi

if [[ -z "${swiftlint_bin}" ]]; then
	for candidate in /opt/homebrew/bin/swiftlint /usr/local/bin/swiftlint; do
		if [[ -x "${candidate}" ]]; then
			swiftlint_bin="${candidate}"
			break
		fi
	done
fi

if [[ -z "${swiftlint_bin}" || ! -x "${swiftlint_bin}" ]]; then
	echo "error: swiftlint is required; set SWIFTLINT_BIN to its executable path" >&2
	exit 1
fi

if [[ ! -f "${baseline_file}" ]]; then
	echo "error: missing SwiftLint baseline at ${baseline_file}" >&2
	echo "       regenerate it intentionally with: swiftlint lint --write-baseline .swiftlint-baseline.yml MacClippy MacClippyKit/Sources MacClippyKit/Tests MacClippyTests MacClippyUITests" >&2
	exit 1
fi

cd "${project_root}"
source_paths=(
	MacClippy
	MacClippyKit/Sources
	MacClippyKit/Tests
	MacClippyTests
	MacClippyUITests
)

"${swiftlint_bin}" lint \
	--baseline "${baseline_file}" \
	"${source_paths[@]}"

# Keep the repository-wide baseline gate above, then run the same baseline
# against only changed Swift files. Existing debt remains baselined, while a
# changed file cannot add a new violation without failing the job. Untracked
# Swift files are included so newly extracted source boundaries receive the
# same gate before commit.
changed_files=()
while IFS= read -r path; do
	case "${path}" in
		MacClippy/*.swift|MacClippyKit/Sources/*\.swift|MacClippyKit/Tests/*\.swift|MacClippyTests/*.swift|MacClippyUITests/*.swift)
			changed_files+=("${path}")
			;;
	esac
done < <(
	{
		git diff --name-only --diff-filter=ACMRTUXB
		git ls-files --others --exclude-standard
	} | sort -u
)

if (( ${#changed_files[@]} > 0 )); then
	echo "SwiftLint changed-file gate: ${#changed_files[@]} Swift files"
	"${swiftlint_bin}" lint --quiet --strict --baseline "${baseline_file}" "${changed_files[@]}"
fi
