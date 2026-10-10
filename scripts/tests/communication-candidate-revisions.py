#!/usr/bin/env python3
"""Separate source/target pins and symlink rejection; no host operations."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

validator = Path(__file__).resolve().parents[1] / "communication-candidate.py"
with tempfile.TemporaryDirectory(prefix="clawgate-candidate-") as tmp:
    base = Path(tmp)
    source, target = base / "source", base / "target"
    for root, text in ((source, "candidate"), (target, "previous")):
        root.mkdir()
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        (root / "file.txt").write_text(text)
        subprocess.run(["git", "-C", str(root), "add", "file.txt"], check=True)
        subprocess.run(["git", "-C", str(root), "-c", "user.name=Fixture", "-c",
                        "user.email=fixture@example.invalid", "commit", "-qm", "fixture"], check=True)
    head = lambda root: subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
    stage = target / "stage"
    stage.mkdir()
    (stage / "file.txt").write_bytes((source / "file.txt").read_bytes())
    manifest = {"version": 2, "source_revision": head(source), "target_base_revision": head(target),
                "files": [{"path": "file.txt", "sha256": hashlib.sha256((source / "file.txt").read_bytes()).hexdigest()}]}
    assert manifest["source_revision"] != manifest["target_base_revision"]
    def run(cwd, root, value):
        path = root / "candidate.json"
        path.write_text(json.dumps(value))
        return subprocess.run(["python3", str(validator), "--manifest", str(path), "--root", str(root)],
                              cwd=cwd, capture_output=True, text=True)
    assert run(source, source, manifest).returncode == 0
    assert run(target, stage, manifest).returncode == 0
    bad = {**manifest, "target_base_revision": manifest["source_revision"]}
    assert "target_base_revision_mismatch" in run(target, stage, bad).stderr
    (stage / "file.txt").unlink()
    (stage / "file.txt").symlink_to(source / "file.txt")
    assert run(target, stage, manifest).returncode != 0
print("candidate independent revisions and symlink rejection: PASS")
