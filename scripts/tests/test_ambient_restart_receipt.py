import importlib.util
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import socket
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

spec = importlib.util.spec_from_file_location(
    "restart_receipt", Path(__file__).resolve().parents[1] / "ambient-restart-state.py")
subject = importlib.util.module_from_spec(spec)
spec.loader.exec_module(subject)


def status(active=True, chunks=0):
    return dict(captureState="capturing" if active else "idle", streaming=False,
                backendPhase="running", chunksSurfaced=chunks,
                secondsSinceLastChunk=0, autoResumeBlockedReason=None)


class RestartReceiptTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.receipt = self.root / "receipt.json"
        self.intent = self.root / "intent.json"
        self.app = self.root / "ClawGate"
        for name, value in [("INTENT_FILE", self.intent)]:
            mock = patch.object(subject, name, value)
            mock.start()
            self.addCleanup(mock.stop)
        self.old = dict(pid=123, started="old-process")
        self.new = dict(pid=456, started="new-process")
        self.set_intent()

    def set_intent(self, active=True, settled=True):
        subject.atomic_json(self.intent, dict(revision=str(uuid.uuid4()), settled=settled,
                                             captureState="capturing" if active else "idle",
                                             streaming=False))

    def prepare(self, active=True):
        if not active:
            self.set_intent(active=False)
        with patch.object(subject, "process_for", return_value=self.old), patch.object(
                subject, "binary_uuid", return_value=["binary-id"]), patch.object(
                subject, "request", return_value=status(active)):
            subject.prepare(self.receipt, self.app, self.app)
        return json.loads(self.receipt.read_text())

    def test_invalid_provenance_and_consumed_receipts_produce_no_requests(self):
        original = self.prepare()
        cases = [
            dict(capturedAt=(datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()),
            dict(capturedAt=(datetime.now(timezone.utc) + timedelta(minutes=1)).isoformat()),
            dict(app_identity="foreign-app"),
            dict(target_uuid=["foreign-binary"], source_uuid=["foreign-binary"]),
            dict(phase="consumed"),
            dict(operation="not-an-operation"),
        ]
        for changes in cases:
            with self.subTest(changes=changes):
                subject.atomic_json(self.receipt, dict(original, **changes))
                with patch.object(subject, "binary_uuid", return_value=["binary-id"]), patch.object(
                        subject, "process_for", return_value=self.new), patch.object(subject, "request") as request:
                    with self.assertRaises(RuntimeError):
                        subject.finish(self.receipt, self.app)
                    request.assert_not_called()

    def test_newer_gui_stop_invalidates_even_a_fresh_matching_binary(self):
        self.prepare()
        self.set_intent(active=False)
        with patch.object(subject, "binary_uuid", return_value=["binary-id"]), patch.object(
                subject, "process_for", return_value=self.new), patch.object(subject, "request") as request:
            with self.assertRaisesRegex(RuntimeError, "newer ambient"):
                subject.finish(self.receipt, self.app)
            request.assert_not_called()

    def test_live_unresponsive_process_is_never_restarted_from_old_receipt(self):
        self.prepare()
        for failure in [socket.timeout("read timeout"), subject.urllib.error.URLError("refused")]:
            with self.subTest(failure=type(failure).__name__):
                with patch.object(subject, "process_for", return_value=self.old), patch.object(
                        subject, "request", side_effect=failure):
                    with self.assertRaisesRegex(RuntimeError, "stopped before termination"):
                        subject.prepare(self.receipt, self.app, self.app)

    def test_interrupted_prepared_operation_survives_and_success_consumes_it(self):
        original = self.prepare()
        self.assertEqual(stat.S_IMODE(self.receipt.stat().st_mode), 0o600)
        with patch.object(subject, "process_for", return_value=None), patch.object(
                subject, "binary_uuid", return_value=["binary-id"]), patch.object(subject, "request") as request:
            subject.prepare(self.receipt, self.app, self.app)
            request.assert_not_called()
        self.assertEqual(json.loads(self.receipt.read_text())["operation"], original["operation"])
        responses = iter([status(False), {}, status(True, chunks=1)])

        def api(path, method="GET"):
            if method == "POST":
                self.assertEqual(path, "/capture/resume")
                self.assertTrue(json.loads(self.receipt.read_text())["restore_attempted"])
                self.set_intent()  # Real controller persists its own accepted control.
            return next(responses)

        with patch.object(subject, "process_for", return_value=self.new), patch.object(
                subject, "binary_uuid", return_value=["binary-id"]), patch.object(
                subject, "request", side_effect=api), patch.object(subject.time, "sleep"):
            subject.finish(self.receipt, self.app)
        self.assertFalse(self.receipt.exists())
        consumed = subject.private_json(str(self.receipt) + ".consumed")
        self.assertEqual(consumed["phase"], "consumed")

    def test_uncertain_post_is_persisted_and_never_replayed(self):
        self.prepare()
        with patch.object(subject, "process_for", return_value=self.new), patch.object(
                subject, "binary_uuid", return_value=["binary-id"]), patch.object(
                subject, "request", side_effect=[status(False), RuntimeError("uncertain")]) as request:
            with self.assertRaisesRegex(RuntimeError, "uncertain"):
                subject.finish(self.receipt, self.app)
            self.assertEqual(request.call_count, 2)
        self.assertTrue(json.loads(self.receipt.read_text())["restore_attempted"])
        with patch.object(subject, "process_for", return_value=self.new), patch.object(
                subject, "binary_uuid", return_value=["binary-id"]), patch.object(subject, "request") as request:
            with self.assertRaisesRegex(RuntimeError, "not retried"):
                subject.finish(self.receipt, self.app)
            request.assert_not_called()

    def test_paused_state_is_retained_without_opening_microphone(self):
        original = self.prepare(active=False)
        original["state"]["captureState"] = "paused"
        subject.atomic_json(self.receipt, original)
        with patch.object(subject, "process_for", return_value=self.new), patch.object(
                subject, "binary_uuid", return_value=["binary-id"]), patch.object(
                subject, "request", return_value=status(False)) as request:
            subject.finish(self.receipt, self.app)
        request.assert_called_once_with("/status")
        self.assertEqual(subject.private_json(str(self.receipt) + ".consumed")["state"]["captureState"], "paused")

    def test_explicit_no_restore_retains_receipt_and_sends_no_request(self):
        original = self.prepare()
        with patch.object(subject, "request") as request:
            subject.prepare(self.receipt, self.app, self.app, without_restore=True)
            request.assert_not_called()
        self.assertEqual(json.loads(self.receipt.read_text()), original)

    def test_absent_source_uses_only_settled_durable_choice(self):
        for active in (False, True):
            with self.subTest(active=active):
                self.receipt.unlink(missing_ok=True)
                self.set_intent(active=active)
                with patch.object(subject, "process_for", return_value=None), patch.object(
                        subject, "binary_uuid", return_value=["binary-id"]), patch.object(subject, "request") as request:
                    subject.prepare(self.receipt, self.app, self.app)
                    request.assert_not_called()
                saved = subject.private_json(self.receipt)
                self.assertEqual(saved["state_kind"], "known")
                self.assertEqual(saved["state_source"], "durable_user_intent")
                self.assertEqual(subject.choice(saved["state"]), dict(capturing=active, streaming=False))

    def test_unknown_and_legacy_null_are_not_success_or_microphone_authority(self):
        self.intent.unlink()
        with patch.object(subject, "process_for", return_value=None), patch.object(
                subject, "binary_uuid", return_value=["binary-id"]), patch.object(subject, "request") as request:
            subject.prepare(self.receipt, self.app, self.app)
            request.assert_not_called()
        original = subject.private_json(self.receipt)
        self.assertEqual(original["state_kind"], "unknown")
        legacy = dict(original)
        legacy.pop("state_kind")
        for saved in (original, legacy):
            subject.atomic_json(self.receipt, saved)
            with patch.object(subject, "process_for", return_value=self.new), patch.object(
                    subject, "binary_uuid", return_value=["binary-id"]), patch.object(subject, "request") as request:
                with self.assertRaises(subject.UnverifiedAmbientState):
                    subject.finish(self.receipt, self.app)
                request.assert_not_called()
            self.assertEqual(subject.private_json(self.receipt), saved)
            self.assertFalse(Path(str(self.receipt) + ".consumed").exists())

    def test_explicit_unavailable_is_distinct_from_unknown(self):
        import io
        failure = subject.urllib.error.HTTPError(
            subject.BASE + "/status", 403, "Forbidden", {},
            io.BytesIO(b'{"ok":false,"error":{"code":"client_only_feature"}}'))
        with patch.object(subject.urllib.request, "urlopen", side_effect=failure):
            self.assertIsNone(subject.request("/status"))
        with patch.object(subject, "process_for", return_value=self.old), patch.object(
                subject, "binary_uuid", return_value=["binary-id"]), patch.object(subject, "request", return_value=None):
            subject.prepare(self.receipt, self.app, self.app)
        self.assertEqual(subject.private_json(self.receipt)["state_kind"], "not_applicable")
        with patch.object(subject, "process_for", return_value=self.new), patch.object(
                subject, "binary_uuid", return_value=["binary-id"]), patch.object(subject, "request", return_value=None) as request:
            subject.finish(self.receipt, self.app)
            request.assert_called_once_with("/status")
        self.assertEqual(subject.private_json(str(self.receipt) + ".consumed")["outcome"], "not_applicable")

    def test_canonical_lease_preserves_arguments_and_excludes_another_restart(self):
        driver = self.root / "driver.sh"
        # The inherited lock must outlive exec into the canonical shell process.
        driver.write_text('test "$1" = "--skip-build" && test "$2" = "two words"\n'
                          '"$3" "$4" run-locked "$5" /does-not-run.sh > /dev/null 2>&1\n'
                          'test "$?" != "0"\n')
        result = subprocess.run(
            [sys.executable, str(Path(subject.__file__)), "run-locked", str(self.root),
             str(driver), "--skip-build", "two words", sys.executable,
             str(Path(subject.__file__)), str(self.root)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_legacy_and_nonprivate_receipts_are_not_recovery_authority(self):
        for value, mode in [({"state": status()}, 0o600), (self.prepare(), 0o644)]:
            subject.atomic_json(self.receipt, value)
            self.receipt.chmod(mode)
            with patch.object(subject, "binary_uuid", return_value=["binary-id"]), patch.object(subject, "request") as request:
                with self.assertRaises(RuntimeError):
                    subject.prepare(self.receipt, self.app, self.app, existing_receipt=True)
                request.assert_not_called()


if __name__ == "__main__":
    unittest.main()
