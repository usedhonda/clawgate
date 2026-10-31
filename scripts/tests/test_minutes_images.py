import hashlib
import importlib.util
import json
import struct
import tempfile
import unittest
from pathlib import Path

PATH = Path(__file__).parents[1] / "personal-hub-illustrate-clawgate-minutes.py"
SPEC = importlib.util.spec_from_file_location("illustrate", PATH)
illustrate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(illustrate)


def png(width=4, height=3):
    return illustrate.PNG_SIGNATURE + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", width, height) + b"\0" * 8


class MinutesImagesTests(unittest.TestCase):
    def test_validated_images_reads_size_and_rejects_bad_results(self):
        item = {"file": "image-1.png", "title": "t", "alt": "a", "topic": ""}
        image = illustrate.validated_images({"images": [item]}, {"image-1.png": png()})[0]
        self.assertEqual((image["width"], image["height"], image["topic_heading"]), (4, 3, None))
        for bad, files in (
            (dict(item, alt=" "), {"image-1.png": png()}),
            (dict(item, file="../x.png"), {"../x.png": png()}),
            (item, {"image-1.png": b"not a png"}),
            (item, {}),
        ):
            with self.assertRaises(ValueError):
                illustrate.validated_images({"images": [bad]}, files)

    def test_only_the_current_stored_revision_is_offered(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            raw = json.dumps({"summary": "s"}).encode()
            revision = "sha256:" + hashlib.sha256(raw).hexdigest()
            for name in ("mtg-same", "mtg-changed", "mtg-pending"):
                (root / name).mkdir()
                (root / name / "minutes.json").write_bytes(raw)
            (root / "knowledge-outbox-hub").mkdir()
            (root / "knowledge-outbox-hub/state.json").write_text(json.dumps({"sourceUUID": "u", "entries": [
                {"meetingID": "mtg-same", "operation": "upsert", "outputRevision": revision, "receipt": {"status": "stored"}},
                {"meetingID": "mtg-changed", "operation": "upsert", "outputRevision": "sha256:" + "0" * 64, "receipt": {"status": "stored"}},
                {"meetingID": "mtg-pending", "operation": "upsert", "outputRevision": revision},
            ]}))
            self.assertEqual([r["meeting_id"] for r in illustrate.delivered_revisions(root)], ["mtg-same"])

    def test_zero_images_still_close_the_revision(self):
        revision = {"source_uuid": "u", "meeting_id": "m", "revision": "sha256:r"}
        event = illustrate.set_event(revision, [], "2026-10-31T00:00:00+00:00")
        self.assertEqual(event["external_id"], "minutes-image-set:u:m:sha256:r")
        self.assertEqual(event["metadata"]["image_count"], 0)
        self.assertNotIn("blob_sha256", event)


if __name__ == "__main__":
    unittest.main()
