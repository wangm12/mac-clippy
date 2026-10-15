#!/usr/bin/env python3
"""Isolated MacClippy E2E, Release performance, and durable soak driver."""

from __future__ import annotations

import argparse
import atexit
import datetime as dt
import fcntl
import hashlib
import json
import math
import os
import plistlib
import random
import shutil
import signal
import socket
import sqlite3
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from collections import Counter, deque
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


SCRIPT_PATH = Path(__file__).resolve()
REPO_ROOT = SCRIPT_PATH.parents[2]
MARKER_NAME = ".macclippy-e2e-root.json"
RUNNER_OWNER_NAME = ".macclippy-e2e-runner.json"
RUNNER_STATUS_NAME = ".macclippy-e2e-status.json"
RUNNER_LOCK_NAME = ".macclippy-e2e-runner.lock"
SOAK_STOP_REQUEST_NAME = ".macclippy-e2e-stop-request.json"
SOAK_EXTEND_REQUEST_NAME = ".macclippy-e2e-extend-request.json"
SOAK_EXTEND_LOCK_NAME = ".macclippy-e2e-extend.lock"
CONTROL_SOCKET_NAME = "control.sock"
EXPECTED_BUNDLE_ID = "com.macallyouneed.macclippy.e2e"
RUNNER_ID = "macclippy-phase5-e2e-runner"
DEFAULT_SEED = 20260925
DEFAULT_PRODUCT_CORPUS = 10_000
DEFAULT_E2E_RETENTION_MAX_ITEMS = 200_000
MAX_E2E_RETENTION_MAX_ITEMS = 200_000
E2E_RETENTION_ENV_NAME = "MACCLIPPY_E2E_RETENTION_MAX_ITEMS"
CORPUS_SIZES = (1_000, 10_000, 100_000)
MAX_CORPUS_PAYLOAD_BYTES = 1_048_576
LONG_RESTART_TEXT_BYTES = 65_536
SOAK_MAX_ACTIVE_HOURS = 72
SOAK_START_HOURS = (24, 72)
RUNTIME_METRIC_INTERVAL_SECONDS = 60
RUNTIME_WORK_INTERVAL_SECONDS = 15
PREVIEW_LOOP_MAX_CYCLES = 1_000
PREVIEW_LOOP_MIN_TIMEOUT_SECONDS = 120
PREVIEW_LOOP_BASE_TIMEOUT_SECONDS = 45
PREVIEW_LOOP_CYCLE_BUDGET_SECONDS = 0.65
SOAK_MAX_RETAINED_ITEMS = 10_000
SOAK_MAX_IMAGE_MEGABYTES = 2_048
SOAK_MAX_HISTORY_MEGABYTES = 4_096
SOAK_MAX_IMAGE_BYTES = SOAK_MAX_IMAGE_MEGABYTES * 1_024 * 1_024
SOAK_MAX_TOTAL_BYTES = SOAK_MAX_HISTORY_MEGABYTES * 1_024 * 1_024
SOAK_SEARCH_RESULT_LIMIT = 512
RETENTION_TELEMETRY_FIELDS = (
    "retentionMaxItems",
    "retentionMaxImageBytes",
    "retentionMaxTotalBytes",
)
SOAK_METRIC_FIELDS = (
    "captureQueueDepth",
    "captureQueueBytes",
    "captureQueueDroppedChangeCount",
    "captureQueueRecoveredChangeCount",
    "captureQueueHasUnrecoveredChanges",
    "captureNotSavedCount",
    "capturePersistFailureCount",
    "captureQueueOverloadErrorCount",
    "captureQueueCurrentGenerationReadRequestCount",
    "ocrQueueDepth",
    "ocrQueueBytes",
    "maintenanceQueueDepth",
    "clipboardWALBytes",
    "searchWALBytes",
    "pinboardWALBytes",
    "snippetWALBytes",
)
SOAK_ERROR_COUNTER_FIELDS = (
    "captureQueueDroppedChangeCount",
    "captureNotSavedCount",
    "capturePersistFailureCount",
    "captureQueueOverloadErrorCount",
)
TARGETS = {
    "warm_panel_interactive_p95_ms": 100.0,
    "app_search_10k_p95_ms": 100.0,
    "app_search_100k_p95_ms": 200.0,
}
ACTIVE_APP_PIDS: dict[tuple[str, str], int] = {}


class E2EError(RuntimeError):
    pass


def validate_retention_max_items(value: Any) -> int:
    if type(value) is not int or not 1 <= value <= MAX_E2E_RETENTION_MAX_ITEMS:
        raise E2EError(
            f"E2E retention max items must be an integer from 1 to {MAX_E2E_RETENTION_MAX_ITEMS}"
        )
    return value


def requested_retention_policy(max_items: int) -> dict[str, int]:
    return {
        "retentionMaxItems": validate_retention_max_items(max_items),
        "retentionMaxImageBytes": SOAK_MAX_IMAGE_BYTES,
        "retentionMaxTotalBytes": SOAK_MAX_TOTAL_BYTES,
    }


def retention_launch_environment(
    max_items: int,
    inherited_environment: dict[str, str] | None = None,
) -> dict[str, str]:
    environment = dict(os.environ if inherited_environment is None else inherited_environment)
    environment.pop(E2E_RETENTION_ENV_NAME, None)
    environment[E2E_RETENTION_ENV_NAME] = str(validate_retention_max_items(max_items))
    return environment


def require_effective_retention_policy(
    metrics: dict[str, Any],
    expected_max_items: int,
    *,
    context: str,
) -> dict[str, int]:
    expected = requested_retention_policy(expected_max_items)
    unavailable = metrics.get("unavailableMetrics")
    unavailable_fields = set(unavailable) if isinstance(unavailable, list) else set()
    missing = [
        field for field in RETENTION_TELEMETRY_FIELDS
        if field in unavailable_fields or type(metrics.get(field)) is not int or metrics[field] <= 0
    ]
    if missing:
        raise E2EError(
            f"{context} cannot verify the effective retention policy; metrics unavailable for {missing}"
        )
    observed = {field: metrics[field] for field in RETENTION_TELEMETRY_FIELDS}
    if observed != expected:
        raise E2EError(
            f"{context} effective retention policy mismatch before workload: "
            f"requested={expected} observed={observed}"
        )
    return observed


def soak_retention_model(effective_policy: dict[str, int]) -> dict[str, Any]:
    verified_policy = require_effective_retention_policy(
        effective_policy,
        SOAK_MAX_RETAINED_ITEMS,
        context="soak retention model",
    )
    return {
        "maxItems": verified_policy["retentionMaxItems"],
        "maxAgeDays": 0,
        "maxImageBytes": verified_policy["retentionMaxImageBytes"],
        "maxTotalBytes": verified_policy["retentionMaxTotalBytes"],
        "maxImageMegabytes": verified_policy["retentionMaxImageBytes"] // 1_048_576,
        "maxHistoryMegabytes": verified_policy["retentionMaxTotalBytes"] // 1_048_576,
        "e2eOverrideApplied": verified_policy["retentionMaxItems"] != DEFAULT_E2E_RETENTION_MAX_ITEMS,
        "policyTelemetry": verified_policy,
        "note": "Effective Runtime item/image/total-byte caps are verified before soak workload; authenticated raw representation bytes remain lower bounds and do not claim database/blob usage",
        "searchResultLimit": SOAK_SEARCH_RESULT_LIMIT,
        "searchCountModel": "the ledger models 10,000-item eviction and caps each primary-kind expectation at the 512-row response limit; after every capture the real type search must match exactly, so age/item/image/total-byte eviction that changes the modeled count fails instead of being treated as a pass",
        "byteCapAccounting": "sampled authenticated raw representation bytes are reported as lower bounds; they are not mislabeled as database/blob usage",
    }


@dataclass(frozen=True)
class QueryContract:
    query_class: str
    query: str
    expected_count: int
    expected_visible_count: int
    required_record_ids: tuple[str, ...] = ()

    def as_json(self) -> dict[str, Any]:
        return {
            "queryClass": self.query_class,
            "query": self.query,
            "expectedRecordCount": self.expected_count,
            "expectedVisibleCount": self.expected_visible_count,
            "requiredRecordIDs": list(self.required_record_ids),
        }


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds")


def monotonic_ns() -> int:
    return time.monotonic_ns()


def compact_json(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def write_json_atomic(path: Path, value: Any, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp")
    descriptor = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, mode)
    try:
        payload = json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8") + b"\n"
        offset = 0
        while offset < len(payload):
            offset += os.write(descriptor, payload[offset:])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.replace(temporary, path)
    os.chmod(path, mode)


def write_json_exclusive(path: Path, value: Any, mode: int = 0o600) -> None:
    """Create a private JSON request without replacing a pending request."""
    payload = json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8") + b"\n"
    descriptor = os.open(
        path,
        os.O_CREAT | os.O_EXCL | os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0),
        mode,
    )
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise E2EError("new request file ownership or permissions are unsafe")
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise E2EError("could not write the private request file")
            offset += written
        os.fsync(descriptor)
    except BaseException:
        try:
            path.unlink()
        except OSError:
            pass
        raise
    finally:
        os.close(descriptor)


def read_private_json(path: Path, description: str) -> tuple[dict[str, Any], os.stat_result]:
    """Read one owner-only regular JSON file without following symlinks."""
    try:
        before = path.lstat()
    except OSError as error:
        raise E2EError(f"{description} is unavailable") from error
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_uid != os.getuid()
        or before.st_mode & 0o077
        or before.st_mode & 0o111
    ):
        raise E2EError(f"{description} ownership or permissions are unsafe")
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError as error:
        raise E2EError(f"{description} could not be safely opened") from error
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != os.getuid()
            or opened.st_mode & 0o077
            or opened.st_mode & 0o111
            or opened.st_dev != before.st_dev
            or opened.st_ino != before.st_ino
        ):
            raise E2EError(f"{description} changed or became unsafe while opening")
        if opened.st_size > 256 * 1_024:
            raise E2EError(f"{description} exceeds the bounded JSON size")
        chunks: list[bytes] = []
        remaining = 256 * 1_024 + 1
        while remaining > 0:
            chunk = os.read(descriptor, min(remaining, 8_192))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        if remaining == 0:
            raise E2EError(f"{description} exceeds the bounded JSON size")
    finally:
        os.close(descriptor)
    try:
        value = json.loads(b"".join(chunks).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise E2EError(f"{description} is not valid JSON") from error
    if not isinstance(value, dict):
        raise E2EError(f"{description} must contain a JSON object")
    return value, before


def append_jsonl(path: Path, value: Any, flush: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
        handle.write("\n")
        handle.flush()
        if flush:
            os.fsync(handle.fileno())


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def path_is_within(path: Path, parent: Path) -> bool:
    try:
        path.resolve(strict=True).relative_to(parent.resolve(strict=True))
        return True
    except (OSError, ValueError):
        return False


def same_resolved_path(actual: Any, expected: Path) -> bool:
    if not isinstance(actual, str) or not actual:
        return False
    try:
        return Path(actual).resolve(strict=True) == expected.resolve(strict=True)
    except (OSError, RuntimeError, ValueError):
        return False


def create_fixture_root(
    retention_max_items: int = DEFAULT_E2E_RETENTION_MAX_ITEMS,
) -> tuple[Path, str]:
    retention_max_items = validate_retention_max_items(retention_max_items)
    temporary_base = Path(tempfile.gettempdir()).resolve(strict=True)
    root = Path(tempfile.mkdtemp(prefix="mce5-", dir=temporary_base)).resolve(strict=True)
    os.chmod(root, 0o700)
    if list(root.iterdir()):
        raise E2EError("temporary fixture directory was not empty")
    run_id = str(uuid.uuid4())
    marker = {
        "schemaVersion": 1,
        "runID": run_id,
        "ownerUID": os.getuid(),
        "createdBy": RUNNER_ID,
        "createdAtUTC": utc_now(),
        "retentionMaxItems": retention_max_items,
        "retentionPolicyRequested": requested_retention_policy(retention_max_items),
    }
    marker_path = root / MARKER_NAME
    descriptor = os.open(marker_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        payload = compact_json(marker) + b"\n"
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise E2EError("could not write the disposable root marker")
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.chmod(marker_path, 0o600)
    return root, run_id


def validate_fixture_root(root_value: str | Path, run_id: str) -> Path:
    root_input = Path(root_value).expanduser()
    if not root_input.is_absolute():
        raise E2EError("fixture root must be an absolute temporary path")
    root = root_input.resolve(strict=True)
    temporary_base = Path(tempfile.gettempdir()).resolve(strict=True)
    if root.parent != temporary_base or not root.name.startswith("mce5-"):
        raise E2EError("fixture root is not a runner-created direct child of the operating-system temporary directory")
    root_stat = root.stat()
    if not stat.S_ISDIR(root_stat.st_mode) or root_stat.st_uid != os.getuid() or root_stat.st_mode & 0o077:
        raise E2EError("fixture root ownership or permissions are unsafe")
    marker_path = root / MARKER_NAME
    marker_stat = marker_path.lstat()
    if not stat.S_ISREG(marker_stat.st_mode) or marker_stat.st_uid != os.getuid() or marker_stat.st_mode & 0o077:
        raise E2EError("fixture root marker ownership or permissions are unsafe")
    marker = json.loads(marker_path.read_text(encoding="utf-8"))
    if (
        marker.get("schemaVersion") != 1
        or marker.get("runID", "").lower() != run_id.lower()
        or marker.get("ownerUID") != os.getuid()
        or marker.get("createdBy") != RUNNER_ID
    ):
        raise E2EError("fixture root marker does not match this runner")
    try:
        marker_max_items = validate_retention_max_items(
            marker.get("retentionMaxItems", DEFAULT_E2E_RETENTION_MAX_ITEMS)
        )
    except E2EError as error:
        raise E2EError("fixture root marker has an invalid retention max item count") from error
    marker_policy = marker.get("retentionPolicyRequested")
    if marker_policy is not None and marker_policy != requested_retention_policy(marker_max_items):
        raise E2EError("fixture root marker retention policy fields are inconsistent")
    if len(os.fsencode(root / CONTROL_SOCKET_NAME)) >= 104:
        raise E2EError("fixture path is too long for the Darwin Unix-domain control socket")
    return root


def fixture_retention_max_items(
    root: Path,
    requested_max_items: int | None = None,
) -> int:
    marker = json.loads((root / MARKER_NAME).read_text(encoding="utf-8"))
    configured = validate_retention_max_items(
        marker.get("retentionMaxItems", DEFAULT_E2E_RETENTION_MAX_ITEMS)
    )
    stored_policy = marker.get("retentionPolicyRequested")
    if stored_policy is not None and stored_policy != requested_retention_policy(configured):
        raise E2EError("fixture root marker retention policy fields are inconsistent")
    if requested_max_items is not None:
        requested = validate_retention_max_items(requested_max_items)
        if requested != configured:
            raise E2EError(
                "requested retention max items do not match this fixture root; "
                f"root={configured} requested={requested}; create a fresh root to change policy"
            )
    return configured


def app_paths(app_value: str | Path) -> tuple[Path, Path, dict[str, Any]]:
    app = Path(app_value).expanduser().resolve(strict=True)
    info_path = app / "Contents" / "Info.plist"
    if not app.name.endswith(".app") or not info_path.is_file():
        raise E2EError("--app must point to a built .app bundle")
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)
    bundle_id = info.get("CFBundleIdentifier")
    if bundle_id != EXPECTED_BUNDLE_ID:
        raise E2EError(f"E2E app bundle ID mismatch: expected {EXPECTED_BUNDLE_ID}")
    executable_name = info.get("CFBundleExecutable")
    if not executable_name:
        raise E2EError("built app has no CFBundleExecutable")
    executable = (app / "Contents" / "MacOS" / executable_name).resolve(strict=True)
    if not os.access(executable, os.X_OK):
        raise E2EError("built app executable is not executable")
    return app, executable, info


def require_release_e2e_app(app_value: str | Path) -> tuple[Path, Path, dict[str, Any]]:
    app, executable, info = app_paths(app_value)
    if info.get("MacClippyE2EBuildConfiguration") != "Release":
        raise E2EError(
            "Release performance/soak requires Info.plist key "
            "MacClippyE2EBuildConfiguration=Release"
        )
    return app, executable, info


def verify_running_app_identity(
    response: dict[str, Any],
    root: Path,
    run_id: str,
    executable: Path,
    info: dict[str, Any],
    expected_pid: int | None = None,
) -> None:
    expected_values = {
        "bundleIdentifier": EXPECTED_BUNDLE_ID,
        "rootPath": str(root),
        "runID": run_id.lower(),
        "executablePath": str(executable),
        "buildConfiguration": info.get("MacClippyE2EBuildConfiguration"),
        "sourceContentSHA256": info.get("MacClippyE2ESourceContentSHA256"),
    }
    for key, expected in expected_values.items():
        actual = response.get(key)
        if key == "rootPath":
            if not same_resolved_path(actual, root):
                raise E2EError(f"running E2E app {key} does not match the selected bundle/build")
            continue
        if key == "executablePath":
            if not same_resolved_path(actual, executable):
                raise E2EError(f"running E2E app {key} does not match the selected bundle/build")
            continue
        if key == "runID" and isinstance(actual, str):
            actual = actual.lower()
        if actual != expected or expected is None:
            raise E2EError(f"running E2E app {key} does not match the selected bundle/build")
    if not isinstance(response.get("pid"), int) or (
        expected_pid is not None and int(response["pid"]) != expected_pid
    ):
        raise E2EError("running E2E app PID does not match the selected instance")


def require_built_source_digest(info: dict[str, Any], source_manifest: dict[str, Any]) -> None:
    built_digest = info.get("MacClippyE2ESourceContentSHA256")
    current_digest = source_manifest["sourceContentSHA256"]
    if not isinstance(built_digest, str) or built_digest != current_digest:
        raise E2EError(
            "E2E executable source digest does not match the current tracked/untracked build inputs; "
            "regenerate the manifest and rebuild the app"
        )


def socket_path(root: Path) -> Path:
    return root / CONTROL_SOCKET_NAME


def control_request(
    root_value: str | Path,
    run_id: str,
    command: str,
    timeout: float = 30.0,
    **arguments: Any,
) -> tuple[dict[str, Any], float]:
    root = validate_fixture_root(root_value, run_id)
    control_path = socket_path(root)
    try:
        info = control_path.lstat()
    except FileNotFoundError as error:
        raise E2EError("E2E app control socket is not available") from error
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise E2EError("E2E app control socket permissions are unsafe")

    message: dict[str, Any] = {"command": command}
    message.update(arguments)
    payload = compact_json(message) + b"\n"
    started = monotonic_ns()
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(timeout)
    try:
        client.connect(str(control_path))
        client.sendall(payload)
        response_bytes = bytearray()
        while len(response_bytes) <= 2 * 1_024 * 1_024:
            chunk = client.recv(8192)
            if not chunk:
                break
            newline = chunk.find(b"\n")
            if newline >= 0:
                response_bytes.extend(chunk[:newline])
                break
            response_bytes.extend(chunk)
        response = json.loads(response_bytes.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        cause = f"{type(error).__name__}: {error}"
        raise E2EError(
            f"E2E app control request failed ({command}); cause={cause[:512]}"
        ) from error
    finally:
        client.close()
    elapsed_ms = (monotonic_ns() - started) / 1_000_000
    if not response.get("ok"):
        code = str(response.get("errorCode", "unknown-error"))[:128]
        detail = str(response.get("message") or "")[:512]
        suffix = f"; detail={detail}" if detail else ""
        raise E2EError(f"E2E app rejected {command}: {code}{suffix}")
    return response, elapsed_ms


def wait_for_app(root: Path, run_id: str, timeout: float = 45.0) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        try:
            response, _ = control_request(root, run_id, "ping", timeout=2.0)
            if response.get("ready") is True:
                return response
        except E2EError as error:
            last_error = error
        time.sleep(0.1)
    raise E2EError(f"E2E app did not become ready: {last_error or 'startup-timeout'}")


def launch_app(
    app_value: str | Path,
    root_value: str | Path,
    run_id: str,
    *,
    retention_max_items: int | None = None,
    timeout: float = 45.0,
) -> tuple[dict[str, Any], int | None, bool, Path, Path, dict[str, Any], dict[str, int]]:
    root = validate_fixture_root(root_value, run_id)
    expected_max_items = fixture_retention_max_items(root, retention_max_items)
    app, executable, info = app_paths(app_value)
    source_manifest = build_source_manifest(REPO_ROOT, root / ".app-source-manifest.json")
    require_built_source_digest(info, source_manifest)
    existing: dict[str, Any] | None = None
    try:
        existing, _ = control_request(root, run_id, "ping", timeout=2.0)
    except E2EError:
        existing = None
    if existing is not None and existing.get("ready"):
        verify_running_app_identity(existing, root, run_id, executable, info)
        metrics, _ = control_request(root, run_id, "metrics", timeout=15)
        effective_policy = require_effective_retention_policy(
            metrics,
            expected_max_items,
            context=f"existing E2E app for root {root}",
        )
        return existing, int(existing["pid"]), False, app, executable, info, effective_policy
    if fixture_root_lock_is_held(root):
        raise E2EError("an isolated app already holds this root but its control socket is unavailable")

    launcher = SCRIPT_PATH.with_name("macclippy-e2e-launch.swift")
    try:
        launched = subprocess.run(
            ["swift", str(launcher), str(app), str(root), run_id],
            cwd=REPO_ROOT,
            check=True,
            capture_output=True,
            text=True,
            timeout=60,
            env=retention_launch_environment(expected_max_items),
        )
        launch_metadata = json.loads(launched.stdout)
        pid = int(launch_metadata["pid"])
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError, KeyError) as error:
        message = error.stderr.strip() if isinstance(error, subprocess.CalledProcessError) and error.stderr else type(error).__name__
        raise E2EError(f"could not launch the isolated E2E app in the background: {message}") from error
    if launch_metadata.get("bundleIdentifier") != EXPECTED_BUNDLE_ID or pid <= 0:
        raise E2EError("Launch Services did not return the expected isolated app identity")
    ACTIVE_APP_PIDS[(str(root), run_id)] = pid
    response = wait_for_app(root, run_id, timeout)
    verify_running_app_identity(response, root, run_id, executable, info, expected_pid=pid)
    try:
        metrics, _ = control_request(root, run_id, "metrics", timeout=15)
        effective_policy = require_effective_retention_policy(
            metrics,
            expected_max_items,
            context=f"new E2E app for root {root}",
        )
    except E2EError:
        try:
            request_terminate(root, run_id, pid)
        finally:
            ACTIVE_APP_PIDS.pop((str(root), run_id), None)
        raise
    write_json_atomic(root / ".macclippy-e2e-app-process.json", {
        "ownerUID": os.getuid(),
        "pid": pid,
        "runID": run_id,
        "executable": str(executable),
        "startedAtUTC": utc_now(),
        "requestedRetentionPolicy": requested_retention_policy(expected_max_items),
        "effectiveRetentionPolicy": effective_policy,
    })
    return response, pid, True, app, executable, info, effective_policy


def fixture_root_lock_is_held(root: Path) -> bool:
    return fixture_lock_is_held(root, ".macclippy-e2e-instance.lock")


def fixture_lock_is_held(root: Path, name: str) -> bool:
    lock_path = root / name
    try:
        info = lock_path.lstat()
    except FileNotFoundError:
        return False
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise E2EError("fixture instance lock ownership or permissions are unsafe")
    try:
        descriptor = os.open(lock_path, os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
    except OSError as error:
        raise E2EError("could not safely inspect the fixture instance lock") from error
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.getuid() or opened.st_mode & 0o077:
            raise E2EError("fixture instance lock ownership or permissions are unsafe")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        else:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            return False
    finally:
        os.close(descriptor)


def acquire_fixture_lock(root: Path, name: str, *, blocking: bool = False) -> int:
    lock_path = root / name
    try:
        descriptor = os.open(
            lock_path,
            os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
    except OSError as error:
        raise E2EError(f"could not safely open fixture lifecycle lock {name}") from error
    info = os.fstat(descriptor)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        os.close(descriptor)
        raise E2EError(f"fixture lifecycle lock {name} ownership or permissions are unsafe")
    try:
        flags = fcntl.LOCK_EX if blocking else fcntl.LOCK_EX | fcntl.LOCK_NB
        fcntl.flock(descriptor, flags)
    except BlockingIOError as error:
        os.close(descriptor)
        raise E2EError(f"fixture lifecycle lock {name} is held") from error
    return descriptor


def wait_for_owned_app_exit(root: Path, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not fixture_root_lock_is_held(root):
            return True
        time.sleep(0.1)
    return not fixture_root_lock_is_held(root)


def request_terminate(root: Path, run_id: str, pid: int | None) -> None:
    try:
        identity, _ = control_request(root, run_id, "ping", timeout=5)
    except E2EError as error:
        raise E2EError(
            "cannot authenticate the isolated app through its root/run control channel; "
            "no process was signaled"
        ) from error
    if not same_resolved_path(identity.get("rootPath"), root) or identity.get("runID", "").lower() != run_id.lower():
        raise E2EError("app control identity does not match the owned root/run; no process was signaled")
    if pid is not None and int(identity.get("pid", -1)) != pid:
        raise E2EError("app control PID differs from the owned process record; no process was signaled")
    control_request(root, run_id, "terminate", timeout=5)
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        try:
            current, _ = control_request(root, run_id, "ping", timeout=1)
            if not same_resolved_path(current.get("rootPath"), root) or current.get("runID", "").lower() != run_id.lower():
                raise E2EError("app control identity changed while terminating the owned instance")
        except E2EError:
            if wait_for_owned_app_exit(root, 1):
                ACTIVE_APP_PIDS.pop((str(root), run_id), None)
                return
        time.sleep(0.1)
    raise E2EError("E2E app did not exit after its own terminate command; no fallback signal was sent")


def build_source_manifest(repo: Path, output_path: Path) -> dict[str, Any]:
    command = ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"]
    completed = subprocess.run(command, cwd=repo, check=True, capture_output=True)
    candidates = sorted({item.decode("utf-8") for item in completed.stdout.split(b"\0") if item})
    suffixes = {
        ".swift", ".c", ".h", ".m", ".mm", ".yml", ".yaml", ".plist", ".entitlements",
        ".xcconfig", ".lock", ".resolved", ".json", ".sh", ".py", ".xctestplan", ".strings",
        ".xcstrings", ".storyboard", ".xib", ".png", ".pdf", ".icns", ".car", ".xcassets",
        ".xcscheme", ".xcworkspacedata", ".xcfilelist", ".xcsettings",
    }
    exact_names = {
        "project.yml", "Package.swift", "Package.resolved", "MacClippy.xcodeproj/project.pbxproj",
        ".swiftlint.yml", ".swiftlint-baseline.yml", ".gitignore", "Makefile",
    }
    excluded_parts = {
        ".git", ".build", "DerivedData", "build", "dist", "reports", "results", "coverage",
        "xcuserdata", "test-results", "performance-results", "soak-results", "__pycache__",
    }
    entries = []
    for relative in candidates:
        path = Path(relative)
        if any(part in excluded_parts for part in path.parts):
            continue
        if relative not in exact_names and path.suffix.lower() not in suffixes:
            continue
        if relative.startswith("docs/") and relative not in exact_names:
            continue
        file_path = repo / relative
        if not file_path.is_file() or file_path.is_symlink():
            continue
        entries.append({"path": relative, "sha256": sha256_file(file_path), "sizeBytes": file_path.stat().st_size})

    base_commit = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=repo, check=True, capture_output=True, text=True
    ).stdout.strip()
    manifest = {
        "schemaVersion": 1,
        "baseCommit": base_commit,
        "createdAtUTC": utc_now(),
        "digestMethod": "sha256(canonical compact UTF-8 JSON array of entries sorted by path; keys sorted; each entry has path, sha256, sizeBytes)",
        "entries": entries,
    }
    canonical_entries = compact_json(entries)
    manifest["sourceContentSHA256"] = hashlib.sha256(canonical_entries).hexdigest()
    write_json_atomic(output_path, manifest)
    manifest["manifestFileSHA256"] = sha256_file(output_path)
    return manifest


def environment_metadata(
    app: Path,
    executable: Path,
    info: dict[str, Any],
    build_configuration: str,
    source_manifest: dict[str, Any],
    effective_retention_policy: dict[str, int],
) -> dict[str, Any]:
    def command_output(command: list[str]) -> str | None:
        try:
            return subprocess.run(command, check=True, capture_output=True, text=True, timeout=10).stdout.strip()
        except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
            return None

    cpu_brand = command_output(["sysctl", "-n", "machdep.cpu.brand_string"])
    cpu_count = command_output(["sysctl", "-n", "hw.ncpu"])
    memory_size = command_output(["sysctl", "-n", "hw.memsize"])
    hardware_model = command_output(["sysctl", "-n", "hw.model"])
    hardware_machine = command_output(["sysctl", "-n", "hw.machine"])
    xcode_version = command_output(["xcodebuild", "-version"])
    actual_configuration = info.get("MacClippyE2EBuildConfiguration")
    if build_configuration != actual_configuration:
        raise E2EError("requested build configuration differs from the built E2E app Info.plist")
    return {
        "createdAtUTC": utc_now(),
        "osVersion": command_output(["sw_vers", "-productVersion"]),
        "osBuild": command_output(["sw_vers", "-buildVersion"]),
        "machine": command_output(["uname", "-m"]),
        "hardwareModel": hardware_model,
        "hardwareMachine": hardware_machine,
        "cpuBrand": cpu_brand,
        "logicalCPUCount": int(cpu_count) if cpu_count and cpu_count.isdigit() else None,
        "physicalMemoryBytes": int(memory_size) if memory_size and memory_size.isdigit() else None,
        "xcodeVersion": xcode_version,
        "buildConfiguration": actual_configuration,
        "bundleIdentifier": info.get("CFBundleIdentifier"),
        "bundleVersion": info.get("CFBundleVersion"),
        "marketingVersion": info.get("CFBundleShortVersionString"),
        "appBundlePath": str(app),
        "executablePath": str(executable),
        "executableSHA256": sha256_file(executable),
        "builtSourceContentSHA256": info.get("MacClippyE2ESourceContentSHA256"),
        "sourceBaseCommit": source_manifest["baseCommit"],
        "sourceContentSHA256": source_manifest["sourceContentSHA256"],
        "sourceManifestSHA256": source_manifest["manifestFileSHA256"],
        "sourceFileCount": len(source_manifest["entries"]),
        "retentionPolicyRequested": requested_retention_policy(
            effective_retention_policy["retentionMaxItems"]
        ),
        "retentionPolicyEffective": effective_retention_policy,
        "workingTreeDirty": subprocess.run(
            ["git", "status", "--porcelain"], cwd=REPO_ROOT, check=True,
            capture_output=True, text=True
        ).stdout.strip() != "",
    }


def make_capture_payload(
    index: int,
    seed: int,
    rng: random.Random,
) -> tuple[str, str, str | None, str, int, int, bool, int]:
    token = f"mc5s{seed:08d}r{index:06d}"
    common = f"mce5commonneedle seed{seed} item{index} {token} "
    special: str | None = None
    if index == 0:
        special = "cjk-emoji"
        extra = "東京 日本語 中文 🧪🚀 👩🏽‍💻 ✨"
        format_name = "text"
    elif index == 1:
        special = "combining-variation-selector"
        extra = "Cafe\u0301 e\u0301 A\ufe0f"
        format_name = "text"
    elif index == 2:
        special = "bidirectional-marks"
        extra = "abc \u2067שלום\u2069 xyz \u200f"
        format_name = "text"
    elif index == 3:
        special = "object-replacement-character"
        extra = "before\ufffcafter"
        format_name = "text"
    elif index == 4:
        special = "bounded-long-text-65536"
        extra = "L" * 65_536
        format_name = "text"
    elif index == 5:
        format_name = "html"
        extra = f"<strong>mixed html {token}</strong>"
    elif index == 6:
        format_name = "rtf"
        extra = f"mixed rich text {token}"
    elif index == 7:
        format_name = "text"
        extra = f"mce5oldneedle oldest searchable fixture {token}"
    elif index == 8:
        format_name = "text"
        extra = f"mce5combinedneedle combined structured fixture {token}"
    elif index == 9:
        format_name = "text"
        extra = f"mce5asciiprefixneedle prefix fixture {token}"
    elif index == 10:
        format_name = "text"
        extra = f"mce5asciiinfixneedle infix fixture {token}"
    elif index == 11:
        format_name = "text"
        extra = f"mce5structuredneedle structured fixture {token}"
    elif index == 12:
        format_name = "image"
        extra = ""
    elif index == 13:
        format_name = "files"
        extra = ""
    elif index in {999, 9_999, 99_999}:
        format_name = "text"
        extra = (
            "tail-only 東京後端 mce5asciiinfixneedle "
            "mce5asciiprefixneedle fullscan-tail fixture"
        )
    else:
        format_name = rng.choices(
            ["text", "html", "rtf", "image", "files"],
            weights=[68, 12, 10, 5, 5],
            k=1,
        )[0]
        chosen_bytes = rng.choice([128, 192, 256, 384, 512, 768, 1_024, 2_048, 4_096])
        filler_length = max(0, chosen_bytes - len(common.encode("utf-8")) - 1)
        extra = "x" * filler_length
    if index > 6:
        text = common + extra
        if format_name == "html":
            text = f"<html><body><p>{common}{extra}</p></body></html>"
    elif format_name == "html":
        text = f"<html><body>{common}{extra}</body></html>"
    else:
        text = common + extra
    payload_bytes = len(text.encode("utf-8"))
    if payload_bytes > MAX_CORPUS_PAYLOAD_BYTES:
        raise E2EError("generated corpus record exceeded the bounded payload size")
    repeat_primary_uti = index % 37 == 0
    item_count = 2 if index % 257 == 0 or repeat_primary_uti else 1
    file_byte_count = rng.choice([64, 128, 256, 512, 1_024]) if format_name == "files" else 0
    return token, format_name, special, text, payload_bytes, item_count, repeat_primary_uti, file_byte_count


def build_query_contracts(
    count: int,
    primary_kind_counts: Counter[str],
    record_ids_by_index: dict[int, str],
) -> tuple[list[QueryContract], list[int]]:
    searchable_count = sum(primary_kind_counts[name] for name in ("text", "html", "rtf"))
    tail_indexes = [index for index in (999, 9_999, 99_999) if index < count]
    tail_ids = tuple(record_ids_by_index[index] for index in tail_indexes)
    contracts = [
        QueryContract("common-hit", "mce5commonneedle", min(searchable_count, 512), min(searchable_count, 16)),
        QueryContract("rare-old-hit", "mce5oldneedle", 1, 1, (record_ids_by_index[7],)),
        QueryContract("zero-hit", "mce5zerohitabsent", 0, 0),
        QueryContract("cjk-substring-tail", "京後", len(tail_ids), len(tail_ids), tail_ids),
        QueryContract(
            "ascii-infix",
            "asciiinfixneedle",
            len(tail_ids) + 1,
            len(tail_ids) + 1,
            (*tail_ids, record_ids_by_index[10]),
        ),
        QueryContract(
            "ascii-prefix",
            "mce5asciiprefix",
            len(tail_ids) + 1,
            len(tail_ids) + 1,
            (*tail_ids, record_ids_by_index[9]),
        ),
        QueryContract(
            "structured-only",
            "type:image",
            min(primary_kind_counts["image"], 512),
            min(primary_kind_counts["image"], 16),
        ),
        QueryContract(
            "structured-text",
            "type:text",
            min(primary_kind_counts["text"], 512),
            min(primary_kind_counts["text"], 16),
        ),
        QueryContract(
            "combined-type-and-term",
            "type:text mce5commonneedle",
            min(primary_kind_counts["text"], 512),
            min(primary_kind_counts["text"], 16),
        ),
        QueryContract(
            "combined-app-and-term",
            "app:com.macallyouneed.macclippy.e2e.synthetic mce5commonneedle",
            min(searchable_count, 512),
            min(searchable_count, 16),
        ),
    ]
    return contracts, tail_indexes


def validate_query_result(
    result: dict[str, Any],
    contract: QueryContract,
    *,
    visible_ui: bool,
) -> int:
    count_key = "visibleCount" if visible_ui else "hitCount"
    expected_count = contract.expected_visible_count if visible_ui else contract.expected_count
    result_count = int(result.get(count_key) or 0)
    if result_count != expected_count:
        raise E2EError(
            f"query contract {contract.query_class} returned {result_count}, expected {expected_count}"
        )
    result_ids = set(result.get("matchedRecordIDs") or [])
    if not set(contract.required_record_ids).issubset(result_ids):
        scope = "visible UI" if visible_ui else "database"
        raise E2EError(f"{scope} query contract {contract.query_class} missed its required stable record IDs")
    return result_count


def wait_for_corpus_quiescence(
    root: Path,
    run_id: str,
    *,
    timeout_seconds: float = 120,
    interval_seconds: float = 0.1,
    required_stable_samples: int = 3,
) -> tuple[float, dict[str, Any]]:
    started = monotonic_ns()
    deadline = time.monotonic() + timeout_seconds
    stable_samples = 0
    latest_metrics: dict[str, Any] = {}
    while time.monotonic() < deadline:
        latest_metrics, _ = control_request(root, run_id, "metrics", timeout=15)
        if latest_metrics.get("captureQueueDepth") == 0 and latest_metrics.get("captureQueueBytes") == 0:
            stable_samples += 1
            if stable_samples >= required_stable_samples:
                return (monotonic_ns() - started) / 1_000_000_000, latest_metrics
        else:
            stable_samples = 0
        time.sleep(interval_seconds)
    raise E2EError(
        "capture queue did not quiesce within the bounded setup window; "
        f"last metrics: {json.dumps(latest_metrics, sort_keys=True)}"
    )


def require_distinct_record_ids(record_ids: Iterable[str], expected_count: int) -> int:
    distinct_count = len(set(record_ids))
    if distinct_count != expected_count:
        raise E2EError(
            "production ingestion deduplicated distinct corpus inputs: "
            f"requested={expected_count} distinctRecordIDs={distinct_count}"
        )
    return distinct_count


def require_primary_content_kind(value: Any, index: int) -> str:
    if not isinstance(value, str) or value not in {"text", "html", "rtf", "image", "files"}:
        raise E2EError(f"production observer returned an unsupported primary content kind for corpus record {index}")
    return str(value)


def require_targeted_recipient_paste(response: dict[str, Any]) -> None:
    if response.get("recipientPostRoute") != "processTargeted":
        raise E2EError("paste did not use the isolated process-targeted poster")
    if response.get("actualOSAXInjectionPerformed") is not False:
        raise E2EError("isolated paste unexpectedly reported OSAX injection")
    if response.get("contentInserted") is not True or int(response.get("recipientInsertionCount") or 0) < 1:
        raise E2EError("paste did not reach the isolated in-memory recipient")


def run_corpus(
    root: Path,
    run_id: str,
    count: int,
    seed: int,
    raw_samples_path: Path,
    *,
    log_every: int = 100,
) -> dict[str, Any]:
    if count not in CORPUS_SIZES:
        raise E2EError(f"corpus count must be one of {CORPUS_SIZES}")
    metrics, _ = control_request(root, run_id, "metrics", timeout=15)
    require_effective_retention_policy(
        metrics,
        DEFAULT_E2E_RETENTION_MAX_ITEMS,
        context="corpus ingestion",
    )
    rng = random.Random(seed)
    source_format_counts: Counter[str] = Counter()
    primary_kind_counts: Counter[str] = Counter()
    type_input_bytes: Counter[str] = Counter()
    type_board_bytes: Counter[str] = Counter()
    type_primary_bytes: Counter[str] = Counter()
    type_fixture_file_bytes: Counter[str] = Counter()
    item_count_distribution: Counter[str] = Counter()
    verified_representation_proof_count = 0
    verified_raw_payload_hash_record_count = 0
    repeated_uti_records = 0
    adversarial = []
    record_ids_by_index: dict[int, str] = {}
    total_input_bytes = 0
    total_board_bytes = 0
    started = monotonic_ns()
    progress_path = root / "corpus-progress.json"
    for index in range(count):
        (
            token,
            format_name,
            special,
            text,
            input_bytes,
            item_count,
            repeat_primary_uti,
            file_byte_count,
        ) = make_capture_payload(index, seed, rng)
        started_call = monotonic_ns()
        response, elapsed_ms = control_request(
            root,
            run_id,
            "capture",
            timeout=120,
            token=token,
            format=format_name,
            text=text,
            payloadKind=format_name,
            itemCount=item_count,
            repeatPrimaryUTI=repeat_primary_uti,
            fileByteCount=file_byte_count,
            forcePoll=True,
            timeoutSeconds=90,
        )
        driver_elapsed = (monotonic_ns() - started_call) / 1_000_000
        board_bytes = int(response.get("payloadByteCount") or input_bytes)
        primary_bytes = int(response.get("rawPayloadByteCount") or 0)
        fixture_file_bytes = int(response.get("fixtureFileByteCount") or 0)
        primary_kind = require_primary_content_kind(response.get("primaryContentKind"), index)
        record_id = response.get("recordID")
        if not isinstance(record_id, str) or not record_id:
            raise E2EError(f"production observer returned no stable record identity for corpus record {index}")
        capture_evidence = require_soak_capture_evidence(
            response,
            token=token,
            source_format=format_name,
            item_count=item_count,
            repeat_primary_uti=repeat_primary_uti,
            file_byte_count=file_byte_count,
        )
        representation_proofs = capture_evidence["representations"]
        if any(proof["byteCount"] is None or proof["sha256"] is None for proof in representation_proofs):
            raise E2EError(f"production observer omitted a bounded raw-byte hash proof for corpus record {index}")
        verified_representation_proof_count += len(representation_proofs)
        verified_raw_payload_hash_record_count += 1
        record_ids_by_index[index] = record_id
        source_format_counts[format_name] += 1
        primary_kind_counts[primary_kind] += 1
        type_input_bytes[format_name] += input_bytes
        type_board_bytes[format_name] += board_bytes
        type_primary_bytes[format_name] += primary_bytes
        type_fixture_file_bytes[format_name] += fixture_file_bytes
        item_count_distribution[str(response.get("capturedItemCount") or item_count)] += 1
        repeated_uti_records += int(repeat_primary_uti)
        total_input_bytes += input_bytes
        total_board_bytes += board_bytes
        if special:
            adversarial.append({
                "token": token,
                "category": special,
                "sourceFormat": format_name,
                "inputPayloadBytes": input_bytes,
                "pasteboardPayloadBytes": board_bytes,
            })
        append_jsonl(raw_samples_path, {
            "schemaVersion": 1,
            "recordType": "sample",
            "wallUTC": utc_now(),
            "monotonicTimestampNS": monotonic_ns(),
            "task": "production_observer_capture_and_index",
            "ingestionMode": "forced_immediate_production_observer_read",
            "corpusIndex": index,
            "token": token,
            "sourceFormat": format_name,
            "recordID": record_id,
            "primaryContentKind": response.get("primaryContentKind"),
            "capturedItemCount": response.get("capturedItemCount"),
            "repeatedPrimaryUTI": repeat_primary_uti,
            "sourceAppBundleIdentifier": response.get("sourceAppBundleIdentifier"),
            "pasteboardTypes": response.get("pasteboardTypes"),
            "inputPayloadBytes": input_bytes,
            "pasteboardPayloadBytes": board_bytes,
            "primaryPayloadBytes": primary_bytes,
            "fixtureFileBytes": fixture_file_bytes,
            "rawPayloadRoundTrip": response.get("rawPayloadRoundTrip"),
            "rawPayloadUTI": response.get("rawPayloadUTI"),
            "rawPayloadBytes": response.get("rawPayloadByteCount"),
            "rawPayloadSHA256": response.get("rawPayloadSHA256"),
            "representationProofs": representation_proofs,
            "driverElapsedMS": driver_elapsed,
            "controlSocketElapsedMS": elapsed_ms,
        })
        if response.get("rawPayloadRoundTrip") is not True:
            raise E2EError(f"raw payload did not round-trip for corpus record {index}")
        if int(response.get("capturedItemCount") or 0) != item_count:
            raise E2EError(f"corpus record {index} did not preserve its declared pasteboard item count")
        if special:
            append_jsonl(raw_samples_path, {
                "schemaVersion": 1,
                "recordType": "adversarial_fixture",
                "wallUTC": utc_now(),
                "token": token,
                "category": special,
                "payloadBytes": input_bytes,
            })
        if (index + 1) % log_every == 0 or index + 1 == count:
            queue_metrics, queue_metrics_elapsed = control_request(root, run_id, "metrics")
            append_jsonl(raw_samples_path, {
                "schemaVersion": 1,
                "recordType": "queue_metrics",
                "wallUTC": utc_now(),
                "monotonicTimestampNS": monotonic_ns(),
                "task": "corpus_ingestion_queue_and_storage_sample",
                "corpusIndex": index,
                "metricsSamplerElapsedMS": queue_metrics_elapsed,
                "appMetrics": queue_metrics,
            })
            write_json_atomic(progress_path, {
                "updatedAtUTC": utc_now(),
                "seed": seed,
                "targetCount": count,
                "capturedCount": index + 1,
                "elapsedSeconds": (monotonic_ns() - started) / 1_000_000_000,
                "sourceFormatDistribution": dict(sorted(source_format_counts.items())),
                "primaryContentKindDistribution": dict(sorted(primary_kind_counts.items())),
                "primaryPayloadBytesBySourceFormat": dict(sorted(type_primary_bytes.items())),
                "fixtureFileBytesBySourceFormat": dict(sorted(type_fixture_file_bytes.items())),
                "capturedItemCountDistribution": dict(sorted(item_count_distribution.items())),
                "repeatedUTIRecordCount": repeated_uti_records,
                "inputPayloadBytes": total_input_bytes,
                "pasteboardPayloadBytes": total_board_bytes,
            })

    distinct_record_count = require_distinct_record_ids(record_ids_by_index.values(), count)

    ingestion_setup_wall_time = (monotonic_ns() - started) / 1_000_000_000
    quiescence_seconds, quiescence_metrics = wait_for_corpus_quiescence(root, run_id)
    contract_verification_started = monotonic_ns()
    query_contracts, tail_indexes = build_query_contracts(count, primary_kind_counts, record_ids_by_index)
    tail_ids = tuple(record_ids_by_index[index] for index in tail_indexes)
    tail_id = tail_ids[-1]
    rare_id = record_ids_by_index[7]
    verified_contracts = []
    for contract in query_contracts:
        result, elapsed = control_request(
            root,
            run_id,
            "search-db",
            query=contract.query,
            limit=512,
        )
        validate_query_result(result, contract, visible_ui=False)
        verified_contracts.append({
            **contract.as_json(),
            "databaseContractVerified": True,
            "matchedRecordIDs": result.get("matchedRecordIDs"),
            "validationControlSocketElapsedMS": elapsed,
        })
    contract_verification_wall_time = (
        monotonic_ns() - contract_verification_started
    ) / 1_000_000_000

    metadata = {
        "schemaVersion": 1,
        "seed": seed,
        "targetRecordCount": count,
        "capturedRecordCount": sum(source_format_counts.values()),
        "distinctCapturedRecordCount": distinct_record_count,
        "authenticatedRawRepresentationHashProofCount": verified_representation_proof_count,
        "authenticatedRawRepresentationHashProofsComplete": verified_raw_payload_hash_record_count == count,
        "authenticatedRawPayloadHashRecordCount": verified_raw_payload_hash_record_count,
        "sourceAppBundleIdentifier": "com.macallyouneed.macclippy.e2e.synthetic",
        "capturePath": "named NSPasteboard -> production MacClippySystemPasteboardReader -> production PasteboardObserver -> MacClippyRuntime -> ClipboardStore and SearchStore FTS",
        "ingestionMode": "forced immediate production observer read for each corpus record; separate from natural background-poll capture",
        "naturalCaptureMeasurement": "not part of the corpus ingestion sample; use capture --ingestion-mode natural-poll for separately labeled observer cadence",
        "declaredRemainderFormatWeights": {"text": 68, "html": 12, "rtf": 10, "image": 5, "files": 5},
        "fixedFixtureIndexes": {
            "unicodeAndRawFormat": list(range(7)),
            "rareOldHit": 7,
            "combinedFilterHit": 8,
            "asciiPrefixHit": 9,
            "asciiInfixHit": 10,
            "structuredHit": 11,
            "imagePrimary": 12,
            "filesPrimary": 13,
            "fullscanTailIndexes": tail_indexes,
        },
        "multipleItemRule": "corpus index divisible by 257 is written as two pasteboard items, plus repeated-UTI fixture rows also require two items",
        "repeatedUTIRule": "corpus index divisible by 37 repeats the primary UTI across pasteboard items",
        "sourceFormatDistribution": dict(sorted(source_format_counts.items())),
        "primaryContentKindDistribution": dict(sorted(primary_kind_counts.items())),
        "inputPayloadBytesBySourceFormat": dict(sorted(type_input_bytes.items())),
        "pasteboardPayloadBytesBySourceFormat": dict(sorted(type_board_bytes.items())),
        "totalInputPayloadBytes": total_input_bytes,
        "totalPasteboardPayloadBytes": total_board_bytes,
        "primaryPayloadBytesBySourceFormat": dict(sorted(type_primary_bytes.items())),
        "fixtureFileBytesBySourceFormat": dict(sorted(type_fixture_file_bytes.items())),
        "capturedItemCountDistribution": dict(sorted(item_count_distribution.items())),
        "repeatedUTIRecordCount": repeated_uti_records,
        "payloadSizeUnit": "bytes; source marker UTF-8, persisted primary UTI payload, observed NSPasteboard representation payloads, and isolated file fixture bytes",
        "adversarialUnicodeRecords": adversarial,
        "queryContracts": verified_contracts,
        "searchFixture": {
            "indexing": "verified through production Runtime.history and SearchStore paths after production observer capture; no direct clipboard DB-only insertion",
            "fullscanTailRecordIDs": list(tail_ids),
            "rareOldRecordID": rare_id,
        },
        "setupWallTimeSeconds": (monotonic_ns() - started) / 1_000_000_000,
        "ingestionSetupWallTimeSeconds": ingestion_setup_wall_time,
        "queryContractVerificationWallTimeSeconds": contract_verification_wall_time,
        "quiescencePolicy": "three consecutive 100 ms samples with captureQueueDepth=0 and captureQueueBytes=0; asynchronous OCR completion is recorded but not required for identity or text-index assertions",
        "quiescenceSeconds": quiescence_seconds,
        "quiescenceMetrics": quiescence_metrics,
        "completedAtUTC": utc_now(),
    }
    write_json_atomic(root / "corpus.json", metadata)
    return metadata


def compile_rusage_helper(root: Path) -> Path:
    tools_dir = root / "tools"
    tools_dir.mkdir(mode=0o700, exist_ok=True)
    output = tools_dir / "macclippy-e2e-rusage"
    source = SCRIPT_PATH.with_name("macclippy-e2e-rusage.c")
    command = [
        "xcrun", "--sdk", "macosx", "clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
        str(source), "-o", str(output),
    ]
    completed = subprocess.run(command, cwd=REPO_ROOT, capture_output=True, text=True)
    if completed.returncode != 0:
        raise E2EError("typed proc_pid_rusage helper compilation failed: " + completed.stderr.strip())
    os.chmod(output, 0o700)
    return output


def collect_process_metrics(helper: Path, pid: int, executable: Path) -> dict[str, Any]:
    completed = subprocess.run(
        [str(helper), str(pid), str(executable)],
        check=False,
        capture_output=True,
        text=True,
        timeout=15,
    )
    if completed.returncode != 0:
        return {"available": False, "reason": "rusage-helper-exit", "exitCode": completed.returncode}
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError:
        return {"available": False, "reason": "rusage-helper-invalid-json"}


def terminate_owned_corpus_app_after_control_failure(
    root: Path,
    run_id: str,
    pid: int,
    executable: Path,
) -> dict[str, Any]:
    """Send SIGTERM only after the root record, root lock, PID, and executable agree."""
    validate_fixture_root(root, run_id)
    process_record, _ = read_private_json(
        root / ".macclippy-e2e-app-process.json",
        "owned E2E app process record",
    )
    if (
        process_record.get("ownerUID") != os.getuid()
        or int(process_record.get("pid", -1)) != pid
        or str(process_record.get("runID", "")).lower() != run_id.lower()
        or not same_resolved_path(process_record.get("executable"), executable)
    ):
        raise E2EError("owned app process record does not match the exact root, run, PID, and executable")
    if not fixture_root_lock_is_held(root):
        ACTIVE_APP_PIDS.pop((str(root), run_id), None)
        return {"status": "already-exited", "pid": pid, "signalSent": False}

    helper = compile_rusage_helper(root)
    identity = collect_process_metrics(helper, pid, executable)
    if not identity.get("available"):
        if not fixture_root_lock_is_held(root):
            ACTIVE_APP_PIDS.pop((str(root), run_id), None)
            return {"status": "already-exited", "pid": pid, "signalSent": False}
        raise E2EError("proc_pidpath could not authenticate the owned E2E PID; no signal was sent")
    if int(identity.get("pid", -1)) != pid or not same_resolved_path(identity.get("executable"), executable):
        raise E2EError("proc_pidpath identity differs from the owned E2E process record; no signal was sent")

    os.kill(pid, signal.SIGTERM)
    if not wait_for_owned_app_exit(root, 20):
        raise E2EError("identity-checked SIGTERM did not release the owned E2E root lock")
    ACTIVE_APP_PIDS.pop((str(root), run_id), None)
    return {"status": "terminated-by-identity-checked-SIGTERM", "pid": pid, "signalSent": True}


def resource_interval(previous: dict[str, Any] | None, current: dict[str, Any], wall_delta_ns: int, expected_ns: int) -> dict[str, Any]:
    if previous is None or not previous.get("available") or not current.get("available"):
        return {
            "coverageAvailable": False,
            "activeCoveredNS": 0,
            "suspectedSleepGapNS": None,
            "unobservedWallGapNS": None,
            "rates": {"cpuCores": None, "interruptWakeupsPerSecond": None, "packageIdleWakeupsPerSecond": None, "processBytesWrittenPerSecond": None},
        }

    numerator = int(current["mach_timebase_numerator"])
    denominator = int(current["mach_timebase_denominator"])
    awake_ticks = max(0, int(current["awake_clock_ticks"]) - int(previous["awake_clock_ticks"]))
    continuous_ticks = max(0, int(current["continuous_clock_ticks"]) - int(previous["continuous_clock_ticks"]))
    awake_ns = awake_ticks * numerator // denominator
    continuous_ns = continuous_ticks * numerator // denominator
    sleep_ns = max(0, continuous_ns - awake_ns)
    wall_gap_ns = max(0, wall_delta_ns - expected_ns)
    unexplained_ns = max(0, wall_delta_ns - awake_ns - sleep_ns)
    gap_threshold_ns = max(10_000_000_000, expected_ns // 2)
    wall_and_monotonic_match = wall_delta_ns >= 0 and abs(wall_delta_ns - continuous_ns) <= gap_threshold_ns
    covered = (
        wall_and_monotonic_match
        and wall_gap_ns <= gap_threshold_ns
        and unexplained_ns <= gap_threshold_ns
    )
    # mach_absolute_time stops during sleep. Count only that awake interval;
    # sleep itself is recorded separately and never counted as active work.
    active_ns = awake_ns if covered else 0

    elapsed_cpu_ns = max(0, int(current["cpu_total_nanoseconds"]) - int(previous["cpu_total_nanoseconds"]))
    interrupt_delta = max(0, int(current["interrupt_wakeups_total"]) - int(previous["interrupt_wakeups_total"]))
    package_delta = max(0, int(current["package_idle_wakeups_total"]) - int(previous["package_idle_wakeups_total"]))
    before_writes = previous.get("process_io_bytes_written")
    after_writes = current.get("process_io_bytes_written")
    write_delta = None
    if isinstance(before_writes, int) and isinstance(after_writes, int) and after_writes >= before_writes:
        write_delta = after_writes - before_writes
    rates = {
        "cpuCores": elapsed_cpu_ns / active_ns if active_ns > 0 else None,
        "interruptWakeupsPerSecond": interrupt_delta / (active_ns / 1_000_000_000) if active_ns > 0 else None,
        "packageIdleWakeupsPerSecond": package_delta / (active_ns / 1_000_000_000) if active_ns > 0 else None,
        "processBytesWrittenPerSecond": write_delta / (active_ns / 1_000_000_000) if active_ns > 0 and write_delta is not None else None,
    }
    return {
        "coverageAvailable": True,
        "covered": covered,
        "activeCoveredNS": active_ns,
        "awakeElapsedNS": awake_ns,
        "continuousElapsedNS": continuous_ns,
        "suspectedSleepGapNS": sleep_ns,
        "unobservedWallGapNS": wall_gap_ns,
        "unexplainedCoverageGapNS": unexplained_ns,
        "cpuTimeDeltaNS": elapsed_cpu_ns,
        "interruptWakeupsDelta": interrupt_delta,
        "packageIdleWakeupsDelta": package_delta,
        "processBytesWrittenDelta": write_delta,
        "rates": rates,
    }


def run_restart_check(app_value: str, root_arg: str | None, run_id_arg: str | None) -> dict[str, Any]:
    created_root = root_arg is None
    root, run_id = create_fixture_root() if created_root else (Path(root_arg).resolve(strict=True), run_id_arg or "")
    if not run_id:
        raise E2EError("--run-id is required when --root is provided")
    root = validate_fixture_root(root, run_id)
    first_launch, process, owned, _, _, _, before_restart_policy = launch_app(
        app_value, root, run_id
    )
    token = f"mc5restart{uuid.uuid4().hex[:16]}"
    prefix = f"mce5commonneedle {token} encrypted restart fixture "
    text = prefix + ("x" * max(0, LONG_RESTART_TEXT_BYTES - len(prefix)))
    if len(text.encode("utf-8")) != LONG_RESTART_TEXT_BYTES:
        raise E2EError("long restart fixture must publish exactly 65,536 UTF-8 bytes")
    captured, capture_elapsed = control_request(root, run_id, "capture", timeout=30, token=token, format="text", text=text)
    if captured.get("sourceAppBundleIdentifier") != "com.macallyouneed.macclippy.e2e.synthetic":
        raise E2EError("capture did not use the synthetic source-app provider")
    request_terminate(root, run_id, process)
    process = None
    launched, process, owned_after_restart, _, _, _, after_restart_policy = launch_app(
        app_value, root, run_id
    )
    if not owned_after_restart:
        raise E2EError("app was already active after the controlled restart")
    if before_restart_policy != after_restart_policy:
        raise E2EError(
            "same-root app restart changed the effective retention policy: "
            f"before={before_restart_policy} after={after_restart_policy}"
        )
    verified, verify_elapsed = control_request(
        root,
        run_id,
        "verify-record",
        recordID=captured.get("recordID"),
        format=captured.get("rawPayloadUTI"),
    )
    restart_payload_evidence = validate_long_text_restart_evidence(
        captured,
        verified,
        token=token,
        expected_byte_count=LONG_RESTART_TEXT_BYTES,
    )
    same_raw_payload = restart_payload_evidence["spilledRepresentationRoundTrip"]
    process_restarted = first_launch.get("pid") != launched.get("pid")
    result = {
        "schemaVersion": 1,
        "test": "production-observer-encrypted-persistence-process-restart-decrypt",
        "passed": restart_payload_evidence["recordIDVerified"] and same_raw_payload and process_restarted,
        "rootPath": str(root),
        "runID": run_id,
        "beforeRestartPID": first_launch.get("pid"),
        "afterRestartPID": launched.get("pid"),
        "recordID": captured["recordID"],
        "sameRunRoot": True,
        "retentionPolicyRequested": requested_retention_policy(
            before_restart_policy["retentionMaxItems"]
        ),
        "retentionPolicyEffectiveBeforeRestart": before_restart_policy,
        "retentionPolicyEffectiveAfterRestart": after_restart_policy,
        "processRestarted": process_restarted,
        "persistentDisposableKeyPresent": (root / ".macclippy-e2e-device-key-v1").is_file(),
        "captureControlElapsedMS": capture_elapsed,
        "restartRecordVerifyAndDecryptElapsedMS": verify_elapsed,
        "encryptedRecordVerified": restart_payload_evidence["recordIDVerified"],
        "rawRepresentationDecryptMatches": same_raw_payload,
        "spilledRepresentationRoundTrip": same_raw_payload,
        "sourceTextUTF8ByteCount": LONG_RESTART_TEXT_BYTES,
        "rawPayloadSHA256BeforeRestart": captured.get("rawPayloadSHA256"),
        "rawPayloadSHA256AfterRestart": verified.get("rawPayloadSHA256"),
        "captureRepresentations": restart_payload_evidence["captureRepresentations"],
        "verifiedRepresentations": restart_payload_evidence["verifiedRepresentations"],
        "completedAtUTC": utc_now(),
    }
    write_json_atomic(root / "restart-check.json", result)
    if not result["passed"]:
        raise E2EError("encrypted process-restart persistence check failed; inspect restart-check.json")
    if owned_after_restart:
        request_terminate(root, run_id, process)
    return result


def nearest_rank(values: Iterable[float], percentile: float) -> float | None:
    ordered = sorted(float(value) for value in values if math.isfinite(float(value)))
    if not ordered:
        return None
    index = max(0, math.ceil(percentile * len(ordered)) - 1)
    return ordered[index]


def sample_summary(samples: list[dict[str, Any]], task: str, key: str) -> dict[str, Any]:
    values = [sample[key] for sample in samples if sample.get("task") == task and isinstance(sample.get(key), (int, float))]
    return {
        "sampleCount": len(values),
        "p50": nearest_rank(values, 0.50),
        "p95": nearest_rank(values, 0.95),
        "p99": nearest_rank(values, 0.99),
        "unit": "milliseconds",
        "quantileMethod": "nearest-rank",
    }


def query_class_summary(samples: list[dict[str, Any]], task: str, query_class: str) -> dict[str, Any]:
    matching = [
        sample for sample in samples
        if sample.get("task") == task and sample.get("queryClass") == query_class
    ]
    return {
        "sampleCount": len(matching),
        "appOperationLatency": sample_summary(matching, task, "appOperationElapsedMS"),
        "controlSocketLatency": sample_summary(matching, task, "controlSocketElapsedMS"),
        "driverLatency": sample_summary(matching, task, "driverElapsedMS"),
        "estimatedIPCAndDriverOverhead": sample_summary(matching, task, "estimatedIPCAndDriverOverheadMS"),
    }


def timed_request(
    root: Path,
    run_id: str,
    task: str,
    command: str,
    timeout: float = 120,
    **arguments: Any,
) -> tuple[dict[str, Any], dict[str, Any]]:
    started = monotonic_ns()
    response, control_elapsed_ms = control_request(root, run_id, command, timeout=timeout, **arguments)
    driver_elapsed_ms = (monotonic_ns() - started) / 1_000_000
    app_elapsed_ms = response.get("uiLatencyMilliseconds")
    if not isinstance(app_elapsed_ms, (int, float)):
        app_elapsed_ms = response.get("elapsedMilliseconds")
    ipc_overhead_ms = None
    if isinstance(app_elapsed_ms, (int, float)):
        ipc_overhead_ms = max(0.0, driver_elapsed_ms - float(app_elapsed_ms))
    return response, {
        "schemaVersion": 1,
        "recordType": "sample",
        "wallUTC": utc_now(),
        "monotonicTimestampNS": monotonic_ns(),
        "task": task,
        "command": command,
        "driverElapsedMS": driver_elapsed_ms,
        "controlSocketElapsedMS": control_elapsed_ms,
        "appOperationElapsedMS": app_elapsed_ms,
        "estimatedIPCAndDriverOverheadMS": ipc_overhead_ms,
        "response": response,
    }


def normalized_preview_cycles(cycles: int) -> int:
    if type(cycles) is not int:
        raise E2EError("preview cycle count must be an integer")
    return max(1, min(cycles, PREVIEW_LOOP_MAX_CYCLES))


def preview_loop_timeout_seconds(cycles: int) -> int:
    normalized = normalized_preview_cycles(cycles)
    workload_budget = PREVIEW_LOOP_BASE_TIMEOUT_SECONDS + math.ceil(
        normalized * PREVIEW_LOOP_CYCLE_BUDGET_SECONDS
    )
    return max(PREVIEW_LOOP_MIN_TIMEOUT_SECONDS, workload_budget)


def preview_loop_request_options(cycles: int) -> dict[str, int]:
    requested = normalized_preview_cycles(cycles)
    return {
        "timeout": preview_loop_timeout_seconds(requested),
        "cycles": requested,
    }


def validate_preview_loop_response(response: dict[str, Any], requested_cycles: int) -> None:
    expected = normalized_preview_cycles(requested_cycles)
    completed = response.get("recordCount")
    if type(completed) is not int or completed != expected:
        raise E2EError(
            f"preview loop completed {completed!r} cycles; expected exactly {expected}"
        )
    if response.get("previewContentReady") is not True or response.get("previewVisible") is not False:
        raise E2EError("preview loop did not report ready content and a closed final presentation")


def acquire_storage_write_lock(database_path: Path, duration_seconds: float) -> tuple[threading.Event, threading.Thread, list[Exception]]:
    ready = threading.Event()
    errors: list[Exception] = []

    def hold_lock() -> None:
        try:
            connection = sqlite3.connect(str(database_path), timeout=5, isolation_level=None)
            try:
                connection.execute("BEGIN IMMEDIATE")
                ready.set()
                time.sleep(duration_seconds)
                connection.execute("COMMIT")
            finally:
                connection.close()
        except Exception as error:  # captured for the benchmark result
            errors.append(error)
            ready.set()

    thread = threading.Thread(target=hold_lock, name="e2e-controlled-sqlite-delay", daemon=True)
    thread.start()
    return ready, thread, errors


def run_interactive_performance(
    app_value: str,
    root_arg: str | None,
    run_id_arg: str | None,
    corpus_count: int,
    seed: int,
    iterations: int,
    preview_cycles: int,
    build_configuration: str,
) -> dict[str, Any]:
    app, executable, info = require_release_e2e_app(app_value)
    created_root = root_arg is None
    root, run_id = create_fixture_root() if created_root else (Path(root_arg).resolve(strict=True), run_id_arg or "")
    if not run_id:
        raise E2EError("--run-id is required when --root is provided")
    root = validate_fixture_root(root, run_id)
    run_name = "performance-" + dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output_dir = root / run_name
    output_dir.mkdir(mode=0o700)
    source_manifest = build_source_manifest(REPO_ROOT, output_dir / "source-manifest.json")
    require_built_source_digest(info, source_manifest)
    _, process, owns_process, app, executable, info, effective_retention_policy = launch_app(
        app_value,
        root,
        run_id,
        retention_max_items=DEFAULT_E2E_RETENTION_MAX_ITEMS,
    )
    environment = environment_metadata(
        app,
        executable,
        info,
        build_configuration,
        source_manifest,
        effective_retention_policy,
    )
    environment["runtimePID"] = int((control_request(root, run_id, "ping")[0]["pid"]))
    environment["testRoot"] = str(root)
    environment["runID"] = run_id
    environment["metricsSampler"] = {
        "method": "typed C helper using libproc.h proc_pid_rusage and sys/resource.h rusage_info_v4",
        "samplingPoints": "baseline, after each measured task, and end-of-run process samples; app queue/WAL snapshot after each measured task",
        "processHelperSpawnElapsedMS": "recorded for each process sample and excluded from app-operation latency",
        "processCPUTimeUnit": "rusage_info_v4 ri_user_time and ri_system_time are Mach time units in XNU; converted using mach_timebase_info to nanoseconds",
        "polling": False,
    }
    environment["unsupportedMetrics"] = {
        "maintenanceQueueDepth": "unavailable: Runtime exposes no synchronized maintenance-queue count",
        "wholeDeviceDiskWrites": "unavailable: this runner records only the known isolated PID process I/O counter",
    }
    samples_path = output_dir / "samples.jsonl"
    samples: list[dict[str, Any]] = []
    helper = compile_rusage_helper(root)
    environment["rusageHelperSHA256"] = sha256_file(helper)
    runtime_pid = int(environment["runtimePID"])
    resource_samples_path = output_dir / "resource-samples.jsonl"
    process_sampler_started = monotonic_ns()
    baseline_process_metrics = collect_process_metrics(helper, runtime_pid, executable)
    baseline_process_sampler_ms = (monotonic_ns() - process_sampler_started) / 1_000_000
    baseline_wall_ns = time.time_ns()
    baseline_mono_ns = monotonic_ns()
    baseline_app_metrics, baseline_app_metrics_ms = control_request(root, run_id, "metrics")
    append_jsonl(resource_samples_path, {
        "schemaVersion": 1,
        "recordType": "process-resource-baseline",
        "wallUTC": utc_now(),
        "wallTimestampNS": baseline_wall_ns,
        "monotonicTimestampNS": baseline_mono_ns,
        "runtimePID": runtime_pid,
        "processMetrics": baseline_process_metrics,
        "processMetricsSamplerElapsedMS": baseline_process_sampler_ms,
        "appMetrics": baseline_app_metrics,
        "appMetricsSamplerElapsedMS": baseline_app_metrics_ms,
    })
    write_json_atomic(output_dir / "environment.json", environment)

    previous_task_process_metrics = [baseline_process_metrics]
    previous_task_process_wall_ns = [baseline_wall_ns]

    def record_sample(sample: dict[str, Any]) -> None:
        app_metrics, sampler_elapsed = control_request(root, run_id, "metrics")
        sample["appQueueAndStorageMetrics"] = app_metrics
        sample["appMetricsSamplerElapsedMS"] = sampler_elapsed
        process_sampler_started = monotonic_ns()
        process_metrics = collect_process_metrics(helper, runtime_pid, executable)
        process_sampler_elapsed_ms = (monotonic_ns() - process_sampler_started) / 1_000_000
        process_wall_ns = time.time_ns()
        process_monotonic_ns = monotonic_ns()
        previous_metrics = previous_task_process_metrics[0]
        previous_wall_ns = previous_task_process_wall_ns[0]
        process_interval = resource_interval(
            previous_metrics,
            process_metrics,
            process_wall_ns - previous_wall_ns,
            max(1, process_wall_ns - previous_wall_ns),
        )
        sample["processResourceMetrics"] = {
            "metrics": process_metrics,
            "samplerElapsedMS": process_sampler_elapsed_ms,
            "interval": process_interval,
        }
        append_jsonl(resource_samples_path, {
            "schemaVersion": 1,
            "recordType": "process-resource-task",
            "wallUTC": utc_now(),
            "wallTimestampNS": process_wall_ns,
            "monotonicTimestampNS": process_monotonic_ns,
            "runtimePID": runtime_pid,
            "task": sample.get("task"),
            "processMetrics": process_metrics,
            "processMetricsSamplerElapsedMS": process_sampler_elapsed_ms,
            "interval": process_interval,
        })
        previous_task_process_metrics[0] = process_metrics
        previous_task_process_wall_ns[0] = process_wall_ns
        samples.append(sample)
        append_jsonl(samples_path, sample)

    corpus_path = root / "corpus.json"
    if corpus_path.exists():
        corpus_metadata = json.loads(corpus_path.read_text(encoding="utf-8"))
        if corpus_metadata.get("targetRecordCount") != corpus_count or corpus_metadata.get("seed") != seed:
            raise E2EError("existing fixture corpus does not match the requested count and seed")
    else:
        corpus_metadata = run_corpus(root, run_id, corpus_count, seed, samples_path)
    write_json_atomic(output_dir / "corpus-metadata.json", corpus_metadata)

    query_contracts = corpus_metadata.get("queryContracts")
    if not isinstance(query_contracts, list) or not query_contracts:
        raise E2EError("corpus metadata has no deterministic query contracts")
    for contract in query_contracts:
        query = str(contract["query"])
        query_class = str(contract["queryClass"])
        expected_count = int(contract["expectedRecordCount"])
        expected_visible_count = int(contract["expectedVisibleCount"])
        required_ids = set(contract.get("requiredRecordIDs") or [])
        for _ in range(max(5, iterations)):
            response, sample = timed_request(
                root,
                run_id,
                "db_only_search",
                "search-db",
                query=query,
                limit=512,
                timeout=120,
            )
            validated_count = validate_query_result(response, QueryContract(
                query_class,
                query,
                expected_count,
                expected_visible_count,
                tuple(required_ids),
            ), visible_ui=False)
            sample.update({
                "corpusCount": corpus_count,
                "queryClass": query_class,
                "query": query,
                "resultCount": validated_count,
                "expectedResultCount": expected_count,
                "resultLimit": 512,
                "requiredRecordIDsPresent": True,
                "searchExecutionLayer": "MacClippyRuntime.history; database/runtime only; no panel activation",
            })
            record_sample(sample)

        for _ in range(max(5, iterations)):
            response, sample = timed_request(
                root,
                run_id,
                "visible_app_search",
                "search-ui",
                query=query,
                timeoutSeconds=90,
            )
            visible_contract = QueryContract(
                query_class,
                query,
                expected_count,
                expected_visible_count,
                tuple(required_ids),
            )
            result_count = validate_query_result(response, visible_contract, visible_ui=True)
            if not response.get("searchCompleted"):
                raise E2EError(f"visible UI search violated {query_class} completion/count contract")
            sample.update({
                "corpusCount": corpus_count,
                "queryClass": query_class,
                "query": query,
                "resultCount": result_count,
                "expectedResultCount": expected_visible_count,
                "databaseExpectedResultCount": expected_count,
                "visibleHistoryPageSize": 16,
                "requiredRecordIDsPresent": True,
                "presentableUI": response.get("panelVisible") is True,
            })
            record_sample(sample)
            _, hide_sample = timed_request(root, run_id, "panel_hide", "panel-hide")
            record_sample(hide_sample)

    for adversarial_index in range(5):
        token = f"mc5s{seed:08d}r{adversarial_index:06d}"
        response, sample = timed_request(
            root,
            run_id,
            "visible_app_search_adversarial",
            "search-ui",
            query=token,
            timeoutSeconds=90,
        )
        sample.update({
            "corpusCount": corpus_count,
            "adversarialCorpusIndex": adversarial_index,
            "resultCount": response.get("visibleCount"),
        })
        if not response.get("visibleCount"):
            raise E2EError(f"visible app search missed adversarial corpus record {adversarial_index}")
        record_sample(sample)
        preview_response, preview_sample = timed_request(
            root,
            run_id,
            "preview_unicode_adversarial",
            "preview-loop",
            timeout=90,
            query=token,
            cycles=1,
        )
        adversarial_category = corpus_metadata["adversarialUnicodeRecords"][adversarial_index]["category"]
        preview_sample.update({
            "corpusCount": corpus_count,
            "adversarialCorpusIndex": adversarial_index,
            "adversarialCategory": adversarial_category,
            "previewContentLoadAwaited": preview_response.get("previewContentReady"),
            "previewPresentationAwaited": preview_response.get("recordCount") == 1,
        })
        if preview_response.get("recordCount") != 1 or preview_response.get("previewContentReady") is not True:
            raise E2EError(f"preview did not load adversarial Unicode record {adversarial_category}")
        record_sample(preview_sample)
        _, hide_sample = timed_request(root, run_id, "panel_hide", "panel-hide")
        record_sample(hide_sample)

    for _ in range(max(5, iterations)):
        _, sample = timed_request(root, run_id, "warm_panel_interactive", "panel-show")
        sample.update({"corpusCount": corpus_count, "interactiveAck": "visible panel + completed initial paint + idle history load + AppKit layout/display flush"})
        record_sample(sample)
        _, hide_sample = timed_request(root, run_id, "panel_hide", "panel-hide")
        record_sample(hide_sample)

    html_token = f"mc5s{seed:08d}r000005"
    for plain in (False, True):
        for _ in range(max(5, iterations)):
            control_request(root, run_id, "recipient-reset")
            response, sample = timed_request(
                root,
                run_id,
                "plain_paste" if plain else "normal_paste",
                "paste",
                query=html_token,
                plain=plain,
                timeoutSeconds=30,
                timeout=45,
            )
            sample.update({
                "contentInserted": response.get("contentInserted"),
                "recipientTypes": response.get("recipientTypes"),
                "recipientByteCount": response.get("recipientByteCount"),
                "recipientSHA256": response.get("recipientSHA256"),
                "recipientLabel": response.get("recipientLabel"),
                "actualOSAXInjectionPerformed": response.get("actualOSAXInjectionPerformed"),
                "recipientPostRoute": response.get("recipientPostRoute"),
                "pasteTransport": "named-pasteboard to MacClippyE2ERecipient in-memory test double; no OSAX or Cmd+V injection; not a real receiving application",
            })
            require_targeted_recipient_paste(response)
            recipient_types = set(response.get("recipientTypes") or [])
            if not response.get("contentInserted"):
                raise E2EError("paste action did not insert matching content into the isolated recipient")
            if (not plain and "public.html" not in recipient_types) or (plain and "public.html" in recipient_types):
                raise E2EError("normal/plain paste did not preserve the expected rich-versus-plain representation types")
            record_sample(sample)

    cancellation = {}
    try:
        control_request(root, run_id, "recipient-reset")
        begin, _ = control_request(
            root,
            run_id,
            "paste-begin-cancelable",
            timeout=120,
            query=html_token,
            plain=False,
            timeoutSeconds=60,
        )
        deadline = time.monotonic() + 10
        status: dict[str, Any] = {}
        while time.monotonic() < deadline:
            status, _ = control_request(root, run_id, "paste-barrier-status", timeout=5)
            if status.get("pasteBarrierWaiting"):
                break
            time.sleep(0.01)
        barrier_entered = bool(status.get("pasteBarrierWaiting"))
        cancelled, cancel_elapsed = control_request(root, run_id, "paste-cancel", timeout=10)
        release_deadline = time.monotonic() + 5
        while time.monotonic() < release_deadline:
            status, _ = control_request(root, run_id, "paste-barrier-status", timeout=5)
            if (
                status.get("pasteBarrierReleased")
                and not status.get("pasteBarrierWaiting")
                and status.get("pasteOperationCompleted")
            ):
                break
            time.sleep(0.01)
        insertion_count = max(
            int(status.get("recipientInsertionCount") or 0),
            int(cancelled.get("recipientInsertionCount") or 0),
        )
        content_inserted = insertion_count > 0
        cancellation = {
            "operationID": begin.get("operationID"),
            "barrierEntered": barrier_entered,
            "barrierReleased": bool(status.get("pasteBarrierReleased")) and not status.get("pasteBarrierWaiting"),
            "cancelAccepted": cancelled.get("ok") is True
                and cancelled.get("pasteResult") == "cancelled-before-injection"
                and cancelled.get("pasteBarrierReleased") is True
                and cancelled.get("pasteOperationCompleted") is True
                and int(cancelled.get("recipientInsertionCount") or 0) == 0,
            "pasteOperationCompleted": bool(status.get("pasteOperationCompleted"))
                and cancelled.get("pasteOperationCompleted") is True,
            "recipientInsertionCount": insertion_count,
            "contentInserted": content_inserted,
            "controlElapsedMS": cancel_elapsed,
            "result": cancelled.get("pasteResult"),
            "recipientLabel": "MacClippyE2ERecipient in-memory test double",
            "actualOSAXInjectionPerformed": False,
        }
    except E2EError as error:
        cancellation = {"availability": "failed", "error": str(error)}
    cancellation_sample = {
        "schemaVersion": 1,
        "recordType": "sample",
        "wallUTC": utc_now(),
        "monotonicTimestampNS": monotonic_ns(),
        "task": "paste_cancellation",
        **cancellation,
    }
    record_sample(cancellation_sample)
    if (
        not cancellation.get("barrierEntered")
        or not cancellation.get("barrierReleased")
        or not cancellation.get("cancelAccepted")
        or cancellation.get("contentInserted")
    ):
        raise E2EError("paste cancellation did not prove cancellation before recipient insertion")

    lock_delay_seconds = 0.25
    database_path = root / "databases" / "clipboard.sqlite"
    ready, lock_thread, lock_errors = acquire_storage_write_lock(database_path, lock_delay_seconds)
    if not ready.wait(timeout=10) or lock_errors:
        raise E2EError("could not acquire controlled clipboard SQLite write lock")
    delay_token = f"mc5delay{uuid.uuid4().hex[:16]}"
    delay_text = f"mce5commonneedle {delay_token} controlled storage contention"
    delay_started = monotonic_ns()
    delay_response, delay_ipc_ms = control_request(
        root,
        run_id,
        "capture",
        timeout=60,
        token=delay_token,
        format="text",
        text=delay_text,
        timeoutSeconds=30,
    )
    lock_thread.join(timeout=10)
    delay_sample = {
        "schemaVersion": 1,
        "recordType": "sample",
        "wallUTC": utc_now(),
        "monotonicTimestampNS": monotonic_ns(),
        "task": "controlled_storage_delay_capture",
        "configuredSQLiteWriteLockMS": lock_delay_seconds * 1_000,
        "driverElapsedMS": (monotonic_ns() - delay_started) / 1_000_000,
        "controlSocketElapsedMS": delay_ipc_ms,
        "recordID": delay_response.get("recordID"),
        "payloadBytes": len(delay_text.encode("utf-8")),
        "mechanism": "separate disposable-process SQLite BEGIN IMMEDIATE lock on isolated clipboard.sqlite; released after configured interval",
    }
    record_sample(delay_sample)

    preview_token = f"mc5s{seed:08d}r000004"
    requested_preview_cycles = normalized_preview_cycles(preview_cycles)
    preview_options = preview_loop_request_options(requested_preview_cycles)
    preview_timeout = preview_options["timeout"]
    preview_response, preview_sample = timed_request(
        root,
        run_id,
        "preview_presentation_and_load",
        "preview-loop",
        timeout=preview_options["timeout"],
        query=preview_token,
        cycles=preview_options["cycles"],
    )
    validate_preview_loop_response(preview_response, requested_preview_cycles)
    preview_sample.update({
        "previewCyclesRequested": requested_preview_cycles,
        "previewCyclesCompleted": preview_response["recordCount"],
        "previewSocketTimeoutSeconds": preview_timeout,
        "previewAnimationPreserved": True,
        "previewContentLoadAwaited": preview_response.get("previewContentReady"),
        "previewPresentationAwaited": True,
    })
    record_sample(preview_sample)

    process_sampler_started = monotonic_ns()
    final_process_metrics = collect_process_metrics(helper, runtime_pid, executable)
    final_process_sampler_ms = (monotonic_ns() - process_sampler_started) / 1_000_000
    final_wall_ns = time.time_ns()
    final_mono_ns = monotonic_ns()
    final_app_metrics, final_app_metrics_ms = control_request(root, run_id, "metrics")
    process_resource_interval = resource_interval(
        baseline_process_metrics,
        final_process_metrics,
        final_wall_ns - baseline_wall_ns,
        max(1, final_wall_ns - baseline_wall_ns),
    )
    append_jsonl(resource_samples_path, {
        "schemaVersion": 1,
        "recordType": "process-resource-final",
        "wallUTC": utc_now(),
        "wallTimestampNS": final_wall_ns,
        "monotonicTimestampNS": final_mono_ns,
        "runtimePID": runtime_pid,
        "processMetrics": final_process_metrics,
        "processMetricsSamplerElapsedMS": final_process_sampler_ms,
        "appMetrics": final_app_metrics,
        "appMetricsSamplerElapsedMS": final_app_metrics_ms,
        "interval": process_resource_interval,
    })

    summaries = {
        "dbOnlySearch": sample_summary(samples, "db_only_search", "appOperationElapsedMS"),
        "visibleAppSearch": sample_summary(samples, "visible_app_search", "appOperationElapsedMS"),
        "visibleAppSearchAdversarial": sample_summary(samples, "visible_app_search_adversarial", "appOperationElapsedMS"),
        "previewUnicodeAdversarial": sample_summary(samples, "preview_unicode_adversarial", "appOperationElapsedMS"),
        "warmPanelInteractive": sample_summary(samples, "warm_panel_interactive", "appOperationElapsedMS"),
        "normalPaste": sample_summary(samples, "normal_paste", "appOperationElapsedMS"),
        "plainPaste": sample_summary(samples, "plain_paste", "appOperationElapsedMS"),
        "previewLoop": sample_summary(samples, "preview_presentation_and_load", "appOperationElapsedMS"),
    }
    query_class_results = {
        str(contract["queryClass"]): {
            "query": contract["query"],
            "expectedDatabaseResultCount": contract["expectedRecordCount"],
            "expectedVisibleResultCount": contract["expectedVisibleCount"],
            "databaseOnly": query_class_summary(samples, "db_only_search", str(contract["queryClass"])),
            "visibleUI": query_class_summary(samples, "visible_app_search", str(contract["queryClass"])),
        }
        for contract in query_contracts
    }
    targets = {
        "warmPanelInteractiveP95MS": {"threshold": TARGETS["warm_panel_interactive_p95_ms"], "unit": "milliseconds"},
        f"visibleAppSearch{corpus_count}P95MS": {
            "threshold": TARGETS["app_search_10k_p95_ms"] if corpus_count == 10_000 else TARGETS["app_search_100k_p95_ms"] if corpus_count == 100_000 else None,
            "unit": "milliseconds",
        },
    }
    observed = {
        "warmPanelInteractiveP95MS": summaries["warmPanelInteractive"]["p95"],
        f"visibleAppSearch{corpus_count}P95MS": summaries["visibleAppSearch"]["p95"],
        "dbOnlySearchP95MS": summaries["dbOnlySearch"]["p95"],
    }
    summary = {
        "schemaVersion": 1,
        "testType": "Release isolated MacClippyE2E visible and storage performance run",
        "runID": run_id,
        "testRoot": str(root),
        "resultsDirectory": str(output_dir),
        "createdAtUTC": environment["createdAtUTC"],
        "completedAtUTC": utc_now(),
        "baseCommit": environment["sourceBaseCommit"],
        "sourceContentSHA256": environment["sourceContentSHA256"],
        "builtSourceContentSHA256": environment["builtSourceContentSHA256"],
        "executableSHA256": environment["executableSHA256"],
        "buildConfiguration": build_configuration,
        "corpus": corpus_metadata,
        "sampleCount": len(samples),
        "observed": observed,
        "targets": targets,
        "quantiles": summaries,
        "queryClassResults": query_class_results,
        "cancellation": cancellation,
        "controlledStorageDelay": delay_sample,
        "previewLoop": {
            "requested": preview_cycles,
            "completed": preview_response.get("recordCount"),
            "eachCycleAwaitedPresentationAndContentLoad": True,
        },
        "generalPasteboardAccess": "not read or written; all capture uses a run-named NSPasteboard",
        "limitations": {
            "generalBoardInterop": "not performed; .general was not read or written",
            "pasteRecipient": "MacClippyE2ERecipient test double; no TextEdit, Safari, Terminal, Finder, OSAX, or real Cmd+V delivery was exercised",
            "foreground": "visible UI commands intentionally activate the E2E app and are excluded from background soak",
            "processDiskWrites": final_process_metrics.get("process_io_bytes_written_availability", "unavailable"),
            "wholeDeviceDiskWrites": "unavailable",
            "maintenanceQueueDepth": "unavailable",
        },
    }
    write_json_atomic(output_dir / "summary.json", summary)
    if owns_process:
        request_terminate(root, run_id, process)
    return summary


def is_runner_process(pid: int, root: Path, run_id: str) -> bool:
    try:
        output = subprocess.run(
            ["ps", "-ww", "-p", str(pid), "-o", "command="],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return False
    return (
        str(SCRIPT_PATH) in output
        and ("_soak-worker" in output or "_soak-control-worker" in output)
        and str(root) in output
        and run_id in output
    )


def read_runner_owner(root: Path, run_id: str) -> dict[str, Any]:
    owner_path = root / RUNNER_OWNER_NAME
    owner, _ = read_private_json(owner_path, "soak runner owner record")
    if (
        type(owner.get("schemaVersion")) is not int
        or owner.get("schemaVersion") != 1
        or type(owner.get("runnerPID")) is not int
        or owner.get("runnerPID", 0) <= 0
        or not isinstance(owner.get("runID"), str)
        or owner.get("runID", "").lower() != run_id.lower()
        or type(owner.get("ownerUID")) is not int
        or owner.get("ownerUID") != os.getuid()
        or owner.get("createdBy") != RUNNER_ID
        or not same_resolved_path(owner.get("rootPath"), root)
    ):
        raise E2EError("soak runner owner record is invalid")
    expected_retention = requested_retention_policy(fixture_retention_max_items(root))
    if (
        "retentionPolicyRequested" in owner
        and owner.get("retentionPolicyRequested") != expected_retention
    ):
        raise E2EError("soak runner owner retention policy does not match its marked root")
    return owner


def validate_soak_worker_identity(root: Path, run_id: str) -> tuple[dict[str, Any], dict[str, Any]]:
    validated_root = validate_fixture_root(root, run_id)
    owner = read_runner_owner(validated_root, run_id)
    if owner["runnerPID"] != os.getpid():
        raise E2EError("soak extension request is not being consumed by its recorded worker")
    status, _ = read_private_json(validated_root / RUNNER_STATUS_NAME, "soak runner status")
    if (
        not isinstance(status.get("runID"), str)
        or status.get("runID", "").lower() != run_id.lower()
        or not same_resolved_path(status.get("rootPath"), validated_root)
        or type(status.get("runnerPID")) is not int
        or status.get("runnerPID") != owner["runnerPID"]
        or status.get("state") not in {"starting", "running"}
    ):
        raise E2EError("soak runner status does not match the active root/run/owner")
    expected_retention = requested_retention_policy(fixture_retention_max_items(validated_root))
    if (
        "retentionPolicyRequested" in status
        and status.get("retentionPolicyRequested") != expected_retention
    ):
        raise E2EError("soak runner status retention policy does not match its marked root")
    return owner, status


def write_extension_rejection(
    root: Path,
    status: dict[str, Any],
    request_id: Any,
    message: str,
) -> None:
    rejection = {
        "requestID": request_id if isinstance(request_id, str) else None,
        "wallUTC": utc_now(),
        "message": message,
    }
    status["lastExtensionRejection"] = rejection
    write_json_atomic(root / RUNNER_STATUS_NAME, status)
    append_jsonl(root / "soak-samples.jsonl", {
        "schemaVersion": 1,
        "recordType": "extension-rejected",
        "wallUTC": rejection["wallUTC"],
        "monotonicTimestampNS": monotonic_ns(),
        "requestID": rejection["requestID"],
        "message": message,
    }, flush=True)


def unlink_request_if_unchanged(path: Path, original: os.stat_result) -> bool:
    try:
        current = path.lstat()
    except FileNotFoundError:
        return True
    if (current.st_dev, current.st_ino, stat.S_IFMT(current.st_mode)) != (
        original.st_dev,
        original.st_ino,
        stat.S_IFMT(original.st_mode),
    ):
        return False
    if stat.S_ISDIR(current.st_mode):
        return False
    path.unlink()
    return True


def consume_extend_request(root: Path, run_id: str) -> int | None:
    request_path = root / SOAK_EXTEND_REQUEST_NAME
    request_lock = acquire_fixture_lock(root, SOAK_EXTEND_LOCK_NAME, blocking=True)
    try:
        try:
            original_info = request_path.lstat()
        except FileNotFoundError:
            return None

        owner, status = validate_soak_worker_identity(root, run_id)
        request_id: Any = None
        try:
            request, read_info = read_private_json(request_path, "soak extension request")
            if (read_info.st_dev, read_info.st_ino) != (original_info.st_dev, original_info.st_ino):
                raise E2EError("soak extension request changed while it was read")
            request_id = request.get("requestID")
            if (
                type(request.get("schemaVersion")) is not int
                or request.get("schemaVersion") != 1
                or type(request.get("ownerUID")) is not int
                or request.get("ownerUID") != os.getuid()
                or not isinstance(request.get("runID"), str)
                or request.get("runID", "").lower() != run_id.lower()
                or not same_resolved_path(request.get("rootPath"), root)
                or type(request.get("runnerPID")) is not int
                or request.get("runnerPID") != owner["runnerPID"]
            ):
                raise E2EError("soak extension request root/run/owner identity mismatch")
            if not isinstance(request_id, str):
                raise E2EError("soak extension request ID is missing")
            try:
                parsed_request_id = uuid.UUID(request_id)
            except (ValueError, AttributeError) as error:
                raise E2EError("soak extension request ID is invalid") from error
            if str(parsed_request_id) != request_id.lower():
                raise E2EError("soak extension request ID is not canonical")
            hours = request.get("additionalActiveHours")
            if type(hours) is not int or hours <= 0:
                raise E2EError("soak extension duration must be a positive integer number of hours")
            prior_request_ids = status.get("acceptedExtensionRequestIDs", [])
            if not isinstance(prior_request_ids, list) or any(not isinstance(item, str) for item in prior_request_ids):
                raise E2EError("soak runner extension receipt list is invalid")
            if request_id in prior_request_ids:
                raise E2EError("soak extension request ID was already consumed")
            current_target = status.get("targetActiveSeconds")
            if (
                isinstance(current_target, bool)
                or not isinstance(current_target, (int, float))
                or current_target <= 0
                or current_target > SOAK_MAX_ACTIVE_HOURS * 3_600
                or (isinstance(current_target, float) and not math.isfinite(current_target))
                or not int(current_target) == current_target
            ):
                raise E2EError("soak runner has an invalid active-duration target")
            current_target_seconds = int(current_target)
            target_seconds = current_target_seconds + hours * 3_600
            if target_seconds > SOAK_MAX_ACTIVE_HOURS * 3_600:
                raise E2EError("soak active duration cannot exceed 72 hours")
        except E2EError as error:
            message = str(error)
            write_extension_rejection(root, status, request_id, message)
            if not unlink_request_if_unchanged(request_path, original_info):
                raise E2EError(f"{message}; unsafe request path could not be safely retired") from error
            return None

        accepted_ids = list(prior_request_ids)
        accepted_ids.append(request_id)
        status["targetActiveSeconds"] = target_seconds
        status["acceptedExtensionRequestIDs"] = accepted_ids
        status["lastExtensionAcceptedAtUTC"] = utc_now()
        write_json_atomic(root / RUNNER_STATUS_NAME, status)
        append_jsonl(root / "soak-samples.jsonl", {
            "schemaVersion": 1,
            "recordType": "soak-extension",
            "wallUTC": utc_now(),
            "monotonicTimestampNS": monotonic_ns(),
            "requestID": request_id,
            "ownerUID": os.getuid(),
            "runID": run_id,
            "runnerPID": owner["runnerPID"],
            "additionalActiveHours": hours,
            "newTargetActiveSeconds": target_seconds,
        }, flush=True)
        if not unlink_request_if_unchanged(request_path, original_info):
            raise E2EError("accepted extension request changed before it could be retired")
        return target_seconds * 1_000_000_000
    finally:
        fcntl.flock(request_lock, fcntl.LOCK_UN)
        os.close(request_lock)


def process_soak_control_requests(root: Path, run_id: str, target_active_ns: int) -> tuple[int, bool]:
    if consume_stop_request(root, run_id):
        return target_active_ns, True
    extended_target_ns = consume_extend_request(root, run_id)
    return (extended_target_ns if extended_target_ns is not None else target_active_ns), False


def start_soak(args: argparse.Namespace) -> dict[str, Any]:
    require_release_e2e_app(args.app)
    requested_policy = requested_retention_policy(SOAK_MAX_RETAINED_ITEMS)
    root, run_id = create_fixture_root(SOAK_MAX_RETAINED_ITEMS)
    requested_smoke_seconds = args.smoke_seconds
    requested_hours = args.hours if args.hours is not None else 24
    if args.hours is not None and requested_smoke_seconds is not None:
        raise E2EError("choose either --hours or --smoke-seconds")
    if requested_smoke_seconds is not None and not 30 <= requested_smoke_seconds <= 1_800:
        raise E2EError("bounded soak smoke duration must be 30 to 1800 seconds")
    sample_interval = args.sample_interval if args.sample_interval is not None else (
        5 if requested_smoke_seconds is not None else RUNTIME_METRIC_INTERVAL_SECONDS
    )
    work_interval = args.work_interval if args.work_interval is not None else (
        5 if requested_smoke_seconds is not None else RUNTIME_WORK_INTERVAL_SECONDS
    )
    if not 5 <= sample_interval <= 3_600 or not 5 <= work_interval <= 3_600:
        raise E2EError("soak sample and work intervals must each be between 5 and 3600 seconds")
    log_path = root / "soak-runner.log"
    log_handle = log_path.open("ab", buffering=0)
    command = [
        sys.executable,
        str(SCRIPT_PATH),
        "_soak-worker",
        "--root", str(root),
        "--run-id", run_id,
        "--app", str(Path(args.app).resolve(strict=True)),
        "--sample-interval", str(sample_interval),
        "--work-interval", str(work_interval),
        "--storage-delay-every", str(args.storage_delay_every),
        "--retention-max-items", str(SOAK_MAX_RETAINED_ITEMS),
        "--build-configuration", args.build_configuration,
    ]
    if requested_smoke_seconds is not None:
        command.extend(["--smoke-seconds", str(requested_smoke_seconds)])
    else:
        command.extend(["--hours", str(requested_hours)])
    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        close_fds=True,
        start_new_session=True,
    )
    log_handle.close()
    owner_record = {
        "schemaVersion": 1,
        "ownerUID": os.getuid(),
        "runID": run_id,
        "rootPath": str(root),
        "runnerPID": process.pid,
        "runnerCommand": command,
        "startedAtUTC": utc_now(),
        "createdBy": RUNNER_ID,
        "retentionPolicyRequested": requested_policy,
        "retentionPolicyEffective": None,
    }
    write_json_atomic(root / RUNNER_OWNER_NAME, owner_record)

    deadline = time.monotonic() + 45
    status_path = root / RUNNER_STATUS_NAME
    try:
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise E2EError(f"soak runner exited during startup; see {log_path}")
            if status_path.exists():
                status = json.loads(status_path.read_text(encoding="utf-8"))
                if status.get("state") in {"running", "starting"}:
                    effective_policy = require_effective_retention_policy(
                        status.get("retentionPolicyEffective", {}),
                        SOAK_MAX_RETAINED_ITEMS,
                        context="soak worker startup",
                    )
                    if status.get("retentionPolicyRequested") != requested_policy:
                        raise E2EError("soak worker status retention request does not match its fresh root")
                    owner_record["retentionPolicyEffective"] = effective_policy
                    write_json_atomic(root / RUNNER_OWNER_NAME, owner_record)
                    return {
                        "root": str(root),
                        "runID": run_id,
                        "runnerPID": process.pid,
                        "state": status.get("state"),
                        "statusFile": str(status_path),
                        "metricsFile": str(root / "soak-samples.jsonl"),
                        "logFile": str(log_path),
                        "targetActiveHours": requested_hours if requested_smoke_seconds is None else None,
                        "targetSmokeSeconds": requested_smoke_seconds,
                        "retentionPolicyRequested": requested_policy,
                        "retentionPolicyEffective": effective_policy,
                        "message": "durable worker started in a separate process session",
                    }
            time.sleep(0.2)
        raise E2EError(f"soak runner did not publish startup status; see {log_path}")
    except E2EError:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired as error:
                raise E2EError("owned soak worker did not exit after its own PID signal") from error
        raise


SOAK_CAPTURE_FORMATS = ("text", "html", "rtf", "image", "files")
SOAK_PRIMARY_KINDS = frozenset({"text", "html", "rtf", "image", "files"})


def soak_capture_parameters(sequence: int) -> dict[str, Any]:
    item_count = 4 if sequence % 10 == 0 else 2 if sequence % 3 == 0 else 1
    return {
        "format": SOAK_CAPTURE_FORMATS[(sequence - 1) % len(SOAK_CAPTURE_FORMATS)],
        "item_count": item_count,
        "repeat_primary_uti": item_count > 1 and sequence % 2 == 0,
        "file_byte_count": 64 + (sequence % 8) * 64,
    }


def require_soak_capture_evidence(
    response: dict[str, Any],
    *,
    token: str,
    source_format: str,
    item_count: int,
    repeat_primary_uti: bool,
    file_byte_count: int,
) -> dict[str, Any]:
    record_id = response.get("recordID")
    primary_kind = response.get("primaryContentKind")
    digest = response.get("rawPayloadSHA256")
    payload_bytes = response.get("rawPayloadByteCount")
    expected_items = min(max(item_count, 1), 4)
    if not isinstance(record_id, str) or not record_id:
        raise E2EError("soak capture did not return a stable record ID")
    if primary_kind not in SOAK_PRIMARY_KINDS:
        raise E2EError(f"soak capture returned an unsupported primary content kind: {primary_kind!r}")
    if response.get("rawPayloadRoundTrip") is not True:
        raise E2EError("soak capture did not prove the published raw payload round trip")
    if not isinstance(response.get("rawPayloadUTI"), str) or not response.get("rawPayloadUTI"):
        raise E2EError("soak capture did not identify its published raw UTI")
    if type(payload_bytes) is not int or payload_bytes <= 0:
        raise E2EError("soak capture returned an invalid raw payload byte count")
    if response.get("recordCount") != 1:
        raise E2EError("soak capture did not return exactly one stable record")
    if not isinstance(digest, str) or len(digest) != 64 or any(character not in "0123456789abcdef" for character in digest):
        raise E2EError("soak capture returned an invalid raw payload SHA-256")
    if response.get("capturedItemCount") != expected_items:
        raise E2EError(
            f"soak capture observed {response.get('capturedItemCount')!r} items; expected {expected_items}"
        )
    if response.get("sourceAppBundleIdentifier") != "com.macallyouneed.macclippy.e2e.synthetic":
        raise E2EError("soak capture source app identity did not match the isolated synthetic source")
    if source_format == "files" and response.get("fixtureFileByteCount") != file_byte_count:
        raise E2EError("soak file capture did not retain the requested fixture byte count")
    representations = validate_representation_proofs(
        response.get("representations"),
        source="capture",
        required_uti=response["rawPayloadUTI"],
        expected_byte_count=payload_bytes,
        expected_sha256=digest,
        repeated_uti=repeat_primary_uti,
    )
    return {
        "recordID": record_id,
        "primaryContentKind": primary_kind,
        "rawPayloadUTI": response["rawPayloadUTI"],
        "rawPayloadByteCount": payload_bytes,
        "rawPayloadSHA256": digest,
        "rawPayloadRoundTrip": True,
        "capturedItemCount": expected_items,
        "repeatPrimaryUTIRequested": repeat_primary_uti,
        "representations": representations,
        "sourceFormat": source_format,
        "token": token,
    }


def validate_soak_search_result(
    response: dict[str, Any],
    *,
    query: str,
    expected_count: int,
    required_record_id: str,
) -> None:
    hit_count = response.get("hitCount")
    result_ids = response.get("matchedRecordIDs")
    if type(hit_count) is not int or hit_count != expected_count:
        raise E2EError(
            f"soak search {query!r} returned {hit_count!r} hits; expected exactly {expected_count}"
        )
    if not isinstance(result_ids, list) or required_record_id not in result_ids:
        raise E2EError(
            f"soak search {query!r} did not return required stable record ID {required_record_id}"
        )


class SoakRetentionLedger:
    """Track item eviction separately from the bounded search page and byte caps."""

    def __init__(
        self,
        max_items: int = SOAK_MAX_RETAINED_ITEMS,
        max_history_bytes: int = SOAK_MAX_HISTORY_MEGABYTES * 1_048_576,
        max_image_bytes: int = SOAK_MAX_IMAGE_MEGABYTES * 1_048_576,
    ) -> None:
        if type(max_items) is not int or max_items <= 0:
            raise E2EError("soak retention item limit must be positive")
        if type(max_history_bytes) is not int or max_history_bytes <= 0:
            raise E2EError("soak retention history byte limit must be positive")
        if type(max_image_bytes) is not int or max_image_bytes <= 0:
            raise E2EError("soak retention image byte limit must be positive")
        self.max_items = max_items
        self.max_history_bytes = max_history_bytes
        self.max_image_bytes = max_image_bytes
        self.recent_kinds: deque[str] = deque()
        self.recent_payload_bytes: deque[tuple[int, int, int]] = deque()
        self.retained_kind_counts: Counter[str] = Counter()
        self.seen_record_ids: set[str] = set()
        self.total_records_seen = 0
        self.retained_raw_representation_bytes_lower_bound = 0
        self.retained_primary_image_bytes_lower_bound = 0
        self.retained_unknown_representation_count = 0

    def add(
        self,
        record_id: str,
        primary_kind: str,
        representation_proofs: list[dict[str, Any]] | None = None,
        *,
        primary_uti: str | None = None,
    ) -> None:
        if not record_id or record_id in self.seen_record_ids:
            raise E2EError(f"soak capture reused or omitted stable record ID {record_id!r}")
        if primary_kind not in SOAK_PRIMARY_KINDS:
            raise E2EError(f"soak capture returned an unsupported primary content kind: {primary_kind!r}")
        proofs = representation_proofs or []
        known_bytes = sum(
            proof["byteCount"]
            for proof in proofs
            if isinstance(proof, dict) and type(proof.get("byteCount")) is int
        )
        unknown_count = sum(
            1
            for proof in proofs
            if not isinstance(proof, dict) or type(proof.get("byteCount")) is not int
        )
        image_bytes = sum(
            proof["byteCount"]
            for proof in proofs
            if primary_kind == "image"
            and isinstance(proof, dict)
            and (primary_uti is None or proof.get("uti") == primary_uti)
            and type(proof.get("byteCount")) is int
        )
        self.seen_record_ids.add(record_id)
        self.total_records_seen += 1
        self.recent_kinds.append(primary_kind)
        self.recent_payload_bytes.append((known_bytes, image_bytes, unknown_count))
        self.retained_kind_counts[primary_kind] += 1
        self.retained_raw_representation_bytes_lower_bound += known_bytes
        self.retained_primary_image_bytes_lower_bound += image_bytes
        self.retained_unknown_representation_count += unknown_count
        if len(self.recent_kinds) > self.max_items:
            evicted_kind = self.recent_kinds.popleft()
            evicted_bytes, evicted_image_bytes, evicted_unknown_count = self.recent_payload_bytes.popleft()
            self.retained_kind_counts[evicted_kind] -= 1
            self.retained_raw_representation_bytes_lower_bound -= evicted_bytes
            self.retained_primary_image_bytes_lower_bound -= evicted_image_bytes
            self.retained_unknown_representation_count -= evicted_unknown_count
            if self.retained_kind_counts[evicted_kind] <= 0:
                del self.retained_kind_counts[evicted_kind]

    def expected_search_count(self, primary_kind: str) -> int:
        retained_count = self.retained_kind_counts[primary_kind]
        return min(retained_count, SOAK_SEARCH_RESULT_LIMIT)

    def as_json(self) -> dict[str, Any]:
        return {
            "maxRetainedItems": self.max_items,
            "maxHistoryBytes": self.max_history_bytes,
            "maxImageBytes": self.max_image_bytes,
            "totalRecordsSeen": self.total_records_seen,
            "retainedRecordCount": len(self.recent_kinds),
            "retainedPrimaryKindCounts": dict(sorted(self.retained_kind_counts.items())),
            "retainedAuthenticatedRawRepresentationBytesLowerBound": self.retained_raw_representation_bytes_lower_bound,
            "retainedPrimaryImagePayloadBytesLowerBound": self.retained_primary_image_bytes_lower_bound,
            "retainedUnknownRepresentationProofCount": self.retained_unknown_representation_count,
            "searchResultLimit": SOAK_SEARCH_RESULT_LIMIT,
            "byteCapAccounting": "authenticated payload bytes are a lower bound, not database/blob usage; exact per-kind search counts are checked after every capture and fail if age/item/image/total-byte retention changes the expected rows",
        }


def validate_representation_proofs(
    representations: Any,
    *,
    source: str,
    required_uti: str,
    expected_byte_count: int,
    expected_sha256: str,
    repeated_uti: bool,
) -> list[dict[str, Any]]:
    if not isinstance(representations, list) or not representations:
        raise E2EError(f"{source} did not return ordered representation proofs")
    normalized: list[dict[str, Any]] = []
    ordering: list[tuple[int, str]] = []
    uti_matches: list[dict[str, Any]] = []
    for proof in representations:
        if not isinstance(proof, dict):
            raise E2EError(f"{source} returned a malformed representation proof")
        item_index = proof.get("itemIndex")
        uti = proof.get("uti")
        payload_state = proof.get("payloadState")
        byte_count = proof.get("byteCount")
        sha256 = proof.get("sha256")
        if type(item_index) is not int or item_index < 0 or not isinstance(uti, str) or not uti:
            raise E2EError(f"{source} returned an invalid item index or UTI")
        if payload_state not in {"present", "spilled", "unavailable", "oversized"}:
            raise E2EError(f"{source} returned an unknown payload state: {payload_state!r}")
        if byte_count is None or sha256 is None:
            if byte_count is not None or sha256 is not None:
                raise E2EError(f"{source} returned a partial byte-count/SHA proof")
        elif (
            type(byte_count) is not int
            or byte_count < 0
            or not isinstance(sha256, str)
            or len(sha256) != 64
            or any(character not in "0123456789abcdef" for character in sha256)
        ):
            raise E2EError(f"{source} returned an invalid byte-count/SHA proof")
        normalized.append({
            "itemIndex": item_index,
            "uti": uti,
            "payloadState": payload_state,
            "byteCount": byte_count,
            "sha256": sha256,
        })
        ordering.append((item_index, uti))
        if uti == required_uti:
            uti_matches.append(normalized[-1])
    if ordering != sorted(ordering):
        raise E2EError(f"{source} representation proofs are not ordered by item index and UTI")
    if not any(proof["itemIndex"] == 0 for proof in uti_matches):
        raise E2EError(f"{source} is missing the requested primary UTI item proofs")
    if repeated_uti and len(uti_matches) < 2:
        raise E2EError(f"{source} is missing the requested repeated primary UTI item proof")
    if repeated_uti and len({proof["itemIndex"] for proof in uti_matches}) < 2:
        raise E2EError(f"{source} repeated primary UTI proofs do not span distinct pasteboard items")
    for proof in uti_matches:
        if proof["byteCount"] != expected_byte_count or proof["sha256"] != expected_sha256:
            raise E2EError(f"{source} primary UTI proof does not match the published payload")
    if repeated_uti:
        repeated_matches = [proof for proof in normalized if proof["uti"] == required_uti]
        if len(repeated_matches) < 2 or any(
            proof["byteCount"] != expected_byte_count or proof["sha256"] != expected_sha256
            for proof in repeated_matches
        ):
            raise E2EError(f"{source} repeated-UTI proofs do not match across pasteboard items")
    return normalized


def validate_soak_verify_record(
    response: dict[str, Any],
    capture_evidence: dict[str, Any],
    *,
    repeated_uti: bool,
) -> dict[str, Any]:
    if response.get("recordID") != capture_evidence["recordID"]:
        raise E2EError("verify-record returned a different stable record ID")
    if response.get("primaryContentKind") != capture_evidence["primaryContentKind"]:
        raise E2EError("verify-record primary kind differs from the capture response")
    if response.get("rawPayloadRoundTrip") is not True:
        raise E2EError("verify-record did not prove the persisted raw payload")
    if response.get("rawPayloadUTI") != capture_evidence["rawPayloadUTI"]:
        raise E2EError("verify-record selected a different raw payload UTI")
    if response.get("rawPayloadByteCount") != capture_evidence["rawPayloadByteCount"]:
        raise E2EError("verify-record byte count differs from the capture proof")
    if response.get("rawPayloadSHA256") != capture_evidence["rawPayloadSHA256"]:
        raise E2EError("verify-record SHA-256 differs from the capture proof")
    if capture_evidence["primaryContentKind"] in {"text", "html", "rtf"}:
        decoded_text = response.get("decodedText")
        if not isinstance(decoded_text, str) or capture_evidence["token"] not in decoded_text:
            raise E2EError("verify-record decoded text did not retain the captured token")
    elif response.get("decodedText") is not None:
        raise E2EError("non-text primary content unexpectedly returned decoded text")
    representations = validate_representation_proofs(
        response.get("representations"),
        source="verify-record",
        required_uti=capture_evidence["rawPayloadUTI"],
        expected_byte_count=capture_evidence["rawPayloadByteCount"],
        expected_sha256=capture_evidence["rawPayloadSHA256"],
        repeated_uti=repeated_uti,
    )
    return {
        "recordID": response["recordID"],
        "primaryContentKind": response["primaryContentKind"],
        "decodedText": response.get("decodedText"),
        "representations": representations,
    }


def validate_long_text_restart_evidence(
    captured: dict[str, Any],
    verified: dict[str, Any],
    *,
    token: str,
    expected_byte_count: int,
) -> dict[str, Any]:
    if expected_byte_count != LONG_RESTART_TEXT_BYTES:
        raise E2EError("long restart evidence must retain the exact 65,536-byte fixture size")
    if captured.get("recordCount") != 1 or captured.get("primaryContentKind") != "text":
        raise E2EError("long restart capture did not produce one text-primary record")
    if captured.get("sourceAppBundleIdentifier") != "com.macallyouneed.macclippy.e2e.synthetic":
        raise E2EError("long restart capture did not use the isolated synthetic source app")
    if captured.get("rawPayloadRoundTrip") is not True:
        raise E2EError("long restart capture did not prove its published raw payload")
    if type(captured.get("spilledRepresentationCount")) is not int or captured["spilledRepresentationCount"] < 1:
        raise E2EError("65,536-byte long restart capture did not persist a spilled representation")
    raw_uti = captured.get("rawPayloadUTI")
    raw_byte_count = captured.get("rawPayloadByteCount")
    raw_sha256 = captured.get("rawPayloadSHA256")
    record_id = captured.get("recordID")
    if not isinstance(record_id, str) or not record_id:
        raise E2EError("long restart capture did not return a stable record ID")
    if not isinstance(raw_uti, str) or not raw_uti or raw_byte_count != expected_byte_count:
        raise E2EError("long restart capture did not retain exactly 65,536 raw UTF-8 bytes")
    if not isinstance(raw_sha256, str):
        raise E2EError("long restart capture did not return a raw payload SHA-256")
    capture_representations = validate_representation_proofs(
        captured.get("representations"),
        source="long restart capture",
        required_uti=raw_uti,
        expected_byte_count=expected_byte_count,
        expected_sha256=raw_sha256,
        repeated_uti=False,
    )
    if not any(
        proof["itemIndex"] == 0 and proof["uti"] == raw_uti and proof["payloadState"] == "spilled"
        for proof in capture_representations
    ):
        raise E2EError("65,536-byte long restart capture was not spilled to the authenticated blob store")

    capture_evidence = {
        "recordID": record_id,
        "primaryContentKind": "text",
        "rawPayloadUTI": raw_uti,
        "rawPayloadByteCount": expected_byte_count,
        "rawPayloadSHA256": raw_sha256,
        "rawPayloadRoundTrip": True,
        "token": token,
    }
    verified_evidence = validate_soak_verify_record(verified, capture_evidence, repeated_uti=False)
    if type(verified.get("spilledRepresentationCount")) is not int or verified["spilledRepresentationCount"] < 1:
        raise E2EError("65,536-byte long restart record did not retain its spill after process restart")
    verified_representations = verified_evidence["representations"]
    if not any(
        proof["itemIndex"] == 0 and proof["uti"] == raw_uti and proof["payloadState"] == "spilled"
        for proof in verified_representations
    ):
        raise E2EError("65,536-byte long restart representation was not spilled after process restart")
    return {
        "recordIDVerified": verified_evidence["recordID"] == record_id,
        "spilledRepresentationRoundTrip": True,
        "captureRepresentations": capture_representations,
        "verifiedRepresentations": verified_representations,
    }


def soak_app_metric_evidence(
    response: dict[str, Any],
    *,
    baseline_counters: dict[str, int | None] | None,
) -> tuple[dict[str, Any], dict[str, int | None], list[str]]:
    if not isinstance(response, dict) or response.get("ok") is not True:
        raise E2EError("soak metrics response was not successful")
    unavailable = response.get("unavailableMetrics", [])
    if not isinstance(unavailable, list) or any(not isinstance(item, str) for item in unavailable):
        raise E2EError("soak metrics unavailableMetrics is malformed")
    unavailable_fields = set(unavailable)
    values: dict[str, Any] = {}
    for field in SOAK_METRIC_FIELDS:
        if field in unavailable_fields or field not in response:
            values[field] = None
            unavailable_fields.add(field)
            continue
        value = response[field]
        if field == "captureQueueHasUnrecoveredChanges":
            if type(value) is not bool:
                raise E2EError(f"soak metric {field} must be boolean when available")
        elif value is not None and (type(value) is not int or value < 0):
            raise E2EError(f"soak metric {field} must be a nonnegative integer when available")
        elif value is None:
            unavailable_fields.add(field)
        values[field] = value

    counters: dict[str, int | None] = {
        field: values[field] if type(values[field]) is int else None
        for field in (
            "captureQueueDroppedChangeCount",
            "captureQueueRecoveredChangeCount",
            "captureNotSavedCount",
            "capturePersistFailureCount",
            "captureQueueOverloadErrorCount",
            "captureQueueCurrentGenerationReadRequestCount",
        )
    }
    deltas: dict[str, int | None] = {}
    violations: list[str] = []
    if baseline_counters is None:
        deltas = {field: None for field in counters}
        for field in SOAK_ERROR_COUNTER_FIELDS:
            value = counters[field]
            if value is not None and value > 0:
                violations.append(f"baseline {field}={value}")
    else:
        for field, value in counters.items():
            baseline = baseline_counters.get(field)
            if value is None or baseline is None:
                deltas[field] = None
                continue
            delta = value - baseline
            deltas[field] = delta
            if delta < 0:
                violations.append(f"{field} decreased from {baseline} to {value}")
            elif field in SOAK_ERROR_COUNTER_FIELDS and delta > 0:
                violations.append(f"{field} increased by {delta}")
    if values["captureQueueHasUnrecoveredChanges"] is True:
        violations.append("captureQueueHasUnrecoveredChanges is true")

    evidence = {
        "values": values,
        "counters": counters,
        "baselineCounters": baseline_counters,
        "counterDeltas": deltas,
        "unavailableMetrics": sorted(unavailable_fields),
        "rawResponse": response,
    }
    return evidence, counters, violations


def capture_and_verify_soak_record(
    root: Path,
    run_id: str,
    samples_path: Path,
    ledger: SoakRetentionLedger,
    *,
    cycle: int,
    token: str,
    source_format: str,
    text: str,
    item_count: int,
    repeat_primary_uti: bool,
    file_byte_count: int,
    task_name: str,
    socket_timeout: float,
) -> dict[str, Any]:
    capture_started = monotonic_ns()
    response, control_ms = control_request(
        root,
        run_id,
        "capture",
        timeout=socket_timeout,
        token=token,
        format=source_format,
        text=text,
        payloadKind=source_format,
        itemCount=item_count,
        repeatPrimaryUTI=repeat_primary_uti,
        fileByteCount=file_byte_count,
        timeoutSeconds=max(30, socket_timeout - 1),
    )
    try:
        capture_evidence = require_soak_capture_evidence(
            response,
            token=token,
            source_format=source_format,
            item_count=item_count,
            repeat_primary_uti=repeat_primary_uti,
            file_byte_count=file_byte_count,
        )
    except Exception as error:
        append_jsonl(samples_path, {
            "schemaVersion": 1,
            "recordType": "workload-capture-rejected",
            "wallUTC": utc_now(),
            "monotonicTimestampNS": monotonic_ns(),
            "phase": "mixed-load",
            "cycle": cycle,
            "task": task_name,
            "sourceFormat": source_format,
            "token": token,
            "requestedItemCount": min(max(item_count, 1), 4),
            "repeatPrimaryUTIRequested": repeat_primary_uti,
            "rawCaptureResponse": response,
            "captureControlSocketElapsedMS": control_ms,
            "validationError": f"{type(error).__name__}: {error}",
        }, flush=True)
        raise
    ledger.add(
        capture_evidence["recordID"],
        capture_evidence["primaryContentKind"],
        capture_evidence["representations"],
        primary_uti=capture_evidence["rawPayloadUTI"],
    )
    primary_kind = capture_evidence["primaryContentKind"]
    retention_snapshot = ledger.as_json()
    capture_elapsed_ms = (monotonic_ns() - capture_started) / 1_000_000
    append_jsonl(samples_path, {
        "schemaVersion": 1,
        "recordType": "workload",
        "wallUTC": utc_now(),
        "monotonicTimestampNS": monotonic_ns(),
        "phase": "mixed-load",
        "cycle": cycle,
        "task": task_name,
        "sourceFormat": source_format,
        "primaryContentKind": primary_kind,
        "token": token,
        "recordID": capture_evidence["recordID"],
        "requestedItemCount": min(max(item_count, 1), 4),
        "repeatPrimaryUTIRequested": repeat_primary_uti,
        "sourceAppBundleIdentifier": response.get("sourceAppBundleIdentifier"),
        "fileFixtureByteCountRequested": file_byte_count if source_format == "files" else None,
        "inputPayloadBytes": len(text.encode("utf-8")),
        "pasteboardPayloadBytes": response.get("payloadByteCount"),
        "rawPayloadEvidence": capture_evidence,
        "rawCaptureResponse": response,
        "captureElapsedMS": capture_elapsed_ms,
        "captureControlSocketElapsedMS": control_ms,
        "retentionWindow": retention_snapshot,
    }, flush=True)
    verify_response, verify_ms = control_request(
        root,
        run_id,
        "verify-record",
        timeout=socket_timeout,
        recordID=capture_evidence["recordID"],
        format=capture_evidence["rawPayloadUTI"],
    )
    try:
        verified_evidence = validate_soak_verify_record(
            verify_response,
            capture_evidence,
            repeated_uti=repeat_primary_uti,
        )
    except Exception as error:
        append_jsonl(samples_path, {
            "schemaVersion": 1,
            "recordType": "workload-verify-rejected",
            "wallUTC": utc_now(),
            "monotonicTimestampNS": monotonic_ns(),
            "phase": "mixed-load",
            "cycle": cycle,
            "task": "production_verify_record_payload",
            "recordID": capture_evidence["recordID"],
            "sourceFormat": source_format,
            "primaryContentKind": primary_kind,
            "rawVerifyRecordResponse": verify_response,
            "verifyRecordControlSocketElapsedMS": verify_ms,
            "validationError": f"{type(error).__name__}: {error}",
        }, flush=True)
        raise
    append_jsonl(samples_path, {
        "schemaVersion": 1,
        "recordType": "workload",
        "wallUTC": utc_now(),
        "monotonicTimestampNS": monotonic_ns(),
        "phase": "mixed-load",
        "cycle": cycle,
        "task": "production_verify_record_payload",
        "sourceFormat": source_format,
        "primaryContentKind": primary_kind,
        "token": token,
        "recordID": capture_evidence["recordID"],
        "verifiedRecordEvidence": verified_evidence,
        "rawVerifyRecordResponse": verify_response,
        "verifyRecordControlSocketElapsedMS": verify_ms,
        "retentionWindow": retention_snapshot,
    }, flush=True)
    query = f"type:{primary_kind}"
    search_response, search_ms = control_request(
        root,
        run_id,
        "search-db",
        timeout=socket_timeout,
        query=query,
        limit=SOAK_SEARCH_RESULT_LIMIT,
    )
    expected_count = ledger.expected_search_count(primary_kind)
    try:
        validate_soak_search_result(
            search_response,
            query=query,
            expected_count=expected_count,
            required_record_id=capture_evidence["recordID"],
        )
    except Exception as error:
        append_jsonl(samples_path, {
            "schemaVersion": 1,
            "recordType": "workload-search-rejected",
            "wallUTC": utc_now(),
            "monotonicTimestampNS": monotonic_ns(),
            "phase": "mixed-load",
            "cycle": cycle,
            "task": "production_FTS_database_search",
            "recordID": capture_evidence["recordID"],
            "query": query,
            "expectedHitCount": expected_count,
            "rawSearchResponse": search_response,
            "searchControlSocketElapsedMS": search_ms,
            "validationError": f"{type(error).__name__}: {error}",
        }, flush=True)
        raise
    append_jsonl(samples_path, {
        "schemaVersion": 1,
        "recordType": "workload",
        "wallUTC": utc_now(),
        "monotonicTimestampNS": monotonic_ns(),
        "phase": "mixed-load",
        "task": "production_FTS_database_search",
        "captureTask": task_name,
        "queryClass": "primary-kind-and-stable-record-id",
        "query": query,
        "sourceFormat": source_format,
        "primaryContentKind": primary_kind,
        "token": token,
        "recordID": capture_evidence["recordID"],
        "expectedHitCount": expected_count,
        "hitCount": search_response.get("hitCount"),
        "matchedRecordIDs": search_response.get("matchedRecordIDs"),
        "searchControlSocketElapsedMS": search_ms,
        "rawSearchResponse": search_response,
        "retentionWindow": retention_snapshot,
        "searchVerified": True,
    }, flush=True)
    return {
        "captureResponse": response,
        "captureEvidence": capture_evidence,
        "verifyResponse": verify_response,
        "verifiedEvidence": verified_evidence,
        "searchResponse": search_response,
        "searchElapsedMS": search_ms,
        "captureControlSocketElapsedMS": control_ms,
        "captureElapsedMS": capture_elapsed_ms,
        "recordID": capture_evidence["recordID"],
        "primaryContentKind": primary_kind,
        "expectedSearchCount": expected_count,
    }


def soak_worker(args: argparse.Namespace) -> int:
    if (args.hours is None) == (args.smoke_seconds is None):
        raise E2EError("soak worker requires exactly one of --hours or --smoke-seconds")
    if args.smoke_seconds is not None and not 30 <= args.smoke_seconds <= 1_800:
        raise E2EError("bounded soak smoke duration must be 30 to 1800 seconds")
    if not 5 <= args.sample_interval <= 3_600 or not 5 <= args.work_interval <= 3_600:
        raise E2EError("soak sample and work intervals must each be between 5 and 3600 seconds")
    if validate_retention_max_items(args.retention_max_items) != SOAK_MAX_RETAINED_ITEMS:
        raise E2EError(f"soak runner requires an explicit {SOAK_MAX_RETAINED_ITEMS}-item E2E retention limit")
    app, executable, info = require_release_e2e_app(args.app)
    root = validate_fixture_root(args.root, args.run_id)
    fixture_retention_max_items(root, args.retention_max_items)
    runner_lock = acquire_fixture_lock(root, RUNNER_LOCK_NAME)
    atexit.register(os.close, runner_lock)
    manifest = build_source_manifest(REPO_ROOT, root / "source-manifest.json")
    require_built_source_digest(info, manifest)
    stop_event = threading.Event()

    def handle_signal(_signum: int, _frame: Any) -> None:
        stop_event.set()

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)
    _, process, owns_process, app, executable, info, effective_retention_policy = launch_app(
        args.app,
        root,
        args.run_id,
        retention_max_items=args.retention_max_items,
        timeout=60,
    )
    if not owns_process:
        raise E2EError(
            "soak runner found an already active app for this root after checking its effective retention; "
            "it will not change policy or restart an app it does not own"
        )

    app_cleanup_completed = [False]

    def cleanup_owned_app_on_worker_exit() -> None:
        if app_cleanup_completed[0] or process is None:
            return
        try:
            request_terminate(root, args.run_id, process)
            app_cleanup_completed[0] = True
        except E2EError:
            pass

    atexit.register(cleanup_owned_app_on_worker_exit)
    pid = int(control_request(root, args.run_id, "ping")[0]["pid"])
    output_dir = root / "soak"
    output_dir.mkdir(mode=0o700)
    samples_path = root / "soak-samples.jsonl"
    environment = environment_metadata(
        app,
        executable,
        info,
        args.build_configuration,
        manifest,
        effective_retention_policy,
    )
    helper = compile_rusage_helper(root)
    metadata = {
        **environment,
        "runID": args.run_id,
        "testRoot": str(root),
        "runtimePID": pid,
        "requestedActiveHours": args.hours,
        "requestedSmokeSeconds": args.smoke_seconds,
        "sampleIntervalSeconds": args.sample_interval,
        "workIntervalSeconds": args.work_interval,
        "storageDelayEveryWorkCycles": args.storage_delay_every,
        "retentionPolicyRequested": requested_retention_policy(args.retention_max_items),
        "retentionPolicyEffective": effective_retention_policy,
        "controlChannel": "event-driven local Unix-domain socket; no app idle polling",
        "metricsSampler": {
            "method": "typed C helper calling proc_pid_rusage(PID, RUSAGE_INFO_V4)",
            "intervalSeconds": args.sample_interval,
            "idleAppOnlyBaselineSeconds": args.sample_interval,
            "runnerProcessSpawnPerSample": True,
            "runnerOwnWritesExcludedFromAppProcessIO": True,
        },
        "workerControlTiming": {
            "workIntervalSeconds": args.work_interval,
            "metricsIntervalSeconds": args.sample_interval,
            "extensionCheck": "at each scheduled work or metric wake; no busy loop",
        },
        "activeCoverageMethod": "separate idle app-only baseline; mixed-load coverage counts awake Mach time only and records sleep/unobserved gaps",
        "retentionModel": soak_retention_model(effective_retention_policy),
        "appMetricsContract": {
            "queueAndCaptureCounters": [
                "captureQueueDepth", "captureQueueBytes", "captureQueueDroppedChangeCount",
                "captureQueueRecoveredChangeCount", "captureQueueHasUnrecoveredChanges",
                "captureNotSavedCount", "capturePersistFailureCount", "captureQueueOverloadErrorCount",
                "captureQueueCurrentGenerationReadRequestCount", "ocrQueueDepth", "ocrQueueBytes",
            ],
            "unavailableMetricPolicy": "null value plus unavailableMetrics entry; never substitute zero",
            "unexpectedCounterPolicy": "compare monotonic counters to idle baseline and fail on drops, unsaved captures, persistence failures, or overload errors",
        },
        "unsupportedMetrics": {
            "maintenanceQueueDepth": "unavailable",
            "wholeDeviceDiskWrites": "unavailable",
            "processDiskWritesZeroValue": "unknown-zero-or-unavailable per rusage_info_v4 interface",
        },
    }
    write_json_atomic(root / "soak-metadata.json", metadata)
    created_at = utc_now()
    started_wall_ns = time.time_ns()
    started_mono_ns = monotonic_ns()
    target_active_seconds = args.smoke_seconds if args.smoke_seconds is not None else args.hours * 3_600
    target_active_ns = int(target_active_seconds * 1_000_000_000)
    covered_active_ns = 0
    previous_metrics: dict[str, Any] | None = None
    previous_wall_ns: int | None = None
    sequence = 0
    work_cycles = 0
    soak_ledger = SoakRetentionLedger(
        max_items=effective_retention_policy["retentionMaxItems"],
        max_history_bytes=effective_retention_policy["retentionMaxTotalBytes"],
        max_image_bytes=effective_retention_policy["retentionMaxImageBytes"],
    )
    app_metric_baseline: dict[str, int | None] | None = None
    metric_samples = 0
    sleep_gap_count = 0
    state = "running"
    last_error: str | None = None
    next_work = time.monotonic() + args.work_interval
    next_sample = time.monotonic()

    def write_status() -> None:
        retained_control_state: dict[str, Any] = {}
        status_path = root / RUNNER_STATUS_NAME
        if status_path.exists():
            previous_status, _ = read_private_json(status_path, "soak runner status")
            for key in ("acceptedExtensionRequestIDs", "lastExtensionRejection", "lastExtensionAcceptedAtUTC"):
                if key in previous_status:
                    retained_control_state[key] = previous_status[key]
        status = {
            "schemaVersion": 1,
            "state": state,
            "runID": args.run_id,
            "rootPath": str(root),
            "runnerPID": os.getpid(),
            "runtimePID": pid,
            "createdAtUTC": created_at,
            "updatedAtUTC": utc_now(),
            "startedWallUTC": dt.datetime.fromtimestamp(started_wall_ns / 1_000_000_000, tz=dt.timezone.utc).isoformat(),
            "targetActiveSeconds": target_active_ns / 1_000_000_000,
            "coveredActiveSeconds": covered_active_ns / 1_000_000_000,
            "wallElapsedSeconds": (time.time_ns() - started_wall_ns) / 1_000_000_000,
            "progressFraction": min(1.0, covered_active_ns / max(1, target_active_ns)),
            "workCycles": work_cycles,
            "metricSamples": metric_samples,
            "suspectedSleepGapCount": sleep_gap_count,
            "lastError": last_error,
            "sampleFile": str(samples_path),
            "logFile": str(root / "soak-runner.log"),
            "retentionPolicyRequested": requested_retention_policy(args.retention_max_items),
            "retentionPolicyEffective": effective_retention_policy,
            "retentionModel": soak_ledger.as_json(),
            "acceptedExtensionRequestIDs": [],
            **retained_control_state,
        }
        write_json_atomic(root / RUNNER_STATUS_NAME, status)

    write_status()
    append_jsonl(samples_path, {
        "schemaVersion": 1,
        "recordType": "liveness",
        "wallUTC": utc_now(),
        "monotonicTimestampNS": monotonic_ns(),
        "state": state,
        "runnerPID": os.getpid(),
        "runtimePID": pid,
        "message": "soak worker started",
    }, flush=True)

    try:
        sampler_started = monotonic_ns()
        idle_start_metrics = collect_process_metrics(helper, pid, executable)
        idle_start_sampler_ms = (monotonic_ns() - sampler_started) / 1_000_000
        idle_start_wall_ns = time.time_ns()
        idle_start_mono_ns = monotonic_ns()
        idle_start_app_metrics, idle_start_app_ms = control_request(root, args.run_id, "metrics")
        idle_start_app_evidence, idle_start_app_counters, idle_start_metric_violations = soak_app_metric_evidence(
            idle_start_app_metrics,
            baseline_counters=None,
        )
        append_jsonl(samples_path, {
            "schemaVersion": 1,
            "recordType": "resource-metrics",
            "wallUTC": utc_now(),
            "wallTimestampNS": idle_start_wall_ns,
            "monotonicTimestampNS": idle_start_mono_ns,
            "task": "isolated_app_idle_baseline_start",
            "phase": "idle-app-only",
            "runtimePID": pid,
            "processMetrics": idle_start_metrics,
            "processMetricsSamplerElapsedMS": idle_start_sampler_ms,
            "appMetrics": idle_start_app_metrics,
            "appMetricEvidence": idle_start_app_evidence,
            "appMetricsControlElapsedMS": idle_start_app_ms,
        }, flush=True)
        if idle_start_metric_violations:
            raise E2EError("idle app metrics reported unexpected product errors: " + "; ".join(idle_start_metric_violations))
        stop_event.wait(args.sample_interval)
        if not stop_event.is_set():
            idle_end_app_metrics, idle_end_app_ms = control_request(root, args.run_id, "metrics")
            idle_end_app_evidence, idle_end_app_counters, idle_end_metric_violations = soak_app_metric_evidence(
                idle_end_app_metrics,
                baseline_counters=idle_start_app_counters,
            )
            sampler_started = monotonic_ns()
            idle_end_metrics = collect_process_metrics(helper, pid, executable)
            idle_end_sampler_ms = (monotonic_ns() - sampler_started) / 1_000_000
            idle_end_wall_ns = time.time_ns()
            idle_end_mono_ns = monotonic_ns()
            if not idle_start_metrics.get("available") or not idle_end_metrics.get("available"):
                raise E2EError("soak requires process Mach clocks to measure awake active coverage")
            idle_interval = resource_interval(
                idle_start_metrics,
                idle_end_metrics,
                idle_end_wall_ns - idle_start_wall_ns,
                int(args.sample_interval * 1_000_000_000),
            )
            if int(idle_interval.get("suspectedSleepGapNS") or 0) > 1_000_000_000:
                sleep_gap_count += 1
            append_jsonl(samples_path, {
                "schemaVersion": 1,
                "recordType": "resource-metrics",
                "wallUTC": utc_now(),
                "wallTimestampNS": idle_end_wall_ns,
                "monotonicTimestampNS": idle_end_mono_ns,
                "task": "isolated_app_idle_baseline",
                "phase": "idle-app-only",
                "runtimePID": pid,
                "processMetrics": idle_end_metrics,
                "processMetricsSamplerElapsedMS": idle_end_sampler_ms,
                "appMetrics": idle_end_app_metrics,
                "appMetricEvidence": idle_end_app_evidence,
                "appMetricsControlElapsedMS": idle_end_app_ms,
                "interval": idle_interval,
            }, flush=True)
            if idle_end_metric_violations:
                raise E2EError("idle app metrics changed unexpectedly: " + "; ".join(idle_end_metric_violations))
            app_metric_baseline = idle_end_app_counters
            write_json_atomic(root / "soak-metrics-baseline.json", {
                "schemaVersion": 1,
                "runID": args.run_id,
                "rootPath": str(root),
                "runtimePID": pid,
                "selectedBaselinePhase": "idle-app-only after the complete idle measurement interval",
                "selectedBaselineCounters": app_metric_baseline,
                "startEvidence": idle_start_app_evidence,
                "selectedBaselineEvidence": idle_end_app_evidence,
                "note": "Unavailable fields remain null and appear in unavailableMetrics; no missing counter is treated as zero",
            })
            previous_metrics = idle_end_metrics
            previous_wall_ns = idle_end_wall_ns
            metric_samples += 1
            write_status()
        next_work = time.monotonic() + args.work_interval
        next_sample = time.monotonic() + args.sample_interval

        while not stop_event.is_set() and covered_active_ns < target_active_ns:
            target_active_ns, stop_requested = process_soak_control_requests(
                root,
                args.run_id,
                target_active_ns,
            )
            if stop_requested:
                stop_event.set()
                break
            now = time.monotonic()
            if now >= next_work and not stop_event.is_set():
                sequence += 1
                token = f"mc5soak{args.run_id.replace('-', '')[:8]}{sequence:012d}"
                capture_parameters = soak_capture_parameters(sequence)
                format_name = capture_parameters["format"]
                item_count = capture_parameters["item_count"]
                repeat_primary_uti = capture_parameters["repeat_primary_uti"]
                file_byte_count = capture_parameters["file_byte_count"]
                base_text = f"mce5commonneedle {token} background synthetic mixed-load cycle {sequence} "
                text = base_text + ("x" * (128 + (sequence % 8) * 64))
                capture_and_verify_soak_record(
                    root,
                    args.run_id,
                    samples_path,
                    soak_ledger,
                    cycle=sequence,
                    token=token,
                    source_format=format_name,
                    text=text,
                    item_count=item_count,
                    repeat_primary_uti=repeat_primary_uti,
                    file_byte_count=file_byte_count,
                    task_name="named_board_production_capture",
                    socket_timeout=max(60, args.work_interval * 4),
                )
                work_cycles += 1

                if args.storage_delay_every > 0 and work_cycles % args.storage_delay_every == 0:
                    delay_token = f"mc5delay{args.run_id.replace('-', '')[:8]}{work_cycles:08d}"
                    delay_text = f"mce5commonneedle {delay_token} delayed storage sample"
                    database_path = root / "databases" / "clipboard.sqlite"
                    ready, lock_thread, errors = acquire_storage_write_lock(database_path, 0.25)
                    if ready.wait(timeout=10) and not errors:
                        delayed = capture_and_verify_soak_record(
                            root,
                            args.run_id,
                            samples_path,
                            soak_ledger,
                            cycle=work_cycles,
                            token=delay_token,
                            source_format="text",
                            text=delay_text,
                            item_count=1,
                            repeat_primary_uti=False,
                            file_byte_count=128,
                            task_name="controlled_storage_delay_capture",
                            socket_timeout=60,
                        )
                        lock_thread.join(timeout=10)
                        if lock_thread.is_alive() or errors:
                            raise E2EError("controlled storage-delay lock did not exit cleanly")
                        append_jsonl(samples_path, {
                            "schemaVersion": 1,
                            "recordType": "controlled-storage-delay",
                            "wallUTC": utc_now(),
                            "monotonicTimestampNS": monotonic_ns(),
                            "task": "sqlite_write_lock_contention",
                            "phase": "mixed-load",
                            "configuredDelayMS": 250,
                            "recordID": delayed["recordID"],
                            "captureControlSocketElapsedMS": delayed["captureControlSocketElapsedMS"],
                            "verifyResponse": delayed["verifyResponse"],
                            "searchResponse": delayed["searchResponse"],
                            "mechanism": "SQLite BEGIN IMMEDIATE on disposable clipboard database",
                        })
                    else:
                        raise E2EError("could not obtain isolated database write lock for controlled delay")
                write_status()
                next_work = time.monotonic() + args.work_interval

            now = time.monotonic()
            if now >= next_sample and not stop_event.is_set():
                app_metrics, app_metrics_ms = control_request(root, args.run_id, "metrics")
                app_metric_evidence, _, app_metric_violations = soak_app_metric_evidence(
                    app_metrics,
                    baseline_counters=app_metric_baseline,
                )
                sampler_started = monotonic_ns()
                process_metrics = collect_process_metrics(helper, pid, executable)
                process_sampler_ms = (monotonic_ns() - sampler_started) / 1_000_000
                wall = time.time_ns()
                monotonic_value = monotonic_ns()
                if not process_metrics.get("available"):
                    raise E2EError("soak process Mach clocks became unavailable; active coverage cannot be measured")
                wall_delta_ns = 0 if previous_wall_ns is None else wall - previous_wall_ns
                interval = resource_interval(
                    previous_metrics,
                    process_metrics,
                    wall_delta_ns,
                    int(args.sample_interval * 1_000_000_000),
                )
                covered_active_ns += int(interval.get("activeCoveredNS") or 0)
                if int(interval.get("suspectedSleepGapNS") or 0) > 1_000_000_000:
                    sleep_gap_count += 1
                sample = {
                    "schemaVersion": 1,
                    "recordType": "resource-metrics",
                    "wallUTC": utc_now(),
                    "wallTimestampNS": wall,
                    "monotonicTimestampNS": monotonic_value,
                    "task": "isolated_process_resource_sample",
                    "phase": "mixed-load",
                    "sampleSequence": metric_samples,
                    "runtimePID": pid,
                    "processMetrics": process_metrics,
                    "processMetricsSamplerElapsedMS": process_sampler_ms,
                    "appMetrics": app_metrics,
                    "appMetricEvidence": app_metric_evidence,
                    "appMetricsControlElapsedMS": app_metrics_ms,
                    "interval": interval,
                    "units": {
                        "monotonicTimestampNS": "nanoseconds from Python monotonic clock",
                        "cpuUserAndSystem": "cumulative Mach absolute-time ticks plus timebase-converted nanoseconds",
                        "residentSizeBytes": "bytes; RSS is separate from physical footprint",
                        "physicalFootprintBytes": "bytes",
                        "wakeups": "cumulative counts; interval rates use covered active seconds only",
                        "processBytesWritten": "cumulative process I/O bytes from rusage_info_v4; zero is marked unknown",
                        "walBytes": "current file size in bytes; absent WAL file is zero bytes",
                    },
                }
                append_jsonl(samples_path, sample, flush=True)
                if app_metric_violations:
                    raise E2EError("product metrics reported unexpected errors: " + "; ".join(app_metric_violations))
                metric_samples += 1
                previous_metrics = process_metrics
                previous_wall_ns = wall
                next_sample = time.monotonic() + args.sample_interval
                write_status()
            wait_seconds = max(0.0, min(next_work, next_sample) - time.monotonic())
            stop_event.wait(wait_seconds)

        state = "stopped" if stop_event.is_set() else "completed"
    except BaseException as error:
        state = "failed"
        last_error = f"{type(error).__name__}: {error}"
        append_jsonl(samples_path, {
            "schemaVersion": 1,
            "recordType": "runner-error",
            "wallUTC": utc_now(),
            "monotonicTimestampNS": monotonic_ns(),
            "errorType": type(error).__name__,
            "message": str(error),
        }, flush=True)
    finally:
        final_app_metric_evidence: dict[str, Any] | None = None
        final_app_metric_error: str | None = None
        final_app_metrics: dict[str, Any] | None = None
        final_app_metrics_ms: float | None = None
        if process is not None:
            final_metrics_wall_ns = time.time_ns()
            final_metrics_mono_ns = monotonic_ns()
            try:
                final_app_metrics, final_app_metrics_ms = control_request(
                    root,
                    args.run_id,
                    "metrics",
                    timeout=5,
                )
                final_app_metric_evidence, _, final_metric_violations = soak_app_metric_evidence(
                    final_app_metrics,
                    baseline_counters=app_metric_baseline,
                )
                append_jsonl(samples_path, {
                    "schemaVersion": 1,
                    "recordType": "resource-metrics",
                    "wallUTC": utc_now(),
                    "wallTimestampNS": final_metrics_wall_ns,
                    "monotonicTimestampNS": final_metrics_mono_ns,
                    "task": "final_pre_termination_product_metrics",
                    "phase": "final",
                    "runtimePID": pid,
                    "appMetrics": final_app_metrics,
                    "appMetricEvidence": final_app_metric_evidence,
                    "appMetricsControlElapsedMS": final_app_metrics_ms,
                    "baselineFile": str(root / "soak-metrics-baseline.json"),
                }, flush=True)
                if final_metric_violations:
                    state = "failed"
                    final_app_metric_error = "final product metrics reported unexpected errors: " + "; ".join(final_metric_violations)
                    last_error = last_error or final_app_metric_error
            except Exception as error:
                final_app_metric_error = f"{type(error).__name__}: {error}"
                append_jsonl(samples_path, {
                    "schemaVersion": 1,
                    "recordType": "resource-metrics",
                    "wallUTC": utc_now(),
                    "wallTimestampNS": final_metrics_wall_ns,
                    "monotonicTimestampNS": final_metrics_mono_ns,
                    "task": "final_pre_termination_product_metrics",
                    "phase": "final",
                    "runtimePID": pid,
                    "metricAvailability": "unavailable",
                    "metricsError": final_app_metric_error,
                    "rawMetricsResponse": final_app_metrics,
                    "appMetricsControlElapsedMS": final_app_metrics_ms,
                    "baselineFile": str(root / "soak-metrics-baseline.json"),
                    "note": "A failed metrics request is unavailable evidence, never a zero-valued metrics sample",
                }, flush=True)
                if state in {"completed", "stopped"}:
                    state = "failed"
                    last_error = last_error or f"final product metrics unavailable: {final_app_metric_error}"
        write_status()
        if process is not None:
            try:
                request_terminate(root, args.run_id, process)
                app_cleanup_completed[0] = True
            except E2EError as error:
                last_error = last_error or str(error)
                state = "failed"
        retained_control_state: dict[str, Any] = {}
        try:
            previous_status, _ = read_private_json(root / RUNNER_STATUS_NAME, "soak runner status")
            for key in ("acceptedExtensionRequestIDs", "lastExtensionRejection", "lastExtensionAcceptedAtUTC"):
                if key in previous_status:
                    retained_control_state[key] = previous_status[key]
        except E2EError:
            pass
        final_status = {
            "schemaVersion": 1,
            "state": state,
            "runID": args.run_id,
            "rootPath": str(root),
            "runnerPID": os.getpid(),
            "runtimePID": pid,
            "createdAtUTC": created_at,
            "completedAtUTC": utc_now(),
            "targetActiveSeconds": target_active_ns / 1_000_000_000,
            "coveredActiveSeconds": covered_active_ns / 1_000_000_000,
            "wallElapsedSeconds": (time.time_ns() - started_wall_ns) / 1_000_000_000,
            "workCycles": work_cycles,
            "metricSamples": metric_samples,
            "suspectedSleepGapCount": sleep_gap_count,
            "lastError": last_error,
            "sampleFile": str(samples_path),
            "retentionModel": soak_ledger.as_json(),
            "appMetricsBaselineFile": str(root / "soak-metrics-baseline.json"),
            "finalAppMetricEvidence": final_app_metric_evidence,
            "finalAppMetricError": final_app_metric_error,
            "acceptedExtensionRequestIDs": [],
            **retained_control_state,
        }
        write_json_atomic(root / RUNNER_STATUS_NAME, final_status)
    return 0 if state in {"completed", "stopped"} else 1


def consume_stop_request(root: Path, run_id: str) -> bool:
    request_path = root / SOAK_STOP_REQUEST_NAME
    try:
        info = request_path.lstat()
    except FileNotFoundError:
        return False
    owner, _ = validate_soak_worker_identity(root, run_id)
    value, read_info = read_private_json(request_path, "soak stop request")
    if (read_info.st_dev, read_info.st_ino) != (info.st_dev, info.st_ino):
        raise E2EError("soak stop request changed while it was read")
    if (
        type(value.get("schemaVersion")) is not int
        or value.get("schemaVersion") != 1
        or type(value.get("ownerUID")) is not int
        or value.get("ownerUID") != os.getuid()
        or not isinstance(value.get("runID"), str)
        or value.get("runID", "").lower() != run_id.lower()
        or not same_resolved_path(value.get("rootPath"), root)
        or type(value.get("runnerPID")) is not int
        or value.get("runnerPID") != owner["runnerPID"]
    ):
        raise E2EError("soak stop request owner mismatch")
    if not unlink_request_if_unchanged(request_path, info):
        raise E2EError("soak stop request changed before it could be retired")
    return True


def publish_soak_extension_request(root: Path, run_id: str, runner_pid: int, hours: int) -> dict[str, Any]:
    if type(hours) is not int or not 1 <= hours <= 48:
        raise E2EError("soak extension duration must be a positive integer from 1 to 48 hours")
    request_id = str(uuid.uuid4())
    request_lock = acquire_fixture_lock(root, SOAK_EXTEND_LOCK_NAME, blocking=True)
    try:
        try:
            write_json_exclusive(root / SOAK_EXTEND_REQUEST_NAME, {
                "schemaVersion": 1,
                "requestID": request_id,
                "ownerUID": os.getuid(),
                "runID": run_id,
                "rootPath": str(root),
                "runnerPID": runner_pid,
                "additionalActiveHours": hours,
                "requestedAtUTC": utc_now(),
            })
        except FileExistsError as error:
            raise E2EError("an extension request is already pending") from error
        except OSError as error:
            raise E2EError("could not create the private extension request") from error
    finally:
        fcntl.flock(request_lock, fcntl.LOCK_UN)
        os.close(request_lock)
    return {
        "requestID": request_id,
        "requestState": "pending-worker-validation",
        "requestedAdditionalActiveHours": hours,
        "root": str(root),
        "runnerPID": runner_pid,
        "message": "queued for root/run/owner, duration, and 72-hour-limit validation by the active worker",
    }


def extend_soak(args: argparse.Namespace) -> dict[str, Any]:
    root = validate_fixture_root(args.root, args.run_id)
    owner = read_runner_owner(root, args.run_id)
    pid = int(owner["runnerPID"])
    if not is_runner_process(pid, root, args.run_id):
        raise E2EError("soak worker PID does not match the recorded isolated runner")
    return publish_soak_extension_request(root, args.run_id, pid, args.hours)


def stop_soak(args: argparse.Namespace) -> dict[str, Any]:
    root = validate_fixture_root(args.root, args.run_id)
    owner = read_runner_owner(root, args.run_id)
    pid = int(owner["runnerPID"])
    if not fixture_lock_is_held(root, RUNNER_LOCK_NAME):
        status_path = root / RUNNER_STATUS_NAME
        state = json.loads(status_path.read_text()).get("state") if status_path.exists() else "unknown"
        return {"stopped": False, "state": state, "runnerPID": pid, "message": "recorded runner PID is no longer running"}
    request_path = root / SOAK_STOP_REQUEST_NAME
    write_json_atomic(request_path, {
        "schemaVersion": 1,
        "ownerUID": os.getuid(),
        "runID": args.run_id,
        "rootPath": str(root),
        "runnerPID": pid,
        "requestedAtUTC": utc_now(),
    })
    deadline = time.monotonic() + args.timeout
    status_path = root / RUNNER_STATUS_NAME
    while time.monotonic() < deadline:
        status = json.loads(status_path.read_text(encoding="utf-8")) if status_path.exists() else {}
        if status.get("state") in {"stopped", "completed", "failed"} and not fixture_lock_is_held(root, RUNNER_LOCK_NAME):
            return {"stopped": True, "state": status.get("state"), "runnerPID": pid, "root": str(root)}
        time.sleep(0.25)
    raise E2EError("soak runner did not stop within the requested timeout")


def status_soak(args: argparse.Namespace) -> dict[str, Any]:
    root = validate_fixture_root(args.root, args.run_id)
    owner = read_runner_owner(root, args.run_id)
    status_path = root / RUNNER_STATUS_NAME
    status = json.loads(status_path.read_text(encoding="utf-8")) if status_path.exists() else {"state": "starting"}
    status["runnerPIDMatchesOwner"] = is_runner_process(int(owner["runnerPID"]), root, args.run_id)
    status["root"] = str(root)
    return status


def clean_root(args: argparse.Namespace) -> dict[str, Any]:
    root = validate_fixture_root(args.root, args.run_id)
    owner_path = root / RUNNER_OWNER_NAME
    if owner_path.exists():
        owner = read_runner_owner(root, args.run_id)
        if fixture_lock_is_held(root, RUNNER_LOCK_NAME):
            raise E2EError(f"cannot clean an active soak root (recorded runner PID {owner['runnerPID']})")
    try:
        control_request(root, args.run_id, "ping", timeout=1)
        raise E2EError("cannot clean a root while its app is running")
    except E2EError as error:
        if "cannot clean" in str(error):
            raise
    lock_descriptors: list[int] = []
    try:
        for lock_name in (".macclippy-e2e-instance.lock", RUNNER_LOCK_NAME):
            lock_descriptors.append(acquire_fixture_lock(root, lock_name))
        quarantine = root.with_name(f".{root.name}.cleaning-{uuid.uuid4().hex}")
        os.rename(root, quarantine)
        try:
            marker = json.loads((quarantine / MARKER_NAME).read_text(encoding="utf-8"))
            if marker.get("runID", "").lower() != args.run_id.lower() or marker.get("ownerUID") != os.getuid():
                raise E2EError("moved fixture root marker changed before cleanup")
            for directory, child_directories, files in os.walk(quarantine, followlinks=False):
                for name in child_directories + files:
                    child = Path(directory) / name
                    if child.is_symlink():
                        raise E2EError("refusing to remove a fixture root containing a symlink")
            shutil.rmtree(quarantine)
        except Exception:
            if quarantine.exists() and not root.exists():
                os.rename(quarantine, root)
            raise
    finally:
        for descriptor in reversed(lock_descriptors):
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)
    return {"cleaned": True, "root": str(root), "evidenceDeleted": True}


def command_request(args: argparse.Namespace) -> dict[str, Any]:
    arguments = {
        "token": args.token,
        "text": args.text,
        "format": args.format,
        "query": args.query,
        "timeoutSeconds": args.timeout_seconds,
        "limit": args.limit,
        "cycles": args.cycles,
        "plain": args.plain,
        "payloadKind": args.payload_kind,
        "itemCount": args.item_count,
        "repeatPrimaryUTI": args.repeat_primary_uti,
        "fileByteCount": args.file_byte_count,
        "forcePoll": None if args.ingestion_mode is None else args.ingestion_mode == "forced-poll",
    }
    arguments = {key: value for key, value in arguments.items() if value is not None}
    response, elapsed_ms = control_request(
        args.root,
        args.run_id,
        args.control_command,
        timeout=args.socket_timeout,
        **arguments,
    )
    if args.control_command == "paste":
        require_targeted_recipient_paste(response)
    return {"controlSocketElapsedMS": elapsed_ms, "response": response}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare = subparsers.add_parser("prepare", help="create a fresh marked disposable root")
    prepare.set_defaults(handler=lambda args: {"root": str((root := create_fixture_root())[0]), "runID": root[1]})

    source_manifest = subparsers.add_parser("source-manifest", help="write a sorted source/build-input manifest and content digest")
    source_manifest.add_argument("--output", required=True, help="manifest output path outside the source tree")
    source_manifest.set_defaults(handler=command_source_manifest)

    start = subparsers.add_parser("start", help="launch the isolated E2E app and leave it running")
    start.add_argument("--app", required=True)
    start.add_argument("--root")
    start.add_argument("--run-id")
    start.set_defaults(handler=command_start)

    capture = subparsers.add_parser("capture", help="write synthetic content to the named test board and await indexed capture")
    capture.add_argument("--root", required=True)
    capture.add_argument("--run-id", required=True)
    capture.add_argument("--token", required=True)
    capture.add_argument("--format", choices=["text", "html", "rtf", "image", "files"], default="text")
    capture.add_argument("--text", required=True)
    capture.add_argument("--ingestion-mode", choices=["forced-poll", "natural-poll"], default="forced-poll")
    capture.add_argument("--item-count", type=int, default=1)
    capture.add_argument("--repeat-primary-uti", action="store_true")
    capture.add_argument("--file-byte-count", type=int, default=128)
    capture.set_defaults(handler=command_capture)

    request = subparsers.add_parser("request", help="send a synthetic-safe command to the isolated app control socket")
    request.add_argument("--root", required=True)
    request.add_argument("--run-id", required=True)
    request.add_argument(
        "--control-command",
        choices=[
            "ping", "metrics", "search-db", "verify-record", "search-ui", "panel-show",
            "panel-show-preserving-activation", "panel-hide",
            "preview-loop", "paste", "paste-injection-probe", "paste-begin-cancelable", "paste-barrier-status", "paste-cancel",
            "native-host-show", "native-host-hide", "recipient-reset", "terminate",
        ],
        required=True,
    )
    request.add_argument("--token")
    request.add_argument("--text")
    request.add_argument("--format", help="capture format name or stored representation UTI, depending on command")
    request.add_argument("--payload-kind", choices=["text", "html", "rtf", "image", "files"])
    request.add_argument("--item-count", type=int)
    request.add_argument("--repeat-primary-uti", action="store_true", default=None)
    request.add_argument("--file-byte-count", type=int)
    request.add_argument("--ingestion-mode", choices=["forced-poll", "natural-poll"])
    request.add_argument("--query")
    request.add_argument("--timeout-seconds", type=float)
    request.add_argument("--socket-timeout", type=float, default=120)
    request.add_argument("--limit", type=int)
    request.add_argument("--cycles", type=int)
    paste_mode = request.add_mutually_exclusive_group()
    paste_mode.add_argument("--plain", dest="plain", action="store_true")
    paste_mode.add_argument("--rich", dest="plain", action="store_false")
    request.set_defaults(plain=None, handler=command_request)

    corpus = subparsers.add_parser("corpus", help="build a reproducible 1k, 10k, or 100k production-ingested corpus")
    corpus.add_argument("--app", required=True)
    corpus.add_argument("--root")
    corpus.add_argument("--run-id")
    corpus.add_argument("--count", type=int, choices=CORPUS_SIZES, default=DEFAULT_PRODUCT_CORPUS)
    corpus.add_argument("--seed", type=int, default=DEFAULT_SEED)
    corpus.set_defaults(handler=command_corpus)

    restart = subparsers.add_parser("restart-check", help="verify persisted encrypted capture after app process restart")
    restart.add_argument("--app", required=True)
    restart.add_argument("--root")
    restart.add_argument("--run-id")
    restart.set_defaults(handler=command_restart)

    benchmark = subparsers.add_parser("benchmark", help="run the Release E2E benchmark in the foreground")
    benchmark.add_argument("--app", required=True)
    benchmark.add_argument("--root")
    benchmark.add_argument("--run-id")
    benchmark.add_argument("--count", type=int, choices=CORPUS_SIZES, default=DEFAULT_PRODUCT_CORPUS)
    benchmark.add_argument("--seed", type=int, default=DEFAULT_SEED)
    benchmark.add_argument("--iterations", type=int, default=30)
    benchmark.add_argument("--preview-cycles", type=int, default=10)
    benchmark.add_argument("--build-configuration", choices=["Release"], default="Release")
    benchmark.add_argument("--interactive", action="store_true", required=True, help="explicitly allow this run to activate the E2E app for visible UI measurement")
    benchmark.set_defaults(handler=command_benchmark)

    soak = subparsers.add_parser("soak", help="manage the durable background named-board soak runner")
    soak_commands = soak.add_subparsers(dest="soak_command", required=True)
    soak_start = soak_commands.add_parser("start", help="start a detached 24h or 72h active-coverage soak")
    soak_start.add_argument("--app", required=True)
    soak_start.add_argument("--hours", type=int, choices=SOAK_START_HOURS)
    soak_start.add_argument("--smoke-seconds", type=int, help="bounded runner validation run (30 to 1800 active seconds)")
    soak_start.add_argument("--sample-interval", type=int)
    soak_start.add_argument("--work-interval", type=int)
    soak_start.add_argument("--storage-delay-every", type=int, default=50)
    soak_start.add_argument("--build-configuration", choices=["Release"], default="Release")
    soak_start.set_defaults(handler=start_soak)

    for name in ("status", "stop", "extend", "clean"):
        item = soak_commands.add_parser(name)
        item.add_argument("--root", required=True)
        item.add_argument("--run-id", required=True)
        if name == "stop":
            item.add_argument("--timeout", type=int, default=30)
            item.set_defaults(handler=stop_soak)
        elif name == "extend":
            item.add_argument("--hours", type=int, choices=tuple(range(1, 49)), required=True)
            item.set_defaults(handler=extend_soak)
        elif name == "clean":
            item.set_defaults(handler=clean_root)
        else:
            item.set_defaults(handler=status_soak)

    worker = subparsers.add_parser("_soak-worker", help=argparse.SUPPRESS)
    worker.add_argument("--root", required=True)
    worker.add_argument("--run-id", required=True)
    worker.add_argument("--app", required=True)
    worker.add_argument("--hours", type=int, choices=SOAK_START_HOURS)
    worker.add_argument("--smoke-seconds", type=int)
    worker.add_argument("--sample-interval", type=int, required=True)
    worker.add_argument("--work-interval", type=int, required=True)
    worker.add_argument("--storage-delay-every", type=int, required=True)
    worker.add_argument("--retention-max-items", type=int, required=True)
    worker.add_argument("--build-configuration", choices=["Release"], required=True)
    worker.set_defaults(handler=soak_worker)

    control_worker = subparsers.add_parser("_soak-control-worker", help=argparse.SUPPRESS)
    control_worker.add_argument("--root", required=True)
    control_worker.add_argument("--run-id", required=True)
    control_worker.add_argument("--target-active-seconds", type=int, required=True)
    control_worker.add_argument("--simulated-step-seconds", type=int, default=1)
    control_worker.add_argument("--poll-interval", type=float, default=0.02)
    control_worker.add_argument("--max-polls", type=int, default=10_000)
    control_worker.set_defaults(handler=soak_control_worker)
    return parser


def soak_control_worker(args: argparse.Namespace) -> dict[str, Any]:
    """Run only the soak control protocol with simulated active time for bounded regression tests."""
    if args.target_active_seconds <= 0 or args.simulated_step_seconds <= 0:
        raise E2EError("control-worker simulated durations must be positive")
    if not 0 < args.poll_interval <= 1 or not 1 <= args.max_polls <= 100_000:
        raise E2EError("control-worker poll bounds are invalid")
    root = validate_fixture_root(args.root, args.run_id)
    runner_lock = acquire_fixture_lock(root, RUNNER_LOCK_NAME)
    target_active_ns = args.target_active_seconds * 1_000_000_000
    covered_active_seconds = 0
    state = "running"
    runner_pid = os.getpid()
    requested_policy = requested_retention_policy(fixture_retention_max_items(root))
    write_json_atomic(root / RUNNER_OWNER_NAME, {
        "schemaVersion": 1,
        "ownerUID": os.getuid(),
        "runID": args.run_id,
        "rootPath": str(root),
        "runnerPID": runner_pid,
        "runnerCommand": sys.argv,
        "startedAtUTC": utc_now(),
        "createdBy": RUNNER_ID,
        "retentionPolicyRequested": requested_policy,
        "retentionPolicyEffective": None,
    })
    write_json_atomic(root / RUNNER_STATUS_NAME, {
        "schemaVersion": 1,
        "state": state,
        "runID": args.run_id,
        "rootPath": str(root),
        "runnerPID": runner_pid,
        "targetActiveSeconds": args.target_active_seconds,
        "coveredActiveSeconds": covered_active_seconds,
        "acceptedExtensionRequestIDs": [],
        "controlLoopTestOnly": True,
        "simulatedActiveTime": True,
        "retentionPolicyRequested": requested_policy,
        "retentionPolicyEffective": None,
        "effectiveRetentionPolicyAvailability": "not-measured-control-flow-only",
    })

    def update_status() -> None:
        retained, _ = read_private_json(root / RUNNER_STATUS_NAME, "soak control worker status")
        status = {
            **retained,
            "state": state,
            "runID": args.run_id,
            "rootPath": str(root),
            "runnerPID": runner_pid,
            "targetActiveSeconds": target_active_ns // 1_000_000_000,
            "coveredActiveSeconds": covered_active_seconds,
            "controlLoopTestOnly": True,
            "simulatedActiveTime": True,
            "updatedAtUTC": utc_now(),
        }
        write_json_atomic(root / RUNNER_STATUS_NAME, status)

    append_jsonl(root / "soak-samples.jsonl", {
        "schemaVersion": 1,
        "recordType": "control-loop-test",
        "wallUTC": utc_now(),
        "monotonicTimestampNS": monotonic_ns(),
        "message": "bounded separate-process extension/stop control loop; simulated active time; not a 24h or 72h soak",
    }, flush=True)
    try:
        for _ in range(args.max_polls):
            target_active_ns, stop_requested = process_soak_control_requests(
                root,
                args.run_id,
                target_active_ns,
            )
            if stop_requested:
                state = "stopped"
                update_status()
                break
            covered_active_seconds += args.simulated_step_seconds
            update_status()
            if covered_active_seconds >= target_active_ns // 1_000_000_000:
                state = "completed"
                update_status()
                break
            time.sleep(args.poll_interval)
        else:
            state = "failed"
            status, _ = read_private_json(root / RUNNER_STATUS_NAME, "soak control worker status")
            status["lastError"] = "control worker exceeded its bounded poll count"
            write_json_atomic(root / RUNNER_STATUS_NAME, status)
    finally:
        fcntl.flock(runner_lock, fcntl.LOCK_UN)
        os.close(runner_lock)
    return {
        "state": state,
        "runID": args.run_id,
        "runnerPID": runner_pid,
        "coveredActiveSeconds": covered_active_seconds,
        "simulatedActiveTime": True,
        "controlLoopTestOnly": True,
        "soakAcceptance": False,
        "message": "bounded control-flow regression only; not a 24h or 72h soak",
    }


def command_start(args: argparse.Namespace) -> dict[str, Any]:
    created_root = args.root is None
    root, run_id = create_fixture_root() if created_root else (Path(args.root).resolve(strict=True), args.run_id or "")
    if not run_id:
        raise E2EError("--run-id is required with --root")
    response, process, owned, app, executable, info, effective_retention_policy = launch_app(
        args.app, root, run_id
    )
    if owned:
        ACTIVE_APP_PIDS.pop((str(root), run_id), None)
    return {
        "root": str(root),
        "runID": run_id,
        "pid": response.get("pid"),
        "appBundle": str(app),
        "executable": str(executable),
        "bundleIdentifier": info.get("CFBundleIdentifier"),
        "launchedByThisCommand": owned,
        "retentionPolicyRequested": requested_retention_policy(
            fixture_retention_max_items(root)
        ),
        "retentionPolicyEffective": effective_retention_policy,
        "message": "E2E app remains available through its root-scoped Unix socket",
    }


def command_source_manifest(args: argparse.Namespace) -> dict[str, Any]:
    output_path = Path(args.output).expanduser()
    if not output_path.is_absolute():
        raise E2EError("source manifest output path must be absolute")
    resolved_output = output_path.resolve(strict=False)
    try:
        resolved_output.relative_to(REPO_ROOT)
    except ValueError:
        pass
    else:
        raise E2EError("source manifest output path must be outside the source tree")
    manifest = build_source_manifest(REPO_ROOT, resolved_output)
    return {
        "manifestPath": str(resolved_output),
        "baseCommit": manifest["baseCommit"],
        "sourceContentSHA256": manifest["sourceContentSHA256"],
        "manifestFileSHA256": manifest["manifestFileSHA256"],
        "sourceFileCount": len(manifest["entries"]),
    }


def command_capture(args: argparse.Namespace) -> dict[str, Any]:
    response, elapsed_ms = control_request(
        args.root,
        args.run_id,
        "capture",
        timeout=60,
        token=args.token,
        format=args.format,
        text=args.text,
        payloadKind=args.format,
        itemCount=args.item_count,
        repeatPrimaryUTI=args.repeat_primary_uti,
        fileByteCount=args.file_byte_count,
        forcePoll=args.ingestion_mode == "forced-poll",
    )
    return {
        "elapsedMS": elapsed_ms,
        "ingestionMode": response.get("ingestionMode"),
        "sourceFormat": args.format,
        "observedPrimaryContentKind": response.get("primaryContentKind"),
        "capture": response,
    }


def command_corpus(args: argparse.Namespace) -> dict[str, Any]:
    created_root = args.root is None
    root, run_id = create_fixture_root() if created_root else (Path(args.root).resolve(strict=True), args.run_id or "")
    if not run_id:
        raise E2EError("--run-id is required with --root")
    _, process, owned, _, executable, _, effective_retention_policy = launch_app(
        args.app,
        root,
        run_id,
        retention_max_items=DEFAULT_E2E_RETENTION_MAX_ITEMS,
    )
    metadata: dict[str, Any] | None = None
    run_error: BaseException | None = None
    try:
        metadata = run_corpus(root, run_id, args.count, args.seed, root / "corpus-samples.jsonl")
    except BaseException as error:
        run_error = error
        progress: dict[str, Any] | None = None
        try:
            if (root / "corpus-progress.json").is_file():
                progress = json.loads((root / "corpus-progress.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            progress = None
        write_json_atomic(root / "corpus-failure.json", {
            "schemaVersion": 1,
            "state": "failed",
            "atUTC": utc_now(),
            "runID": run_id,
            "targetCount": args.count,
            "seed": args.seed,
            "errorType": type(error).__name__[:128],
            "detail": str(error)[:768],
            "progress": progress,
            "appPID": process,
            "ownedByThisCommand": owned,
        })
    cleanup_error: E2EError | None = None
    cleanup_evidence: dict[str, Any] = {"status": "not-owned-by-this-command", "signalSent": False}
    if owned:
        try:
            request_terminate(root, run_id, process)
            cleanup_evidence = {"status": "terminated-through-control-socket", "signalSent": False}
        except E2EError as error:
            try:
                cleanup_evidence = terminate_owned_corpus_app_after_control_failure(
                    root,
                    run_id,
                    int(process),
                    executable,
                )
                cleanup_evidence["controlFailure"] = str(error)[:512]
            except E2EError as fallback_error:
                cleanup_error = E2EError(
                    f"control cleanup failed: {str(error)[:384]}; "
                    f"identity-checked cleanup failed: {str(fallback_error)[:384]}"
                )
                cleanup_evidence = {
                    "status": "failed",
                    "signalSent": False,
                    "controlFailure": str(error)[:512],
                    "identityCheckFailure": str(fallback_error)[:512],
                }
        write_json_atomic(root / "corpus-cleanup.json", {
            "schemaVersion": 1,
            "atUTC": utc_now(),
            "runID": run_id,
            "appPID": process,
            "ownedByThisCommand": owned,
            "identityCheckedExecutable": str(executable) if owned else None,
            **cleanup_evidence,
        })
    if run_error is not None:
        if cleanup_error is not None:
            raise E2EError(
                f"{run_error}; owned-app cleanup also failed: {str(cleanup_error)[:512]}"
            ) from run_error
        raise run_error
    if cleanup_error is not None:
        raise cleanup_error
    if metadata is None:
        raise E2EError("corpus command ended without result metadata")
    return {
        "root": str(root),
        "runID": run_id,
        "retentionPolicyRequested": requested_retention_policy(DEFAULT_E2E_RETENTION_MAX_ITEMS),
        "retentionPolicyEffective": effective_retention_policy,
        "ownedAppTerminated": cleanup_evidence.get("status") in {
            "terminated-through-control-socket",
            "terminated-by-identity-checked-SIGTERM",
            "already-exited",
        },
        "corpus": metadata,
    }


def command_restart(args: argparse.Namespace) -> dict[str, Any]:
    return run_restart_check(args.app, args.root, args.run_id)


def command_benchmark(args: argparse.Namespace) -> dict[str, Any]:
    if not args.interactive:
        raise E2EError("visible UI benchmark requires --interactive explicit opt-in")
    return run_interactive_performance(
        args.app,
        args.root,
        args.run_id,
        args.count,
        args.seed,
        max(5, args.iterations),
        args.preview_cycles,
        args.build_configuration,
    )


def print_json(value: Any) -> None:
    sys.stdout.write(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True))
    sys.stdout.write("\n")


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        result = args.handler(args)
        print_json(result)
        return 0
    except E2EError as error:
        print_json({"ok": False, "error": str(error)})
        return 2
    except KeyboardInterrupt:
        return 130
    finally:
        for (root_value, run_id), pid in list(ACTIVE_APP_PIDS.items()):
            try:
                request_terminate(Path(root_value), run_id, pid)
            except E2EError:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
