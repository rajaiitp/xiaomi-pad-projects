import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "power-mode/measure-standby.sh"
SPEC = importlib.util.spec_from_file_location(
    "standby_analysis", ROOT / "power-mode/analyze.py"
)
ANALYSIS = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = ANALYSIS
SPEC.loader.exec_module(ANALYSIS)
FAKE = r"""
import json
import os
from pathlib import Path
import signal
import sys
root = Path(os.environ['FAKE_MEASUREMENT'])
name = Path(sys.argv[0]).name
if name == 'id': print('0')
elif name == 'pidof': print('744')
elif name in ('sync', 'cp', 'mv', 'rm', 'du', 'date'):
    fault_file = root / 'fault.json'
    if fault_file.exists():
        fault = json.loads(fault_file.read_text())
        if fault['command'] == name and fault.get('contains', '') in ' '.join(sys.argv[1:]):
            fault['hits'] = fault.get('hits', 1) - 1
            if fault['hits'] == 0:
                fault_file.unlink()
                if fault.get('kill', False): os.kill(os.getppid(), signal.SIGKILL)
                sys.exit(1)
            fault_file.write_text(json.dumps(fault))
    if name == 'sync': pass
    elif name == 'date' and (root / 'fake-date').exists(): print((root / 'fake-date').read_text().strip())
    elif name == 'du' and (root / 'fake-usage').exists(): print((root / 'fake-usage').read_text().strip() + '\t' + sys.argv[-1])
    else: os.execv('/usr/bin/' + name, [name, *sys.argv[1:]])
elif name == 'dumpsys':
    print((root / ('dump-' + sys.argv[-1])).read_text(), end='')
else: raise AssertionError(name)
"""


class StandbyMeasurementTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="standby-measurement-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state = self.root / "state"
        self.data = self.state / "measurement"
        self.fs = self.root / "fs"
        self.gauge = self.fs / "sys/class/power_supply/battery"
        self.gauge.mkdir(parents=True)
        for key, value in {
            "charge_counter": "8000000",
            "charge_full": "8776000",
            "charge_full_design": "8840000",
            "capacity": "91",
            "temp": "215",
            "voltage_now": "4200000",
            "status": "Discharging",
        }.items():
            (self.gauge / key).write_text(value + "\n")
        boot = self.fs / "proc/sys/kernel/random/boot_id"
        boot.parent.mkdir(parents=True)
        boot.write_text("boot-a\n")
        (self.fs / "proc/uptime").write_text("100.00 50.00\n")
        (self.fs / "proc/interrupts").write_text(" CPU0\n 1: 10 timer\n")
        (self.root / "dump-suspend_control_internal").write_text(
            "total suspend time: 1000 ms\n"
        )
        (self.root / "dump-power").write_text("  mWakefulness=Asleep\n")
        (self.root / "dump-battery").write_text(
            "  AC powered: false\n  USB powered: false\n  Wireless powered: false\n"
        )
        binary = self.root / "bin"
        binary.mkdir()
        for name in ("id", "pidof", "sync", "dumpsys", "cp", "mv", "rm", "du", "date"):
            file = binary / name
            file.write_text(f"#!{sys.executable}\n{FAKE}")
            file.chmod(0o755)
        self.environment = {
            **os.environ,
            "POWER_MODE_STATE_DIR": str(self.state),
            "POWER_MODE_MEASUREMENT_ROOT": str(self.fs),
            "FAKE_MEASUREMENT": str(self.root),
            "POWER_MODE_COMMAND_PATH": f"{binary}:{os.defpath}",
        }
        self.command("arm")
        (self.state / "snapshot").mkdir()

    def command(self, *arguments, success=True):
        result = subprocess.run(
            ["sh", str(SCRIPT), *arguments],
            env=self.environment,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(result.returncode == 0, success, result.stderr)
        return result.stdout.strip()

    def start(self):
        self.command("start")
        self.command("accept")

    def advance(self, seconds=28800):
        before = float((self.fs / "proc/uptime").read_text().split()[0])
        (self.fs / "proc/uptime").write_text(f"{before + seconds:.2f} 100.00\n")
        charge = int((self.gauge / "charge_counter").read_text())
        (self.gauge / "charge_counter").write_text(f"{charge - 32000}\n")
        dump = self.root / "dump-suspend_control_internal"
        previous = int(dump.read_text().split(":")[1].split()[0])
        dump.write_text(f"total suspend time: {previous + int(seconds * 950)} ms\n")
        (self.root / "dump-power").write_text("  mWakefulness=Awake\n")

    def enable_monitor(self):
        (self.state / "snapshot").rmdir()
        self.command("monitor-enable")
        (self.state / "snapshot").mkdir()

    def new_policy(self):
        number = len(list(self.root.glob("previous-policy-*")))
        (self.state / "snapshot").rename(self.root / f"previous-policy-{number}")
        (self.state / "snapshot").mkdir()
        (self.root / "dump-power").write_text("  mWakefulness=Asleep\n")

    def history(self):
        return ANALYSIS.analyze_history(self.state)

    def inject(self, command, contains="", kill=False, hits=1):
        (self.root / "fault.json").write_text(
            json.dumps(
                {"command": command, "contains": contains, "kill": kill, "hits": hits}
            )
        )

    def old_record(self, suffix="old", closed_age=0):
        directory = (
            self.state
            / "measurement-history"
            / f"session.0000001000.{suffix}"
            / "measurement"
        )
        directory.mkdir(parents=True)
        (directory / "schema").write_text("1\n")
        (directory / "phase").write_text("failed\n")
        (directory / "closed_age_s").write_text(f"{closed_age}\n")
        return directory.parent

    def test_monitor_records_successive_sessions_without_manual_arm(self):
        self.enable_monitor()
        for _ in range(2):
            self.start()
            self.advance()
            self.command("end", "guard")
            self.new_policy()
        records = self.history()["records"]
        self.assertEqual(sum(record["valid"] for record in records), 2)
        self.assertFalse((self.data / "armed").exists())
        self.assertIn("enabled=1", self.command("monitor-status"))

    def test_monitor_duplicate_start_preserves_completed_session(self):
        self.enable_monitor()
        self.start()
        self.advance()
        self.command("end", "guard")
        identity = (self.data / "admission_id").read_text()
        self.command("start", success=False)
        self.assertEqual(self.command("status"), "complete")
        self.assertEqual((self.data / "admission_id").read_text(), identity)
        self.assertEqual(
            sum(record["valid"] for record in self.history()["records"]), 1
        )

    def test_disable_finishes_active_session_and_reenable_defers_existing_policy(self):
        self.enable_monitor()
        self.start()
        self.command("monitor-disable")
        self.advance()
        self.command("end", "guard")
        self.assertTrue(ANALYSIS.analyze(self.data).valid)
        self.new_policy()
        self.command("start")
        self.command("monitor-enable")
        self.command("start", success=False)
        self.new_policy()
        self.start()
        self.assertEqual(self.command("status"), "sleeping")

    def test_startup_aborts_without_reusing_same_policy(self):
        self.enable_monitor()
        self.start()
        self.command("abort", "startup")
        self.command("start", success=False)
        self.assertEqual(self.command("status"), "failed")
        self.new_policy()
        self.start()
        self.advance()
        self.command("end", "guard")
        self.assertEqual(
            sum(record["valid"] for record in self.history()["records"]), 1
        )

    def test_rotation_interruptions_never_overwrite_or_duplicate_prior_result(self):
        self.enable_monitor()
        self.start()
        self.advance()
        self.command("end", "guard")
        for command, contains, hits in (
            ("mv", "measurement-admission", 1),
            ("cp", "/measurement/.", 1),
            ("mv", "/.archive.", 1),
            ("mv", "rotation_archive_id", 1),
            ("rm", "/measurement/schema", 1),
            ("mv", "/measurement/phase", 2),
        ):
            with self.subTest(command=command, contains=contains):
                self.new_policy()
                self.inject(command, contains, kill=True, hits=hits)
                self.command("start", success=False)
                self.command("abort", "startup")
                self.command("start", success=False)
                valid = [
                    record for record in self.history()["records"] if record["valid"]
                ]
                self.assertEqual(len(valid), 1)
        self.new_policy()
        self.start()
        self.advance()
        self.command("end", "guard")
        self.assertEqual(
            sum(record["valid"] for record in self.history()["records"]), 2
        )

    def test_interrupted_rotation_keeps_archive_references_protected_until_recovery(
        self,
    ):
        self.enable_monitor()
        self.start()
        self.advance()
        self.command("end", "guard")
        self.new_policy()
        self.inject("rm", "/measurement/phase", kill=True)
        self.command("start", success=False)
        self.assertFalse((self.data / "admission_id").exists())
        reference = (self.data / "rotation_archive_id").read_text().strip()
        archive = self.state / "measurement-history" / reference / "measurement"
        self.assertTrue(ANALYSIS.analyze(archive).valid)
        current = float((self.fs / "proc/uptime").read_text().split()[0])
        (self.fs / "proc/uptime").write_text(f"{current + 8 * 86400} 100.00\n")
        self.command("prune")
        self.assertTrue(archive.exists())
        self.command("abort", "startup")
        self.new_policy()
        self.start()
        self.assertEqual(self.command("status"), "sleeping")

    def test_admission_reserves_record_capacity_even_if_capture_is_disabled_or_fails(
        self,
    ):
        self.enable_monitor()
        for index in range(512):
            self.old_record(f"{index:04d}")
        (self.state / "measurement-sequence").write_text("2000\n")
        self.inject("cp", "/measurement/.")
        self.command("start", success=False)
        self.command("monitor-disable")
        self.command("abort", "startup")
        self.assertLessEqual(
            len(list((self.state / "measurement-history").glob("session.*"))), 512
        )

    def test_admission_at_byte_capacity_does_not_assume_end_cleanup_will_make_room(
        self,
    ):
        self.enable_monitor()
        self.old_record()
        (self.root / "fake-usage").write_text("131072\n")
        self.command("start", success=False)
        self.assertFalse((self.state / "measurement-admission").exists())
        self.assertIn("history_capacity", self.command("monitor-status"))

    def test_pruning_clock_delete_sync_and_usage_failures_prevent_new_admission(self):
        self.enable_monitor()
        old = self.old_record()
        clock = self.state / "measurement-clock"
        original_clock = clock.read_text()
        clock.write_text("torn\n")
        self.command("start", success=False)
        self.assertFalse((self.state / "measurement-admission").exists())
        clock.write_text(original_clock)
        (self.fs / "proc/uptime").write_text("691300.00 100.00\n")
        for command, contains, hits in (
            ("rm", str(old), 1),
            ("sync", "", 3),
            ("du", "", 2),
        ):
            with self.subTest(command=command):
                if not old.exists():
                    self.old_record()
                self.inject(command, contains, hits=hits)
                self.command("start", success=False)
                self.assertFalse((self.state / "measurement-admission").exists())
                self.assertNotIn("error=none", self.command("monitor-status"))

    def test_torn_admission_is_reported_and_does_not_replace_prior_result(self):
        self.enable_monitor()
        self.start()
        self.advance()
        self.command("end", "guard")
        (self.state / "measurement-admission.new").write_text("torn\n")
        self.new_policy()
        self.command("start", success=False)
        self.assertTrue(ANALYSIS.analyze(self.data).valid)
        self.assertNotIn("error=none", self.command("monitor-status"))

    def test_retention_uses_monotonic_elapsed_time_not_wall_clock(self):
        self.enable_monitor()
        old = self.old_record()
        (self.root / "fake-date").write_text("2099-01-01T00:00:00Z\n")
        self.command("prune")
        self.assertTrue(old.exists())
        (self.root / "fake-date").write_text("1970-01-01T00:00:00Z\n")
        self.command("prune")
        self.assertTrue(old.exists())
        (self.fs / "proc/uptime").write_text("691300.00 100.00\n")
        self.command("prune")
        self.assertFalse(old.exists())

    def test_reboot_does_not_age_records_by_unverified_wall_time(self):
        self.enable_monitor()
        old = self.old_record()
        (self.fs / "proc/sys/kernel/random/boot_id").write_text("boot-b\n")
        (self.fs / "proc/uptime").write_text("100.00 50.00\n")
        (self.root / "fake-date").write_text("2099-01-01T00:00:00Z\n")
        self.command("prune")
        self.assertTrue(old.exists())
        (self.fs / "proc/uptime").write_text("691300.00 100.00\n")
        self.command("prune")
        self.assertFalse(old.exists())

    def test_retention_pruning_is_bounded_and_storage_failure_blocks_admission(self):
        self.enable_monitor()
        for index in range(12):
            self.old_record(str(index))
        (self.root / "fake-usage").write_text("131073\n")
        self.command("start", success=False)
        self.assertEqual(
            len(list((self.state / "measurement-history").glob("session.*"))), 4
        )
        self.assertFalse((self.state / "measurement-admission").exists())
        self.assertNotIn("error=none", self.command("monitor-status"))

    def test_record_count_limit_prunes_oldest_without_removing_latest(self):
        self.enable_monitor()
        for index in range(514):
            self.old_record(f"{index:04d}")
        self.command("prune")
        self.assertEqual(
            len(list((self.state / "measurement-history").glob("session.*"))), 512
        )

    def test_dump_output_limit_does_not_become_zero_suspend_time(self):
        self.start()
        self.advance()
        (self.root / "dump-suspend_control_internal").write_text(
            "total suspend time: 27361000 ms\n" + "x" * 270000
        )
        self.command("end", "guard")
        result = ANALYSIS.analyze(self.data)
        self.assertTrue(result.valid)
        self.assertIsNone(result.metrics["system_suspend_percent"])
        self.assertEqual(
            (self.data / "end/suspend_status").read_text(), "output_limit\n"
        )

    def test_rpmh_raw_deltas_are_not_unverified_residency_percentages(self):
        source = self.fs / "sys/power/rpmh_stats/master_stats"
        source.parent.mkdir(parents=True)
        source.write_text(
            "APSS\n\tVersion:0x1\n\tSleep Count:0x10\n\tSleep Accumulated Duration:0x100\n"
        )
        self.start()
        self.advance()
        source.write_text(
            "APSS\n\tVersion:0x1\n\tSleep Count:0x20\n\tSleep Accumulated Duration:0x500\n"
        )
        self.command("end", "guard")
        result = ANALYSIS.analyze(self.data)
        self.assertEqual(
            result.metrics["rpmh_states"]["APSS"]["accumulated_duration_ticks_delta"],
            1024,
        )
        self.assertIsNone(result.metrics["rpmh_states"]["APSS"]["residency_percent"])

    def test_rpmh_reset_or_malformed_data_does_not_fabricate_residency(self):
        source = self.fs / "sys/power/rpmh_stats/master_stats"
        source.parent.mkdir(parents=True)
        source.write_text(
            "APSS\n\tVersion:0x1\n\tSleep Count:0x10\n\tSleep Accumulated Duration:0x100\n"
        )
        self.start()
        self.advance()
        source.write_text(
            "APSS\n\tVersion:0x1\n\tSleep Count:0x1\n\tSleep Accumulated Duration:0x1\n"
        )
        self.command("end", "guard")
        result = ANALYSIS.analyze(self.data)
        self.assertEqual(result.metrics["rpmh_states"], {})
        self.assertIn("rpmh_counter_reset:APSS", result.warnings)
        (self.data / "end/rpmh.txt").write_text("bad data\n")
        self.assertIn("rpmh_stats_malformed", ANALYSIS.analyze(self.data).warnings)

    def test_history_does_not_average_uncertain_windows(self):
        self.enable_monitor()
        self.start()
        self.advance(60)
        self.command("end", "guard")
        history = self.history()
        self.assertIsNone(history["aggregate_drain"])
        self.assertFalse(
            any(
                record["preferred_for_drain_comparison"]
                for record in history["records"]
            )
        )

    def test_monitor_enable_persistence_failure_is_not_success(self):
        (self.state / "snapshot").rmdir()
        self.inject("mv", "measurement-monitor")
        self.command("monitor-enable", success=False)
        self.assertFalse((self.state / "measurement-monitor").exists())

    def test_round_trip_has_correct_units_and_no_recapture(self):
        self.start()
        self.advance()
        self.command("end", "guard")
        result = ANALYSIS.analyze(self.data)
        self.assertTrue(result.valid, result.issues)
        self.assertEqual(result.metrics["hours"], 8)
        self.assertEqual(result.metrics["estimated_mah_per_day"], 96)
        self.assertEqual(result.metrics["average_current_ua"], 4000)
        self.assertEqual(result.metrics["system_suspend_percent"], 95)
        self.assertFalse(result.metrics["uninterrupted_sleep_certified"])
        self.assertIn(
            "near_full_start_gauge_relaxation_may_bias_drain", result.warnings
        )
        captured = (self.data / "start/charge_counter").read_text()
        self.command("start")
        self.assertEqual((self.data / "start/charge_counter").read_text(), captured)
        self.assertFalse((self.data / "armed").exists())

    def test_orphan_endpoints_prevent_rearming(self):
        for name in ("phase", "armed", "schema"):
            (self.data / name).unlink()
        for name in ("start", "end"):
            (self.data / name).mkdir()
            (self.data / name / "boot_id").write_text("old-boot\n")
        self.command("arm", success=False)
        self.assertEqual((self.data / "start/boot_id").read_text(), "old-boot\n")

    def test_existing_endpoint_is_not_used_as_a_move_destination(self):
        self.start()
        self.advance()
        (self.data / "end").mkdir()
        (self.data / "end/boot_id").write_text("old-boot\n")
        self.command("end", "guard", success=False)
        self.assertEqual(self.command("status"), "failed")
        self.assertEqual((self.data / "end/boot_id").read_text(), "old-boot\n")

    def test_acceptance_after_end_capture_is_rejected(self):
        self.start()
        self.advance()
        self.command("end", "guard")
        (self.data / "accepted_s").write_text("30000\n")
        with self.assertRaisesRegex(ValueError, "acceptance chronology"):
            ANALYSIS.analyze(self.data)

    def test_unaccepted_start_cannot_complete(self):
        self.command("start")
        self.advance()
        self.command("end", "guard", success=False)
        self.assertEqual(self.command("status"), "failed")
        self.assertFalse(ANALYSIS.analyze(self.data).valid)

    def test_recovery_aborts_instead_of_manufacturing_completion(self):
        self.start()
        self.command("abort", "startup")
        self.command("start")
        self.assertEqual(self.command("status"), "failed")
        self.assertEqual((self.data / "reason").read_text(), "startup\n")

    def test_reboot_is_rejected(self):
        self.start()
        self.advance()
        (self.fs / "proc/sys/kernel/random/boot_id").write_text("boot-b\n")
        self.command("end", "guard", success=False)
        self.assertEqual(self.command("status"), "failed")

    def test_different_policy_transaction_is_rejected(self):
        self.start()
        self.advance()
        (self.state / "snapshot").rename(self.state / "old-snapshot")
        (self.state / "snapshot").mkdir()
        self.command("end", "guard", success=False)
        self.assertEqual(self.command("status"), "failed")

    def test_invalid_gauge_fails_without_publishing_a_start(self):
        (self.gauge / "charge_counter").write_text("unknown\n")
        self.command("start", success=False)
        self.assertEqual(self.command("status"), "failed")
        self.assertFalse((self.data / "start").exists())
        self.assertFalse((self.data / "armed").exists())

    def test_charging_or_unobserved_wake_does_not_certify_sleep(self):
        self.start()
        self.advance()
        (self.root / "dump-battery").write_text(
            "  AC powered: true\n  USB powered: false\n  Wireless powered: false\n"
        )
        (self.root / "dump-power").write_text("  mWakefulness=Asleep\n")
        self.command("end", "guard")
        result = ANALYSIS.analyze(self.data)
        self.assertFalse(result.valid)
        self.assertIn("charging_or_unknown_power_state", result.issues)
        self.assertIn("unexpected_wakefulness", result.issues)

    def test_missing_suspend_counter_is_not_reported_as_zero_sleep(self):
        self.start()
        self.advance()
        (self.root / "dump-suspend_control_internal").write_text("not supported\n")
        self.command("end", "guard")
        result = ANALYSIS.analyze(self.data)
        self.assertTrue(result.valid)
        self.assertIsNone(result.metrics["system_suspend_percent"])
        self.assertIn("system_suspend_time_unavailable", result.warnings)

    def test_reset_suspend_counter_is_not_used_for_residency(self):
        (self.root / "dump-suspend_control_internal").write_text(
            "total suspend time: 10000 ms\n"
        )
        self.start()
        self.advance()
        (self.root / "dump-suspend_control_internal").write_text(
            "total suspend time: 100 ms\n"
        )
        self.command("end", "guard")
        result = ANALYSIS.analyze(self.data)
        self.assertIsNone(result.metrics["system_suspend_percent"])
        self.assertIn("suspend_counter_reset_or_inconsistent", result.warnings)


if __name__ == "__main__":
    unittest.main()
