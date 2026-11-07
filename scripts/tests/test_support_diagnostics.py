import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


class SupportDiagnosticsTests(unittest.TestCase):
    def test_bundle_is_private_and_does_not_collect_process_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / "project" / "scripts"
            scripts.mkdir(parents=True)
            source = Path(__file__).resolve().parents[1] / "support-diagnostics.sh"
            script = scripts / source.name
            shutil.copyfile(source, script)
            fakebin = root / "bin"
            fakebin.mkdir()
            # A support bundle must work with standard OS tools, without rg or
            # other developer utilities inherited from the caller's PATH.
            for name in ("dirname", "date", "mktemp", "ls", "head", "tail", "grep"):
                (fakebin / name).symlink_to(shutil.which(name))
            bash = shutil.which("bash")
            commands = {
                "curl": '#!/bin/sh\ncase "$*" in *"--connect-timeout 2 --max-time 10"*) echo health-ok;; *) exit 71;; esac\n',
                "ps": '#!/bin/sh\n[ "$*" = "-axo pid=,ppid=,comm=" ] || { echo unexpected-argv-collection; exit 72; }\necho "123 1 /Applications/ClawGate.app/Contents/MacOS/ClawGate"\n',
            }
            for name, content in commands.items():
                executable = fakebin / name
                executable.write_text(content)
                executable.chmod(0o755)
            env = dict(os.environ, PATH=str(fakebin), TMPDIR=str(root))
            result = subprocess.run([bash, str(script)], env=env, text=True, capture_output=True, timeout=10, check=True)
            output = Path(result.stdout.strip())
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(output.parent.stat().st_mode), 0o700)
            body = output.read_text()
            self.assertIn("123 1 /Applications/ClawGate.app/Contents/MacOS/ClawGate", body)
            self.assertEqual(body.count("health-ok"), 3)
            self.assertNotIn("unexpected-argv-collection", body)
            self.assertNotIn("curl_failed", body)
            second = subprocess.run([bash, str(script)], env=env, text=True, capture_output=True, timeout=10, check=True)
            self.assertNotEqual(second.stdout.strip(), str(output))


if __name__ == "__main__":
    unittest.main()
