"""Train the Setup 2 PPO policy for long, graph-planned road routes."""

from __future__ import annotations

import argparse
from functools import partial
import json
import math
from pathlib import Path

from godot_gym_env import ENVIRONMENT_VERSION, GodotRoadEnv
from training_control import TrainingControl, parse_reward_config
from training_config import TRAINING_DEFAULTS, prepare_manifest, runtime_provenance
from policy_checkpoint import load_policy as load_sb3_checkpoint


def make_training_env(godot_executable: str | None, reward_config: dict[str, float], generator_type: str = "original", *,
                      parent_window_id: int | None = None) -> object:
    from stable_baselines3.common.monitor import Monitor

    if parent_window_id is None:
        return Monitor(GodotRoadEnv(godot_executable, reward_config=reward_config, generator_type=generator_type))
    return Monitor(GodotRoadEnv(godot_executable, reward_config=reward_config, visible=True,
                               parent_window_id=parent_window_id, close_visible_on_exit=True, generator_type=generator_type))


def capture_training_state(model: object) -> None:
    """Store worker curriculum and RNG alongside the policy in every ZIP."""
    model.training_environment_state = {
        "version": ENVIRONMENT_VERSION,
        "workers": model.get_env().env_method("get_training_state"),
    }


def restore_training_state(model: object) -> None:
    snapshot = getattr(model, "training_environment_state", None)
    if not snapshot or snapshot.get("version") != ENVIRONMENT_VERSION:
        raise ValueError("Checkpoint uses the old training environment; start a fresh run after the environment fixes.")
    env = model.get_env()
    workers = snapshot["workers"]
    if len(workers) != env.num_envs:
        raise ValueError("Resume with the original worker count to preserve each worker's curriculum.")
    for index, state in enumerate(workers):
        env.env_method("set_training_state", state, indices=index)


def main() -> None:
    # Keep torch/SB3 out of spawned worker imports to limit per-worker memory.
    from stable_baselines3 import PPO
    import torch
    from training_callbacks import make_callbacks
    from stable_baselines3.common.vec_env import SubprocVecEnv

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--steps", type=int, default=1_000_000)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--n-envs", type=int, default=1, help="Parallel Godot training worlds")
    parser.add_argument("--generator-type", choices=["original", "segmented"], default="original")
    parser.add_argument("--learning-rate", type=float, default=3e-4)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--gamma", type=float, default=0.999)
    parser.add_argument("--entropy-coefficient", type=float, default=0.01)
    parser.add_argument("--checkpoint-every", type=int, default=10_240)
    parser.add_argument(
        "--run-name",
        default="setup2_network_routes_ppo_v3",
        help="Versioned basename for this run's model/checkpoints (without extension)",
    )
    parser.add_argument("--torch-threads", type=int, default=1)
    parser.add_argument("--eval-workers", type=int, default=4)
    parser.add_argument("--eval-every", type=int, default=50_000)
    parser.add_argument(
        "--eval-episodes",
        type=int,
        default=128,
        help="Mixed-tier deterministic episodes per checkpoint evaluation",
    )
    parser.add_argument("--eval-seed", type=int, default=10_000)
    parser.add_argument("--min-eval-stage-episodes", type=int, default=16)
    parser.add_argument("--final-eval-episodes", type=int, default=256, help="Independent final holdout episodes; 0 disables")
    parser.add_argument("--final-eval-seed", type=int, default=1_000_000)
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
    parser.add_argument("--visual-parents", help="JSON file listing one native GUI parent window ID per training worker")
    parser.set_defaults(**{("n_envs" if key == "workers" else key): value for key, value in TRAINING_DEFAULTS.items()
                           if key not in {"run_name", "resume", "output_root"}})
    arguments = parser.parse_args()
    visual_parents = None
    if arguments.visual_parents:
        try:
            visual_parents = json.loads(Path(arguments.visual_parents).read_text(encoding="utf-8"))
            if (not isinstance(visual_parents, list) or len(visual_parents) != arguments.n_envs
                    or any(type(x) is not int or x <= 0 for x in visual_parents)
                    or len(set(visual_parents)) != len(visual_parents)):
                raise ValueError("provide one distinct positive window ID per training worker")
        except (OSError, ValueError) as error:
            parser.error(f"Invalid --visual-parents: {error}")
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
    if not 1 <= arguments.torch_threads <= 64 or not 1 <= arguments.eval_workers <= 32:
        parser.error("thread and evaluation worker counts must be positive and within their supported limits")
    torch.set_num_threads(arguments.torch_threads)
    if arguments.steps < 1:
        parser.error("--steps must be at least 1")
    if arguments.n_envs < 1:
        parser.error("--n-envs must be at least 1")
    if arguments.n_envs > 32:
        print(
            f"Warning: {arguments.n_envs} workers selected. More than 32 workers "
            "can use a lot of CPU and RAM, slow training, or run out of memory. "
            "Training is still allowed.", flush=True,
        )
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
    if arguments.min_eval_stage_episodes < 1 or arguments.final_eval_episodes < 0:
        parser.error("evaluation sample limits must be positive (final evaluation may be zero)")
    if arguments.final_eval_episodes and max(arguments.eval_seed, arguments.final_eval_seed) < min(
            arguments.eval_seed + arguments.eval_episodes, arguments.final_eval_seed + arguments.final_eval_episodes):
        parser.error("final holdout seeds must not overlap the checkpoint-selection seeds")
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
        "environment_version": ENVIRONMENT_VERSION,
        "generator_type": arguments.generator_type,
        "workers": arguments.n_envs,
        "evaluation": {"seed": arguments.eval_seed, "episodes": arguments.eval_episodes, "threshold": arguments.success_threshold},
        "reward_config": reward_config,
        "learning_rate": arguments.learning_rate,
        "batch_size": arguments.batch_size,
        "gamma": arguments.gamma,
        "entropy_coefficient": arguments.entropy_coefficient,
    }
    manifest["runtime"] = runtime_provenance()
    manifest["training_options"] = {key: getattr(arguments, "n_envs" if key == "workers" else key)
                                    for key in TRAINING_DEFAULTS if key not in {"run_name", "resume", "output_root"}}
    try:
        prepare_manifest(manifest_path, manifest, resume=bool(arguments.resume))
    except (OSError, ValueError) as error:
        parser.error(str(error))
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
    control.metrics["visual_training"] = visual_parents is not None
    control.write_status("starting", 0, "Starting training worlds")
    # Align the rollout with whole minibatches, including worker counts such as six.
    rollout_steps = max(128, 1024 // arguments.n_envs)
    alignment = arguments.batch_size // math.gcd(arguments.batch_size, arguments.n_envs)
    rollout_steps = ((rollout_steps + alignment - 1) // alignment) * alignment
    try:
        if arguments.n_envs == 1:
            env = (make_training_env(arguments.godot, reward_config, arguments.generator_type, parent_window_id=visual_parents[0])
                   if visual_parents else make_training_env(arguments.godot, reward_config, arguments.generator_type))
        else:
            env = SubprocVecEnv(
                [partial(make_training_env, arguments.godot, reward_config, arguments.generator_type, parent_window_id=parent)
                 for parent in visual_parents] if visual_parents else
                [partial(make_training_env, arguments.godot, reward_config, arguments.generator_type) for _ in range(arguments.n_envs)],
                start_method="spawn",
            )
    except Exception as error:
        control.write_status("failed", 0, str(error))
        raise
    evaluation_env: object | None = None
    try:
        if arguments.resume:
            model = load_sb3_checkpoint(arguments.resume, env)
            restore_training_state(model)
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

        callback, evaluation_env = make_callbacks(
            arguments, control, model, model_dir, runs_dir, capture_training_state,
            partial(make_training_env, arguments.godot, reward_config, arguments.generator_type),
        )
        model.learn(
            total_timesteps=remaining_steps,
            callback=callback,
            progress_bar=False,
            reset_num_timesteps=not bool(arguments.resume),
        )
        output = model_dir / arguments.run_name
        control.write_status("saving", model.num_timesteps, "Saving the latest PPO model")
        capture_training_state(model)
        model.save(output)
        control.metrics["last_model_path"] = str(output) + ".zip"
        if evaluation_env is not None and arguments.final_eval_episodes and not control.stop_requested:
            # Evaluate the selected best model, not the potentially worse final
            # update. This suite must never feed back into model selection.
            best = model_dir / f"{arguments.run_name}_best.zip"
            heldout_model = load_sb3_checkpoint(str(best), None) if best.exists() else model
            evaluation_env.model = heldout_model
            evaluation_env.num_timesteps = model.num_timesteps
            evaluation_env.evaluate(holdout=True)
        control.metrics["phase"] = "finished"
        print(f"Saved PPO policy to {output}.zip")
        control.write_status(
            "stopped" if control.stop_requested else "completed",
            model.num_timesteps,
            f"Model saved to {output}.zip",
        )
    except (Exception, KeyboardInterrupt) as error:
        recovery_note = ""
        if "model" in locals():
            try:
                # A failed subprocess may no longer answer env_method. Save
                # immediately with the last captured curriculum snapshot.
                recovery_path = model_dir / f"{arguments.run_name}_recovery_{model.num_timesteps}_steps"
                model.save(recovery_path)
                recovery_note = f" Recovery policy saved to {recovery_path}.zip."
            except Exception as save_error:
                recovery_note = f" Recovery save failed: {save_error}."
        control.write_status("failed", model.num_timesteps if "model" in locals() else 0, (str(error) or type(error).__name__) + recovery_note)
        raise
    finally:
        if evaluation_env is not None:
            evaluation_env.close()
        env.close()


if __name__ == "__main__":
    main()
