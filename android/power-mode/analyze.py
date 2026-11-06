import argparse
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
import json
from pathlib import Path
import re


SCHEMA_VERSION = "1"
MINIMUM_HOURS = Decimal(8)
NEAR_FULL_CAPACITY = 90
NEAR_EMPTY_CAPACITY = 10
TEMPERATURE_CAUTION_C = Decimal(2)
RPMH_FIELDS = ("Version", "Sleep Count", "Sleep Accumulated Duration")
DRAIN_CAUTIONS = frozenset(
    {
        "shorter_than_requested_overnight_window",
        "near_full_start_gauge_relaxation_may_bias_drain",
        "near_empty_start_gauge_uncertainty",
        "temperature_change_may_bias_gauge",
        "learned_full_capacity_changed",
    }
)
SECONDS_PER_HOUR = Decimal(3600)
HOURS_PER_DAY = Decimal(24)


def text(directory, name):
    return (directory / name).read_text().strip()


def number(directory, name):
    value = Decimal(text(directory, name))
    if not value.is_finite():
        raise ValueError(f"Non-finite {name}")
    return value


def midpoint(directory, prefix):
    before = number(directory, f"{prefix}_before_s")
    after = number(directory, f"{prefix}_after_s")
    if after < before:
        raise ValueError(f"Reversed {prefix} timestamps")
    return (before + after) / 2


def suspend_ms(directory):
    if (directory / "suspend_status").exists():
        return None
    match = re.search(
        r"^\s*total suspend time:\s*(\d+)\s*ms\s*$",
        text(directory, "suspend.txt"),
        re.MULTILINE,
    )
    return Decimal(match[1]) if match else None


def wakefulness(directory):
    if (directory / "power_status").exists():
        return None
    match = re.search(
        r"^\s*mWakefulness=(Awake|Asleep|Dozing|Dreaming)\s*$",
        text(directory, "power.txt"),
        re.MULTILINE,
    )
    return match[1] if match else None


def unpowered(directory):
    if (directory / "battery_status").exists():
        return False
    flags = re.findall(
        r"^\s*(AC|USB|Wireless|Dock) powered: (true|false)\s*$",
        text(directory, "battery.txt"),
        re.MULTILINE,
    )
    values = dict(flags)
    return (
        len(values) == len(flags)
        and {"AC", "USB", "Wireless"} <= values.keys()
        and all(value == "false" for value in values.values())
    )


@dataclass(frozen=True)
class MasterSleepCounters:
    version: int
    count: int
    ticks: int


def rpmh_counters(directory):
    if (directory / "rpmh_status").exists() or not (directory / "rpmh.txt").is_file():
        return None
    counters = {}
    name = None
    fields = {}
    for line in text(directory, "rpmh.txt").splitlines() + [""]:
        if not line.strip():
            if name is not None:
                if (
                    not all(field in fields for field in RPMH_FIELDS)
                    or name in counters
                ):
                    raise ValueError("Malformed RPMh counters")
                counters[name] = MasterSleepCounters(
                    *(fields[field] for field in RPMH_FIELDS)
                )
            name, fields = None, {}
        elif re.fullmatch(r"[A-Z][A-Z0-9_]*", line):
            if name is not None:
                raise ValueError("Unterminated RPMh block")
            name = line
        else:
            match = re.fullmatch(r"\s*([^:]+):0x([0-9a-fA-F]+)", line)
            if name is None or match is None or match[1] in fields:
                raise ValueError("Malformed RPMh field")
            fields[match[1]] = int(match[2], 16)
    return counters or None


def rpmh_deltas(start, end, warnings):
    try:
        before, after = rpmh_counters(start), rpmh_counters(end)
        if before is None or after is None:
            warnings.append("rpmh_stats_unavailable")
            return {}
        for endpoint in (start, end):
            if not (
                number(endpoint, "capture_before_s")
                <= number(endpoint, "rpmh_before_s")
                <= number(endpoint, "rpmh_after_s")
                <= number(endpoint, "capture_after_s")
            ):
                raise ValueError("Invalid RPMh timestamps")
        if midpoint(end, "rpmh") <= midpoint(start, "rpmh"):
            raise ValueError("Invalid RPMh interval")
    except (OSError, ValueError, InvalidOperation):
        warnings.append("rpmh_stats_malformed")
        return {}
    result = {}
    for name in sorted(before.keys() | after.keys()):
        if name not in before or name not in after:
            warnings.append(f"rpmh_state_changed:{name}")
            continue
        first, last = before[name], after[name]
        if (
            first.version != last.version
            or last.count < first.count
            or last.ticks < first.ticks
        ):
            warnings.append(f"rpmh_counter_reset:{name}")
            continue
        result[name] = {
            "sleep_count_delta": last.count - first.count,
            "accumulated_duration_ticks_delta": last.ticks - first.ticks,
            "counter_hz": None,
            "residency_percent": None,
        }
    return result


@dataclass(frozen=True)
class Result:
    valid: bool
    issues: list[str]
    warnings: list[str]
    metrics: dict


def analyze(directory):
    directory = Path(directory)
    if text(directory, "schema") != SCHEMA_VERSION:
        raise ValueError("Unsupported measurement schema")
    if text(directory, "phase") != "complete":
        return Result(False, ["measurement_incomplete"], [], {})
    start = directory / "start"
    end = directory / "end"
    issues = []
    warnings = []
    accepted = number(directory, "accepted_s")
    if not (
        number(start, "capture_after_s") <= accepted <= number(end, "capture_before_s")
    ):
        raise ValueError("Inconsistent acceptance chronology")
    for endpoint in (start, end):
        beginning = number(endpoint, "capture_before_s")
        ending = number(endpoint, "capture_after_s")
        for prefix in ("charge", "suspend"):
            if not (
                beginning
                <= number(endpoint, f"{prefix}_before_s")
                <= number(endpoint, f"{prefix}_after_s")
                <= ending
            ):
                raise ValueError("Counter timestamps outside collection brackets")
    if text(start, "boot_id") != text(end, "boot_id"):
        issues.append("boot_changed")
    if text(start, "transaction") != text(end, "transaction"):
        issues.append("policy_transaction_changed")
    if text(directory, "reason") != "guard":
        issues.append("unexpected_policy_end")
    if wakefulness(start) not in ("Asleep", "Dozing") or wakefulness(end) != "Awake":
        issues.append("unexpected_wakefulness")
    if not unpowered(start) or not unpowered(end):
        issues.append("charging_or_unknown_power_state")
    if text(start, "status") != "Discharging" or text(end, "status") != "Discharging":
        issues.append("gauge_not_discharging")
    elapsed = midpoint(end, "charge") - midpoint(start, "charge")
    if elapsed <= 0:
        raise ValueError("Non-positive measurement duration")
    hours = elapsed / SECONDS_PER_HOUR
    if hours < MINIMUM_HOURS:
        warnings.append("shorter_than_requested_overnight_window")
    if int(text(start, "capacity")) >= NEAR_FULL_CAPACITY:
        warnings.append("near_full_start_gauge_relaxation_may_bias_drain")
    if int(text(start, "capacity")) <= NEAR_EMPTY_CAPACITY:
        warnings.append("near_empty_start_gauge_uncertainty")
    if abs(number(end, "temp") - number(start, "temp")) / 10 >= TEMPERATURE_CAUTION_C:
        warnings.append("temperature_change_may_bias_gauge")
    full = number(start, "charge_full")
    if full <= 0:
        raise ValueError("Invalid full-charge capacity")
    if full != number(end, "charge_full"):
        warnings.append("learned_full_capacity_changed")
    loss = number(start, "charge_counter") - number(end, "charge_counter")
    if loss < 0 or loss > full:
        issues.append("implausible_charge_delta")
    metrics = {
        "hours": float(hours),
        "charge_loss_uah": float(loss),
        "charge_full_uah": float(full),
        "estimated_mah_per_day": float(loss / 1000 / hours * HOURS_PER_DAY)
        if loss >= 0
        else None,
        "estimated_capacity_percentage_points_per_day": float(
            loss / full / hours * HOURS_PER_DAY * 100
        )
        if loss >= 0
        else None,
        "average_current_ua": float(loss / hours) if loss >= 0 else None,
        "start_temperature_c": float(number(start, "temp") / 10),
        "end_temperature_c": float(number(end, "temp") / 10),
        "entry_collection_s": float(
            number(start, "capture_after_s") - number(start, "capture_before_s")
        ),
        "exit_collection_s": float(
            number(end, "capture_after_s") - number(end, "capture_before_s")
        ),
        "entry_observer_tail_s": float(
            number(directory, "accepted_s") - number(start, "charge_before_s")
        ),
        "system_suspend_percent": None,
        "hardware_rail_residency": "not_measured",
        "uninterrupted_sleep_certified": False,
        "rpmh_states": rpmh_deltas(start, end, warnings),
    }
    first_suspend = suspend_ms(start)
    last_suspend = suspend_ms(end)
    if first_suspend is None or last_suspend is None:
        warnings.append("system_suspend_time_unavailable")
    elif (
        text(start, "suspend_pid") == "unavailable"
        or text(end, "suspend_pid") == "unavailable"
    ):
        warnings.append("suspend_service_identity_unavailable")
    elif text(start, "suspend_pid") != text(end, "suspend_pid"):
        warnings.append("suspend_service_restarted")
    else:
        suspend_elapsed = midpoint(end, "suspend") - midpoint(start, "suspend")
        delta = (last_suspend - first_suspend) / 1000
        if suspend_elapsed <= 0 or delta < 0 or delta > suspend_elapsed:
            warnings.append("suspend_counter_reset_or_inconsistent")
        else:
            metrics["system_suspend_percent"] = float(delta / suspend_elapsed * 100)
            metrics["system_suspend_seconds"] = float(delta)
    return Result(not issues, issues, warnings, metrics)


def analyze_history(state):
    state = Path(state)
    candidates = [
        state / "measurement",
        *sorted((state / "measurement-history").glob("session.*/measurement")),
    ]
    records = []
    identities = set()
    for directory in candidates:
        if not directory.is_dir() or not any(
            (directory / name).exists() for name in ("schema", "phase", "start")
        ):
            continue
        try:
            result = analyze(directory)
            if result.valid:
                identity = (
                    text(directory / "start", "boot_id"),
                    text(directory / "start", "transaction"),
                    text(directory / "start", "charge_before_s"),
                )
                if identity in identities:
                    continue
                identities.add(identity)
            record = {"directory": str(directory), **result.__dict__}
            record["preferred_for_drain_comparison"] = (
                result.valid and not DRAIN_CAUTIONS.intersection(result.warnings)
            )
        except (OSError, ValueError, InvalidOperation):
            record = {
                "directory": str(directory),
                "valid": False,
                "issues": ["malformed_record"],
                "warnings": [],
                "metrics": {},
                "preferred_for_drain_comparison": False,
            }
        records.append(record)
    uncommitted = []
    owner_file = state / "measurement/admission_id"
    current_id = owner_file.read_text().strip() if owner_file.is_file() else None
    for directory in sorted((state / "measurement-history").glob("session.*")):
        if not (directory / "measurement").exists() and directory.name != current_id:
            uncommitted.append(str(directory))
    return {
        "records": records,
        "uncommitted_admissions": uncommitted,
        "retention_clock": "observed_monotonic_elapsed_time",
        "aggregate_drain": None,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument(
        "--history",
        action="store_true",
        help="Read a power-mode state directory without averaging uncertain sessions",
    )
    args = parser.parse_args()
    try:
        if args.history:
            print(json.dumps(analyze_history(args.directory), indent=2))
            return 0
        result = analyze(args.directory)
        print(json.dumps(result.__dict__, indent=2))
    except (OSError, ValueError, InvalidOperation) as error:
        parser.exit(1, f"Measurement unavailable: {error}\n")
    return 0 if result.valid else 1


if __name__ == "__main__":
    raise SystemExit(main())
