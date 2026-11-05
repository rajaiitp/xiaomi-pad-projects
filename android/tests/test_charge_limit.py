import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "power-mode/remove-charge-limit.sh"


class ChargeLimitTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.service = self.root / "service.d/charge-threshold.sh"
        self.service.parent.mkdir()
        self.service.write_text("original service\n")
        self.state = self.root / "state"
        self.state.mkdir()
        (self.state / "paused").write_text("owned\n")
        self.switch = self.root / "charging_enabled"
        self.switch.write_text("0\n")
        binary = self.root / "bin"
        binary.mkdir()
        for name, body in {
            "id": "printf '0\\n'",
            "ps": "printf 'PID ARGS\\n'",
            "sync": ":",
        }.items():
            file = binary / name
            file.write_text(f"#!/bin/sh\n{body}\n")
            file.chmod(0o755)
        self.environment = {
            **os.environ,
            "PATH": f"{binary}:{os.defpath}",
            "CHARGE_LIMIT_SERVICE": str(self.service),
            "CHARGE_LIMIT_STATE": str(self.state),
            "CHARGE_LIMIT_SWITCH": str(self.switch),
            "POWER_MODE_BACKUPS": str(self.root / "backups"),
        }

    def run_script(self):
        return subprocess.run(
            ["sh", str(SCRIPT)],
            env=self.environment,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

    def test_removal_preserves_backup_and_resumes_charging(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("charge_limit=100", result.stdout)
        self.assertFalse(self.service.exists())
        self.assertFalse((self.state / "paused").exists())
        self.assertEqual(self.switch.read_text(), "1\n")
        backups = list((self.root / "backups").glob("*/charge-threshold.sh"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), "original service\n")
        self.assertEqual((backups[0].parent / "paused").read_text(), "owned\n")

    def test_repeated_removal_is_safe(self):
        self.assertEqual(self.run_script().returncode, 0)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.switch.read_text(), "1\n")

    def test_missing_switch_retains_recovery_marker(self):
        self.switch.unlink()
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.state / "paused").exists())
        self.assertTrue(list((self.root / "backups").glob("*/charge-threshold.sh")))


if __name__ == "__main__":
    unittest.main()
