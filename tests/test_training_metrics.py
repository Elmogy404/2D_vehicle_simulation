"""Telemetry must describe the exact evaluated episodes, including parallel slots."""
from __future__ import annotations

from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ai"))
from training_callbacks import ParallelEvaluation, TrainingObserver
from training_control import TrainingControl
from training_metrics import summarize, success_interval


class EvaluationWorld:
    def __init__(self):
        self.resets = []
        self.closed = False

    def reset(self, *, seed, options):
        assert options["curriculum"] is False
        self.stage, self.seed = options["curriculum_stage"], seed
        self.steps = 0
        self.resets.append((seed, self.stage))
        return np.array([self.stage], dtype=np.float32), {"seed": seed}

    def step(self, action):
        # Unequal episode lengths force slots to finish and refill separately.
        assert action[0] == self.stage, "batched actions went to the wrong world"
        self.steps += 1
        done = self.steps == self.stage % 4 + 1
        return np.array([self.stage], dtype=np.float32), 2.0, done, False, {
            "success": self.seed % 3 == 0, "crashed": self.seed % 3 != 0,
            "turn_requirement_met": True, "progress_fraction": 0.5,
        }

    def close(self):
        self.closed = True


class MetricsTests(unittest.TestCase):
    def test_empty_window_and_binomial_uncertainty(self):
        self.assertEqual(summarize([]), {"episodes": 0})
        self.assertEqual(success_interval(0, 0), [0.0, 1.0])
        low, high = success_interval(8, 8)
        self.assertAlmostEqual(low, 0.675592, places=5)
        self.assertAlmostEqual(high, 1.0)
        self.assertGreater(success_interval(8, 8)[1] - low,
                           success_interval(80, 80)[1] - success_interval(80, 80)[0])

    def test_parallel_evaluation_matches_single_worker_and_counts_every_seed(self):
        summaries = []
        for workers in (1, 4):
            with self.subTest(workers=workers), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                args = SimpleNamespace(run_name="parallel_test", resume=None, n_envs=1, steps=64,
                    eval_every=64, eval_episodes=21, eval_workers=workers, eval_seed=10000,
                    success_threshold=0.9, early_stop_patience=0)
                control = TrainingControl(None, None, "test", args.run_name, 64, 1)
                observer = TrainingObserver(args, control, lambda model: None)
                batches = []

                def predict(observations, deterministic):
                    self.assertTrue(deterministic)
                    batches.append(len(observations))
                    return observations.copy(), None

                model = SimpleNamespace(num_timesteps=0, predict=predict,
                    logger=SimpleNamespace(name_to_value={}),
                    save=lambda path: Path(str(path) + ".zip").write_bytes(b"policy"))
                worlds = []

                def factory():
                    world = EvaluationWorld()
                    worlds.append(world)
                    return world

                callback = ParallelEvaluation(args, control, observer, factory, root, root, lambda model: None, model)
                callback.model = model
                callback.num_timesteps = 64
                try:
                    self.assertTrue(callback._on_step())
                    summary = control.last_evaluation
                    self.assertEqual(summary["episodes"], 21)
                    self.assertEqual([x["episodes"] for x in summary["stages"]], [3, 3, 3, 3, 3, 2, 2, 2])
                    self.assertEqual(sorted(x for world in worlds for x in world.resets),
                                     [(10000 + i, i % 8) for i in range(21)])
                    self.assertEqual(max(batches), workers)
                    self.assertEqual(model.training_evaluation_state["last_evaluation"], summary)
                    self.assertGreater(control.metrics["performance"]["evaluation_seconds"], 0)
                    summaries.append([{k: v for k, v in stage.items()} for stage in summary["stages"]])
                finally:
                    callback.close()
                self.assertTrue(all(world.closed for world in worlds))
        self.assertEqual(*summaries)

    def test_final_telemetry_includes_final_evaluation_and_gradient_time(self):
        args = SimpleNamespace(n_envs=1, steps=1024, eval_every=512)
        control = TrainingControl(None, None, "test", "test", 1024, 1)
        observer = TrainingObserver(args, control, lambda model: None)
        observer.model = SimpleNamespace(logger=SimpleNamespace(name_to_value={"train/value_loss": 0.125}))
        observer.num_timesteps = 1024
        observer.started -= 5
        observer.evaluation_seconds = 3
        observer._on_training_end()
        performance = control.metrics["performance"]
        self.assertGreaterEqual(performance["elapsed_seconds"], 5)
        self.assertEqual(performance["evaluation_seconds"], 3)
        self.assertIsNone(performance["eta_seconds"])
        self.assertEqual(control.metrics["optimizer"]["value_loss"], 0.125)

    def test_training_timeouts_use_the_vector_environment_termination_flag(self):
        args = SimpleNamespace(n_envs=1, steps=1024, eval_every=512)
        control = TrainingControl(None, None, "test", "test", 1024, 1)
        observer = TrainingObserver(args, control, lambda model: None)
        observer.model = SimpleNamespace(logger=SimpleNamespace(name_to_value={}))
        observer.locals = {"dones": [True], "infos": [{"TimeLimit.truncated": True,
            "episode": {"r": -20.0, "l": 1800}}]}
        self.assertTrue(observer._on_step())
        self.assertEqual(control.metrics["training_metrics"]["timeout_rate"], 1.0)


if __name__ == "__main__":
    unittest.main()
