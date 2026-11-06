import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / "power-mode/install-pipa.sh"
BOOT = Path(__file__).resolve().parents[1] / "power-mode/recover-on-boot.sh"
PACKAGE = "local.power.mode"
UID = 10194
FAKE = r"""
import json
import os
from pathlib import Path
import re
import shutil
import sys
root = Path(os.environ['FAKE_INSTALL'])
name = Path(sys.argv[0]).name
args = sys.argv[1:]
state_file = root / 'platform.json'
state = json.loads(state_file.read_text())
key = name
if name == 'pm': key = 'pm:' + args[0]
if name == 'am': key = 'am:' + args[0]
if name == 'controller-op': key = 'controller:' + args[0]
if name == 'magisk' and args[1].startswith('INSERT OR REPLACE'): key = 'magisk:grant'
if name == 'restorecon': key = 'restorecon:' + Path(args[-1]).name
with (root / 'calls').open('a') as log:
    log.write(key + ':' + os.environ.get('LABEL', '') + '\n')
state['counts'][key] = state['counts'].get(key, 0) + 1
state_file.write_text(json.dumps(state))
if state['faults'].get(key) == state['counts'][key]: sys.exit(1)
if name == 'id': print('0')
elif name == 'getprop': print('pipa' if args == ['ro.product.device'] else '1')
elif name in ('chown', 'restorecon', 'sleep', 'sync'): pass
elif name == 'cmd':
    if args == ['activity', 'get-current-user']: print('0')
    elif '-U' in args:
        print('package:local.power.mode uid:10194')
        if '--uid' in args and state.get('shared_uid', False): print('package:other.app uid:10194')
    else: print('package:local.power.mode')
elif name == 'pm':
    if args[0] == 'path': print('package:' + str(root / 'app.apk'))
    elif args[0] == 'install':
        if (root / 'app.apk').read_text() == 'new-apk' and Path(args[-1]).read_text() == 'old-apk' and '-d' not in args:
            print('Failure [INSTALL_FAILED_VERSION_DOWNGRADE]')
            sys.exit(1)
        shutil.copyfile(args[-1], root / 'app.apk')
        print('Success')
    else: raise AssertionError(args)
elif name == 'magisk':
    sql = args[1]
    if sql.startswith('SELECT'):
        if state['policy'] is not None:
            print('|'.join(k + '=' + str(v) for k,v in zip(('uid','policy','until','logging','notification'), state['policy'])))
    elif sql.startswith('BEGIN IMMEDIATE'):
        match = re.search(r'VALUES\(([-0-9,]+)\)', sql)
        state['policy'] = [int(value) for value in match[1].split(',')] if match else None
        assert state['policy'] is None or state['policy'][0] == 10194
    elif sql.startswith('INSERT'):
        match = re.search(r'VALUES\(([-0-9,]+)\)', sql)
        assert match, sql
        state['policy'] = [int(value) for value in match[1].split(',')]
        assert state['policy'][0] == 10194
    else: raise AssertionError(sql)
elif name == 'am':
    state['mode'] = 'armed' if args[0] == 'start-foreground-service' and not state.get('suppress_start', False) else 'stopped'
elif name == 'controller-op':
    enabled = root / 'data/adb/power-mode/enabled'
    if args[0] == 'check': print('ready')
    elif args[0] == 'disable':
        enabled.unlink(missing_ok=True)
        state['mode'] = 'off'
        print('off')
    elif args[0] == 'recover': print('stopped' if enabled.exists() else 'off')
    elif args[0] == 'enable':
        enabled.write_text('1\n')
        state['mode'] = 'stopped'
        print('stopped')
    elif args[0] == 'status':
        print(state['mode'] if state['mode'] in ('armed','sleeping') else ('stopped' if enabled.exists() else 'off'))
    else: raise AssertionError(args)
else: raise AssertionError((name,args))
state_file.write_text(json.dumps(state))
"""


class PowerModeInstallTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sleep-install-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state = self.root / "data/adb/power-mode"
        self.state.mkdir(parents=True)
        (self.state / "enabled").write_text("1\n")
        self.control = self.root / "data/adb/power-mode-control"
        self.recovery = self.root / "data/adb/service.d/90-power-mode-recover.sh"
        self.recovery.parent.mkdir()
        self.reading = self.root / "data/adb/reading-mode-control"
        self.private = self.root / f"data/user_de/0/{PACKAGE}/files"
        self.private.mkdir(parents=True)
        self.stage = self.root / "stage"
        self.stage.mkdir()
        controller = '#!/bin/sh\nLABEL=old\nexport LABEL\nexec controller-op "$@"\n'
        self.control.write_text(controller)
        self.control.chmod(0o700)
        self.recovery.write_text("#!/bin/sh\n: old-recovery\n")
        self.reading.write_text("#!/bin/sh\n: old-reading\n")
        (self.stage / "controller").write_text(
            controller.replace("LABEL=old", "LABEL=new")
        )
        (self.stage / "recover").write_text("#!/bin/sh\n: new-recovery\n")
        (self.stage / "reading").write_text("#!/bin/sh\n: new-reading\n")
        (self.stage / "measurement").write_text("#!/bin/sh\n: new-measurement\n")
        (self.stage / "app.apk").write_text("new-apk")
        (self.root / "app.apk").write_text("old-apk")
        self.baseline = [
            self.control.read_text(),
            self.recovery.read_text(),
            self.reading.read_text(),
        ]
        self.platform = self.root / "platform.json"
        self.platform.write_text(
            json.dumps({"policy": None, "mode": "stopped", "counts": {}, "faults": {}})
        )
        binary = self.root / "bin"
        binary.mkdir()
        for name in (
            "id",
            "getprop",
            "cmd",
            "pm",
            "am",
            "magisk",
            "chown",
            "restorecon",
            "sleep",
            "sync",
            "controller-op",
        ):
            path = binary / name
            path.write_text(f"#!{sys.executable}\n{FAKE}")
            path.chmod(0o755)
        self.environment = {
            **os.environ,
            "FAKE_INSTALL": str(self.root),
            "POWER_MODE_DEVICE_ROOT": str(self.root),
            "POWER_MODE_COMMAND_PATH": f"{binary}:{os.defpath}",
        }

    def change(self, **values):
        self.platform.write_text(
            json.dumps({**json.loads(self.platform.read_text()), **values})
        )

    def run_install(self, success=False):
        result = subprocess.run(
            ["sh", str(INSTALLER), str(self.stage)],
            env=self.environment,
            capture_output=True,
            text=True,
            timeout=20,
            check=False,
        )
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def assert_rolled_back(self, policy=None):
        self.assertEqual(self.control.read_text(), self.baseline[0])
        self.assertEqual(self.recovery.read_text(), self.baseline[1])
        self.assertEqual(self.reading.read_text(), self.baseline[2])
        self.assertEqual((self.root / "app.apk").read_text(), "old-apk")
        self.assertEqual((self.state / "enabled").read_text(), "1\n")
        self.assertEqual(json.loads(self.platform.read_text())["policy"], policy)
        self.assertFalse((self.private / "maintenance").exists())

    def run_boot(self, success=True):
        result = subprocess.run(
            ["sh", str(BOOT)],
            env={
                **self.environment,
                "POWER_MODE_CONTROLLER": str(self.control),
                "POWER_MODE_STATE_DIR": str(self.state),
                "POWER_MODE_MAINTENANCE_FILE": str(self.private / "maintenance"),
            },
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(result.returncode == 0, success, result.stderr)
        return json.loads(self.platform.read_text())

    def test_boot_restores_then_starts_enabled_helper(self):
        platform = self.run_boot()
        self.assertEqual(platform["mode"], "armed")
        self.assertEqual(platform["counts"]["controller:recover"], 1)

    def test_boot_honors_admin_disable_and_maintenance(self):
        (self.private / "maintenance").touch()
        self.assertNotIn("am:start-foreground-service", self.run_boot()["counts"])
        (self.private / "maintenance").unlink()
        (self.state / "enabled").unlink()
        self.assertNotIn("am:start-foreground-service", self.run_boot()["counts"])

    def test_boot_recovery_failure_prevents_startup(self):
        self.change(faults={"controller:recover": 1})
        platform = self.run_boot(success=False)
        self.assertNotIn("am:start-foreground-service", platform["counts"])

    def test_success_arms_headless_helper_and_retains_backup(self):
        result = self.run_install(success=True)
        self.assertIn("mode=armed", result.stdout)
        self.assertEqual((self.root / "app.apk").read_text(), "new-apk")
        self.assertEqual(
            json.loads(self.platform.read_text())["policy"], [UID, 2, 0, 1, 0]
        )
        self.assertFalse((self.private / "maintenance").exists())
        backups = list((self.root / "data/adb/power-mode-backups").glob("standby.*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "app.apk").read_text(), "old-apk")
        self.assertEqual((backups[0] / "phase").read_text(), "complete\n")

    def test_stage_failures_restore_files_apk_policy_and_startup(self):
        for command in (
            "pm:install",
            "restorecon:power-mode-control",
            "magisk:grant",
            "am:start-foreground-service",
        ):
            with self.subTest(command=command):
                self.change(counts={}, faults={command: 1}, mode="stopped")
                result = self.run_install()
                self.assertIn("rollback=complete", result.stderr)
                self.assert_rolled_back()

    def test_install_and_rollback_preserve_monitor_configuration(self):
        monitor = self.state / "measurement-monitor"
        monitor.write_text("1:7\n")
        self.run_install(success=True)
        self.assertEqual(monitor.read_text(), "1:7\n")
        self.change(
            counts={}, faults={"am:start-foreground-service": 1}, mode="stopped"
        )
        self.run_install()
        self.assertEqual(monitor.read_text(), "1:7\n")

    def test_live_collector_lock_prevents_script_replacement(self):
        directory = self.state / "measurement"
        directory.mkdir()
        with (directory / "lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_install()
        self.assertIn("Rollback incomplete", result.stderr)
        self.assertEqual(self.control.read_text(), self.baseline[0])
        self.assertEqual((self.root / "app.apk").read_text(), "old-apk")
        self.assertTrue((self.private / "maintenance").exists())

    def test_descendant_holding_collector_lock_also_prevents_cutover(self):
        directory = self.state / "measurement"
        directory.mkdir()
        lock = (directory / "lock").open("w")
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        child = subprocess.Popen(["/bin/sleep", "60"], pass_fds=(lock.fileno(),))
        lock.close()
        self.addCleanup(lambda: child.poll() is not None or child.kill())
        self.addCleanup(lambda: child.poll() is not None or child.wait(timeout=3))
        try:
            result = self.run_install()
            self.assertIn("Rollback incomplete", result.stderr)
            self.assertEqual(self.control.read_text(), self.baseline[0])
        finally:
            child.kill()
            child.wait(timeout=3)

    def test_existing_measurement_tool_is_restored_on_failure(self):
        tool = self.root / "data/adb/power-mode-measure"
        tool.write_text("#!/bin/sh\n: prior-measurement\n")
        original = tool.read_text()
        self.change(faults={"am:start-foreground-service": 1})
        self.run_install()
        self.assertEqual(tool.read_text(), original)
        self.assert_rolled_back()

    def test_existing_magisk_policy_is_restored_exactly(self):
        old_policy = [UID, 1, 1234567890, 0, 1]
        self.change(policy=old_policy, faults={"am:start-foreground-service": 1})
        self.run_install()
        self.assert_rolled_back(old_policy)

    def test_failed_recovery_keeps_new_files_and_inhibits_startup(self):
        self.change(faults={"am:start-foreground-service": 1, "controller:disable": 2})
        result = self.run_install()
        self.assertIn("Rollback incomplete", result.stderr)
        self.assertTrue((self.private / "maintenance").exists())
        self.assertIn("LABEL=new", self.control.read_text())
        self.assertTrue(
            list((self.root / "data/adb/power-mode-backups").glob("standby.*"))
        )

    def test_rollback_restart_failure_retains_maintenance_barrier(self):
        self.change(
            mode="armed",
            policy=[UID, 2, 0, 1, 0],
            faults={"magisk:grant": 1, "am:start-foreground-service": 1},
        )
        result = self.run_install()
        self.assertIn("Rollback incomplete", result.stderr)
        self.assertTrue((self.private / "maintenance").exists())
        self.assertEqual(self.control.read_text(), self.baseline[0])
        self.assertEqual((self.root / "app.apk").read_text(), "old-apk")

    def test_rollback_dispatch_without_readiness_is_not_success(self):
        self.change(
            mode="sleeping",
            policy=[UID, 2, 0, 1, 0],
            suppress_start=True,
            faults={"magisk:grant": 1},
        )
        result = self.run_install()
        self.assertIn("Rollback incomplete", result.stderr)
        self.assertTrue((self.private / "maintenance").exists())

    def test_shared_uid_is_rejected_before_any_mutation(self):
        self.change(shared_uid=True)
        self.run_install()
        self.assert_rolled_back()

    def test_preflight_failure_does_not_replace_anything(self):
        self.change(faults={"controller:check": 1})
        self.run_install()
        self.assert_rolled_back()

    def test_interrupted_installation_is_not_silently_rearmed(self):
        (self.private / "maintenance").touch()
        result = self.run_install()
        self.assertIn("unfinished installation", result.stderr)
        self.assertEqual((self.root / "app.apk").read_text(), "old-apk")

    def test_busy_broker_aborts_and_restores_prior_state(self):
        with (self.state / "controller.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.run_install()
        self.assert_rolled_back()


if __name__ == "__main__":
    unittest.main()
