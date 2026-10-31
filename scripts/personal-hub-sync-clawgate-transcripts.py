#!/usr/bin/env python3
"""Mirror ClawGate's transcript-enabled sessions, never rolling raw audio."""

import argparse
import json
import math
import os
import subprocess
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path


def options():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sessions-root", type=Path, default=Path.home() /
                        "Library/Application Support/ClawGate/ambient-context/sessions")
    parser.add_argument("--checkpoint", type=Path, default=Path.home() /
                        "Library/Application Support/ClawGate/hub-sync/clawgate-transcripts.json")
    parser.add_argument("--days", type=int, default=30)
    parser.add_argument("--remote-host", required=True)
    parser.add_argument("--apply", action="store_true")
    return parser.parse_args()


def event_for(session_id, number, row):
    when = row.get("capturedAt")
    if not isinstance(when, (float, int)) or isinstance(when, bool) or not math.isfinite(when):
        raise ValueError("invalid transcript capture time")
    if not isinstance(row.get("text"), str):
        raise ValueError("invalid transcript text")
    return {"source": "clawgate", "domain": "audio", "kind": "ambient-transcript-segment",
            "occurred_at": datetime.fromtimestamp(when, timezone.utc).isoformat(),
            "external_id": "clawgate:session:" + session_id + ":raw:" + str(number),
            "identity": None,
            "metadata": {"session_id": session_id, "stream": row.get("stream"),
                         "start_seconds": row.get("startSeconds"),
                         "end_seconds": row.get("endSeconds"),
                         "time_zone": row.get("timeZone"), "text": row["text"],
                         "original_audio_available": False,
                         "coverage": "transcription_enabled_session"}}


def gap_event_for(session_id, marker):
    if (not isinstance(marker, dict) or type(marker.get("version")) is not int
            or marker["version"] != 1 or marker.get("sessionID") != session_id
            or not isinstance(marker.get("reason"), str) or not marker["reason"].strip()
            or not isinstance(marker.get("recordedAt"), str)):
        raise ValueError("invalid raw gap marker")
    when = datetime.fromisoformat(marker["recordedAt"].replace("Z", "+00:00"))
    if when.tzinfo is None:
        raise ValueError("invalid raw gap time")
    return {"source": "clawgate", "domain": "audio", "kind": "clawgate.raw-gap.v1",
            "external_id": "clawgate:session:" + session_id + ":raw-gap",
            "occurred_at": marker["recordedAt"], "identity": None,
            "metadata": {"session_id": session_id, "reason": marker["reason"],
                         "recorded_at": marker["recordedAt"], "marker_version": marker["version"]}}


def main():
    arg = options()
    if arg.days < 1 or not arg.sessions_root.is_dir():
        raise SystemExit("invalid days or session root")
    checkpoint = json.loads(arg.checkpoint.read_text()) if arg.checkpoint.is_file() else {}
    if not isinstance(checkpoint, dict):
        raise SystemExit("checkpoint invalid")
    next_checkpoint = dict(checkpoint)
    cutoff = (datetime.now(timezone.utc) - timedelta(days=arg.days)).timestamp()
    pending = []
    counts = {"sessions": 0, "segments": 0, "skipped_old": 0,
              "created": 0, "duplicate": 0, "gap_markers": 0, "invalid_gap_markers": 0,
              "ungapped_sessions_skipped": 0}
    for directory in sorted(arg.sessions_root.iterdir()):
        if not directory.is_dir() or directory.is_symlink() or not directory.name.startswith("ctx-"):
            continue
        marker_path = directory / "transcripts" / "hub-raw-gap.json"
        has_gap = False
        if marker_path.exists() or marker_path.is_symlink():
            try:
                if marker_path.is_symlink():
                    raise ValueError("invalid marker path")
                pending.append(gap_event_for(directory.name, json.loads(marker_path.read_text())))
                counts["gap_markers"] += 1
                has_gap = True
            except (OSError, ValueError):
                counts["invalid_gap_markers"] += 1
        if not has_gap:
            counts["ungapped_sessions_skipped"] += 1
            continue
        path = directory / "transcripts" / "raw.jsonl"
        if not path.is_file() or path.is_symlink() or path.stat().st_mtime < cutoff:
            continue
        counts["sessions"] += 1
        current = checkpoint.get(directory.name, {"offset": 0, "line": 0, "inode": path.stat().st_ino})
        stat = path.stat()
        if current["inode"] != stat.st_ino or current["offset"] > stat.st_size:
            raise SystemExit("transcript source rotated or truncated; checkpoint unchanged")
        offset, number = current["offset"], current["line"]
        with path.open("rb") as stream:
            stream.seek(offset)
            while True:
                raw = stream.readline()
                if not raw or not raw.endswith(b"\n"):
                    break
                number += 1
                offset = stream.tell()
                row = json.loads(raw)
                event = event_for(directory.name, number, row)
                if datetime.fromisoformat(event["occurred_at"]).timestamp() < cutoff:
                    counts["skipped_old"] += 1
                    continue
                pending.append(event)
                counts["segments"] += 1
        next_checkpoint[directory.name] = {"offset": offset, "line": number, "inode": stat.st_ino}
    if arg.apply and pending:
        command = ["ssh", "-o", "BatchMode=yes", arg.remote_host,
                   "python3 ~/projects/openclaw/general/scripts/personal-hub-import-clawgate.py"]
        payload = "".join(json.dumps(event, separators=(",", ":"), ensure_ascii=False) + "\n"
                          for event in pending)
        result_process = subprocess.run(command, input=payload, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, timeout=300)
        if result_process.returncode:
            raise SystemExit("hub transcript import failed; checkpoint unchanged")
        result = json.loads(result_process.stdout)
        counts["created"], counts["duplicate"] = result["created"], result["duplicate"]
    if arg.apply and next_checkpoint != checkpoint:
        arg.checkpoint.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd, name = tempfile.mkstemp(prefix="clawgate-transcripts-", dir=arg.checkpoint.parent)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w") as stream:
                json.dump(next_checkpoint, stream, sort_keys=True)
                stream.flush(); os.fsync(stream.fileno())
            os.replace(name, arg.checkpoint)
        finally:
            if os.path.exists(name):
                os.unlink(name)
    print(json.dumps(counts, sort_keys=True))


if __name__ == "__main__":
    main()
