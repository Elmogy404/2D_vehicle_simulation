"""Evaluate a saved Setup 2 policy on deterministic, held-out map seeds."""

from __future__ import annotations

import argparse
import csv
import io
from pathlib import Path
import zipfile
from unittest.mock import patch

from stable_baselines3 import PPO
import torch

from godot_gym_env import GodotRoadEnv


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, help="Saved Stable-Baselines3 PPO model")
    parser.add_argument("--episodes", type=int, default=50)
    parser.add_argument("--seed", type=int, default=10_000)
    parser.add_argument(
        "--curriculum-stage",
        type=int,
        default=0,
        help="Evaluate a fixed goal-distance tier (0=shortest, 7=longest, 4,200–5,500 units)",
    )
    parser.add_argument(
        "--success-threshold",
        type=float,
        default=0.9,
        help="Report whether the success rate meets this gate (default: 0.9)",
    )
    parser.add_argument("--output-csv", help="Optional path for per-episode metrics")
    parser.add_argument(
        "--visible",
        action="store_true",
        help="Open the Godot Setup 2 world window while evaluating the policy",
    )
    parser.add_argument("--godot", help="Godot 4 executable; defaults to GODOT_BIN/PATH")
    arguments = parser.parse_args()
    if arguments.episodes < 1:
        parser.error("--episodes must be at least 1")
    if arguments.curriculum_stage not in range(8):
        parser.error("--curriculum-stage must be from 0 to 7")
    if not 0.0 <= arguments.success_threshold <= 1.0:
        parser.error("--success-threshold must be between 0 and 1")

    model_path = Path(arguments.model)
    # SB3 passes ZIP members directly to torch.load. On this Windows/PyTorch
    # combination, torch's archive reader rejects ZipExtFile even though the
    # checkpoint is valid; buffering each member makes the reader seekable.
    original_torch_load = torch.load

    def load_buffered_zip_member(
        file_object: object,
        *args: object,
        **kwargs: object,
    ) -> object:
        if isinstance(file_object, zipfile.ZipExtFile):
            file_object = io.BytesIO(file_object.read())
        return original_torch_load(file_object, *args, **kwargs)

    with patch.object(torch, "load", side_effect=load_buffered_zip_member):
        model = PPO.load(model_path, device="cpu")
    env = GodotRoadEnv(arguments.godot, visible=arguments.visible)
    results: list[dict[str, float | bool]] = []
    try:
        for episode in range(arguments.episodes):
            observation, _info = env.reset(
                seed=arguments.seed + episode,
                options={
                    "curriculum": False,
                    "curriculum_stage": arguments.curriculum_stage,
                },
            )
            episode_return = 0.0
            steps = 0
            final_info: dict[str, object] = {}
            while True:
                action, _state = model.predict(observation, deterministic=True)
                observation, reward, terminated, truncated, final_info = env.step(action)
                episode_return += reward
                steps += 1
                if terminated or truncated:
                    break
            results.append(
                {
                    "seed": arguments.seed + episode,
                    "curriculum_stage": arguments.curriculum_stage,
                    "success": bool(final_info.get("success", False)),
                    "crashed": bool(final_info.get("crashed", False)),
                    "off_road": bool(final_info.get("off_road", False)),
                    "route_turns": int(final_info.get("route_turns", 0)),
                    "turn_requirement_met": bool(
                        final_info.get("turn_requirement_met", False)
                    ),
                    "steps": float(steps),
                    "return": episode_return,
                }
            )
            print(
                "episode %d/%d seed=%d success=%s turns=%d steps=%d return=%.2f"
                % (
                    episode + 1,
                    arguments.episodes,
                    arguments.seed + episode,
                    results[-1]["success"],
                    results[-1]["route_turns"],
                    steps,
                    episode_return,
                )
            )
    finally:
        env.close()

    count = float(len(results))
    success_rate = sum(bool(result["success"]) for result in results) / count
    crash_rate = sum(bool(result["crashed"]) for result in results) / count
    off_road_rate = sum(bool(result["off_road"]) for result in results) / count
    turn_coverage_rate = sum(
        bool(result["turn_requirement_met"]) for result in results
    ) / count
    evaluation_passed = (
        success_rate >= arguments.success_threshold
        and turn_coverage_rate >= arguments.success_threshold
    )
    print(
        "SUMMARY episodes=%d stage=%d success=%.1f%% crash=%.1f%% off_road=%.1f%% "
        "turn_coverage=%.1f%% mean_steps=%.1f mean_turns=%.2f mean_return=%.2f "
        "gate=%s (required %.0f%%)"
        % (
            len(results),
            arguments.curriculum_stage,
            100.0 * success_rate,
            100.0 * crash_rate,
            100.0 * off_road_rate,
            100.0 * turn_coverage_rate,
            sum(float(result["steps"]) for result in results) / count,
            sum(float(result["route_turns"]) for result in results) / count,
            sum(float(result["return"]) for result in results) / count,
            "PASS" if evaluation_passed else "NOT MET",
            100.0 * arguments.success_threshold,
        )
    )
    if arguments.output_csv:
        output_path = Path(arguments.output_csv)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with output_path.open("w", newline="", encoding="utf-8") as csv_file:
            writer = csv.DictWriter(csv_file, fieldnames=list(results[0]))
            writer.writeheader()
            writer.writerows(results)
        print(f"Episode metrics saved to {output_path}")


if __name__ == "__main__":
    main()
