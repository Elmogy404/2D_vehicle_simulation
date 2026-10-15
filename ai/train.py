"""Train the Setup 2 PPO policy for long, graph-planned road routes."""

from __future__ import annotations

import argparse
import csv
from functools import partial
import json
from pathlib import Path

from godot_gym_env import GodotRoadEnv
from training_control import TrainingControl, parse_reward_config


def load_sb3_checkpoint(path: str, env: object) -> object:
    """Load SB3 weights safely from a ZIP member on the local Windows/PyTorch runtime."""
    import io
    import zipfile
    from unittest.mock import patch

    import torch
    from stable_baselines3 import PPO

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
        return PPO.load(path, env=env, device="cpu")


def make_training_env(godot_executable: str | None, reward_config: dict[str, float]) -> object:
    from stable_baselines3.common.monitor import Monitor

    return Monitor(GodotRoadEnv(godot_executable, reward_config=reward_config))


def main() -> None:
    # Keep torch/SB3 out of spawned worker imports to limit per-worker memory.
    from stable_baselines3 import PPO
    from stable_baselines3.common.callbacks import CallbackList, CheckpointCallback, BaseCallback
    from stable_baselines3.common.vec_env import SubprocVecEnv

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--steps", type=int, default=1_000_000)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--n-envs", type=int, default=1, help="Parallel Godot training worlds")
    parser.add_argument("--learning-rate", type=float, default=3e-4)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--gamma", type=float, default=0.995)
    parser.add_argument("--entropy-coefficient", type=float, default=0.01)
    parser.add_argument("--checkpoint-every", type=int, default=10_240)
    parser.add_argument(
        "--run-name",
        default="setup2_network_routes_ppo_v1",
        help="Versioned basename for this run's model/checkpoints (without extension)",
    )
    parser.add_argument("--eval-every", type=int, default=50_000)
    parser.add_argument(
        "--eval-episodes",
        type=int,
        default=16,
        help="Mixed-tier deterministic episodes per checkpoint evaluation",
    )
    parser.add_argument("--eval-seed", type=int, default=10_000)
    parser.add_argument("--success-threshold", type=float, default=0.9)
    parser.add_argument(
        "--early-stop-patience",
        type=int,
        default=3,
        help=(
            "Stop after this many consecutive evaluations meet the overall and "
            "longest-route success gates; set 0 to disable"
        ),
    )
    parser.add_argument(
        "--resume",
        help="Resume a checkpoint from the same reward-version/run name up to --steps total",
    )
    parser.add_argument("--godot", help="Godot 4 executable; defaults to GODOT_BIN/PATH")
    parser.add_argument("--reward-config", help="JSON overrides for this run's reward weights")
    parser.add_argument("--reward-config-file", help="JSON file with reward weights for this run")
    parser.add_argument("--control-file", help="JSON command file used by the Godot training GUI")
    parser.add_argument("--status-file", help="JSON status file read by the Godot training GUI")
    parser.add_argument("--gui-log-path", default="", help="Log path displayed by the Godot training GUI")
    parser.add_argument("--run-id", default="cli", help="Unique ID guarding GUI control commands")
    parser.add_argument("--output-root", help="Directory for models and evaluation logs; defaults to ai/")
    arguments = parser.parse_args()
    if arguments.reward_config and arguments.reward_config_file:
        parser.error("use either --reward-config or --reward-config-file, not both")
    try:
        reward_source = (
            Path(arguments.reward_config_file).read_text(encoding="utf-8")
            if arguments.reward_config_file else arguments.reward_config
        )
        reward_config = parse_reward_config(reward_source)
    except (OSError, ValueError, TypeError) as error:
        parser.error(str(error))
    if arguments.steps < 1:
        parser.error("--steps must be at least 1")
    if arguments.n_envs < 1:
        parser.error("--n-envs must be at least 1")
    if not 0.0 < arguments.learning_rate <= 0.01:
        parser.error("--learning-rate must be positive and at most 0.01")
    if arguments.batch_size < 1:
        parser.error("--batch-size must be positive")
    if not 0.0 < arguments.gamma < 1.0:
        parser.error("--gamma must be between 0 and 1")
    if not 0.0 <= arguments.entropy_coefficient <= 1.0:
        parser.error("--entropy-coefficient must be between 0 and 1")
    if arguments.checkpoint_every < 1:
        parser.error("--checkpoint-every must be at least 1")
    if arguments.eval_every < 0:
        parser.error("--eval-every must be zero (disabled) or positive")
    if arguments.eval_episodes < 1:
        parser.error("--eval-episodes must be at least 1")
    if arguments.early_stop_patience < 0:
        parser.error("--early-stop-patience must be zero (disabled) or positive")
    if arguments.eval_every == 0 and arguments.early_stop_patience > 0:
        parser.error("--eval-every 0 requires --early-stop-patience 0")
    if not 0.0 <= arguments.success_threshold <= 1.0:
        parser.error("--success-threshold must be between 0 and 1")
    if Path(arguments.run_name).name != arguments.run_name or arguments.run_name.endswith(".zip"):
        parser.error("--run-name must be a basename without a .zip extension")
    if arguments.resume and arguments.run_name not in Path(arguments.resume).name:
        parser.error(
            "--resume must use a checkpoint from the same run/reward version; "
            "start fresh after changing the reward"
        )

    output_root = Path(arguments.output_root).resolve() if arguments.output_root else Path(__file__).resolve().parent
    model_dir = output_root / "models"
    model_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = model_dir / f"{arguments.run_name}_training_config.json"
    manifest = {
        "reward_config": reward_config,
        "learning_rate": arguments.learning_rate,
        "batch_size": arguments.batch_size,
        "gamma": arguments.gamma,
        "entropy_coefficient": arguments.entropy_coefficient,
    }
    if arguments.resume and manifest_path.exists():
        previous_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        if previous_manifest != manifest:
            parser.error(
                "resume settings differ from this run's saved reward/PPO settings; "
                "keep the original values or start a new run"
            )
    elif arguments.resume:
        print("Warning: no run manifest exists; reward/PPO settings cannot be verified.", flush=True)
    else:
        manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    checkpoint_dir = model_dir / "checkpoints"
    checkpoint_dir.mkdir(parents=True, exist_ok=True)
    runs_dir = output_root / "runs"
    runs_dir.mkdir(parents=True, exist_ok=True)
    control = TrainingControl(
        arguments.control_file,
        arguments.status_file,
        arguments.run_id,
        arguments.run_name,
        arguments.steps,
        arguments.n_envs,
        arguments.gui_log_path,
    )
    control.write_status("starting", 0, "Starting training worlds")
    try:
        if arguments.n_envs == 1:
            env = make_training_env(arguments.godot, reward_config)
            rollout_steps = 1024
        else:
            env = SubprocVecEnv(
                [partial(make_training_env, arguments.godot, reward_config) for _ in range(arguments.n_envs)],
                start_method="spawn",
            )
            # Keep each PPO update near a 1,024-transition batch as workers increase.
            rollout_steps = max(128, 1024 // arguments.n_envs)
    except Exception as error:
        control.write_status("failed", 0, str(error))
        raise
    evaluation_env: object | None = None
    try:
        if arguments.resume:
            model = load_sb3_checkpoint(arguments.resume, env)
            remaining_steps = arguments.steps - model.num_timesteps
            if remaining_steps <= 0:
                parser.error(
                    "resume checkpoint already has %d steps; --steps must be larger"
                    % model.num_timesteps
                )
            print(
                "Resuming at %d/%d timesteps" % (model.num_timesteps, arguments.steps),
                flush=True,
            )
        else:
            model = PPO(
                "MlpPolicy",
                env,
                verbose=1,
                seed=arguments.seed,
                n_steps=rollout_steps,
                batch_size=arguments.batch_size,
                learning_rate=arguments.learning_rate,
                gamma=arguments.gamma,
                gae_lambda=0.95,
                ent_coef=arguments.entropy_coefficient,
                device="cpu",
            )
            remaining_steps = arguments.steps

        callbacks = [
            CheckpointCallback(
                save_freq=max(1, arguments.checkpoint_every // arguments.n_envs),
                save_path=str(checkpoint_dir),
                name_prefix=arguments.run_name,
                verbose=1,
            )
        ]

        class GuiControlCallback(BaseCallback):
            def _on_training_start(self) -> None:
                control.write_status("running", self.num_timesteps, "Training in progress")

            def _on_step(self) -> bool:
                return control.poll(self.num_timesteps)

        callbacks.append(GuiControlCallback())

        if arguments.eval_every > 0:
            evaluation_env = make_training_env(arguments.godot, reward_config)

            class SuccessRateEvalCallback(BaseCallback):
                """Compare checkpoints by a fixed, mixed-difficulty success suite."""

                def __init__(self) -> None:
                    super().__init__(verbose=0)
                    self.next_eval_timestep = arguments.eval_every
                    self.best_score: tuple[float, float, float, float, float, float] | None = None
                    self.early_stop_streak = 0
                    self.can_early_stop = arguments.eval_episodes >= 8
                    self.best_path = model_dir / f"{arguments.run_name}_best"
                    self.csv_path = runs_dir / f"{arguments.run_name}_success_eval.csv"
                    if not self.csv_path.exists():
                        with self.csv_path.open("w", newline="", encoding="utf-8") as csv_file:
                            csv.writer(csv_file).writerow(
                                [
                                    "timesteps",
                                    "episodes",
                                    "stage_mix",
                                    "success_rate",
                                    "crash_rate",
                                    "off_road_rate",
                                    "mean_steps",
                                    "mean_route_turns",
                                    "longest_stage_success_rate",
                                    "longest_stage_turn_coverage",
                                    "mean_return",
                                    "best_checkpoint_saved",
                                    "90_percent_gate_met",
                                    "early_stop_streak",
                                ]
                            )

                def _on_training_start(self) -> None:
                    self.next_eval_timestep = (
                        self.num_timesteps // arguments.eval_every + 1
                    ) * arguments.eval_every
                    if arguments.early_stop_patience > 0 and not self.can_early_stop:
                        print(
                            "Early stopping disabled for this run: --eval-episodes "
                            "must cover all 8 route-distance stages.",
                            flush=True,
                        )

                def _on_step(self) -> bool:
                    if self.num_timesteps < self.next_eval_timestep:
                        return True
                    self.next_eval_timestep += arguments.eval_every
                    if not control.poll(self.num_timesteps):
                        return False

                    outcomes: list[dict[str, float | bool | int]] = []
                    for episode in range(arguments.eval_episodes):
                        stage = episode % 8
                        observation, _reset_info = evaluation_env.reset(
                            seed=arguments.eval_seed + episode,
                            options={
                                "curriculum": False,
                                "curriculum_stage": stage,
                            },
                        )
                        episode_return = 0.0
                        steps = 0
                        final_info: dict[str, object] = {}
                        while True:
                            if steps % 64 == 0 and not control.poll(self.num_timesteps):
                                return False
                            action, _state = self.model.predict(
                                observation, deterministic=True
                            )
                            (
                                observation,
                                reward,
                                terminated,
                                truncated,
                                final_info,
                            ) = evaluation_env.step(action)
                            episode_return += float(reward)
                            steps += 1
                            if terminated or truncated:
                                break
                        outcomes.append(
                            {
                                "stage": stage,
                                "success": bool(final_info.get("success", False)),
                                "crashed": bool(final_info.get("crashed", False)),
                                "off_road": bool(final_info.get("off_road", False)),
                                "steps": float(steps),
                                "route_turns": float(final_info.get("route_turns", 0)),
                                "turn_requirement_met": bool(
                                    final_info.get("turn_requirement_met", False)
                                ),
                                "return": episode_return,
                            }
                        )

                    count = float(len(outcomes))
                    success_rate = sum(
                        bool(item["success"]) for item in outcomes
                    ) / count
                    crash_rate = sum(
                        bool(item["crashed"]) for item in outcomes
                    ) / count
                    off_road_rate = sum(
                        bool(item["off_road"]) for item in outcomes
                    ) / count
                    mean_steps = sum(float(item["steps"]) for item in outcomes) / count
                    mean_route_turns = sum(
                        float(item["route_turns"]) for item in outcomes
                    ) / count
                    mean_return = sum(float(item["return"]) for item in outcomes) / count
                    longest_stage_outcomes = [
                        item for item in outcomes if int(item["stage"]) == 7
                    ]
                    longest_stage_success_rate = (
                        sum(bool(item["success"]) for item in longest_stage_outcomes)
                        / float(len(longest_stage_outcomes))
                        if longest_stage_outcomes
                        else 0.0
                    )
                    longest_stage_turn_coverage = (
                        sum(bool(item.get("turn_requirement_met", False)) for item in longest_stage_outcomes)
                        / float(len(longest_stage_outcomes))
                        if longest_stage_outcomes
                        else 0.0
                    )
                    stage_mix = ";".join(
                        str(int(item["stage"])) for item in outcomes
                    )
                    score = (
                        longest_stage_success_rate,
                        longest_stage_turn_coverage,
                        success_rate,
                        -crash_rate,
                        -off_road_rate,
                        mean_return,
                    )
                    save_best = self.best_score is None or score > self.best_score
                    if save_best:
                        self.best_score = score
                        self.model.save(self.best_path)

                    overall_gate_met = success_rate >= arguments.success_threshold
                    longest_route_gate_met = (
                        longest_stage_success_rate >= arguments.success_threshold
                        and longest_stage_turn_coverage >= arguments.success_threshold
                    )
                    gate_met = overall_gate_met and longest_route_gate_met
                    if arguments.early_stop_patience > 0 and self.can_early_stop:
                        self.early_stop_streak = self.early_stop_streak + 1 if gate_met else 0
                    print(
                        "SUCCESS EVAL steps=%d episodes=%d stages=%s success=%.1f%% "
                        "crash=%.1f%% off_road=%.1f%% mean_steps=%.1f turns=%.2f "
                        "longest_stage=%.1f%% turn_coverage=%.1f%% mean_return=%.2f best_saved=%s "
                        "gate_%d%%=%s stop_streak=%d/%d"
                        % (
                            self.num_timesteps,
                            len(outcomes),
                            stage_mix,
                            success_rate * 100.0,
                            crash_rate * 100.0,
                            off_road_rate * 100.0,
                            mean_steps,
                            mean_route_turns,
                            longest_stage_success_rate * 100.0,
                            longest_stage_turn_coverage * 100.0,
                            mean_return,
                            save_best,
                            int(arguments.success_threshold * 100),
                            gate_met,
                            self.early_stop_streak,
                            arguments.early_stop_patience,
                        ),
                        flush=True,
                    )
                    control.last_evaluation = {
                        "timesteps": self.num_timesteps,
                        "success_rate": success_rate,
                        "crash_rate": crash_rate,
                        "off_road_rate": off_road_rate,
                        "longest_stage_success_rate": longest_stage_success_rate,
                        "best_checkpoint_saved": save_best,
                    }
                    control.write_status("running", self.num_timesteps, "Evaluation complete")
                    with self.csv_path.open("a", newline="", encoding="utf-8") as csv_file:
                        csv.writer(csv_file).writerow(
                            [
                                self.num_timesteps,
                                len(outcomes),
                                stage_mix,
                                success_rate,
                                crash_rate,
                                off_road_rate,
                                mean_steps,
                                mean_route_turns,
                                longest_stage_success_rate,
                                longest_stage_turn_coverage,
                                mean_return,
                                save_best,
                                gate_met,
                                self.early_stop_streak,
                            ]
                        )
                    if (
                        arguments.early_stop_patience > 0
                        and self.can_early_stop
                        and self.early_stop_streak >= arguments.early_stop_patience
                    ):
                        print(
                            "EARLY STOP: success gates held for %d consecutive evaluations at %d timesteps."
                            % (self.early_stop_streak, self.num_timesteps),
                            flush=True,
                        )
                        return False
                    return True

            callbacks.append(SuccessRateEvalCallback())

        callback = CallbackList(callbacks)
        model.learn(
            total_timesteps=remaining_steps,
            callback=callback,
            progress_bar=False,
            reset_num_timesteps=not bool(arguments.resume),
        )
        output = model_dir / arguments.run_name
        control.write_status("saving", model.num_timesteps, "Saving the latest PPO model")
        model.save(output)
        print(f"Saved PPO policy to {output}.zip")
        control.write_status(
            "stopped" if control.stop_requested else "completed",
            model.num_timesteps,
            f"Model saved to {output}.zip",
        )
    except Exception as error:
        control.write_status("failed", model.num_timesteps if "model" in locals() else 0, str(error))
        raise
    finally:
        if evaluation_env is not None:
            evaluation_env.close()
        env.close()


if __name__ == "__main__":
    main()
