import fcntl
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time
import unittest


CONTROLLER = Path(__file__).resolve().parents[1] / "power-mode/power-mode-control.sh"
BASELINE = {
    "low_power": "0",
    "wifi_on": "1",
    "bluetooth_on": "1",
    "wifi_scan_always_enabled": "1",
}
FAKE = r"""
import json
import os
from pathlib import Path
import sys
root = Path(os.environ['FAKE_ANDROID'])
name = Path(sys.argv[0]).name
args = sys.argv[1:]
key = ':'.join([name, *args])
with (root / 'calls').open('a') as stream:
    stream.write(key + '\n')
faults = json.loads((root / 'faults').read_text())
if faults.get(key, 0):
    faults[key] -= 1
    (root / 'faults').write_text(json.dumps(faults))
    if faults[key] == 0:
        sys.exit(1)
if name == 'id':
    print(os.environ.get('FAKE_UID', '0'))
    sys.exit(0)
if name in ('sync', 'sleep'):
    sys.exit(0)
guard = json.loads((root / 'guard').read_text())
if name == 'dumpsys':
    assert args[:2] == ['-t', '5'], args
    args = args[2:]
    if args == ['power']:
        print(guard.get('power_output', '  mWakefulness=' + guard['wake']))
    elif args == ['battery']:
        print(guard.get('battery_output', '  AC powered: ' + str(guard['charging']).lower() + '\n  USB powered: false\n  Wireless powered: false\n  Dock powered: false'))
    elif args == ['display']:
        print(guard.get('display_output', 'DisplayDeviceInfo type INTERNAL state OFF' + ('\nDisplayDeviceInfo type EXTERNAL state ON' if guard['external'] else '')))
    else:
        raise AssertionError(args)
    sys.exit(0)
db_file = root / 'settings'
db = json.loads(db_file.read_text())
if name == 'settings':
    action, namespace, setting, *values = args
    assert namespace == 'global'
    if action == 'get':
        print(db.get(setting, 'null'))
        sys.exit(0)
    if action == 'put':
        db[setting] = values[0]
    elif action == 'delete':
        db.pop(setting, None)
    else:
        raise AssertionError(args)
elif name == 'cmd':
    if args[:2] == ['power', 'set-mode']:
        db['low_power'] = args[2]
    elif args[:2] == ['wifi', 'set-wifi-enabled']:
        db['wifi_on'] = '1' if args[2] == 'enabled' else '0'
    elif args[0] == 'bluetooth_manager':
        if args[1].startswith('wait-for-state:'):
            sys.exit(0)
        db['bluetooth_on'] = '1' if args[1] == 'enable' else '0'
    else:
        raise AssertionError(args)
else:
    raise AssertionError(name)
if key == os.environ.get('FAKE_WAKE_AFTER', ''):
    guard['wake'] = 'Awake'
    (root / 'guard').write_text(json.dumps(guard))
if key != os.environ.get('FAKE_IGNORE', ''):
    db_file.write_text(json.dumps(db))
"""


class ControllerTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="standby-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state = self.root / "state"
        binary = self.root / "bin"
        binary.mkdir()
        for name in ("id", "sync", "sleep", "settings", "cmd", "dumpsys"):
            file = binary / name
            file.write_text(f"#!{sys.executable}\n{FAKE}")
            file.chmod(0o755)
        (self.root / "settings").write_text(json.dumps(BASELINE))
        (self.root / "faults").write_text("{}")
        self.guard(wake="Asleep")
        self.environment = {
            **os.environ,
            "FAKE_ANDROID": str(self.root),
            "POWER_MODE_STATE_DIR": str(self.state),
            "POWER_MODE_COMMAND_PATH": f"{binary}:{os.defpath}",
        }
        self.brokers = []
        self.addCleanup(self.stop_brokers)

    def guard(self, wake="Asleep", charging=False, external=False, **output):
        (self.root / "guard").write_text(
            json.dumps(
                {"wake": wake, "charging": charging, "external": external, **output}
            )
        )

    def settings(self):
        return json.loads((self.root / "settings").read_text())

    def change(self, **values):
        (self.root / "settings").write_text(json.dumps({**self.settings(), **values}))

    def command(self, operation, success=True):
        result = subprocess.run(
            ["sh", str(CONTROLLER), operation],
            env=self.environment,
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(result.returncode == 0, success, result.stderr)
        return result.stdout.strip()

    def response(self, broker):
        self.assertTrue(
            select.select([broker.stdout], [], [], 10)[0], "broker timed out"
        )
        return broker.stdout.readline().strip()

    def broker(self):
        broker = subprocess.Popen(
            ["sh", str(CONTROLLER), "broker"],
            env=self.environment,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.brokers.append(broker)
        self.assertEqual(self.response(broker), "ready")
        return broker

    def send(self, broker, operation):
        broker.stdin.write(operation + "\n")
        broker.stdin.flush()
        return self.response(broker)

    def close(self, broker):
        broker.stdin.close()
        broker.stdin = None
        output, errors = broker.communicate(timeout=10)
        self.assertEqual(broker.returncode, 0, errors + output)
        self.brokers.remove(broker)

    def stop_brokers(self):
        for broker in self.brokers:
            if broker.poll() is None:
                if broker.stdin is not None:
                    broker.stdin.close()
                    broker.stdin = None
                try:
                    broker.communicate(timeout=10)
                except subprocess.TimeoutExpired:
                    broker.kill()
                    broker.communicate()
            else:
                broker.communicate()

    def test_capability_check_does_not_enable_policy(self):
        self.assertEqual(self.command("check"), "ready")
        self.assertFalse((self.state / "enabled").exists())
        self.assertFalse((self.state / "snapshot").exists())
        self.assertEqual(self.settings(), BASELINE)

    def test_cli_enable_does_not_apply_without_live_controller(self):
        self.assertEqual(self.command("enable"), "stopped")
        self.assertEqual(self.settings(), BASELINE)

    def test_sleep_wake_round_trip_restores_missing_scan_setting(self):
        broker = self.broker()
        self.assertEqual(self.send(broker, "enable"), "sleeping")
        self.assertEqual(
            self.settings(),
            {
                "low_power": "1",
                "wifi_on": "0",
                "bluetooth_on": "0",
                "wifi_scan_always_enabled": "0",
                "ble_scan_always_enabled": "0",
            },
        )
        self.guard(wake="Awake")
        self.assertEqual(self.send(broker, "reconcile"), "armed")
        self.assertEqual(self.settings(), BASELINE)
        self.assertEqual(self.send(broker, "disable"), "off")

    def test_unknown_or_truncated_guards_prevent_apply(self):
        broker = self.broker()
        for output in (
            {"power_output": ""},
            {"battery_output": "  AC powered: false"},
            {
                "battery_output": "  AC powered: false\n  USB powered: false\n  Wireless powered: unknown"
            },
            {"display_output": ""},
            {"display_output": "DisplayDeviceInfo type INTERNAL state UNKNOWN"},
            {
                "display_output": "DisplayDeviceInfo type INTERNAL state OFF\nDisplayDeviceInfo type EXTERNAL state UNKNOWN"
            },
        ):
            with self.subTest(output=output):
                self.guard(**output)
                self.assertEqual(self.send(broker, "enable"), "error")
                self.assertEqual(self.settings(), BASELINE)
                self.assertFalse((self.state / "snapshot").exists())

    def test_reading_snapshot_blocks_sleep_mutations(self):
        reading = self.root / "reading-mode" / "snapshot"
        reading.mkdir(parents=True)
        broker = self.broker()
        self.assertEqual(self.send(broker, "enable"), "armed")
        self.assertEqual(self.settings(), BASELINE)

    def test_shared_settings_lock_prevents_overlap(self):
        with (self.root / "power-mode-settings.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.command("enable", success=False)
        self.assertEqual(self.settings(), BASELINE)

    def test_busy_broker_with_snapshot_does_not_claim_recovery(self):
        broker = self.broker()
        self.assertEqual(self.send(broker, "enable"), "sleeping")
        self.command("recover", success=False)
        self.assertTrue((self.state / "snapshot").exists())

    def test_measurement_failure_does_not_break_policy_or_protocol(self):
        tool = self.root / "measurement"
        tool.write_text("#!/bin/sh\nprintf 'not-a-broker-response\\n'\nexit 1\n")
        tool.chmod(0o755)
        self.environment["POWER_MODE_MEASUREMENT_TOOL"] = str(tool)
        broker = self.broker()
        (self.state / "measurement").mkdir()
        (self.state / "measurement/armed").write_text("1\n")
        self.assertEqual(self.send(broker, "enable"), "sleeping")
        self.guard(wake="Awake")
        self.assertEqual(self.send(broker, "reconcile"), "armed")
        self.assertEqual(self.settings(), BASELINE)

    def test_monitor_flag_records_each_policy_without_one_shot_arming(self):
        tool = self.root / "measurement"
        tool.write_text(
            "#!/bin/sh\nprintf '%s\\n' \"$1\" >>\"$FAKE_ANDROID/monitor-calls\"\nprintf 'not-a-broker-response\\n'\n"
        )
        tool.chmod(0o755)
        self.environment["POWER_MODE_MEASUREMENT_TOOL"] = str(tool)
        self.state.mkdir()
        (self.state / "measurement-monitor").write_text("1:7\n")
        broker = self.broker()
        self.assertEqual(self.send(broker, "enable"), "sleeping")
        self.assertEqual(self.send(broker, "reconcile"), "sleeping")
        self.guard(wake="Awake")
        self.assertEqual(self.send(broker, "reconcile"), "armed")
        self.guard(wake="Asleep")
        self.assertEqual(self.send(broker, "reconcile"), "sleeping")
        calls = (self.root / "monitor-calls").read_text().splitlines()
        self.assertEqual(calls.count("start"), 2)
        self.assertEqual(calls.count("accept"), 2)
        self.assertEqual(calls.count("end"), 1)
        self.assertFalse((self.state / "measurement/armed").exists())

    def test_term_resistant_measurement_cannot_block_restoration(self):
        tool = self.root / "measurement"
        tool.write_text("#!/bin/sh\ntrap '' TERM\nexec /bin/sleep 60\n")
        tool.chmod(0o755)
        self.environment["POWER_MODE_MEASUREMENT_TOOL"] = str(tool)
        broker = self.broker()
        self.assertEqual(self.send(broker, "enable"), "sleeping")
        (self.state / "measurement").mkdir()
        (self.state / "measurement/armed").write_text("1\n")
        self.guard(wake="Awake")
        started = time.monotonic()
        self.assertEqual(self.send(broker, "reconcile"), "armed")
        self.assertLess(time.monotonic() - started, 9)
        self.assertEqual(self.settings(), BASELINE)

    def test_measurement_descendants_do_not_keep_controller_locks(self):
        tool = self.root / "measurement"
        tool.write_text(
            "#!/bin/sh\ncase $1 in\n"
            "end) printf 'capture-started\\n' >&2; trap '' TERM; exec /bin/sleep 60 ;;\n"
            'abort) rm -f "$POWER_MODE_STATE_DIR/measurement/armed" ;;\nesac\n'
        )
        tool.chmod(0o755)
        self.environment["POWER_MODE_MEASUREMENT_TOOL"] = str(tool)
        broker = self.broker()
        self.assertEqual(self.send(broker, "enable"), "sleeping")
        (self.state / "measurement").mkdir()
        (self.state / "measurement/armed").write_text("1\n")
        self.guard(wake="Awake")
        broker.stdin.write("reconcile\n")
        broker.stdin.flush()
        self.assertTrue(select.select([broker.stderr], [], [], 3)[0])
        self.assertEqual(broker.stderr.readline(), "capture-started\n")
        broker.kill()
        broker.wait(timeout=3)
        self.assertEqual(self.command("recover"), "stopped")
        self.assertEqual(self.settings(), BASELINE)

    def test_wake_during_measurement_capture_is_rechecked(self):
        tool = self.root / "measurement"
        tool.write_text(
            f"#!{sys.executable}\nimport json, os, sys\nfrom pathlib import Path\n"
            "root=Path(os.environ['FAKE_ANDROID'])\n"
            "with (root/'measure-calls').open('a') as log: log.write(sys.argv[1]+'\\n')\n"
            "if sys.argv[1]=='start':\n"
            " data=json.loads((root/'guard').read_text()); data['wake']='Awake'; (root/'guard').write_text(json.dumps(data))\n"
        )
        tool.chmod(0o755)
        self.environment["POWER_MODE_MEASUREMENT_TOOL"] = str(tool)
        broker = self.broker()
        (self.state / "measurement").mkdir()
        (self.state / "measurement/armed").write_text("1\n")
        self.assertEqual(self.send(broker, "enable"), "armed")
        self.assertEqual(self.settings(), BASELINE)
        self.assertNotIn(
            "accept", (self.root / "measure-calls").read_text().splitlines()
        )

    def test_reading_charging_and_external_display_prevent_apply(self):
        broker = self.broker()
        for guard in ({"wake": "Awake"}, {"charging": True}, {"external": True}):
            self.guard(**guard)
            self.assertEqual(self.send(broker, "enable"), "armed")
            self.assertEqual(self.settings(), BASELINE)

    def test_charger_connection_restores_active_snapshot(self):
        broker = self.broker()
        self.assertEqual(self.send(broker, "enable"), "sleeping")
        self.guard(charging=True)
        self.assertEqual(self.send(broker, "reconcile"), "armed")
        self.assertEqual(self.settings(), BASELINE)

    def test_controller_disconnect_restores_without_app(self):
        broker = self.broker()
        self.assertEqual(self.send(broker, "enable"), "sleeping")
        self.close(broker)
        self.assertEqual(self.settings(), BASELINE)
        self.assertEqual(self.command("status"), "stopped")

    def test_manual_changes_are_preserved_and_not_reasserted(self):
        self.change(wifi_on="0", low_power="1")
        broker = self.broker()
        self.assertEqual(self.send(broker, "enable"), "sleeping")
        self.change(wifi_on="1", low_power="0", wifi_scan_always_enabled="1")
        self.assertEqual(self.send(broker, "reconcile"), "sleeping")
        self.assertEqual(self.settings()["wifi_on"], "1")
        self.guard(wake="Awake")
        self.assertEqual(self.send(broker, "reconcile"), "armed")
        self.assertEqual(self.settings()["wifi_on"], "1")
        self.assertEqual(self.settings()["low_power"], "0")

    def test_wake_during_apply_reverses_stale_decision(self):
        self.environment["FAKE_WAKE_AFTER"] = "cmd:bluetooth_manager:disable"
        broker = self.broker()
        self.assertEqual(self.send(broker, "enable"), "armed")
        self.assertEqual(self.settings(), BASELINE)

    def test_apply_failure_rolls_back(self):
        (self.root / "faults").write_text(
            json.dumps({"cmd:wifi:set-wifi-enabled:disabled": 1})
        )
        broker = self.broker()
        self.assertEqual(self.send(broker, "enable"), "error")
        self.assertEqual(self.settings(), BASELINE)
        self.assertFalse((self.state / "snapshot").exists())

    def test_silent_command_failure_rolls_back(self):
        self.environment["FAKE_IGNORE"] = "cmd:power:set-mode:1"
        broker = self.broker()
        self.assertEqual(self.send(broker, "enable"), "error")
        self.assertEqual(self.settings(), BASELINE)

    def test_wake_after_last_mutation_is_also_restored(self):
        self.environment["FAKE_WAKE_AFTER"] = "cmd:wifi:set-wifi-enabled:disabled"
        broker = self.broker()
        self.assertEqual(self.send(broker, "enable"), "armed")
        self.assertEqual(self.settings(), BASELINE)

    def test_bluetooth_completion_failure_rolls_back(self):
        (self.root / "faults").write_text(
            json.dumps({"cmd:bluetooth_manager:wait-for-state:STATE_OFF": 1})
        )
        broker = self.broker()
        self.assertEqual(self.send(broker, "enable"), "error")
        self.assertEqual(self.settings(), BASELINE)

    def test_unknown_guard_restores_instead_of_applying(self):
        broker = self.broker()
        self.assertEqual(self.send(broker, "enable"), "sleeping")
        self.guard(wake="Unknown")
        self.assertEqual(self.send(broker, "reconcile"), "error")
        self.assertEqual(self.settings(), BASELINE)

    def test_invalid_setting_stops_before_mutation(self):
        self.change(bluetooth_on="2")
        before = self.settings()
        broker = self.broker()
        self.assertEqual(self.send(broker, "enable"), "error")
        self.assertEqual(self.settings(), before)

    def test_failed_restore_retains_snapshot_and_retries(self):
        broker = self.broker()
        self.assertEqual(self.send(broker, "enable"), "sleeping")
        (self.root / "faults").write_text(
            json.dumps({"cmd:wifi:set-wifi-enabled:enabled": 1})
        )
        self.guard(wake="Awake")
        self.assertEqual(self.send(broker, "reconcile"), "error")
        self.assertEqual(self.command("status"), "recovery")
        self.assertEqual(self.send(broker, "reconcile"), "armed")
        self.assertEqual(self.settings(), BASELINE)

    def test_crashed_broker_snapshot_is_restored_before_new_handshake(self):
        broker = self.broker()
        self.assertEqual(self.send(broker, "enable"), "sleeping")
        broker.kill()
        broker.wait(timeout=5)
        self.assertTrue((self.state / "snapshot").exists())
        self.assertEqual(self.command("status"), "recovery")
        self.guard(wake="Awake")
        replacement = self.broker()
        self.assertEqual(self.settings(), BASELINE)
        self.assertEqual(self.send(replacement, "status"), "armed")

    def test_second_broker_cannot_take_over(self):
        broker = self.broker()
        self.assertEqual(self.send(broker, "enable"), "sleeping")
        self.command("broker", success=False)
        self.assertEqual(self.settings()["wifi_on"], "0")

    def test_invalid_snapshot_is_not_discarded(self):
        self.state.mkdir()
        snapshot = self.state / "snapshot"
        snapshot.mkdir()
        (snapshot / "schema").write_text("999\n")
        self.command("recover", success=False)
        self.assertTrue(snapshot.exists())

    def test_journal_sync_failures_do_not_report_success(self):
        for failure in (1, 2, 3, 4, 5, 6):
            with self.subTest(sync=failure):
                broker = self.broker()
                (self.root / "faults").write_text(json.dumps({"sync": failure}))
                self.assertEqual(self.send(broker, "enable"), "error")
                (self.root / "faults").write_text("{}")
                self.close(broker)
                self.assertEqual(self.settings(), BASELINE)


if __name__ == "__main__":
    unittest.main()
