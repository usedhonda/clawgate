#!/usr/bin/env python3
"""Send explicitly selected ClawGate meeting audio and timed transcript to hub.

The client Mac reads only pinned meeting audio, never the rolling archive. SSH
streams events to the Mac mini importer; source data and credentials stay local.
"""

import argparse
import base64
import hashlib
import json
import os
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path


def stamp(seconds):
    return datetime.fromtimestamp(float(seconds), timezone.utc).isoformat()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument("--meetings-root", type=Path, default=Path.home() /
        "Library/Application Support/ClawGate/ambient-context/meetings")
    parser.add_argument("--checkpoint", type=Path, default=Path.home() /
        ".local/share/personal-data-hub/clawgate-meetings.json")
    parser.add_argument("--remote-host", required=True)
    parser.add_argument("--apply", action="store_true")
    return parser.parse_args()


def main():
    options = arguments()
    root = options.meetings_root.resolve()
    if not root.is_dir():
        raise SystemExit("meeting store unavailable")
    try:
        checkpoint = json.loads(options.checkpoint.read_text()) if options.checkpoint.is_file() else {}
    except ValueError:
        raise SystemExit("checkpoint invalid; no overwrite")
    pending = []
    counts = {"selected_meetings": 0, "audio_chunks": 0, "missing_audio": 0,
              "transcripts": 0, "unchanged_meetings": 0}
    next_checkpoint = dict(checkpoint)
    for directory in sorted(root.iterdir()):
        if not directory.is_dir() or directory.is_symlink():
            continue
        record_path = directory / "meeting.json"
        audio_dir = directory / "audio"
        index_path = audio_dir / "index.json"
        transcript_path = directory / "transcript.json"
        if not record_path.is_file() or (not index_path.is_file() and not transcript_path.is_file()):
            continue
        try:
            record = json.loads(record_path.read_text())
            if record.get("id") != directory.name or not isinstance(record.get("startedAt"), (int, float)):
                continue
            chunks = json.loads(index_path.read_text()) if index_path.is_file() else []
            if not isinstance(chunks, list):
                continue
            transcript = json.loads(transcript_path.read_text()) if transcript_path.is_file() else None
        except (OSError, ValueError):
            continue
        counts["selected_meetings"] += 1
        # The source supplies absolute meeting/chunk and per-segment capture
        # times; no transcript completion time is promoted to utterance time.
        descriptor = [record_path.stat().st_mtime_ns,
                      index_path.stat().st_mtime_ns if index_path.is_file() else None,
                      transcript_path.stat().st_mtime_ns if transcript_path.is_file() else None]
        files = []
        for chunk in chunks:
            if (not isinstance(chunk, dict) or not isinstance(chunk.get("fileName"), str) or
                    chunk["fileName"] != Path(chunk["fileName"]).name):
                counts["missing_audio"] += 1
                continue
            path = audio_dir / chunk["fileName"]
            if not path.is_file() or path.is_symlink():
                counts["missing_audio"] += 1
                continue
            files.append((chunk, path))
            stat = path.stat()
            descriptor.append((chunk.get("id"), stat.st_size, stat.st_mtime_ns))
        signature = digest(json.dumps(descriptor, sort_keys=True).encode())
        if checkpoint.get(directory.name) == signature:
            counts["unchanged_meetings"] += 1
            continue
        for chunk, path in files:
            if not isinstance(chunk.get("id"), str) or not isinstance(chunk.get("startedAt"), (int, float)):
                counts["missing_audio"] += 1
                continue
            counts["audio_chunks"] += 1
            if options.apply:
                payload = path.read_bytes()
                pending.append({"source": "clawgate", "domain": "audio", "kind": "selected-meeting-original",
                    "occurred_at": stamp(chunk["startedAt"]),
                    "external_id": "clawgate:meeting:" + directory.name + ":audio:" + chunk["id"],
                    "identity": None,
                    "metadata": {"meeting_id": directory.name, "stream": chunk.get("source"),
                                 "chunk_id": chunk["id"], "started_at": chunk["startedAt"],
                                 "ended_at": chunk.get("endedAt"), "selection": "explicit"},
                    "payload_base64": base64.b64encode(payload).decode("ascii")})
        if isinstance(transcript, list):
            counts["transcripts"] += 1
            if options.apply:
                revision = digest(json.dumps(transcript, sort_keys=True, ensure_ascii=False).encode())
                pending.append({"source": "clawgate", "domain": "audio", "kind": "selected-meeting-transcript",
                    "occurred_at": stamp(record["startedAt"]),
                    "external_id": "clawgate:meeting:" + directory.name + ":transcript:" + revision,
                    "identity": None,
                    "metadata": {"meeting_id": directory.name, "time_basis": "meeting_started_at",
                                 "selection": "explicit", "segments": transcript,
                                 "missing_originals": not bool(files)}})
        next_checkpoint[directory.name] = signature
    if options.apply and pending:
        command = ["ssh", "-o", "BatchMode=yes", options.remote_host,
            "python3 ~/projects/openclaw/general/scripts/personal-hub-import-clawgate.py"]
        process = subprocess.Popen(command, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        try:
            for event in pending:
                process.stdin.write(json.dumps(event, separators=(",", ":"), ensure_ascii=False) + "\n")
            process.stdin.close()
            output = process.stdout.read()
            code = process.wait(timeout=300)
        except Exception:
            process.kill()
            raise
        if code:
            raise SystemExit("hub import failed; checkpoint unchanged")
        result = json.loads(output)
        counts["created"] = result["created"]
        counts["duplicate"] = result["duplicate"]
    if options.apply and next_checkpoint != checkpoint:
        options.checkpoint.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix="clawgate-meetings-", dir=options.checkpoint.parent)
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(next_checkpoint, stream, sort_keys=True)
                stream.flush()
                os.fsync(stream.fileno())
            os.chmod(temporary, 0o600)
            os.replace(temporary, options.checkpoint)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    print(json.dumps(counts, sort_keys=True))


if __name__ == "__main__":
    main()
