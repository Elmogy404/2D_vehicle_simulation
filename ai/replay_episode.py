"""Replay a recorded episode and compare it with the reference run.

Exit codes:
    0  exact match, or match within the requested tolerances
    1  divergence
    2  incompatible/invalid recording or replay infrastructure failure
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

from deterministic_seeds import runtime_metadata
from episode_recording import (
    DEFAULT_ATOL,
    DEFAULT_RTOL,
    IncompatibleRecordingError,
    RecordingError,
    check_recording_compatibility,
    compare_recordings,
    load_recording,
    replay_recording,
)
from godot_gym_env import ENVIRONMENT_VERSION, GodotRoadEnv


def _print_report(report: dict, *, recording_path: Path) -> None:
    print(
        "REPLAY %s steps=%d atol=%g rtol=%g max_abs_observation_error=%g"
        % (
            report["status"].upper(),
            report["steps_compared"],
            report["tolerances"]["atol"],
            report["tolerances"]["rtol"],
            report["max_abs_observation_error"],
        ),
        flush=True,
    )
    if report["first_divergence"] is not None:
        print("FIRST DIVERGENCE:", json.dumps(report["first_divergence"], indent=2, sort_keys=True), flush=True)
    elif report["status"] == "exact":
        print("Replay matched the recording exactly (excluding wall-clock and PID fields).", flush=True)
    else:
        print("Replay matched within the configured floating-point tolerances.", flush=True)
    print(f"Recording: {recording_path}", flush=True)


def _write_json_report(path: Path | None, report: dict) -> None:
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, sort_keys=True), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recording", type=Path, required=True, help="JSONL episode recording")
    parser.add_argument("--godot", help="Godot 4 executable; defaults to GODOT_BIN/PATH")
    parser.add_argument("--atol", type=float, default=DEFAULT_ATOL, help="Absolute floating-point tolerance")
    parser.add_argument("--rtol", type=float, default=DEFAULT_RTOL, help="Relative floating-point tolerance")
    parser.add_argument("--no-compare-info", action="store_true", help="Compare observations/rewards/flags only")
    parser.add_argument("--write-replay", type=Path, help="Optionally save the replay run as a new recording")
    parser.add_argument("--json", type=Path, help="Write the full comparison report as JSON")
    arguments = parser.parse_args()
    if arguments.atol < 0 or arguments.rtol < 0:
        parser.error("--atol and --rtol must be non-negative")

    try:
        recording = load_recording(arguments.recording)
        check_recording_compatibility(
            recording,
            environment_version=ENVIRONMENT_VERSION,
            reward_config=recording.header["reward_config"],
            generator_type=str(recording.header["generator_type"]),
        )
        env = GodotRoadEnv(
            arguments.godot,
            reward_config=recording.header["reward_config"],
            generator_type=str(recording.header["generator_type"]),
            master_seed=(
                recording.reset.get("info", {}).get("master_seed", recording.master_seed)
            ),
        )
        try:
            replayed = replay_recording(env, recording)
        finally:
            env.close()
    except IncompatibleRecordingError as error:
        report = {
            "status": "incompatible",
            "error": str(error),
            "recording": str(arguments.recording),
            "runtime": runtime_metadata(),
        }
        _write_json_report(arguments.json, report)
        print(f"INCOMPATIBLE RECORDING: {error}", file=sys.stderr)
        raise SystemExit(2) from error
    except (RecordingError, OSError, RuntimeError) as error:
        report = {
            "status": "error",
            "error": str(error),
            "recording": str(arguments.recording),
            "runtime": runtime_metadata(),
        }
        _write_json_report(arguments.json, report)
        print(f"REPLAY ERROR: {error}", file=sys.stderr)
        raise SystemExit(2) from error

    report = compare_recordings(
        recording,
        replayed,
        atol=arguments.atol,
        rtol=arguments.rtol,
        compare_info=not arguments.no_compare_info,
    )
    report["recording"] = str(arguments.recording)
    report["runtime"] = runtime_metadata()
    _print_report(report, recording_path=arguments.recording)
    if arguments.write_replay is not None:
        replayed.write(arguments.write_replay)
        print(f"Replay recording saved to {arguments.write_replay}", flush=True)
    if arguments.json is not None:
        _write_json_report(arguments.json, report)
        print(f"Comparison report saved to {arguments.json}", flush=True)
    raise SystemExit(0 if report["status"] in {"exact", "tolerance"} else 1)


if __name__ == "__main__":
    main()
