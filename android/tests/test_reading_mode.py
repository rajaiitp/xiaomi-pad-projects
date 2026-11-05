import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


CONTROLLER = Path(__file__).resolve().parents[1] / "reading-mode.sh"
BASELINE = {
    "secure/night_display_auto_mode": "2",
    "secure/night_display_activated": "0",
    "secure/night_display_color_temperature": "2596",
    "global/low_power": "0",
    "global/wifi_on": "1",
    "global/bluetooth_on": "1",
    "global/zen_mode": "0",
    "global/wifi_scan_always_enabled": "1",
}
FAKE_COMMAND = r"""
import json
import os
from pathlib import Path
import sys

name = Path(sys.argv[0]).name
args = sys.argv[1:]
root = Path(os.environ["FAKE_ANDROID_ROOT"])
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps([name, *args]) + "\n")
key = ":".join([name, *args])
fault_file = root / "faults.json"
faults = json.loads(fault_file.read_text())
if faults.get(key, 0):
    faults[key] -= 1
    fault_file.write_text(json.dumps(faults))
    if faults[key] == 0:
        sys.exit(1)
if key == os.environ.get("FAKE_IGNORE", ""):
    sys.exit(0)
if name == "id":
    print(os.environ.get("FAKE_UID", "0"))
    sys.exit(0)
if name in ("sleep", "sync"):
    sys.exit(0)
db_file = root / "settings.json"
db = json.loads(db_file.read_text())
if name == "settings":
    assert args[:2] == ["--user", "0"], args
    action, namespace, setting, *values = args[2:]
    setting_key = namespace + "/" + setting
    if action == "get":
        print(db.get(setting_key, "null"))
        sys.exit(0)
    if action == "put":
        db[setting_key] = values[0]
    elif action == "delete":
        db.pop(setting_key, None)
    else:
        raise AssertionError(args)
elif name == "cmd":
    if args == ["activity", "get-current-user"]:
        print("0")
        sys.exit(0)
    if args[:2] == ["power", "set-mode"]:
        db["global/low_power"] = args[2]
    elif args[:2] == ["wifi", "set-wifi-enabled"]:
        db["global/wifi_on"] = "1" if args[2] == "enabled" else "0"
    elif args[0] == "bluetooth_manager":
        if args[1].startswith("wait-for-state:"):
            sys.exit(0)
        db["global/bluetooth_on"] = "1" if args[1] == "enable" else "0"
    elif args[:2] == ["notification", "set_dnd"]:
        db["global/zen_mode"] = {"all": "0", "priority": "1", "none": "2", "alarms": "3"}[args[2]]
    else:
        raise AssertionError(args)
    print("command accepted")
else:
    raise AssertionError(name)
db_file.write_text(json.dumps(db))
"""


class ReadingModeTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="reading-mode-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state = self.root / "state"
        binary = self.root / "bin"
        binary.mkdir()
        for name in ("settings", "cmd", "id", "sync", "sleep"):
            file = binary / name
            file.write_text(f"#!{sys.executable}\n{FAKE_COMMAND}")
            file.chmod(0o755)
        self.database = self.root / "settings.json"
        self.database.write_text(json.dumps(BASELINE))
        (self.root / "faults.json").write_text("{}")
        self.environment = {
            **os.environ,
            "READING_MODE_COMMAND_PATH": f"{binary}:{os.defpath}",
            "READING_MODE_STATE_DIR": str(self.state),
            "FAKE_ANDROID_ROOT": str(self.root),
        }

    def run_controller(self, operation, success=True):
        result = subprocess.run(
            ["sh", str(CONTROLLER), operation],
            env=self.environment,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def settings(self):
        return json.loads(self.database.read_text())

    def calls(self):
        return [
            json.loads(line)
            for line in (self.root / "calls.jsonl").read_text().splitlines()
        ]

    def fault(self, command, count=1):
        (self.root / "faults.json").write_text(json.dumps({command: count}))

    def test_initial_status_and_check_do_not_change_settings(self):
        self.assertEqual(self.run_controller("status").stdout, "off\n")
        self.assertEqual(self.run_controller("check").stdout, "ready\n")
        self.assertFalse(self.state.exists())
        self.assertEqual(self.settings(), BASELINE)
        self.assertEqual([call[0] for call in self.calls()], ["id", "id"])

    def test_round_trip_restores_exact_values_and_absent_settings(self):
        self.assertEqual(self.run_controller("toggle").stdout, "on\n")
        self.assertEqual(self.run_controller("status").stdout, "on\n")
        enabled = self.settings()
        for setting in (
            "wifi_on",
            "bluetooth_on",
            "wifi_scan_always_enabled",
            "ble_scan_always_enabled",
        ):
            self.assertEqual(enabled[f"global/{setting}"], "0")
        self.assertEqual(enabled["global/low_power"], "1")
        self.assertEqual(enabled["global/zen_mode"], "3")
        self.assertEqual(enabled["secure/night_display_activated"], "1")
        self.assertEqual(enabled["secure/night_display_auto_mode"], "0")
        self.assertEqual(enabled["secure/night_display_color_temperature"], "2596")
        self.assertEqual(self.run_controller("toggle").stdout, "off\n")
        self.assertEqual(self.settings(), BASELINE)
        self.assertFalse((self.state / "snapshot").exists())

    def test_radios_disconnect_only_after_other_changes(self):
        self.run_controller("toggle")
        commands = [call for call in self.calls() if call[0] == "cmd"]
        self.assertEqual(commands[-1], ["cmd", "wifi", "set-wifi-enabled", "disabled"])
        self.assertLess(
            commands.index(["cmd", "power", "set-mode", "1"]),
            commands.index(["cmd", "bluetooth_manager", "disable"]),
        )
        mutations = [
            index
            for index, call in enumerate(self.calls())
            if call[0] == "settings" and call[3] == "put"
        ]
        self.assertGreaterEqual(
            sum(call[0] == "sync" for call in self.calls()[: mutations[0]]), 2
        )
        self.assertEqual((self.state / "snapshot").stat().st_mode & 0o777, 0o700)
        self.assertEqual(
            (self.state / "snapshot" / "wifi_on").stat().st_mode & 0o777, 0o600
        )

    def test_existing_stricter_settings_are_not_weakened(self):
        baseline = {
            **BASELINE,
            "global/zen_mode": "2",
            "global/low_power": "1",
            "global/wifi_on": "0",
            "global/bluetooth_on": "0",
        }
        self.database.write_text(json.dumps(baseline))
        self.run_controller("toggle")
        self.assertEqual(self.settings()["global/zen_mode"], "2")
        self.run_controller("toggle")
        self.assertEqual(self.settings(), baseline)

    def test_failure_before_radio_changes_rolls_back(self):
        self.fault("cmd:power:set-mode:1")
        self.run_controller("toggle", success=False)
        self.assertEqual(self.settings(), BASELINE)
        self.assertFalse((self.state / "snapshot").exists())
        self.assertFalse(
            any(
                call[:3] == ["cmd", "wifi", "set-wifi-enabled"] for call in self.calls()
            )
        )

    def test_silent_command_failure_is_detected(self):
        self.environment["FAKE_IGNORE"] = "cmd:power:set-mode:1"
        result = self.run_controller("toggle", success=False)
        self.assertIn("did not settle", result.stderr)
        self.assertEqual(self.settings(), BASELINE)

    def test_wifi_failure_restores_already_changed_bluetooth(self):
        self.fault("cmd:wifi:set-wifi-enabled:disabled")
        self.run_controller("toggle", success=False)
        self.assertEqual(self.settings(), BASELINE)
        self.assertIn(["cmd", "bluetooth_manager", "enable"], self.calls())

    def test_failed_restore_keeps_snapshot_for_next_tap(self):
        self.run_controller("toggle")
        self.fault("cmd:bluetooth_manager:enable")
        self.run_controller("toggle", success=False)
        self.assertEqual(self.run_controller("status").stdout, "recovery\n")
        self.assertEqual(self.run_controller("toggle").stdout, "off\n")
        self.assertEqual(self.settings(), BASELINE)

    def test_failed_rollback_keeps_snapshot_for_recovery(self):
        self.fault("cmd:wifi:set-wifi-enabled:disabled")
        self.environment["FAKE_IGNORE"] = "cmd:bluetooth_manager:enable"
        self.run_controller("toggle", success=False)
        self.assertEqual(self.run_controller("status").stdout, "recovery\n")
        self.environment.pop("FAKE_IGNORE")
        self.run_controller("toggle")
        self.assertEqual(self.settings(), BASELINE)

    def test_reboot_interrupted_activation_restores_instead_of_reenabling(self):
        self.run_controller("toggle")
        (self.state / "snapshot" / "phase").write_text("prepared\n")
        self.assertEqual(self.run_controller("status").stdout, "recovery\n")
        self.assertEqual(self.run_controller("toggle").stdout, "off\n")
        self.assertEqual(self.settings(), BASELINE)

    def test_invalid_snapshot_is_not_executed_or_discarded(self):
        self.run_controller("toggle")
        snapshot = self.state / "snapshot"
        (snapshot / "wifi_on").write_text("$(touch /tmp/reading-mode-unsafe)\n")
        before = self.settings()
        self.run_controller("status", success=False)
        self.run_controller("toggle", success=False)
        self.assertEqual(self.settings(), before)
        self.assertTrue(snapshot.exists())

    def test_unrecognized_radio_state_stops_before_changing_anything(self):
        baseline = {**BASELINE, "global/wifi_on": "3"}
        self.database.write_text(json.dumps(baseline))
        self.run_controller("toggle", success=False)
        self.assertEqual(self.settings(), baseline)
        self.assertFalse((self.state / "snapshot").exists())

    def test_snapshot_write_failure_stops_before_settings_changes(self):
        self.fault("sync")
        self.run_controller("toggle", success=False)
        self.assertEqual(self.settings(), BASELINE)
        self.assertFalse((self.state / "snapshot").exists())

    def test_final_commit_failure_rolls_back_instead_of_reporting_success(self):
        self.fault("sync", count=4)
        self.run_controller("toggle", success=False)
        self.assertEqual(self.settings(), BASELINE)
        self.assertFalse((self.state / "snapshot").exists())

    def test_unset_night_settings_are_restored_as_absent(self):
        baseline = dict(BASELINE)
        baseline.pop("secure/night_display_auto_mode")
        baseline.pop("secure/night_display_activated")
        self.database.write_text(json.dumps(baseline))
        self.run_controller("toggle")
        self.run_controller("toggle")
        self.assertEqual(self.settings(), baseline)

    def test_sleep_snapshot_prevents_overlapping_activation(self):
        (self.root / "power-mode" / "snapshot").mkdir(parents=True)
        result = self.run_controller("toggle", success=False)
        self.assertIn("Sleep mode restoration", result.stderr)
        self.assertEqual(self.settings(), BASELINE)
        self.assertFalse((self.state / "snapshot").exists())

    def test_shared_power_lock_prevents_activation_during_restoration(self):
        with (self.root / "power-mode-settings.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_controller("toggle", success=False)
        self.assertIn("Another power controller", result.stderr)
        self.assertEqual(self.settings(), BASELINE)

    def test_concurrent_toggle_is_rejected_without_mutation(self):
        self.run_controller("toggle")
        before = self.settings()
        with (self.state / "lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.run_controller("toggle", success=False)
        self.assertEqual(self.settings(), before)

    def test_nonroot_and_unknown_operations_are_rejected(self):
        self.run_controller("on", success=False)
        self.environment["FAKE_UID"] = "1000"
        self.run_controller("toggle", success=False)
        self.assertEqual(self.settings(), BASELINE)
        self.assertFalse(self.state.exists())


if __name__ == "__main__":
    unittest.main()
