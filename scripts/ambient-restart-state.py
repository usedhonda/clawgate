#!/usr/bin/env python3
"""Preserve the local microphone/stream choice across a canonical restart."""

import json
import sys
import time
import urllib.error
import urllib.request


BASE = "http://127.0.0.1:8765/v1/ambient"


def request(path, method="GET"):
    req = urllib.request.Request(BASE + path, method=method)
    try:
        with urllib.request.urlopen(req, timeout=3) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 403:
            payload = json.load(error)
            if (payload.get("error") or {}).get("code") == "ambient_unavailable":
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


def restore(before, timeout=45):
    if before is None:
        return
    if set(before) != {"capturing", "streaming"} or any(type(v) is not bool for v in before.values()):
        raise RuntimeError("invalid ambient restart snapshot")
    deadline = time.monotonic() + timeout
    resumed = False
    while True:
        status = request("/status")
        if status is None:
            raise RuntimeError("ambient became unavailable after restart")
        current = choice(status)
        capturing = current["capturing"]
        streaming = current["streaming"]
        if not before["capturing"]:
            if capturing or streaming != before["streaming"]:
                raise RuntimeError("ambient inactive choice changed after restart")
            return  # Never open a microphone that was intentionally inactive.
        if status.get("autoResumeBlockedReason"):
            raise RuntimeError("ambient safety inhibit prevents restoration")
        if status.get("backendPhase") in ("failed", "timedOut"):
            raise RuntimeError("ambient backend failed during restoration")
        if streaming and not before["streaming"]:
            raise RuntimeError("transcription unexpectedly enabled after restart")
        if not resumed and (not capturing or streaming != before["streaming"]):
            route = "/stream/start" if before["streaming"] else "/capture/resume"
            if request(route, "POST") is None:
                raise RuntimeError("ambient restoration was not acknowledged")
            resumed = True  # An uncertain/failed POST is never retried.
        elif capturing and streaming == before["streaming"] and status.get("backendPhase") == "running":
            # Capture-only status deliberately hides tap liveness. A new process's
            # finalized chunk is direct audio-delivery evidence in either mode.
            age = status.get("secondsSinceLastChunk", -1)
            if status.get("chunksSurfaced", 0) > 0 and 0 <= age <= 35:
                return
        if time.monotonic() >= deadline:
            raise RuntimeError("ambient restoration lacks fresh audio delivery")
        time.sleep(1)


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "snapshot":
        print(json.dumps(snapshot(), separators=(",", ":")))
    elif len(sys.argv) == 3 and sys.argv[1] == "restore":
        restore(json.loads(sys.argv[2]))
        print("Ambient pre-restart choice verified (fresh audio required when active).")
    else:
        raise RuntimeError("usage: ambient-restart-state.py snapshot | restore <snapshot>")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        reason = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print("Ambient restart preservation failed: " + reason, file=sys.stderr)
        sys.exit(1)
