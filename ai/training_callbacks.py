"""Training telemetry and parallel, deterministic checkpoint evaluation."""
from __future__ import annotations

from collections import deque
from concurrent.futures import ThreadPoolExecutor
import csv
import json
import math
import time

import numpy as np
from stable_baselines3.common.callbacks import BaseCallback, CallbackList, CheckpointCallback

from godot_gym_env import ENVIRONMENT_VERSION
from training_metrics import summarize, summarize_evaluation, evaluation_gate


class TrainingObserver(BaseCallback):
    def __init__(self, arguments, control, capture):
        super().__init__()
        self.args, self.control, self.capture = arguments, control, capture
        self.started = self.sample_time = time.perf_counter()
        self.sample_steps = 0
        self.last_publish = 0.0
        self.completed = deque(maxlen=200)
        self.workers = [{} for _ in range(arguments.n_envs)]
        self.history = deque(maxlen=120)
        self.steps_per_second = 0.0
        self.evaluation_seconds = 0.0
        self.last_paused_seconds = 0.0

    def _on_training_start(self):
        self.capture(self.model)
        self.sample_steps = self.num_timesteps
        self.control.write_status("running", self.num_timesteps, "Collecting driving experience")

    def _on_step(self):
        for index, (done, info) in enumerate(zip(self.locals.get("dones", []), self.locals.get("infos", []))):
            state = info.get("training_state", {})
            recent = state.get("recent_results", [])
            self.workers[index] = {
                "worker": index + 1, "stage": state.get("curriculum_stage", info.get("curriculum_stage", 0)),
                "episode_stage": info.get("curriculum_stage", 0), "turn_level": state.get("turn_level", 0),
                "recent_episodes": len(recent), "recent_success_rate": sum(recent) / len(recent) if recent else None,
                "progress": info.get("progress_fraction", 0), "speed_kmh": info.get("speed_kmh", 0),
                "speed_cap_kmh": info.get("speed_cap_kmh", 150), "reset_ms": info.get("reset_ms", 0),
                "map_reused": info.get("map_reused", False), "map_attempts": info.get("map_attempts", 0),
                "godot_pid": info.get("godot_pid"),
            }
            if done:
                episode = info.get("episode", {})
                self.completed.append(dict(info, stage=info.get("curriculum_stage", 0),
                                           **{"return": episode.get("r", 0), "steps": episode.get("l", info.get("episode_steps", 0)),
                                              "truncated": bool(info.get("TimeLimit.truncated", False))}))
        now = time.perf_counter()
        if now - self.last_publish >= 0.5:
            self.publish(now)
        keep_running = self.control.poll(self.num_timesteps)
        if self.control.paused_seconds != self.last_paused_seconds:
            self.sample_time, self.sample_steps = time.perf_counter(), self.num_timesteps
            self.last_paused_seconds = self.control.paused_seconds
        return keep_running

    def _on_rollout_end(self):
        self.control.metrics["phase"] = "optimizing"
        self.control.write_status("running", self.num_timesteps, "Updating the PPO policy")

    def _on_training_end(self):
        # Include the last evaluation and gradient update even when no further
        # environment step triggers the regular telemetry timer.
        self.publish(final=True)

    def publish(self, now=None, *, final=False):
        now = now or time.perf_counter()
        interval = now - self.sample_time
        if interval > 0 and self.num_timesteps > self.sample_steps:
            self.steps_per_second = (self.num_timesteps - self.sample_steps) / interval
        elapsed = now - self.started - self.control.paused_seconds
        remaining = max(0, self.args.steps - self.num_timesteps)
        optimizer = {}
        for key, value in self.model.logger.name_to_value.items():
            if key.startswith("train/") and isinstance(value, (int, float, np.number)) and math.isfinite(float(value)):
                optimizer[key.removeprefix("train/")] = float(value)
        training = summarize(list(self.completed))
        self.history.append({"steps": self.num_timesteps, "return": training.get("mean_return"),
                             "success": training.get("success_rate"), "fps": self.steps_per_second})
        self.control.metrics.update(
            phase="finished" if final else "collecting", performance={"steps_per_second": self.steps_per_second, "elapsed_seconds": elapsed,
                  "eta_seconds": None if final else (remaining / self.steps_per_second if self.steps_per_second else None),
                  "evaluation_seconds": self.evaluation_seconds},
            training_metrics=training, worker_metrics=self.workers, optimizer=optimizer, history=list(self.history),
            next_eval_step=(self.num_timesteps // self.args.eval_every + 1) * self.args.eval_every if self.args.eval_every else None,
        )
        if not final:
            self.control.write_status("running", self.num_timesteps, "Collecting driving experience")
        self.sample_time, self.sample_steps, self.last_publish = now, self.num_timesteps, now


class ParallelEvaluation(BaseCallback):
    def __init__(self, arguments, control, observer, factory, model_dir, runs_dir, capture, model):
        super().__init__()
        self.args, self.control, self.observer = arguments, control, observer
        self.factory, self.model_dir, self.runs_dir, self.capture = factory, model_dir, runs_dir, capture
        self.envs = []
        self.executor = None
        self.best_path = model_dir / f"{arguments.run_name}_best"
        self.score_path = model_dir / f"{arguments.run_name}_best_score.json"
        state = getattr(model, "training_evaluation_state", {})
        self.best_score = tuple(state["best_score"]) if state.get("best_score") is not None else None
        self.streak = int(state.get("early_stop_streak", 0))
        if arguments.resume and state.get("last_evaluation"):
            self.control.last_evaluation = state["last_evaluation"]
        if arguments.resume and self.score_path.exists():
            previous = json.loads(self.score_path.read_text())
            if previous.get("environment_version") == ENVIRONMENT_VERSION:
                candidate = tuple(previous["score"])
                self.best_score = max(self.best_score or candidate, candidate)
        if arguments.resume and self.best_path.with_suffix(".zip").exists():
            self.control.metrics["best_model_path"] = str(self.best_path) + ".zip"
        self.next_eval = (model.num_timesteps // arguments.eval_every + 1) * arguments.eval_every

    def close(self):
        if self.executor is not None:
            self.executor.shutdown(wait=True)
            self.executor = None
        for env in self.envs:
            env.close()
        self.envs.clear()

    def _on_training_end(self):
        self.close()

    def _on_step(self):
        if self.control.stop_requested:
            return False
        if self.num_timesteps < self.next_eval:
            return True
        self.next_eval += self.args.eval_every
        return self.evaluate()

    def evaluate(self, *, holdout=False):
        episode_count = getattr(self.args, "final_eval_episodes", 256) if holdout else self.args.eval_episodes
        seed = getattr(self.args, "final_eval_seed", 1_000_000) if holdout else self.args.eval_seed
        started = time.perf_counter()
        paused_before = self.control.paused_seconds
        self.control.metrics.update(phase="evaluating", evaluation_progress={"completed": 0, "total": episode_count})
        self.control.write_status("running", self.num_timesteps, "Evaluating independent final holdout" if holdout else "Evaluating checkpoint on all eight route stages")
        if not self.envs:
            self.executor = ThreadPoolExecutor(max_workers=min(self.args.eval_workers, episode_count))
            # Append one by one so partial startup is also closed on failure.
            for _ in range(min(self.args.eval_workers, episode_count)):
                self.envs.append(self.factory())
        active = {}
        outcomes = []
        next_episode = 0

        def reset_slot(index, episode):
            obs, info = self.envs[index].reset(seed=seed + episode,
                options={"curriculum": False, "curriculum_stage": episode % 8})
            return {"observation": obs, "stage": episode % 8, "steps": 0, "return": 0.0,
                    "seed": seed + episode, "actual_map_seed": info.get("seed")}

        try:
            pending = {index: self.executor.submit(reset_slot, index, index) for index in range(len(self.envs))}
            active = {index: future.result() for index, future in pending.items()}
            next_episode = len(active)
            last_status = 0.0
            while active:
                if not self.control.poll(self.num_timesteps):
                    return False
                indices = list(active)
                actions, _ = self.model.predict(np.stack([active[i]["observation"] for i in indices]), deterministic=True)
                futures = {i: self.executor.submit(self.envs[i].step, actions[j]) for j, i in enumerate(indices)}
                for i, future in futures.items():
                    obs, reward, terminated, truncated, info = future.result()
                    slot = active[i]
                    slot["steps"] += 1
                    slot["return"] += float(reward)
                    slot["observation"] = obs
                    if terminated or truncated:
                        outcomes.append(dict(info, **{k: v for k, v in slot.items() if k != "observation"}, truncated=bool(truncated)))
                        del active[i]
                pending = {}
                for i in indices:
                    if i not in active and next_episode < episode_count:
                        pending[i] = self.executor.submit(reset_slot, i, next_episode)
                        next_episode += 1
                active.update({i: future.result() for i, future in pending.items()})
                now = time.perf_counter()
                if now - last_status >= 0.5:
                    self.control.metrics["evaluation_progress"] = {"completed": len(outcomes), "total": episode_count,
                        "elapsed_seconds": now - started, "workers": len(self.envs)}
                    self.control.write_status("running", self.num_timesteps, "Evaluating checkpoint")
                    last_status = now
            summary = summarize_evaluation(outcomes)
            summary["timesteps"] = self.num_timesteps
            summary["duration_seconds"] = time.perf_counter() - started
            minimum = getattr(self.args, "min_eval_stage_episodes", 16)
            gate = evaluation_gate(summary, self.args.success_threshold, minimum)
            if holdout:
                summary.update(suite="independent_holdout", gate_met=gate, minimum_stage_episodes=minimum,
                               seed=seed, model_path=str(self.best_path) + ".zip" if self.best_path.with_suffix(".zip").exists() else str(self.model_dir / self.args.run_name) + ".zip")
                self.control.metrics["final_evaluation"] = summary
                (self.runs_dir / f"{self.args.run_name}_holdout.json").write_text(
                    json.dumps({"summary": summary, "episodes": outcomes}, indent=2))
                print(f"HOLDOUT episodes={len(outcomes)} success={summary['success_rate']:.1%} gate={gate}", flush=True)
                return True
            score = (summary["longest_stage_success_rate"], summary["longest_stage_turn_coverage"], summary["success_rate"],
                     -summary["crash_rate"], -summary["off_road_rate"], summary["mean_return"])
            save_best = self.best_score is None or score > self.best_score
            if save_best:
                self.best_score = score
            self.streak = self.streak + 1 if gate else 0
            summary.update(best_checkpoint_saved=save_best, early_stop_streak=self.streak, early_stop_patience=self.args.early_stop_patience,
                           success_threshold=self.args.success_threshold, gate_met=gate)
            self.model.training_evaluation_state = {"best_score": self.best_score, "early_stop_streak": self.streak,
                                                    "last_evaluation": summary}
            if save_best:
                self.capture(self.model)
                self.model.save(self.best_path)
                temporary = self.score_path.with_suffix(".tmp")
                temporary.write_text(json.dumps({"environment_version": ENVIRONMENT_VERSION, "score": score}))
                temporary.replace(self.score_path)
                self.control.metrics["best_model_path"] = str(self.best_path) + ".zip"
            self.control.last_evaluation = summary
            self.control.metrics["evaluation_progress"] = {"completed": len(outcomes), "total": episode_count}
            path = self.runs_dir / f"{self.args.run_name}_success_eval.csv"
            fields = [k for k in summary if k not in ("stages", "success_interval")]
            new_file = not path.exists()
            with path.open("a", newline="", encoding="utf-8") as f:
                writer = csv.DictWriter(f, fieldnames=fields)
                if new_file:
                    writer.writeheader()
                writer.writerow({k: summary[k] for k in fields})
            (self.runs_dir / f"{self.args.run_name}_evaluation_{self.num_timesteps}.json").write_text(json.dumps(summary, indent=2))
            print(f"EVAL steps={self.num_timesteps} episodes={len(outcomes)} success={summary['success_rate']:.1%} longest={summary['longest_stage_success_rate']:.1%} best_saved={save_best}", flush=True)
            return not (self.args.early_stop_patience > 0 and self.streak >= self.args.early_stop_patience)
        finally:
            self.observer.evaluation_seconds += time.perf_counter() - started - (self.control.paused_seconds - paused_before)
            self.observer.sample_time = time.perf_counter()
            self.observer.sample_steps = self.num_timesteps
            performance = self.control.metrics.setdefault("performance", {})
            performance["evaluation_seconds"] = self.observer.evaluation_seconds
            performance["elapsed_seconds"] = time.perf_counter() - self.observer.started - self.control.paused_seconds
            self.control.metrics["phase"] = "collecting"
            self.control.write_status("stopping" if self.control.stop_requested else "running", self.num_timesteps,
                "Saving the current policy" if self.control.stop_requested else "Evaluation complete")


def make_callbacks(arguments, control, model, model_dir, runs_dir, capture, factory):
    observer = TrainingObserver(arguments, control, capture)
    callbacks = [observer]
    evaluator = ParallelEvaluation(arguments, control, observer, factory, model_dir, runs_dir, capture, model) if arguments.eval_every else None
    if evaluator:
        callbacks.append(evaluator)

    class StatefulCheckpoint(CheckpointCallback):
        def _on_step(self):
            if self.n_calls % self.save_freq == 0:
                capture(self.model)
                control.metrics["last_checkpoint"] = str(model_dir / "checkpoints" / f"{arguments.run_name}_{self.num_timesteps}_steps.zip")
            return super()._on_step()
    callbacks.append(StatefulCheckpoint(save_freq=max(1, arguments.checkpoint_every // arguments.n_envs),
        save_path=str(model_dir / "checkpoints"), name_prefix=arguments.run_name))
    return CallbackList(callbacks), evaluator
