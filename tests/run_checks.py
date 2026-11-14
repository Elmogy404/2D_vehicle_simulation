"""Run project checks with one command; optionally include environment sweeps.

Usage: .venv-ai/Scripts/python.exe tests/run_checks.py --godot PATH --full
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
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
           "ai_training_ui_test", "map_regeneration_shortcut_test"]

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    parser.add_argument("--full", action="store_true")
    parser.add_argument("--lifecycle", action="store_true", help="Start a short isolated real PPO session to check pause/resume/save")
    parser.add_argument("--report", default="ai/runs/project_checks.json")
    args = parser.parse_args()
    godot = find_godot(args.godot)
    runs = ROOT / "ai/runs"
    runs.mkdir(exist_ok=True)
    tasks = [("python", [sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", "test_*.py"])]
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
            result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True,
                                    encoding="utf-8", errors="replace", timeout=300)
            output = result.stdout + result.stderr
            passed = result.returncode == 0 and "SCRIPT ERROR:" not in output
        except subprocess.TimeoutExpired:
            passed, output = False, "Timed out after 300 seconds"
        results.append(dict(name=name, passed=passed, seconds=round(time.monotonic()-start, 2), output=output))
        print(f"{'PASS' if passed else 'FAIL'} {name} ({results[-1]['seconds']}s)", flush=True)
        if not passed:
            print(output[-8000:], flush=True)
    report = ROOT / args.report
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps(results, indent=2), encoding="utf-8")
    failures = sum(not result["passed"] for result in results)
    print(f"{len(results)-failures}/{len(results)} checks passed. Report: {report}")
    raise SystemExit(bool(failures))

if __name__ == "__main__":
    main()
