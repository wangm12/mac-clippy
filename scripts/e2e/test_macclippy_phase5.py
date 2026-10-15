#!/usr/bin/env python3
"""Bounded disposable-root fault tests for the Phase 5 E2E driver."""

from __future__ import annotations

import importlib.util
import fcntl
import json
import os
import random
import shutil
import subprocess
import sys
import threading
import time
import uuid
import unittest
from collections import Counter
from pathlib import Path
from unittest import mock


DRIVER_PATH = Path(__file__).with_name("macclippy-phase5.py")
SPEC = importlib.util.spec_from_file_location("macclippy_phase5_driver", DRIVER_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load the Phase 5 E2E driver")
DRIVER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = DRIVER
SPEC.loader.exec_module(DRIVER)


class QueryContractTests(unittest.TestCase):
    def test_panel_request_can_preserve_the_host_activation_path(self) -> None:
        args = DRIVER.build_parser().parse_args([
            "request", "--root", "/tmp/owned-e2e-root", "--run-id", "owned-e2e-run",
            "--control-command", "panel-show-preserving-activation",
        ])
        with mock.patch.object(DRIVER, "control_request", return_value=({"ok": True}, 0.1)) as request:
            result = DRIVER.command_request(args)
        self.assertTrue(result["response"]["ok"])
        request.assert_called_once_with(
            "/tmp/owned-e2e-root", "owned-e2e-run", "panel-show-preserving-activation", timeout=120)

    def test_fixed_contracts_cover_structured_combined_and_tail_queries(self) -> None:
        type_counts = Counter({"text": 700, "html": 120, "rtf": 100, "image": 50, "files": 30})
        indexes = (7, 9, 10, 999, 9_999, 99_999)
        record_ids = {index: f"record-{index}" for index in indexes}

        contracts, tail_indexes = DRIVER.build_query_contracts(100_000, type_counts, record_ids)
        by_class = {contract.query_class: contract for contract in contracts}

        self.assertEqual(tail_indexes, [999, 9_999, 99_999])
        self.assertEqual(by_class["cjk-substring-tail"].expected_count, 3)
        self.assertEqual(by_class["ascii-infix"].expected_count, 4)
        self.assertEqual(by_class["ascii-prefix"].expected_count, 4)
        self.assertEqual(by_class["structured-only"].query, "type:image")
        self.assertEqual(by_class["combined-type-and-term"].query, "type:text mce5commonneedle")
        self.assertEqual(
            by_class["combined-app-and-term"].query,
            "app:com.macallyouneed.macclippy.e2e.synthetic mce5commonneedle",
        )
        self.assertEqual(by_class["common-hit"].expected_count, 512)

    def test_structured_contract_counts_use_observed_primary_kinds(self) -> None:
        primary_kinds = Counter({"text": 13, "html": 2, "image": 3})
        record_ids = {7: "rare-old", 9: "prefix", 10: "infix", 999: "tail"}

        contracts, _ = DRIVER.build_query_contracts(1_000, primary_kinds, record_ids)
        by_class = {contract.query_class: contract for contract in contracts}

        self.assertEqual(by_class["structured-text"].expected_count, 13)
        self.assertEqual(by_class["structured-only"].expected_count, 3)
        self.assertEqual(by_class["common-hit"].expected_count, 15)

    def test_primary_content_kind_is_reported_separately_from_source_format(self) -> None:
        self.assertEqual(DRIVER.require_primary_content_kind("text", 6), "text")
        with self.assertRaisesRegex(DRIVER.E2EError, "unsupported primary content kind"):
            DRIVER.require_primary_content_kind("unsupported", 6)

    def test_isolated_paste_requires_the_process_targeted_recipient(self) -> None:
        response = {
            "recipientPostRoute": "processTargeted",
            "actualOSAXInjectionPerformed": False,
            "contentInserted": True,
            "recipientInsertionCount": 1,
        }
        DRIVER.require_targeted_recipient_paste(response)
        with self.assertRaisesRegex(DRIVER.E2EError, "process-targeted poster"):
            DRIVER.require_targeted_recipient_paste({**response, "recipientPostRoute": "globalFallback"})

    def test_tail_contract_rejects_a_limit16_front_page_miss(self) -> None:
        contract = DRIVER.QueryContract(
            "ascii-infix",
            "asciiinfixneedle",
            4,
            4,
            ("tail-999", "tail-9999", "tail-99999", "fixed-10"),
        )
        result = {
            "hitCount": 4,
            "matchedRecordIDs": ["fixed-10", "recent-1", "recent-2", "recent-3"],
        }

        with self.assertRaisesRegex(DRIVER.E2EError, "required stable record IDs"):
            DRIVER.validate_query_result(result, contract, visible_ui=False)

    def test_corpus_fails_if_distinct_inputs_collapse_to_one_record(self) -> None:
        self.assertEqual(DRIVER.require_distinct_record_ids(["one", "two"], 2), 2)
        with self.assertRaisesRegex(DRIVER.E2EError, "deduplicated distinct corpus inputs"):
            DRIVER.require_distinct_record_ids(["same", "same"], 2)

    def test_fixed_corpus_prefix_has_real_image_and_file_primary_kinds(self) -> None:
        seed = 20260925
        rng = random.Random(seed)
        generated = [DRIVER.make_capture_payload(index, seed, rng) for index in range(258)]

        self.assertEqual(generated[12][1], "image")
        self.assertEqual(generated[13][1], "files")
        self.assertGreater(generated[13][7], 0)
        self.assertEqual(generated[4][2], "bounded-long-text-65536")
        self.assertTrue(generated[4][3].endswith("L" * 65_536))
        self.assertEqual(generated[4][4], len(generated[4][3].encode("utf-8")))
        self.assertTrue(generated[37][6])
        self.assertEqual(generated[37][5], 2)
        self.assertEqual(generated[257][5], 2)

    def test_preview_timeout_scales_with_requested_work_and_is_clamped(self) -> None:
        self.assertEqual(DRIVER.normalized_preview_cycles(10), 10)
        self.assertEqual(DRIVER.preview_loop_timeout_seconds(10), DRIVER.PREVIEW_LOOP_MIN_TIMEOUT_SECONDS)
        self.assertEqual(DRIVER.normalized_preview_cycles(1_000), 1_000)
        self.assertEqual(DRIVER.preview_loop_timeout_seconds(1_000), 695)
        self.assertEqual(DRIVER.preview_loop_request_options(1_000), {"timeout": 695, "cycles": 1_000})
        self.assertEqual(DRIVER.normalized_preview_cycles(2_000), 1_000)
        self.assertEqual(DRIVER.preview_loop_timeout_seconds(2_000), 695)
        with self.assertRaisesRegex(DRIVER.E2EError, "integer"):
            DRIVER.preview_loop_timeout_seconds(1.5)

    def test_preview_response_must_account_for_every_requested_cycle(self) -> None:
        response = {"recordCount": 1_000, "previewContentReady": True, "previewVisible": False}
        DRIVER.validate_preview_loop_response(response, 1_000)
        with self.assertRaisesRegex(DRIVER.E2EError, "completed"):
            DRIVER.validate_preview_loop_response({**response, "recordCount": 999}, 1_000)
        with self.assertRaisesRegex(DRIVER.E2EError, "ready content"):
            DRIVER.validate_preview_loop_response({**response, "previewContentReady": False}, 1_000)

    def test_soak_rotates_through_real_capture_formats_and_multi_item_fixtures(self) -> None:
        parameters = [DRIVER.soak_capture_parameters(index) for index in range(1, 21)]
        self.assertEqual({entry["format"] for entry in parameters}, {"text", "html", "rtf", "image", "files"})
        self.assertTrue(any(entry["format"] == "image" for entry in parameters))
        self.assertTrue(any(entry["format"] == "files" for entry in parameters))
        self.assertTrue(any(entry["item_count"] > 1 for entry in parameters))
        self.assertTrue(any(entry["repeat_primary_uti"] for entry in parameters))

    def test_soak_search_checks_exact_count_and_required_stable_id(self) -> None:
        DRIVER.validate_soak_search_result(
            {"hitCount": 2, "matchedRecordIDs": ["fresh-id", "older-id"]},
            query="type:image",
            expected_count=2,
            required_record_id="fresh-id",
        )
        with self.assertRaisesRegex(DRIVER.E2EError, "expected exactly"):
            DRIVER.validate_soak_search_result(
                {"hitCount": 1, "matchedRecordIDs": ["fresh-id"]},
                query="type:image",
                expected_count=2,
                required_record_id="fresh-id",
            )

    def test_soak_retention_model_accounts_for_eviction_and_search_limit(self) -> None:
        ledger = DRIVER.SoakRetentionLedger(max_items=3)
        ledger.add("text-1", "text")
        ledger.add("image-1", "image")
        ledger.add("text-2", "text")
        self.assertEqual(ledger.expected_search_count("text"), 2)
        ledger.add("file-1", "files")
        self.assertEqual(ledger.expected_search_count("text"), 1)
        self.assertEqual(ledger.expected_search_count("image"), 1)
        self.assertEqual(ledger.as_json()["retainedRecordCount"], 3)
        limited = DRIVER.SoakRetentionLedger(max_items=600)
        for index in range(513):
            limited.add(f"image-{index}", "image")
        self.assertEqual(limited.expected_search_count("image"), 512)

        payload_digest = "c" * 64
        byte_ledger = DRIVER.SoakRetentionLedger(max_items=1, max_history_bytes=100, max_image_bytes=80)
        byte_ledger.add("image-raw", "image", [
            {"uti": "public.png", "byteCount": 64, "sha256": payload_digest},
            {"uti": "public.utf8-plain-text", "byteCount": 12, "sha256": payload_digest},
        ], primary_uti="public.png")
        byte_ledger.add("text-next", "text", [
            {"uti": "public.utf8-plain-text", "byteCount": 21, "sha256": payload_digest},
            {"uti": "public.data", "byteCount": None, "sha256": None},
        ])
        snapshot = byte_ledger.as_json()
        self.assertEqual(snapshot["maxHistoryBytes"], 100)
        self.assertEqual(snapshot["maxImageBytes"], 80)
        self.assertEqual(snapshot["retainedAuthenticatedRawRepresentationBytesLowerBound"], 21)
        self.assertEqual(snapshot["retainedPrimaryImagePayloadBytesLowerBound"], 0)
        self.assertEqual(snapshot["retainedUnknownRepresentationProofCount"], 1)

    def test_ordered_raw_representation_proofs_cover_repeated_uti_and_decoded_text(self) -> None:
        payload_digest = "a" * 64
        proof = lambda index: {
            "itemIndex": index,
            "uti": "public.utf8-plain-text",
            "payloadState": "spilled" if index == 0 else "present",
            "byteCount": 42,
            "sha256": payload_digest,
        }
        capture = {
            "recordID": "stable-record-id",
            "primaryContentKind": "text",
            "rawPayloadUTI": "public.utf8-plain-text",
            "rawPayloadByteCount": 42,
            "rawPayloadSHA256": payload_digest,
            "rawPayloadRoundTrip": True,
            "token": "soak-token-1",
        }
        verify = {
            "recordID": "stable-record-id",
            "primaryContentKind": "text",
            "decodedText": "captured soak-token-1 text",
            "rawPayloadUTI": "public.utf8-plain-text",
            "rawPayloadByteCount": 42,
            "rawPayloadSHA256": payload_digest,
            "rawPayloadRoundTrip": True,
            "representations": [proof(0), proof(1)],
        }
        result = DRIVER.validate_soak_verify_record(verify, capture, repeated_uti=True)
        self.assertEqual([entry["itemIndex"] for entry in result["representations"]], [0, 1])
        self.assertEqual(result["decodedText"], verify["decodedText"])

        with self.assertRaisesRegex(DRIVER.E2EError, "ordered"):
            DRIVER.validate_soak_verify_record(
                {**verify, "representations": [proof(1), proof(0)]},
                capture,
                repeated_uti=True,
            )
        with self.assertRaisesRegex(DRIVER.E2EError, "repeated primary UTI"):
            DRIVER.validate_soak_verify_record(
                {**verify, "representations": [proof(0)]},
                capture,
                repeated_uti=True,
            )
        with self.assertRaisesRegex(DRIVER.E2EError, "distinct pasteboard items"):
            DRIVER.validate_soak_verify_record(
                {**verify, "representations": [proof(0), proof(0)]},
                capture,
                repeated_uti=True,
            )

    def test_soak_capture_keeps_source_format_distinct_from_observed_primary_kind(self) -> None:
        payload_digest = "d" * 64
        raw_uti = "public.rtf"
        capture_response = {
            "recordID": "stable-rtf-record",
            "recordCount": 1,
            "primaryContentKind": "text",
            "capturedItemCount": 2,
            "sourceAppBundleIdentifier": "com.macallyouneed.macclippy.e2e.synthetic",
            "rawPayloadUTI": raw_uti,
            "rawPayloadByteCount": 42,
            "rawPayloadSHA256": payload_digest,
            "rawPayloadRoundTrip": True,
            "representations": [
                {"itemIndex": 0, "uti": raw_uti, "payloadState": "spilled", "byteCount": 42, "sha256": payload_digest},
                {"itemIndex": 1, "uti": raw_uti, "payloadState": "present", "byteCount": 42, "sha256": payload_digest},
            ],
        }
        evidence = DRIVER.require_soak_capture_evidence(
            capture_response,
            token="rtf-source-token",
            source_format="rtf",
            item_count=2,
            repeat_primary_uti=True,
            file_byte_count=128,
        )
        self.assertEqual(evidence["sourceFormat"], "rtf")
        self.assertEqual(evidence["primaryContentKind"], "text")
        self.assertEqual([proof["itemIndex"] for proof in evidence["representations"]], [0, 1])

    def test_non_text_verify_record_keeps_decoded_text_unavailable(self) -> None:
        digest = "b" * 64
        capture = {
            "recordID": "image-record",
            "primaryContentKind": "image",
            "rawPayloadUTI": "public.png",
            "rawPayloadByteCount": 9,
            "rawPayloadSHA256": digest,
            "rawPayloadRoundTrip": True,
            "token": "image-token",
        }
        verify = {
            "recordID": "image-record",
            "primaryContentKind": "image",
            "decodedText": None,
            "rawPayloadUTI": "public.png",
            "rawPayloadByteCount": 9,
            "rawPayloadSHA256": digest,
            "rawPayloadRoundTrip": True,
            "representations": [{
                "itemIndex": 0,
                "uti": "public.png",
                "payloadState": "present",
                "byteCount": 9,
                "sha256": digest,
            }],
        }
        self.assertIsNone(DRIVER.validate_soak_verify_record(verify, capture, repeated_uti=False)["decodedText"])
        with self.assertRaisesRegex(DRIVER.E2EError, "non-text"):
            DRIVER.validate_soak_verify_record({**verify, "decodedText": "OCR must not be assumed"}, capture, repeated_uti=False)

    def test_long_restart_fixture_remains_exact_65536_bytes_and_spilled_across_restart(self) -> None:
        token = "restart-long-token"
        payload = token.encode("utf-8") + b"x" * (DRIVER.LONG_RESTART_TEXT_BYTES - len(token))
        digest = DRIVER.hashlib.sha256(payload).hexdigest()
        raw_uti = "public.utf8-plain-text"
        representation = {
            "itemIndex": 0,
            "uti": raw_uti,
            "payloadState": "spilled",
            "byteCount": len(payload),
            "sha256": digest,
        }
        captured = {
            "recordID": "restart-record-id",
            "recordCount": 1,
            "primaryContentKind": "text",
            "sourceAppBundleIdentifier": "com.macallyouneed.macclippy.e2e.synthetic",
            "rawPayloadUTI": raw_uti,
            "rawPayloadByteCount": len(payload),
            "rawPayloadSHA256": digest,
            "rawPayloadRoundTrip": True,
            "spilledRepresentationCount": 1,
            "representations": [representation],
        }
        verified = {
            **captured,
            "decodedText": payload.decode("utf-8"),
        }
        evidence = DRIVER.validate_long_text_restart_evidence(
            captured,
            verified,
            token=token,
            expected_byte_count=DRIVER.LONG_RESTART_TEXT_BYTES,
        )
        self.assertTrue(evidence["recordIDVerified"])
        self.assertTrue(evidence["spilledRepresentationRoundTrip"])
        self.assertEqual(captured["rawPayloadByteCount"], 65_536)
        with self.assertRaisesRegex(DRIVER.E2EError, "exactly 65,536"):
            DRIVER.validate_long_text_restart_evidence(
                {**captured, "rawPayloadByteCount": 65_535},
                verified,
                token=token,
                expected_byte_count=DRIVER.LONG_RESTART_TEXT_BYTES,
            )
        with self.assertRaisesRegex(DRIVER.E2EError, "after process restart"):
            DRIVER.validate_long_text_restart_evidence(
                captured,
                {**verified, "representations": [{**representation, "payloadState": "present"}]},
                token=token,
                expected_byte_count=DRIVER.LONG_RESTART_TEXT_BYTES,
            )

    def test_metrics_preserve_unavailable_as_null_and_fail_on_error_deltas(self) -> None:
        baseline_response = {"ok": True, "unavailableMetrics": ["maintenanceQueueDepth"]}
        for field in DRIVER.SOAK_METRIC_FIELDS:
            baseline_response[field] = False if field == "captureQueueHasUnrecoveredChanges" else 0
        baseline_response["maintenanceQueueDepth"] = None
        baseline, baseline_counters, violations = DRIVER.soak_app_metric_evidence(
            baseline_response,
            baseline_counters=None,
        )
        self.assertEqual(violations, [])
        self.assertEqual(baseline["values"]["captureNotSavedCount"], 0)
        self.assertIsNone(baseline["values"]["maintenanceQueueDepth"])
        self.assertIn("maintenanceQueueDepth", baseline["unavailableMetrics"])

        later_response = {**baseline_response, "captureNotSavedCount": 1}
        later, _, violations = DRIVER.soak_app_metric_evidence(
            later_response,
            baseline_counters=baseline_counters,
        )
        self.assertEqual(later["counterDeltas"]["captureNotSavedCount"], 1)
        self.assertIn("captureNotSavedCount increased by 1", violations)

        missing_counter = {**baseline_response}
        del missing_counter["capturePersistFailureCount"]
        missing, _, _ = DRIVER.soak_app_metric_evidence(
            missing_counter,
            baseline_counters=baseline_counters,
        )
        self.assertIsNone(missing["values"]["capturePersistFailureCount"])
        self.assertIn("capturePersistFailureCount", missing["unavailableMetrics"])
        with self.assertRaisesRegex(DRIVER.E2EError, "required stable record ID"):
            DRIVER.validate_soak_search_result(
                {"hitCount": 2, "matchedRecordIDs": ["older-id", "other-id"]},
                query="type:image",
                expected_count=2,
                required_record_id="fresh-id",
            )


class RetentionLaunchPolicyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root, self.run_id = DRIVER.create_fixture_root(DRIVER.SOAK_MAX_RETAINED_ITEMS)

    def tearDown(self) -> None:
        DRIVER.ACTIVE_APP_PIDS.pop((str(self.root), self.run_id), None)
        if self.root.exists():
            shutil.rmtree(self.root)

    def test_default_corpus_and_soak_limits_override_ambient_environment(self) -> None:
        inherited = {"PATH": "/usr/bin", DRIVER.E2E_RETENTION_ENV_NAME: "17"}
        corpus_environment = DRIVER.retention_launch_environment(
            DRIVER.DEFAULT_E2E_RETENTION_MAX_ITEMS,
            inherited,
        )
        soak_environment = DRIVER.retention_launch_environment(
            DRIVER.SOAK_MAX_RETAINED_ITEMS,
            inherited,
        )

        self.assertEqual(corpus_environment[DRIVER.E2E_RETENTION_ENV_NAME], "200000")
        self.assertEqual(soak_environment[DRIVER.E2E_RETENTION_ENV_NAME], "10000")
        self.assertEqual(DRIVER.fixture_retention_max_items(self.root), 10_000)
        default_root, default_run_id = DRIVER.create_fixture_root()
        try:
            self.assertEqual(DRIVER.fixture_retention_max_items(default_root), 200_000)
            self.assertEqual(
                json.loads((default_root / DRIVER.MARKER_NAME).read_text())["retentionPolicyRequested"],
                DRIVER.requested_retention_policy(200_000),
            )
        finally:
            shutil.rmtree(default_root)

    def start_mock_soak(self, effective_policy: dict[str, int]):
        class FakeWorker:
            pid = 23001
            terminated = False

            def poll(self):
                return None

            def terminate(self):
                self.terminated = True

            def wait(self, timeout: float):
                return 0

        worker = FakeWorker()
        self.mock_soak_worker = worker
        command_seen: list[str] = []
        requested_policy = DRIVER.requested_retention_policy(DRIVER.SOAK_MAX_RETAINED_ITEMS)

        def start_worker(command: list[str], **_kwargs: object):
            command_seen.extend(command)
            DRIVER.write_json_atomic(self.root / DRIVER.RUNNER_STATUS_NAME, {
                "state": "running",
                "retentionPolicyRequested": requested_policy,
                "retentionPolicyEffective": effective_policy,
            })
            return worker

        args = type("Args", (), {
            "app": str(DRIVER.REPO_ROOT),
            "hours": 24,
            "smoke_seconds": None,
            "sample_interval": 60,
            "work_interval": 15,
            "storage_delay_every": 50,
            "build_configuration": "Release",
        })()
        with mock.patch.object(DRIVER, "require_release_e2e_app"), \
                mock.patch.object(DRIVER, "create_fixture_root", return_value=(self.root, self.run_id)), \
                mock.patch.object(DRIVER.subprocess, "Popen", side_effect=start_worker):
            result = DRIVER.start_soak(args)
        return result, command_seen, worker

    def test_soak_coordinator_pins_10k_and_records_verified_effective_status(self) -> None:
        policy = DRIVER.requested_retention_policy(DRIVER.SOAK_MAX_RETAINED_ITEMS)
        result, command, worker = self.start_mock_soak(policy)

        retention_argument = command.index("--retention-max-items")
        self.assertEqual(command[retention_argument + 1], "10000")
        self.assertEqual(result["retentionPolicyRequested"], policy)
        self.assertEqual(result["retentionPolicyEffective"], policy)
        owner = json.loads((self.root / DRIVER.RUNNER_OWNER_NAME).read_text())
        self.assertEqual(owner["retentionPolicyRequested"], policy)
        self.assertEqual(owner["retentionPolicyEffective"], policy)
        self.assertFalse(worker.terminated)

    def test_soak_coordinator_rejects_wrong_effective_policy_before_start_returns(self) -> None:
        wrong_policy = DRIVER.requested_retention_policy(
            DRIVER.DEFAULT_E2E_RETENTION_MAX_ITEMS
        )
        with self.assertRaisesRegex(DRIVER.E2EError, "effective retention policy mismatch before workload"):
            self.start_mock_soak(wrong_policy)
        self.assertTrue(self.mock_soak_worker.terminated)

    def test_launch_passes_persisted_limit_and_reuses_it_after_same_root_restart(self) -> None:
        app = Path("/tmp/fake-MacClippyE2E.app")
        executable = app / "Contents/MacOS/MacClippyE2E"
        info = {
            "CFBundleIdentifier": DRIVER.EXPECTED_BUNDLE_ID,
            "MacClippyE2ESourceContentSHA256": "source-digest",
        }
        manifest = {
            "sourceContentSHA256": "source-digest",
            "manifestFileSHA256": "manifest-digest",
            "entries": [],
        }
        policy = DRIVER.requested_retention_policy(DRIVER.SOAK_MAX_RETAINED_ITEMS)
        launch_results = [
            subprocess.CompletedProcess([], 0, json.dumps({"pid": 21001, "bundleIdentifier": DRIVER.EXPECTED_BUNDLE_ID}), ""),
            subprocess.CompletedProcess([], 0, json.dumps({"pid": 21002, "bundleIdentifier": DRIVER.EXPECTED_BUNDLE_ID}), ""),
        ]
        ready_responses = [
            {"ready": True, "pid": 21001},
            {"ready": True, "pid": 21002},
        ]

        def control_response(_root: Path, _run_id: str, command: str, **_kwargs: object):
            if command == "ping":
                raise DRIVER.E2EError("no active app in this offline fixture")
            if command == "metrics":
                return ({**policy, "unavailableMetrics": []}, 0.1)
            raise AssertionError(f"unexpected control request before workload: {command}")

        with mock.patch.object(DRIVER, "app_paths", return_value=(app, executable, info)), \
                mock.patch.object(DRIVER, "build_source_manifest", return_value=manifest), \
                mock.patch.object(DRIVER, "require_built_source_digest"), \
                mock.patch.object(DRIVER, "verify_running_app_identity"), \
                mock.patch.object(DRIVER, "wait_for_app", side_effect=ready_responses), \
                mock.patch.object(DRIVER, "control_request", side_effect=control_response), \
                mock.patch.object(DRIVER.subprocess, "run", side_effect=launch_results) as launch, \
                mock.patch.dict(DRIVER.os.environ, {DRIVER.E2E_RETENTION_ENV_NAME: "200000"}):
            first = DRIVER.launch_app(app, self.root, self.run_id)
            DRIVER.os.environ[DRIVER.E2E_RETENTION_ENV_NAME] = "41"
            second = DRIVER.launch_app(app, self.root, self.run_id)

        requested_values = [
            call.kwargs["env"][DRIVER.E2E_RETENTION_ENV_NAME]
            for call in launch.call_args_list
        ]
        self.assertEqual(requested_values, ["10000", "10000"])
        self.assertEqual(first[6], policy)
        self.assertEqual(second[6], policy)
        process_manifest = json.loads((self.root / ".macclippy-e2e-app-process.json").read_text())
        self.assertEqual(process_manifest["requestedRetentionPolicy"], policy)
        self.assertEqual(process_manifest["effectiveRetentionPolicy"], policy)

    def test_existing_wrong_limit_is_rejected_before_any_capture_or_relaunch(self) -> None:
        app = Path("/tmp/fake-MacClippyE2E.app")
        executable = app / "Contents/MacOS/MacClippyE2E"
        info = {
            "CFBundleIdentifier": DRIVER.EXPECTED_BUNDLE_ID,
            "MacClippyE2ESourceContentSHA256": "source-digest",
        }
        manifest = {"sourceContentSHA256": "source-digest", "entries": []}
        observed_policy = DRIVER.requested_retention_policy(
            DRIVER.DEFAULT_E2E_RETENTION_MAX_ITEMS
        )
        commands: list[str] = []

        def control_response(_root: Path, _run_id: str, command: str, **_kwargs: object):
            commands.append(command)
            if command == "ping":
                return ({"ready": True, "pid": 22001}, 0.1)
            if command == "metrics":
                return ({**observed_policy, "unavailableMetrics": []}, 0.1)
            raise AssertionError(f"workload request {command} ran before policy rejection")

        with mock.patch.object(DRIVER, "app_paths", return_value=(app, executable, info)), \
                mock.patch.object(DRIVER, "build_source_manifest", return_value=manifest), \
                mock.patch.object(DRIVER, "require_built_source_digest"), \
                mock.patch.object(DRIVER, "verify_running_app_identity"), \
                mock.patch.object(DRIVER, "control_request", side_effect=control_response), \
                mock.patch.object(DRIVER.subprocess, "run") as launch:
            with self.assertRaisesRegex(DRIVER.E2EError, "effective retention policy mismatch before workload"):
                DRIVER.launch_app(
                    app,
                    self.root,
                    self.run_id,
                    retention_max_items=DRIVER.SOAK_MAX_RETAINED_ITEMS,
                )

        self.assertEqual(commands, ["ping", "metrics"])
        launch.assert_not_called()

    def test_actual_byte_caps_drive_model_and_unavailable_or_mismatched_values_fail(self) -> None:
        metrics = {
            **DRIVER.requested_retention_policy(DRIVER.SOAK_MAX_RETAINED_ITEMS),
            "unavailableMetrics": [],
        }
        effective = DRIVER.require_effective_retention_policy(
            metrics,
            DRIVER.SOAK_MAX_RETAINED_ITEMS,
            context="offline soak fixture",
        )
        model = DRIVER.soak_retention_model(effective)
        ledger = DRIVER.SoakRetentionLedger(
            max_items=effective["retentionMaxItems"],
            max_history_bytes=effective["retentionMaxTotalBytes"],
            max_image_bytes=effective["retentionMaxImageBytes"],
        )
        ledger_json = ledger.as_json()

        self.assertEqual(model["maxItems"], 10_000)
        self.assertEqual(model["maxImageBytes"], metrics["retentionMaxImageBytes"])
        self.assertEqual(model["maxTotalBytes"], metrics["retentionMaxTotalBytes"])
        self.assertEqual(model["policyTelemetry"], effective)
        self.assertEqual(ledger_json["maxRetainedItems"], model["maxItems"])
        self.assertEqual(ledger_json["maxImageBytes"], model["maxImageBytes"])
        self.assertEqual(ledger_json["maxHistoryBytes"], model["maxTotalBytes"])
        self.assertEqual(ledger_json["searchResultLimit"], 512)

        unavailable = {**metrics, "retentionMaxImageBytes": None, "unavailableMetrics": ["retentionMaxImageBytes"]}
        with self.assertRaisesRegex(DRIVER.E2EError, "metrics unavailable"):
            DRIVER.require_effective_retention_policy(
                unavailable,
                DRIVER.SOAK_MAX_RETAINED_ITEMS,
                context="offline soak fixture",
            )
        wrong_caps = {**metrics, "retentionMaxTotalBytes": metrics["retentionMaxTotalBytes"] // 2}
        with self.assertRaisesRegex(DRIVER.E2EError, "effective retention policy mismatch"):
            DRIVER.require_effective_retention_policy(
                wrong_caps,
                DRIVER.SOAK_MAX_RETAINED_ITEMS,
                context="offline soak fixture",
            )


class RunnerLifecycleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root, self.run_id = DRIVER.create_fixture_root()

    def tearDown(self) -> None:
        if self.root.exists():
            marker = self.root / DRIVER.MARKER_NAME
            if marker.exists():
                lock = DRIVER.acquire_fixture_lock(self.root, ".test-cleanup.lock")
                try:
                    shutil.rmtree(self.root)
                finally:
                    fcntl.flock(lock, fcntl.LOCK_UN)
                    os.close(lock)

    def test_path_identity_accepts_a_canonical_alias_only_for_the_same_directory(self) -> None:
        alias = self.root.parent / f"mce5-alias-{self.run_id}"
        os.symlink(self.root, alias)
        try:
            self.assertTrue(DRIVER.same_resolved_path(str(alias), self.root))
            self.assertFalse(DRIVER.same_resolved_path(str(self.root.parent), self.root))
        finally:
            alias.unlink()

    def test_terminate_fails_closed_without_control_identity(self) -> None:
        with mock.patch.object(DRIVER, "control_request", side_effect=DRIVER.E2EError("socket unavailable")):
            with mock.patch.object(DRIVER.os, "kill") as process_signal:
                with self.assertRaisesRegex(DRIVER.E2EError, "no process was signaled"):
                    DRIVER.request_terminate(self.root, self.run_id, 12345)

        process_signal.assert_not_called()

    def test_terminate_rejects_a_different_root_identity_before_requesting_exit(self) -> None:
        with mock.patch.object(
            DRIVER,
            "control_request",
            return_value=({"rootPath": "/different-run", "runID": self.run_id, "pid": 12345}, 1.0),
        ) as control:
            with mock.patch.object(DRIVER.os, "kill") as process_signal:
                with self.assertRaisesRegex(DRIVER.E2EError, "does not match the owned root/run"):
                    DRIVER.request_terminate(self.root, self.run_id, 12345)

        process_signal.assert_not_called()
        control.assert_called_once_with(self.root, self.run_id, "ping", timeout=5)

    def test_clean_refuses_a_live_worker_lock_and_keeps_the_fixture(self) -> None:
        owner = {
            "schemaVersion": 1,
            "ownerUID": DRIVER.os.getuid(),
            "runID": self.run_id,
            "rootPath": str(self.root),
            "runnerPID": 12345,
            "runnerCommand": ["disposable-test-worker"],
            "createdBy": DRIVER.RUNNER_ID,
        }
        DRIVER.write_json_atomic(self.root / DRIVER.RUNNER_OWNER_NAME, owner)
        lock = DRIVER.acquire_fixture_lock(self.root, DRIVER.RUNNER_LOCK_NAME)
        args = type("Args", (), {"root": str(self.root), "run_id": self.run_id})()
        try:
            with self.assertRaisesRegex(DRIVER.E2EError, "active soak root"):
                DRIVER.clean_root(args)
            self.assertTrue(self.root.exists())
            self.assertTrue((self.root / DRIVER.MARKER_NAME).is_file())
        finally:
            DRIVER.fcntl.flock(lock, DRIVER.fcntl.LOCK_UN)
            DRIVER.os.close(lock)


class SoakExtensionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root, self.run_id = DRIVER.create_fixture_root()
        self.control_process: subprocess.Popen[str] | None = None
        self.control_worker_log: Path | None = None
        self.control_worker_log_handle: Any = None
        self.install_worker_identity(target_seconds=3_600)

    def tearDown(self) -> None:
        if self.control_process is not None and self.control_process.poll() is None:
            try:
                DRIVER.stop_soak(type("Args", (), {
                    "root": str(self.root),
                    "run_id": self.run_id,
                    "timeout": 3,
                })())
            except DRIVER.E2EError:
                self.control_process.terminate()
                self.control_process.wait(timeout=3)
        if self.control_worker_log_handle is not None:
            self.control_worker_log_handle.close()
            self.control_worker_log_handle = None
        if self.root.exists() and (self.root / DRIVER.MARKER_NAME).is_file():
            shutil.rmtree(self.root)

    def install_worker_identity(self, *, target_seconds: int, runner_pid: int | None = None) -> int:
        pid = os.getpid() if runner_pid is None else runner_pid
        DRIVER.write_json_atomic(self.root / DRIVER.RUNNER_OWNER_NAME, {
            "schemaVersion": 1,
            "ownerUID": os.getuid(),
            "runID": self.run_id,
            "rootPath": str(self.root),
            "runnerPID": pid,
            "runnerCommand": ["bounded-control-worker"],
            "startedAtUTC": DRIVER.utc_now(),
            "createdBy": DRIVER.RUNNER_ID,
        })
        DRIVER.write_json_atomic(self.root / DRIVER.RUNNER_STATUS_NAME, {
            "schemaVersion": 1,
            "state": "running",
            "ownerUID": os.getuid(),
            "runID": self.run_id,
            "rootPath": str(self.root),
            "runnerPID": pid,
            "targetActiveSeconds": target_seconds,
            "coveredActiveSeconds": 0,
            "acceptedExtensionRequestIDs": [],
        })
        return pid

    def extension_request(self, **overrides: object) -> dict[str, object]:
        owner = json.loads((self.root / DRIVER.RUNNER_OWNER_NAME).read_text(encoding="utf-8"))
        request: dict[str, object] = {
            "schemaVersion": 1,
            "requestID": str(uuid.uuid4()),
            "ownerUID": os.getuid(),
            "runID": self.run_id,
            "rootPath": str(self.root),
            "runnerPID": owner["runnerPID"],
            "additionalActiveHours": 1,
            "requestedAtUTC": DRIVER.utc_now(),
        }
        request.update(overrides)
        DRIVER.write_json_atomic(self.root / DRIVER.SOAK_EXTEND_REQUEST_NAME, request)
        return request

    def assert_extension_rejected_without_target_change(
        self,
        expected_message: str,
        *,
        expected_target: int = 3_600,
    ) -> None:
        request_path = self.root / DRIVER.SOAK_EXTEND_REQUEST_NAME
        result = DRIVER.consume_extend_request(self.root, self.run_id)
        status = json.loads((self.root / DRIVER.RUNNER_STATUS_NAME).read_text(encoding="utf-8"))
        self.assertIsNone(result)
        self.assertEqual(status["targetActiveSeconds"], expected_target)
        self.assertIn(expected_message, status["lastExtensionRejection"]["message"])
        events = [json.loads(line) for line in (self.root / "soak-samples.jsonl").read_text().splitlines()]
        self.assertEqual(events[-1]["recordType"], "extension-rejected")
        self.assertFalse(request_path.exists())

    def test_valid_extension_updates_target_and_records_receipt(self) -> None:
        self.install_worker_identity(target_seconds=24 * 3_600)
        request = self.extension_request(additionalActiveHours=48)

        target_ns = DRIVER.consume_extend_request(self.root, self.run_id)

        status = json.loads((self.root / DRIVER.RUNNER_STATUS_NAME).read_text(encoding="utf-8"))
        self.assertEqual(target_ns, 72 * 3_600 * 1_000_000_000)
        self.assertEqual(status["targetActiveSeconds"], 72 * 3_600)
        self.assertEqual(status["acceptedExtensionRequestIDs"], [request["requestID"]])
        event = json.loads((self.root / "soak-samples.jsonl").read_text().splitlines()[-1])
        self.assertEqual(event["recordType"], "soak-extension")
        self.assertEqual(event["requestID"], request["requestID"])
        self.assertFalse((self.root / DRIVER.SOAK_EXTEND_REQUEST_NAME).exists())

    def test_bad_root_run_owner_and_worker_identity_are_rejected(self) -> None:
        cases = (
            ({"runID": "another-run"}, "identity mismatch"),
            ({"ownerUID": os.getuid() + 1}, "identity mismatch"),
            ({"rootPath": str(self.root.parent)}, "identity mismatch"),
            ({"runnerPID": os.getpid() + 1}, "identity mismatch"),
        )
        for overrides, expected in cases:
            with self.subTest(overrides=overrides):
                self.install_worker_identity(target_seconds=3_600)
                self.extension_request(**overrides)
                self.assert_extension_rejected_without_target_change(expected)

    def test_unsafe_file_mode_and_symlink_are_rejected_without_following(self) -> None:
        self.extension_request()
        os.chmod(self.root / DRIVER.SOAK_EXTEND_REQUEST_NAME, 0o644)
        self.assert_extension_rejected_without_target_change("ownership or permissions are unsafe")

        self.extension_request()
        os.chmod(self.root / DRIVER.SOAK_EXTEND_REQUEST_NAME, 0o700)
        self.assert_extension_rejected_without_target_change("ownership or permissions are unsafe")

        target_digest = DRIVER.sha256_file(DRIVER_PATH)
        request_path = self.root / DRIVER.SOAK_EXTEND_REQUEST_NAME
        request_path.symlink_to(DRIVER_PATH)
        self.assert_extension_rejected_without_target_change("ownership or permissions are unsafe")
        self.assertTrue(request_path.is_symlink() is False)
        self.assertEqual(DRIVER.sha256_file(DRIVER_PATH), target_digest)

    def test_duration_must_be_a_positive_json_integer_and_target_must_stay_under_72h(self) -> None:
        for invalid_duration in (0, -1, False, 1.5, "1"):
            with self.subTest(invalid_duration=invalid_duration):
                self.install_worker_identity(target_seconds=3_600)
                self.extension_request(additionalActiveHours=invalid_duration)
                self.assert_extension_rejected_without_target_change("positive integer")

        self.install_worker_identity(target_seconds=71 * 3_600)
        self.extension_request(additionalActiveHours=2)
        self.assert_extension_rejected_without_target_change(
            "cannot exceed 72 hours",
            expected_target=71 * 3_600,
        )

    def test_replay_is_rejected_and_does_not_extend_twice(self) -> None:
        request = self.extension_request()
        first_target = DRIVER.consume_extend_request(self.root, self.run_id)
        self.assertEqual(first_target, 2 * 3_600 * 1_000_000_000)
        replay = self.extension_request(requestID=request["requestID"])

        second_target = DRIVER.consume_extend_request(self.root, self.run_id)

        status = json.loads((self.root / DRIVER.RUNNER_STATUS_NAME).read_text(encoding="utf-8"))
        self.assertIsNone(second_target)
        self.assertEqual(status["targetActiveSeconds"], 2 * 3_600)
        self.assertEqual(status["acceptedExtensionRequestIDs"], [replay["requestID"]])
        self.assertIn("already consumed", status["lastExtensionRejection"]["message"])

    def test_concurrent_publishers_leave_one_private_pending_request(self) -> None:
        owner = DRIVER.read_runner_owner(self.root, self.run_id)
        barrier = threading.Barrier(3)
        results: list[dict[str, object]] = []
        errors: list[str] = []

        def publish() -> None:
            barrier.wait()
            try:
                results.append(DRIVER.publish_soak_extension_request(
                    self.root,
                    self.run_id,
                    owner["runnerPID"],
                    1,
                ))
            except DRIVER.E2EError as error:
                errors.append(str(error))

        threads = [threading.Thread(target=publish) for _ in range(2)]
        for thread in threads:
            thread.start()
        barrier.wait()
        for thread in threads:
            thread.join(timeout=3)

        self.assertEqual(len(results), 1)
        self.assertEqual(errors, ["an extension request is already pending"])
        request_path = self.root / DRIVER.SOAK_EXTEND_REQUEST_NAME
        self.assertEqual(request_path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(request_path.read_text())["requestID"], results[0]["requestID"])

    def test_real_subprocess_worker_accepts_extension_replay_guard_and_stop(self) -> None:
        marker = json.loads((self.root / DRIVER.MARKER_NAME).read_text(encoding="utf-8"))
        marker["retentionMaxItems"] = DRIVER.SOAK_MAX_RETAINED_ITEMS
        marker["retentionPolicyRequested"] = DRIVER.requested_retention_policy(
            DRIVER.SOAK_MAX_RETAINED_ITEMS
        )
        DRIVER.write_json_atomic(self.root / DRIVER.MARKER_NAME, marker)
        self.control_worker_log = Path("/tmp") / (
            f"macclippy-phase6-python-soak-control-worker-{self.run_id}.log"
        )
        self.control_worker_log_handle = self.control_worker_log.open("w", encoding="utf-8")
        process = subprocess.Popen(
            [
                sys.executable,
                str(DRIVER_PATH),
                "_soak-control-worker",
                "--root", str(self.root),
                "--run-id", self.run_id,
                "--target-active-seconds", "3600",
                "--simulated-step-seconds", "1",
                "--poll-interval", "0.01",
                "--max-polls", "100000",
            ],
            stdin=subprocess.DEVNULL,
            stdout=self.control_worker_log_handle,
            stderr=subprocess.STDOUT,
            text=True,
        )
        self.control_process = process
        deadline = time.monotonic() + 3
        status: dict[str, object] = {}
        while time.monotonic() < deadline:
            if process.poll() is not None:
                self.control_worker_log_handle.flush()
                self.fail(f"bounded control worker exited early: {self.control_worker_log.read_text(encoding='utf-8')}")
            try:
                status = json.loads((self.root / DRIVER.RUNNER_STATUS_NAME).read_text(encoding="utf-8"))
            except (FileNotFoundError, json.JSONDecodeError):
                time.sleep(0.01)
                continue
            try:
                owner = json.loads((self.root / DRIVER.RUNNER_OWNER_NAME).read_text(encoding="utf-8"))
            except (FileNotFoundError, json.JSONDecodeError):
                owner = {}
            if status.get("state") == "running" and status.get("runnerPID") == process.pid and owner.get("runnerPID") == process.pid:
                break
            time.sleep(0.01)
        else:
            self.fail("bounded control worker did not publish owner/status")

        expected_retention = DRIVER.requested_retention_policy(DRIVER.SOAK_MAX_RETAINED_ITEMS)
        self.assertEqual(owner["retentionPolicyRequested"], expected_retention)
        self.assertIsNone(owner["retentionPolicyEffective"])
        self.assertEqual(status["retentionPolicyRequested"], expected_retention)
        self.assertIsNone(status["retentionPolicyEffective"])
        self.assertEqual(
            status["effectiveRetentionPolicyAvailability"],
            "not-measured-control-flow-only",
        )

        runner_command = subprocess.run(
            ["ps", "-ww", "-p", str(process.pid), "-o", "command="],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        self.assertTrue(
            DRIVER.is_runner_process(process.pid, self.root, self.run_id),
            f"owned worker command was not recognized: {runner_command}",
        )

        extension = DRIVER.extend_soak(type("Args", (), {
            "root": str(self.root),
            "run_id": self.run_id,
            "hours": 1,
        })())
        self.assertEqual(extension["requestState"], "pending-worker-validation")
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            status = json.loads((self.root / DRIVER.RUNNER_STATUS_NAME).read_text(encoding="utf-8"))
            if extension["requestID"] in status.get("acceptedExtensionRequestIDs", []):
                break
            time.sleep(0.01)
        else:
            self.fail(f"worker did not consume extension; status={status}")
        self.assertEqual(status["targetActiveSeconds"], 7_200)

        DRIVER.write_json_exclusive(self.root / DRIVER.SOAK_EXTEND_REQUEST_NAME, {
            "schemaVersion": 1,
            "requestID": extension["requestID"],
            "ownerUID": os.getuid(),
            "runID": self.run_id,
            "rootPath": str(self.root),
            "runnerPID": process.pid,
            "additionalActiveHours": 1,
            "requestedAtUTC": DRIVER.utc_now(),
        })
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            status = json.loads((self.root / DRIVER.RUNNER_STATUS_NAME).read_text(encoding="utf-8"))
            rejection = status.get("lastExtensionRejection")
            if isinstance(rejection, dict) and rejection.get("requestID") == extension["requestID"]:
                break
            time.sleep(0.01)
        else:
            self.fail(f"worker did not diagnose extension replay; status={status}")
        self.assertEqual(status["targetActiveSeconds"], 7_200)

        stop = DRIVER.stop_soak(type("Args", (), {
            "root": str(self.root),
            "run_id": self.run_id,
            "timeout": 5,
        })())
        self.assertTrue(stop["stopped"])
        process.communicate(timeout=3)
        self.control_worker_log_handle.flush()
        stdout = self.control_worker_log.read_text(encoding="utf-8")
        self.assertEqual(process.returncode, 0, stdout)
        self.assertIn("not a 24h or 72h soak", stdout)
        final_status = json.loads((self.root / DRIVER.RUNNER_STATUS_NAME).read_text(encoding="utf-8"))
        self.assertEqual(final_status["state"], "stopped")
        self.assertEqual(final_status["targetActiveSeconds"], 7_200)
        self.assertTrue(final_status["simulatedActiveTime"])
        self.assertEqual(final_status["retentionPolicyRequested"], expected_retention)
        self.assertIsNone(final_status["retentionPolicyEffective"])

    def test_clean_removes_only_the_selected_marked_fixture_root(self) -> None:
        other_root, other_run_id = DRIVER.create_fixture_root()
        args = type("Args", (), {"root": str(self.root), "run_id": self.run_id})()
        try:
            with mock.patch.object(
                DRIVER,
                "control_request",
                side_effect=DRIVER.E2EError("no listening control socket"),
            ):
                result = DRIVER.clean_root(args)
            self.assertTrue(result["cleaned"])
            self.assertFalse(self.root.exists())
            self.assertTrue((other_root / DRIVER.MARKER_NAME).is_file())
        finally:
            if other_root.exists():
                other_args = type("Args", (), {"root": str(other_root), "run_id": other_run_id})()
                with mock.patch.object(
                    DRIVER,
                    "control_request",
                    side_effect=DRIVER.E2EError("no listening control socket"),
                ):
                    DRIVER.clean_root(other_args)

    def test_clean_refuses_an_authenticated_app_control_endpoint(self) -> None:
        args = type("Args", (), {"root": str(self.root), "run_id": self.run_id})()
        with mock.patch.object(DRIVER, "control_request", return_value=({"ok": True}, 1.0)):
            with self.assertRaisesRegex(DRIVER.E2EError, "while its app is running"):
                DRIVER.clean_root(args)

        self.assertTrue(self.root.exists())
        self.assertTrue((self.root / DRIVER.MARKER_NAME).is_file())

    def test_stop_writes_owned_request_without_signaling_worker_pid(self) -> None:
        owner = {
            "schemaVersion": 1,
            "ownerUID": DRIVER.os.getuid(),
            "runID": self.run_id,
            "rootPath": str(self.root),
            "runnerPID": 12345,
            "runnerCommand": ["disposable-test-worker"],
            "createdBy": DRIVER.RUNNER_ID,
        }
        DRIVER.write_json_atomic(self.root / DRIVER.RUNNER_OWNER_NAME, owner)
        DRIVER.write_json_atomic(self.root / DRIVER.RUNNER_STATUS_NAME, {"state": "running"})
        lock = DRIVER.acquire_fixture_lock(self.root, DRIVER.RUNNER_LOCK_NAME)
        args = type("Args", (), {"root": str(self.root), "run_id": self.run_id, "timeout": 0.01})()
        try:
            with mock.patch.object(DRIVER.os, "kill") as process_signal:
                with self.assertRaisesRegex(DRIVER.E2EError, "did not stop"):
                    DRIVER.stop_soak(args)
            process_signal.assert_not_called()
            request = json.loads((self.root / DRIVER.SOAK_STOP_REQUEST_NAME).read_text(encoding="utf-8"))
            self.assertEqual(request["runID"], self.run_id)
            self.assertEqual(request["ownerUID"], DRIVER.os.getuid())
        finally:
            DRIVER.fcntl.flock(lock, DRIVER.fcntl.LOCK_UN)
            DRIVER.os.close(lock)


@unittest.skipUnless(os.environ.get("MACCLIPPY_E2E_QUERY_TEST_APP"), "Requires a source-bound Release E2E app")
class FullQueryRuntimeRegressionTests(unittest.TestCase):
    """Exercise the real full-query control path against a disposable root."""

    def test_native_host_is_opt_in_and_survives_dock_close_with_isolated_paste(self) -> None:
        root, run_id = DRIVER.create_fixture_root()
        pid = None
        observations = []

        def request(command: str, **arguments):
            response, elapsed = DRIVER.control_request(root, run_id, command, timeout=70, **arguments)
            observations.append({"command": command, "response": response, "elapsedMS": elapsed})
            return response

        try:
            launched, _, owned, _, _, _, _ = DRIVER.launch_app(
                os.environ["MACCLIPPY_E2E_QUERY_TEST_APP"], root, run_id)
            self.assertTrue(owned)
            pid = launched["pid"]
            self.assertFalse(request("metrics")["nativeHostVisible"])
            shown = request("native-host-show")
            self.assertTrue(shown["ready"])
            self.assertTrue(shown["nativeHostVisible"])
            request("capture", token="nativehostfixture", format="text", text="nativehostfixture payload")
            request("panel-show")
            request("panel-hide")
            self.assertTrue(request("metrics")["nativeHostVisible"])
            pasted = request("paste", query="nativehostfixture")
            self.assertTrue(pasted["contentInserted"])
            self.assertEqual(pasted["recipientInsertionCount"], 1)
            self.assertTrue(request("metrics")["nativeHostVisible"])
            self.assertFalse(request("native-host-hide")["nativeHostVisible"])
        finally:
            if pid is not None:
                DRIVER.request_terminate(root, run_id, pid)
            DRIVER.write_json_atomic(root / "native-host-regression.json", {
                "root": str(root), "runID": run_id, "observations": observations,
                "rootLockHeldAfterStop": DRIVER.fixture_root_lock_is_held(root)})

    def test_filtered_unfiltered_and_repeated_queries_replace_the_full_query(self) -> None:
        app = os.environ["MACCLIPPY_E2E_QUERY_TEST_APP"]
        root, run_id = DRIVER.create_fixture_root()
        evidence = Path(os.environ.get("MACCLIPPY_E2E_QUERY_TEST_EVIDENCE", str(root / "query-regression.json")))
        observations = []
        pid = None

        def request(command: str, **arguments):
            response, elapsed = DRIVER.control_request(root, run_id, command, timeout=70, **arguments)
            observations.append({"command": command, "arguments": arguments,
                                 "response": response, "elapsedMS": elapsed})
            return response

        try:
            response, _, owned, _, _, _, _ = DRIVER.launch_app(app, root, run_id)
            self.assertTrue(owned, "A fresh regression root must own its isolated app")
            pid = response["pid"]
            request("capture", token="queryregressiontext", format="text", text="queryregressiontext body")
            request("capture", token="queryregressionhtml", format="html", text="<p>queryregressionhtml body</p>")
            filtered = request("search-ui", query="queryregressiontext type:text")
            self.assertEqual(filtered["hitCount"], 1)
            expected_html = request("search-db", query="queryregressionhtml")
            unfiltered = request("search-ui", query="queryregressionhtml")
            self.assertEqual(unfiltered["matchedRecordIDs"], expected_html["matchedRecordIDs"])
            self.assertEqual(unfiltered["hitCount"], 1)
            repeated_filtered = request("search-ui", query="queryregressiontext type:text")
            repeated_again = request("search-ui", query="queryregressiontext type:text")
            self.assertEqual(repeated_filtered["matchedRecordIDs"], filtered["matchedRecordIDs"])
            self.assertEqual(repeated_again["matchedRecordIDs"], filtered["matchedRecordIDs"])
            final = request("search-ui", query="queryregressionhtml")
            self.assertEqual(final["matchedRecordIDs"], expected_html["matchedRecordIDs"])
        finally:
            if pid is not None:
                DRIVER.request_terminate(root, run_id, pid)
            DRIVER.write_json_atomic(evidence, {"root": str(root), "runID": run_id,
                                                "observations": observations})


if __name__ == "__main__":
    unittest.main()
