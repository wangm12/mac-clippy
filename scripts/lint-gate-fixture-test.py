#!/usr/bin/env python3
"""Exercise scripts/lint.sh against isolated Git states and the pinned SwiftLint."""

from __future__ import annotations

import os
import pathlib
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
LINT_SCRIPT = REPO_ROOT / "scripts" / "lint.sh"
EXPECTED_SWIFTLINT_VERSION = "0.63.2"


class LintGateFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        pinned_file = (REPO_ROOT / "scripts" / "pinned-tool-versions.sh").read_text()
        match = re.search(r"MACCLIPPY_SWIFTLINT_VERSION:=([0-9.]+)", pinned_file)
        if match is None:
            raise AssertionError("cannot read pinned SwiftLint version")
        cls.swiftlint_version = match.group(1)
        if cls.swiftlint_version != EXPECTED_SWIFTLINT_VERSION:
            raise AssertionError(
                f"fixture expects pinned SwiftLint {EXPECTED_SWIFTLINT_VERSION}, "
                f"repository pins {cls.swiftlint_version}"
            )

        configured = os.environ.get("SWIFTLINT_BIN")
        executable = configured or shutil.which("swiftlint")
        if not executable or not pathlib.Path(executable).is_file():
            raise AssertionError("SwiftLint is required; set SWIFTLINT_BIN to the pinned executable")
        cls.swiftlint = str(pathlib.Path(executable).resolve())
        version = subprocess.check_output([cls.swiftlint, "version"], text=True).strip()
        if version != cls.swiftlint_version:
            raise AssertionError(f"expected SwiftLint {cls.swiftlint_version}, found {version}")

    def test_clean_checkout_rejects_new_warning(self) -> None:
        root, warning_file = self.make_fixture("clean-new-warning")
        self.write_warning(warning_file)
        self.commit_fixture(root)
        self.assert_clean_checkout(root)

        result, arguments = self.run_lint(root)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Trailing Whitespace Violation", result.stdout + result.stderr)
        self.assertIn("--strict", arguments)

    def test_existing_baseline_debt_remains_allowed_on_clean_checkout(self) -> None:
        root, warning_file = self.make_fixture("baseline-debt")
        self.write_warning(warning_file)
        baseline = root / ".swiftlint-baseline.yml"
        generated = subprocess.run(
            [
                self.swiftlint,
                "lint",
                "--write-baseline",
                str(baseline),
                "--no-cache",
                "--config",
                str(root / "config.yml"),
                "MacClippy",
            ],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
        )
        self.assertEqual(generated.returncode, 0, generated.stdout + generated.stderr)
        self.commit_fixture(root)
        self.assert_clean_checkout(root)

        result, arguments = self.run_lint(root)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("--strict", arguments)

    def test_unstaged_warning_fails_changed_file_gate(self) -> None:
        root, warning_file = self.make_fixture("unstaged-warning")
        warning_file.write_text("let lintFixture = 1\n")
        self.commit_fixture(root)
        self.write_warning(warning_file)
        self.assertIn("MacClippy/Warning.swift", self.git(root, "diff", "--name-only"))

        result, arguments = self.run_lint(root)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("SwiftLint changed-file gate: 1 Swift files", result.stdout)
        self.assertIn("MacClippy/Warning.swift", arguments)

    def test_untracked_warning_fails_changed_file_gate(self) -> None:
        root, warning_file = self.make_fixture("untracked-warning")
        self.commit_fixture(root, include_warning=False)
        self.write_warning(warning_file)
        self.assertIn("MacClippy/Warning.swift", self.git(root, "ls-files", "--others", "--exclude-standard"))

        result, arguments = self.run_lint(root)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("SwiftLint changed-file gate: 1 Swift files", result.stdout)
        self.assertIn("MacClippy/Warning.swift", arguments)

    def test_staged_warning_fails_changed_file_gate(self) -> None:
        root, warning_file = self.make_fixture("staged-warning")
        warning_file.write_text("let lintFixture = 1\n")
        self.commit_fixture(root)
        self.write_warning(warning_file)
        self.git(root, "add", "MacClippy/Warning.swift")
        self.assertIn("MacClippy/Warning.swift", self.git(root, "diff", "--cached", "--name-only"))

        result, arguments = self.run_lint(root)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("SwiftLint changed-file gate: 1 Swift files", result.stdout)
        self.assertIn("MacClippy/Warning.swift", arguments)

    def make_fixture(self, name: str) -> tuple[pathlib.Path, pathlib.Path]:
        root = pathlib.Path(tempfile.mkdtemp(prefix=f"macclippy-lint-{name}-")).resolve()
        os.chmod(root, 0o700)
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        for relative in (
            "scripts",
            "bin",
            "MacClippy",
            "MacClippyKit/Sources",
            "MacClippyKit/Tests",
            "MacClippyTests",
            "MacClippyUITests",
        ):
            (root / relative).mkdir(parents=True, exist_ok=True)

        script = root / "scripts" / "lint.sh"
        shutil.copy2(LINT_SCRIPT, script)
        self.assertEqual(script.read_bytes(), LINT_SCRIPT.read_bytes())
        (root / ".swiftlint-baseline.yml").write_text("[]\n")
        (root / ".gitignore").write_text(
            "/bin/\n/config.yml\n/*.path\n/lint-arguments.bin\n"
        )
        (root / "config.yml").write_text("only_rules:\n  - trailing_whitespace\n")
        warning_file = root / "MacClippy" / "Warning.swift"

        wrapper = root / "bin" / "swiftlint-wrapper"
        wrapper.write_text(
            "#!/bin/bash\n"
            "set -euo pipefail\n"
            "printf '%s\\0' \"$@\" >> \"$LINT_ARGUMENT_LOG\"\n"
            f"exec {shlex.quote(self.swiftlint)} \"$@\" --no-cache --config \"$LINT_CONFIG\"\n"
        )
        wrapper.chmod(0o700)
        (root / "lint-wrapper.path").write_text(str(wrapper))
        (root / "lint-argument-log.path").write_text(str(root / "lint-arguments.bin"))
        (root / "lint-config.path").write_text(str(root / "config.yml"))
        return root, warning_file

    @staticmethod
    def write_warning(path: pathlib.Path) -> None:
        path.write_text("let lintFixture = 1  \n")

    def commit_fixture(self, root: pathlib.Path, include_warning: bool = True) -> None:
        self.git(root, "init", "-q")
        self.git(root, "config", "user.name", "MacClippy lint fixture")
        self.git(root, "config", "user.email", "lint-fixture@example.invalid")
        files = ["scripts/lint.sh", ".swiftlint-baseline.yml", ".gitignore"]
        if include_warning:
            files.append("MacClippy/Warning.swift")
        self.git(root, "add", *files)
        self.git(root, "commit", "-q", "-m", "lint fixture baseline")

    def run_lint(self, root: pathlib.Path) -> tuple[subprocess.CompletedProcess[str], str]:
        wrapper = (root / "lint-wrapper.path").read_text()
        argument_log = (root / "lint-argument-log.path").read_text()
        config = (root / "lint-config.path").read_text()
        environment = dict(os.environ)
        environment.update(
            {
                "SWIFTLINT_BIN": wrapper,
                "LINT_ARGUMENT_LOG": argument_log,
                "LINT_CONFIG": config,
            }
        )
        result = subprocess.run(
            ["/bin/bash", "scripts/lint.sh"],
            cwd=root,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
        )
        log = pathlib.Path(argument_log).read_bytes()
        return result, log.decode(errors="replace")

    def assert_clean_checkout(self, root: pathlib.Path) -> None:
        self.assertEqual(self.git(root, "status", "--porcelain"), "")

    @staticmethod
    def git(root: pathlib.Path, *arguments: str) -> str:
        return subprocess.check_output(["git", *arguments], cwd=root, text=True).strip()


if __name__ == "__main__":
    unittest.main(verbosity=2)
