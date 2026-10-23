import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import tempfile
import urllib.error
import json


spec = importlib.util.spec_from_file_location(
    "ambient_restart_state", Path(__file__).resolve().parents[1] / "ambient-restart-state.py"
)
subject = importlib.util.module_from_spec(spec)
spec.loader.exec_module(subject)


def status(capturing=True, streaming=False, chunks=0, **extra):
    return dict(captureState="capturing" if capturing else "idle", streaming=streaming,
                backendPhase="running", autoResumeBlockedReason=None,
                chunksSurfaced=chunks, secondsSinceLastChunk=0, **extra)


class AmbientRestartStateTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        fence = patch.object(subject, "INTENT_FILE", Path(directory.name) / "intent.json")
        fence.start()
        self.addCleanup(fence.stop)

    def test_snapshot_does_not_substitute_unattributed_historical_state(self):
        with patch.object(subject, "request", side_effect=urllib.error.URLError("refused")):
            with self.assertRaises(urllib.error.URLError):
                subject.snapshot()

    def test_incomplete_status_cannot_open_microphone(self):
        with patch.object(subject, "request", return_value={}) as request:
            with self.assertRaisesRegex(RuntimeError, "not restorable"):
                subject.restore({"capturing": True, "streaming": False})
        request.assert_called_once_with("/status")

    def test_capture_only_is_resumed_once_without_starting_transcription(self):
        with patch.object(subject, "request", side_effect=[status(False), status(), status(chunks=1)]) as request, patch.object(subject.time, "sleep"):
            subject.restore({"capturing": True, "streaming": False})
        self.assertEqual(request.call_args_list[1].args, ("/capture/resume", "POST"))
        self.assertEqual(request.call_count, 3)

    def test_stream_is_restored_only_when_previously_active(self):
        with patch.object(subject, "request", side_effect=[status(False), status(streaming=True), status(streaming=True, chunks=1)]) as request, patch.object(subject.time, "sleep"):
            subject.restore({"capturing": True, "streaming": True})
        self.assertEqual(request.call_args_list[1].args, ("/stream/start", "POST"))

    def test_intentionally_inactive_microphone_is_never_opened(self):
        with patch.object(subject, "request", return_value=status(False)) as request:
            subject.restore({"capturing": False, "streaming": False})
        request.assert_called_once_with("/status")

    def test_safety_inhibit_is_not_bypassed(self):
        blocked = status(False)
        blocked["autoResumeBlockedReason"] = "backend_timeout"
        with patch.object(subject, "request", return_value=blocked) as request:
            with self.assertRaisesRegex(RuntimeError, "safety inhibit"):
                subject.restore({"capturing": True, "streaming": False})
        request.assert_called_once_with("/status")

    def test_chunk_finalization_does_not_block_restored_capture(self):
        with patch.object(subject, "request", return_value=status()) as request:
            subject.restore({"capturing": True, "streaming": False}, timeout=0)
        request.assert_called_once_with("/status")

    def test_pending_control_still_cannot_complete_restoration(self):
        with patch.object(subject, "request", return_value=status(chunks=1)) as request, patch.object(subject, "read_intent", return_value={"settled": False}):
            with self.assertRaisesRegex(RuntimeError, "control state"):
                subject.restore({"capturing": True, "streaming": False}, timeout=0)
        request.assert_called_once_with("/status")

    def test_unexpected_transcription_is_not_silently_accepted(self):
        with patch.object(subject, "request", return_value=status(streaming=True)) as request:
            with self.assertRaisesRegex(RuntimeError, "unexpectedly enabled"):
                subject.restore({"capturing": True, "streaming": False})
        request.assert_called_once_with("/status")

    def test_uncertain_post_is_not_retried(self):
        with patch.object(subject, "request", side_effect=[status(False), RuntimeError("request failed")]) as request:
            with self.assertRaises(RuntimeError):
                subject.restore({"capturing": True, "streaming": False})
        self.assertEqual(request.call_count, 2)


if __name__ == "__main__":
    unittest.main()
