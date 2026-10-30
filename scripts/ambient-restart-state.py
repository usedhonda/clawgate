#!/usr/bin/env python3
"""Preserve the local microphone/stream choice across a canonical restart."""

import json
from pathlib import Path
import argparse
from datetime import datetime, timedelta, timezone
import fcntl
import hashlib
import os
import socket
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid


BASE = "http://127.0.0.1:8765/v1/ambient"
INTENT_FILE = Path.home() / "Library/Application Support/ClawGate/ambient-context/capture-choice.json"
RECEIPT_SECONDS = 15 * 60


class UnverifiedAmbientState(RuntimeError):
    """The app is ready, but no trustworthy pre-restart choice is available."""


def request(path, method="GET"):
    req = urllib.request.Request(BASE + path, method=method)
    try:
        with urllib.request.urlopen(req, timeout=3) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 403:
            payload = json.load(error)
            if (payload.get("error") or {}).get("code") in ("ambient_unavailable", "client_only_feature"):
                return None
        raise RuntimeError("ambient request failed") from None
    if payload.get("ok") is not True or not isinstance(payload.get("result"), dict):
        raise RuntimeError("ambient request was not acknowledged")
    return payload["result"]


def choice(status):
    if type(status.get("streaming")) is not bool or status.get("captureState") not in (
        "idle", "paused", "capturing"
    ):
        raise RuntimeError("ambient state is not restorable")
    if status["streaming"] and status["captureState"] != "capturing":
        raise RuntimeError("ambient state is transitioning; restart not started")
    return {
        "capturing": status["captureState"] == "capturing",
        "streaming": status["streaming"],
    }


def snapshot():
    status = request("/status")
    return None if status is None else choice(status)


def restore(before, timeout=45, guard=lambda: None, before_post=lambda: None):
    if before is None:
        raise UnverifiedAmbientState("pre-restart ambient choice unknown; no restoration attempted")
    if set(before) != {"capturing", "streaming"} or any(type(v) is not bool for v in before.values()):
        raise RuntimeError("invalid ambient restart snapshot")
    deadline = time.monotonic() + timeout
    resumed = False
    while True:
        if not resumed:
            guard()
        status = request("/status")
        if status is None:
            # HTTP readiness can precede ambient endpoint availability. Keep
            # the known pre-restart intent fence and wait within the existing
            # deadline; unavailability is never evidence of an inactive mic.
            if time.monotonic() >= deadline:
                raise RuntimeError("ambient became unavailable after restart")
            time.sleep(1)
            continue
        current = choice(status)
        capturing = current["capturing"]
        streaming = current["streaming"]
        if not before["capturing"]:
            if capturing or streaming != before["streaming"]:
                raise RuntimeError("ambient inactive choice changed after restart")
            return "not_required"  # Never open an intentionally inactive microphone.
        if status.get("autoResumeBlockedReason"):
            raise RuntimeError("ambient safety inhibit prevents restoration")
        if status.get("backendPhase") in ("failed", "timedOut"):
            raise RuntimeError("ambient backend failed during restoration")
        if streaming and not before["streaming"]:
            raise RuntimeError("transcription unexpectedly enabled after restart")
        if not resumed and (not capturing or streaming != before["streaming"]):
            route = "/stream/start" if before["streaming"] else "/capture/resume"
            guard()
            before_post()  # Persist before sending: an uncertain POST is never replayed.
            if request(route, "POST") is None:
                raise RuntimeError("ambient restoration was not acknowledged")
            resumed = True  # An uncertain/failed POST is never retried.
        elif capturing and streaming == before["streaming"] and status.get("backendPhase") == "running":
            # Restore the acknowledged control state, not a chunk-production
            # schedule. Audio delivery is observed separately: a finalized chunk
            # can take 30 seconds and must not become an extra restart gate.
            intent = read_intent(allow_pending=True)
            intent_settled = intent is None or intent["settled"]
            if intent_settled:
                return "restored" if resumed else "already_matching"
        if time.monotonic() >= deadline:
            raise RuntimeError("ambient control state was not restored")
        time.sleep(1)


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix="." + path.name, dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump(value, stream, separators=(",", ":"))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_intent(allow_pending=False):
    try:
        value = json.loads(INTENT_FILE.read_text())
    except FileNotFoundError:
        return None  # First installation: live status only, never crash replay.
    if not isinstance(value, dict) or type(value.get("settled")) is not bool:
        raise RuntimeError("ambient user intent is invalid")
    try:
        uuid.UUID(value["revision"])
    except (ValueError, KeyError, TypeError, AttributeError):
        raise RuntimeError("ambient user intent is invalid") from None
    if not allow_pending and not value["settled"]:
        raise RuntimeError("ambient user control is pending; restart stopped before termination; "
                           "--restart-without-ambient-restore requires explicit one-operation authorization")
    return value


def intent_matches(receipt):
    current = read_intent()
    revision = current["revision"] if current else None
    if revision != receipt["intent_revision"]:
        raise RuntimeError("newer ambient user control; restoration refused")


def process_for(app_bin):
    result = subprocess.run(["ps", "-axo", "pid=,lstart=,comm="],
                            check=True, capture_output=True, text=True)
    matches = []
    for line in result.stdout.splitlines():
        fields = line.split(None, 6)
        if len(fields) == 7 and fields[6] == str(Path(app_bin).resolve()):
            matches.append({"pid": int(fields[0]), "started": " ".join(fields[1:6])})
    if len(matches) > 1:
        raise RuntimeError("multiple local app processes; restart refused")
    return matches[0] if matches else None


def binary_uuid(app_bin):
    result = subprocess.run(["xcrun", "dwarfdump", "--uuid", str(app_bin)],
                            check=True, capture_output=True, text=True)
    values = [line.split()[1] for line in result.stdout.splitlines() if line.startswith("UUID:")]
    if not values:
        raise RuntimeError("application binary identity unavailable")
    return sorted(values)


def app_identity(app_bin):
    return hashlib.sha256(str(Path(app_bin).resolve()).encode()).hexdigest()


def private_json(path):
    path = Path(path)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise RuntimeError("restart receipt must be an owned private regular file")
    return json.loads(path.read_text())


def load_receipt(path, app_bin):
    value = private_json(path)
    try:
        uuid.UUID(value["operation"])
        captured = datetime.fromisoformat(value["capturedAt"]).timestamp()
        expires = datetime.fromisoformat(value["expiresAt"]).timestamp()
        age = time.time() - captured
        valid = (value["schema"] == 1 and 0 <= age <= RECEIPT_SECONDS
                 and 0 < expires - captured <= RECEIPT_SECONDS and time.time() <= expires
                 and value["phase"] in ("prepared", "stopped", "launched")
                 and type(value["restore_attempted"]) is bool
                 and value["app_identity"] == app_identity(app_bin)
                 and binary_uuid(app_bin) in (value["source_uuid"], value["target_uuid"]))
        if value["state"] is not None:
            choice(value["state"])
        kind = value.get("state_kind", "known" if value["state"] is not None else "unknown")
        valid = valid and kind in ("known", "unknown", "not_applicable")
        valid = valid and ((kind == "known") == (value["state"] is not None))
    except (ValueError, KeyError, TypeError):
        valid = False
    if not valid:
        raise RuntimeError("restart receipt is stale, foreign, invalid or consumed")
    return value


def prepare(path, app_bin, target_bin, without_restore=False, existing_receipt=False):
    if without_restore:
        print("Explicit restart without ambient restoration; any receipt retained.", file=sys.stderr)
        return
    if existing_receipt:
        load_receipt(path, app_bin)
    source = process_for(app_bin)
    try:
        intent_before = read_intent()
        status = request("/status") if source else None
        intent_after = read_intent()
        if intent_before != intent_after:
            raise RuntimeError("ambient control changed during snapshot")
        if status is not None:
            choice(status)
            if intent_after and choice(intent_after) != choice(status):
                raise RuntimeError("ambient user intent has not settled to current state")
    except (urllib.error.URLError, TimeoutError, socket.timeout):
        if source:
            raise RuntimeError("live app API unavailable; stopped before termination; receipt: " + str(path)
                               + "; --restart-without-ambient-restore requires explicit one-operation authorization") from None
        status = None
        intent_after = read_intent()
    if source is None and Path(path).exists():
        receipt = load_receipt(path, app_bin)
        if receipt["restore_attempted"] or receipt["intent_revision"] is None:
            raise RuntimeError("restart receipt cannot be automatically replayed")
        if binary_uuid(target_bin) != receipt["target_uuid"]:
            raise RuntimeError("recovery target differs from interrupted operation")
        intent_matches(receipt)
        # No app is alive to accept a newer GUI control; the durable revision
        # fences any control received before the source or replacement exited.
        return
    state_kind = "known" if status is not None else "not_applicable" if source else "unknown"
    state_source = "live_status" if source else "unavailable"
    if source is None and intent_after is not None:
        choice(intent_after)
        status = intent_after
        state_kind = "known"
        state_source = "durable_user_intent"
    captured_at = datetime.now(timezone.utc)
    value = {
        "schema": 1, "operation": str(uuid.uuid4()),
        "capturedAt": captured_at.isoformat(),
        "expiresAt": (captured_at + timedelta(seconds=RECEIPT_SECONDS)).isoformat(),
        "app_identity": app_identity(app_bin), "source_process": source,
        "source_uuid": binary_uuid(app_bin), "target_uuid": binary_uuid(target_bin),
        "intent_revision": intent_after["revision"] if intent_after else None,
        "state": None if status is None else {key: status[key] for key in ("captureState", "streaming")},
        "state_kind": state_kind, "state_source": state_source,
        "phase": "prepared", "restore_attempted": False,
    }
    if Path(path).exists():
        old = private_json(path)
        old["phase"] = "superseded"
        atomic_json(str(path) + ".previous", old)
    atomic_json(path, value)  # Must complete before the caller sends SIGTERM.


def finish(path, app_bin):
    receipt = load_receipt(path, app_bin)
    process = process_for(app_bin)
    if process is None or process == receipt["source_process"]:
        raise RuntimeError("replacement process identity not established")
    if binary_uuid(app_bin) != receipt["target_uuid"]:
        raise RuntimeError("installed replacement differs from restart target")
    if receipt["restore_attempted"]:
        raise RuntimeError("earlier restore POST outcome uncertain; not retried")
    intent_matches(receipt)

    def mark_post():
        receipt["restore_attempted"] = True
        atomic_json(path, receipt)

    kind = receipt.get("state_kind", "known" if receipt["state"] is not None else "unknown")
    if kind == "not_applicable":
        if request("/status") is not None:
            raise UnverifiedAmbientState("ambient availability changed; pre-restart choice unknown")
        outcome = "not_applicable"
    else:
        before = None if receipt["state"] is None else choice(receipt["state"])
        outcome = restore(before, guard=lambda: intent_matches(receipt), before_post=mark_post)
    receipt["outcome"] = outcome
    receipt["phase"] = "consumed"
    atomic_json(path, receipt)
    os.replace(path, str(path) + ".consumed")
    print("Ambient control outcome: " + outcome + "; receipt consumed. Audio delivery is observed separately.")


def run_locked(project, script, arguments):
    path = Path(project) / ".local/ambient-restart.lock"
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise RuntimeError("another canonical local restart owns the receipt") from None
    os.set_inheritable(fd, True)
    os.environ["CLAWGATE_RESTART_LOCK"] = str(Path(project).resolve())
    os.execv("/bin/bash", ["/bin/bash", script, *arguments])


def main():
    if len(sys.argv) >= 4 and sys.argv[1] == "run-locked":
        run_locked(sys.argv[2], sys.argv[3], sys.argv[4:])
        return
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("snapshot", "prepare", "stopped", "launched", "finish"))
    parser.add_argument("--receipt")
    parser.add_argument("--app-bin")
    parser.add_argument("--target-bin")
    parser.add_argument("--without-restore", action="store_true")
    parser.add_argument("--existing-receipt", action="store_true")
    args = parser.parse_args()
    if args.action == "snapshot":
        print(json.dumps(snapshot(), separators=(",", ":")))
    elif args.action == "prepare":
        prepare(args.receipt, args.app_bin, args.target_bin, args.without_restore, args.existing_receipt)
    elif args.action == "finish":
        finish(args.receipt, args.app_bin)
    else:
        receipt = load_receipt(args.receipt, args.app_bin)
        if args.action == "stopped" and process_for(args.app_bin) is not None:
            raise RuntimeError("old application is still alive")
        receipt["phase"] = args.action
        atomic_json(args.receipt, receipt)


if __name__ == "__main__":
    try:
        main()
    except UnverifiedAmbientState as error:
        print("Ambient restoration unverified: " + str(error) + "; receipt retained.", file=sys.stderr)
        sys.exit(3)
    except Exception as error:
        reason = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print("Ambient restart preservation failed: " + reason, file=sys.stderr)
        sys.exit(1)
