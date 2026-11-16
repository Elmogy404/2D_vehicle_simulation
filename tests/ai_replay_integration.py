"""Live Python/Godot deterministic record-replay integration check."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys
import tempfile

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ai"))

from deterministic_seeds import runtime_metadata  # noqa: E402
from episode_recording import (  # noqa: E402
    EpisodeRecorder,
    compare_recordings,
    load_recording,
    replay_recording,
)
from godot_gym_env import ENVIRONMENT_VERSION, GodotRoadEnv  # noqa: E402


OPTIONS = {"curriculum": False, "curriculum_stage": 0}
MASTER_SEED = 7301
EPISODE_SEED = 4101
ACTIONS = [[0.0, 0.35]] * 20


def run_actions(env: GodotRoadEnv, actions: list[list[float]], recording_path: Path | None = None):
    recorder = EpisodeRecorder(
        recording_path,
        environment_version=env.environment_version,
        reward_config=env.reward_config,
        generator_type=env.generator_type,
        master_seed=MASTER_SEED,
        capture_full_info=False,
        runtime=runtime_metadata(),
    )
    observation, info = env.reset(seed=EPISODE_SEED, options=OPTIONS)
    recorder.record_reset(
        observation,
        info,
        episode_seed=EPISODE_SEED,
        options=OPTIONS,
    )
    terminated = truncated = False
    for index, action in enumerate(actions):
        observation, reward, terminated, truncated, info = env.step(np.asarray(action, dtype=np.float32))
        recorder.record_step(
            index=index,
            action=action,
            observation=observation,
            reward=reward,
            terminated=terminated,
            truncated=truncated,
            info=info,
        )
        if terminated or truncated:
            break
    recording = recorder.close(terminated=terminated, truncated=truncated)
    if recording is None:
        raise RuntimeError("episode recorder did not produce a recording")
    return recording


def make_env(godot: str) -> GodotRoadEnv:
    return GodotRoadEnv(godot, generator_type="original", master_seed=MASTER_SEED)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True, help="Godot 4 executable")
    arguments = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="godot_replay_") as directory:
        recording_path = Path(directory) / "episode.jsonl"

        first_env = make_env(arguments.godot)
        try:
            reference = run_actions(first_env, ACTIONS, recording_path)
            first_pid = first_env.bridge.process_id
        finally:
            first_env.close()
        if first_env.bridge.process_id is not None:
            raise RuntimeError("first Godot process was not terminated by close()")
        if not recording_path.is_file():
            raise RuntimeError("recording file was not written")
        print(f"RECORD PASS: seed={EPISODE_SEED} steps={len(reference.steps)} pid={first_pid}")

        loaded = load_recording(recording_path)
        second_env = make_env(arguments.godot)
        try:
            replayed = replay_recording(second_env, loaded)
        finally:
            second_env.close()
        if second_env.bridge.process_id is not None:
            raise RuntimeError("replay Godot process was not terminated by close()")
        report = compare_recordings(loaded, replayed)
        if report["status"] not in {"exact", "tolerance"}:
            raise RuntimeError(f"deterministic replay diverged: {report['first_divergence']}")
        print(
            "REPLAY PASS: status=%s steps=%d atol=%g rtol=%g max_abs_observation_error=%g"
            % (
                report["status"],
                report["steps_compared"],
                report["tolerances"]["atol"],
                report["tolerances"]["rtol"],
                report["max_abs_observation_error"],
            )
        )

        tampered_actions = [list(action) for action in ACTIONS]
        tampered_actions[2] = [0.0, -1.0]
        third_env = make_env(arguments.godot)
        try:
            tampered = run_actions(third_env, tampered_actions)
        finally:
            third_env.close()
        if third_env.bridge.process_id is not None:
            raise RuntimeError("tampered-run Godot process was not terminated by close()")
        tampered_report = compare_recordings(loaded, tampered)
        if tampered_report["status"] != "divergence":
            raise RuntimeError("an intentionally modified action was not detected as divergence")
        if tampered_report["first_divergence"] is None or tampered_report["first_divergence"]["step"] != 2:
            raise RuntimeError(
                "modified action divergence did not start at step 2: "
                f"{tampered_report['first_divergence']}"
            )
        print(
            "DIVERGENCE PASS: modified action detected at step=%s fields=%s"
            % (
                tampered_report["first_divergence"]["step"],
                sorted({field["field"] for field in tampered_report["first_divergence"]["fields"]}),
            )
        )
        print(
            "REPLAY INTEGRATION PASS: same seed/action sequence matched; modified action diverged; "
            "temporary files cleaned and processes closed"
        )


if __name__ == "__main__":
    main()
