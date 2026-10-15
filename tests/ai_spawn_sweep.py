"""Check that seeded training episodes start on collision-free road poses."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ai"))

from godot_bridge import GodotBridge


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--count", type=int, default=12)
    arguments = parser.parse_args()
    checked = 0
    with GodotBridge(arguments.godot) as bridge:
        for offset in range(arguments.count):
            for stage in (0, 7):
                seed = 12000 + offset
                response = bridge.request(
                    {
                        "type": "reset",
                        "seed": seed,
                        "options": {"curriculum": False, "curriculum_stage": stage},
                    }
                )
                if not response["info"].get("spawn_clear", False):
                    raise RuntimeError(f"Seed {seed}, stage {stage} spawned on a barrier")
                checked += 1
    print(f"SPAWN SWEEP PASSED: {checked} seeded routes start with full-body curb clearance")


if __name__ == "__main__":
    main()
