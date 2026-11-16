"""Run project checks with one command; optionally include environment sweeps.

Usage: .venv-ai/Scripts/python.exe tests/run_checks.py --godot PATH --full
"""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ai"))
from godot_bridge import find_godot

SCRIPTS = ["segment_navigation_test", "road_piece_catalog_test", "segment_road_generator_test",
           "segment_road_boundary_test", "road_generation_router_test", "main_segmented_generation_test",
           "authored_signal_test", "npc_clearance_test", "spatial_index_test", "optimization_smoke_test",
           "ai_gameplay_parity_test", "ai_headless_parity_test", "ai_route_planner_test", "ai_speed_reward_test",
           "ai_reward_config_test", "ai_training_ui_test", "deterministic_seed_test", "map_regeneration_shortcut_test",
           "collision_system_test", "drivable_area_test", "schema_validation_test"]


def run_command(command: list[str], timeout: float) -> tuple[int | None, str, bool]:
    """Run a child, report timeout, and terminate its whole process tree."""
    creationflags = subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0
    process = subprocess.Popen(
        command,
        cwd=ROOT,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=creationflags,
        start_new_session=os.name != "nt",
    )
    try:
        output, _ = process.communicate(timeout=timeout)
        return process.returncode, output or "", False
    except subprocess.TimeoutExpired:
        if os.name == "nt":
            subprocess.run(
                ["taskkill", "/F", "/T", "/PID", str(process.pid)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
        else:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        try:
            output, _ = process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            output, _ = process.communicate()
        return process.returncode, (output or "") + f"\nTimed out after {timeout:g} seconds", True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    parser.add_argument("--full", action="store_true")
    parser.add_argument("--lifecycle", action="store_true", help="Start a short isolated real PPO session to check pause/resume/save")
    parser.add_argument("--skip-python", action="store_true", help="Skip the Python unit suite when another CI job runs it")
    parser.add_argument("--timeout", type=float, default=300.0, help="Per-check timeout in seconds")
    parser.add_argument("--report", default="ai/runs/project_checks.json")
    args = parser.parse_args()
    try:
        godot = find_godot(args.godot)
    except FileNotFoundError as error:
        print(f"GODOT NOT FOUND: {error}", file=sys.stderr)
        raise SystemExit(2) from error
    runs = ROOT / "ai/runs"
    runs.mkdir(exist_ok=True)
    tasks = []
    if not args.skip_python:
        tasks.append(("python", [sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", "test_*.py"]))
    tasks.extend([
        ("interface_schema_integration", [sys.executable, "tests/interface_schema_integration.py", "--godot", godot]),
        ("replay_integration", [sys.executable, "tests/ai_replay_integration.py", "--godot", godot]),
    ])
    for name in SCRIPTS + (["ai_environment_test"] if args.full else []) + (["ai_training_lifecycle_integration"] if args.lifecycle else []):
        tasks.append((name, [godot, "--headless", "--fixed-fps", "60", "--path", str(ROOT),
                            "--log-file", str(runs / (name + ".log")), "--script", "res://tests/" + name + ".gd"]))
    for name in ["gameplay_test", "environment_generation_smoke"] + (["environment_stress_test"] if args.full else []):
        tasks.append((name, [godot, "--headless", "--fixed-fps", "60", "--path", str(ROOT),
                            "--log-file", str(runs / (name + ".log")), "res://tests/" + name + ".tscn"]))
    results = []
    for name, command in tasks:
        start = time.monotonic()
        try:
            returncode, output, timed_out = run_command(command, args.timeout)
            passed = not timed_out and returncode == 0 and "SCRIPT ERROR:" not in output
        except OSError as error:
            returncode, output, timed_out = None, str(error), False
            passed = False
        results.append(dict(
            name=name,
            passed=passed,
            seconds=round(time.monotonic() - start, 2),
            returncode=returncode,
            timed_out=timed_out,
            output=output,
        ))
        print(f"{'PASS' if passed else 'FAIL'} {name} ({results[-1]['seconds']}s)", flush=True)
        if not passed:
            print(output[-8000:], flush=True)
    report = ROOT / args.report if not Path(args.report).is_absolute() else Path(args.report)
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps(results, indent=2), encoding="utf-8")
    failures = sum(not result["passed"] for result in results)
    print(f"{len(results)-failures}/{len(results)} checks passed. Report: {report}")
    raise SystemExit(bool(failures))

if __name__ == "__main__":
    main()
