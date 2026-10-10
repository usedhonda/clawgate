#!/usr/bin/env python3
"""Validate a bounded, inert communication candidate manifest."""
import hashlib
import json
import pathlib
import subprocess
import sys


def fail(message):
    raise SystemExit(f"candidate rejected: {message}")


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in {"--manifest", "--files-from"}:
        fail("usage: communication-candidate.py --manifest PATH|--files-from PATH")
    manifest_path = pathlib.Path(sys.argv[2]).resolve()
    if sys.argv[1] == "--files-from":
        manifest_path = pathlib.Path(sys.argv[2]).resolve()
        manifest = json.loads(manifest_path.read_text())
    else:
        manifest = json.loads(manifest_path.read_text())
    if set(manifest) != {"version", "base_revision", "files"} or manifest["version"] != 1:
        fail("schema")
    try:
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        fail("git_head_unavailable")
    if manifest["base_revision"] != head:
        fail("base_revision_mismatch")
    files = manifest["files"]
    if not isinstance(files, list) or not files:
        fail("files_missing")
    root = pathlib.Path.cwd().resolve()
    out = []
    for item in files:
        if not isinstance(item, dict) or set(item) != {"path", "sha256"}:
            fail("file_schema")
        rel = item["path"]
        if not isinstance(rel, str) or not rel or rel.startswith("/") or "/../" in f"/{rel}/" or rel.startswith("../"):
            fail("file_path")
        if rel.startswith(".local/secrets/") or rel in {".env", ".env.local"}:
            fail("secret_path")
        path = (root / rel).resolve()
        if not path.is_relative_to(root) or not path.is_file() or path.is_symlink():
            fail("file_missing_or_symlink")
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != item["sha256"]:
            fail("file_hash_mismatch")
        out.append(rel)
    if len(set(out)) != len(out):
        fail("duplicate_file")
    print("\n".join(out))


if __name__ == "__main__":
    main()
