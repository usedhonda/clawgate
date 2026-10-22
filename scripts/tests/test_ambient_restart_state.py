import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch


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

    def test_running_backend_without_audio_is_not_success(self):
        with patch.object(subject, "request", return_value=status()) as request:
            with self.assertRaisesRegex(RuntimeError, "fresh audio"):
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
