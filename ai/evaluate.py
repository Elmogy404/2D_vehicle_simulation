"""Evaluate a saved Setup 2 policy on deterministic, held-out map seeds."""

from __future__ import annotations

import argparse
import csv
from pathlib import Path

from godot_gym_env import GodotRoadEnv
from deterministic_seeds import set_global_seeds
from episode_recording import EpisodeRecorder
from interface_schema import SCHEMA_VERSION, SchemaCompatibilityError
from policy_checkpoint import (
    STRATEGIES,
    CheckpointError,
    checkpoint_generator,
    load_policy,
    resolve_checkpoint,
)
from reward_config import RewardConfigError, reward_config_from_manifest
from training_metrics import summarize_evaluation, evaluation_gate


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", help="Saved Stable-Baselines3 PPO model; overrides discovery")
    parser.add_argument("--model-dir", type=Path, help="Override the configured checkpoint directory")
    parser.add_argument("--strategy", choices=STRATEGIES, help="Automatic checkpoint selection strategy")
    parser.add_argument("--manifest", type=Path, help="Optional training manifest for the selected checkpoint")
    parser.add_argument("--config", type=Path, help="Optional checkpoint_config.json path")
    parser.add_argument("--require-manifest", action="store_true", help="Reject checkpoints without a valid manifest")
    parser.add_argument("--episodes", type=int, default=50)
    parser.add_argument("--seed", type=int, default=1_000_000)
    parser.add_argument("--all-stages", action="store_true", help="Evaluate all eight tiers on independent holdout seeds")
    parser.add_argument("--min-stage-episodes", type=int, default=16)
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
        "--record",
        type=Path,
        help="Write one versioned deterministic replay recording to this JSONL path",
    )
    parser.add_argument(
        "--record-episode",
        type=int,
        default=0,
        help="Zero-based evaluation episode to record when --record is used",
    )
    parser.add_argument(
        "--record-full-info",
        action="store_true",
        help="Store the complete per-step info payload instead of the compact replay fields",
    )
    parser.add_argument(
        "--visible",
        action="store_true",
        help="Open the Godot Setup 2 world window while evaluating the policy",
    )
    parser.add_argument("--godot", help="Godot 4 executable; defaults to GODOT_BIN/PATH")
    parser.add_argument("--generator-type", choices=["original", "segmented"])
    arguments = parser.parse_args()
    if arguments.episodes < 1:
        parser.error("--episodes must be at least 1")
    if arguments.curriculum_stage not in range(8):
        parser.error("--curriculum-stage must be from 0 to 7")
    if not 0.0 <= arguments.success_threshold <= 1.0:
        parser.error("--success-threshold must be between 0 and 1")
    if arguments.record_episode not in range(arguments.episodes):
        parser.error("--record-episode must identify an episode in the requested evaluation range")
    set_global_seeds(arguments.seed)

    model_path = Path(arguments.model) if arguments.model else None
    try:
        resolved = resolve_checkpoint(
            model_path,
            config_path=arguments.config,
            model_dir=arguments.model_dir,
            manifest=arguments.manifest,
            strategy=arguments.strategy,
            require_manifest=arguments.require_manifest,
        )
        print(
            "Using checkpoint %s (source=%s, strategy=%s, steps=%d)"
            % (resolved.path, resolved.source, resolved.strategy, resolved.num_timesteps),
            flush=True,
        )
        model = load_policy(
            resolved.path,
            manifest=resolved.manifest_path,
            require_manifest=arguments.require_manifest,
        )
        reward_config = reward_config_from_manifest(
            resolved.manifest,
            source=f"checkpoint manifest {resolved.manifest_path or '(none)'}",
        )
    except (CheckpointError, SchemaCompatibilityError, RewardConfigError) as error:
        parser.error(str(error))
    env = GodotRoadEnv(
        arguments.godot,
        visible=arguments.visible,
        reward_config=reward_config,
        generator_type=checkpoint_generator(resolved.path, arguments.generator_type, manifest=resolved.manifest_path),
    )
    results: list[dict[str, float | bool]] = []
    recorder: EpisodeRecorder | None = None
    try:
        for episode in range(arguments.episodes):
            stage = episode % 8 if arguments.all_stages else arguments.curriculum_stage
            reset_options = {
                "curriculum": False,
                "curriculum_stage": stage,
            }
            if arguments.record and episode == arguments.record_episode:
                recorder = EpisodeRecorder(
                    arguments.record,
                    environment_version=env.environment_version,
                    reward_config=reward_config,
                    generator_type=env.generator_type,
                    master_seed=arguments.seed,
                    capture_full_info=arguments.record_full_info,
                )
            observation, _info = env.reset(
                seed=arguments.seed + episode,
                options=reset_options,
            )
            if recorder is not None:
                recorder.record_reset(
                    observation,
                    _info,
                    episode_seed=arguments.seed + episode,
                    options=reset_options,
                )
            episode_return = 0.0
            steps = 0
            final_info: dict[str, object] = {}
            terminated = truncated = False
            while True:
                action, _state = model.predict(observation, deterministic=True)
                observation, reward, terminated, truncated, final_info = env.step(action)
                episode_return += reward
                steps += 1
                if recorder is not None:
                    recorder.record_step(
                        index=steps - 1,
                        action=action,
                        observation=observation,
                        reward=reward,
                        terminated=terminated,
                        truncated=truncated,
                        info=final_info,
                    )
                if terminated or truncated:
                    break
            if recorder is not None:
                recorder.close(terminated=terminated, truncated=truncated)
                print(f"Recorded replay episode to {arguments.record}")
                recorder = None
            results.append(
                {
                    "seed": arguments.seed + episode,
                    "curriculum_stage": stage,
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
        if recorder is not None:
            recorder.close()
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
        "SUMMARY episodes=%d stage=%d schema=%d success=%.1f%% crash=%.1f%% off_road=%.1f%% "
        "turn_coverage=%.1f%% mean_steps=%.1f mean_turns=%.2f mean_return=%.2f "
        "gate=%s (required %.0f%%)"
        % (
            len(results),
            arguments.curriculum_stage,
            SCHEMA_VERSION,
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
    if arguments.all_stages:
        summary = summarize_evaluation([dict(x, stage=x["curriculum_stage"]) for x in results])
        for stage in summary["stages"]:
            print(f"STAGE {stage['stage']}: {stage.get('successes', 0)}/{stage.get('episodes', 0)} goals; 95% interval={stage.get('success_interval')}")
        print("ALL-STAGE GATE:", evaluation_gate(summary, arguments.success_threshold, arguments.min_stage_episodes))


if __name__ == "__main__":
    main()
