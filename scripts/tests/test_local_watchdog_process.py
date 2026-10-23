"""Exercise the real watchdog without launching or restarting any application."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class LocalWatchdogProcessTests(unittest.TestCase):
    def test_normal_and_native_probe_are_not_treated_as_missing(self):
        script = Path(__file__).resolve().parents[1] / "local-clawgate-watchdog.sh"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            pgrep = bin_dir / "pgrep"
            pgrep.write_text("#!" + sys.executable + "\nimport os,re,sys\nsys.exit(0 if re.search(sys.argv[2], os.environ['TEST_APP_ARGV']) else 1)\n")
            pgrep.chmod(0o700)
            curl = bin_dir / "curl"
            curl.write_text('#!/bin/sh\nprintf \'{"ok":true}\\n\'\n')
            curl.chmod(0o700)
            for suffix in ["", " --native-input-probe /fixture/.local/probe"]:
                with self.subTest(suffix=suffix):
                    env = dict(os.environ, HOME=str(root), PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
                               TEST_APP_ARGV="/fixture/ClawGate.app/Contents/MacOS/ClawGate" + suffix,
                               WATCHDOG_FUNCTIONAL_CHECK="0", WATCHDOG_AMBIENT_CHECK="0")
                    result = subprocess.run(["/bin/bash", str(script)], env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    log = root / ".clawgate/logs/watchdog.log"
                    self.assertFalse(log.exists(), "A healthy process must not enter the restart path")


if __name__ == "__main__":
    unittest.main()
