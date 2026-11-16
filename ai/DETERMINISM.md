# Deterministic seeds, recording, replay, and CI

This document describes the reproducibility contract added for Phase 1.2. It
covers the effective guarantee, not an aspirational one: same-platform replay
is verified; cross-platform bitwise equality is not claimed.

## 1. Reproducible seeds

`ai/deterministic_seeds.py` is the single seed policy for Python tools. A user
supplies one non-negative master seed:

```powershell
python ai/train.py --seed 7 --n-envs 6
python ai/evaluate.py --seed 20000 --episodes 10
python ai/watch_policy.py --seed 30000
```

The master seed is expanded with SHA-256 into stable, independent component
seeds (`python`, `numpy`, `torch`, `gymnasium`, `episode_stream`, `map`,
`scenario`, `traffic`, `pedestrians`, and `traffic_lights`). Training workers
also receive derived `worker_seed`, `replay_seed`, and per-worker component
seeds. Worker 0 and worker 1 therefore do not share a random stream.

`set_global_seeds(master_seed)` seeds Python `random`, NumPy, and (when
installed) PyTorch. Stable-Baselines3 still receives `--seed` and applies its
own RNG and action-space seeding. `.venv` training defaults to CPU and one
PyTorch thread, which removes a common source of thread-dependent variation.

`GodotRoadEnv(..., master_seed=..., worker_index=...)` initialises its Gymnasium
stream from the derived worker seed. Explicit evaluation resets such as
`env.reset(seed=20000 + episode)` are preserved exactly and are not rewritten.
Godot's reset protocol already receives the episode seed; map generation,
episode RNG, scenario route selection, traffic, pedestrians, and traffic lights
continue to derive from that seed. No extra bridge message is required.

Training manifests now record:

* `seed`;
* `seed_config` (master, derivation, components, workers);
* `determinism` (seed derivation, global generators, replay format version,
  comparison defaults, and the documented guarantee);
* `runtime.code_revision` when the project is a Git checkout.

Resume checks preserve the original seed when it is recorded. Legacy manifests
without `seed` remain resumable. Existing checkpoints and manifest reward
validation are unchanged.

## 2. Determinism guarantee

Supported guarantee:

> With the same environment version, platform/build, dependency versions,
> reward configuration, generator type, observation/action schema, seed,
> initial conditions, and ordered action sequence, observations, rewards,
> termination/truncation flags, and collision metadata reproduce within the
> configured comparison tolerances.

The same-platform contract was verified locally on Windows with Godot 4.7.2:

* A 20-action live Python/Godot integration episode replayed **exactly**
  (`max_abs_observation_error = 0`).
* A 201-action recorded evaluation episode replayed **exactly** with
  `atol=1e-6`, `rtol=1e-6`.
* Intentionally changing one action produced divergence at that step.

The simulation is stepped by fixed 60 Hz physics ticks and each action advances
exactly four physics ticks. Vehicle movement is suspended while Python is
thinking or training is paused, so wall-clock speed does not change the
dynamics. Wall-clock and process fields (`reset_ms`, `godot_pid`) are excluded
from comparison rather than treated as simulated state.

Not guaranteed:

* bitwise equality across operating systems, CPU architectures, Godot builds,
  BLAS libraries, or graphics drivers;
* bitwise equality of PPO/Torch training after many updates across different
  hardware or thread configurations;
* replay of a recording made with a different environment version, schema,
  reward configuration, or generator type.

Linux CI is configured below, but this local report only claims Windows
verification. macOS is not included because it has not been verified.

## 3. Recording an episode

`evaluate.py` records one selected evaluation episode:

```powershell
python ai/evaluate.py `
  --model ai/models/<checkpoint>.zip `
  --episodes 1 --seed 20000 --curriculum-stage 0 `
  --record ai/runs/episode.jsonl
```

The recorded episode uses the same seed and environment configuration as that
evaluation episode. Add `--record-episode N` to record a later episode in a
multi-episode evaluation. By default only replay-relevant info is stored; use
`--record-full-info` for the complete telemetry payload.

The file is JSON Lines, format version `1`:

1. `header`: recording version, creation time, environment version, interface
   schema, reward configuration and SHA-256 hash, generator type, master seed,
   episode seed, reset options, initial conditions, runtime fingerprint.
2. `reset`: initial observation and reset info.
3. `step` records: contiguous step index, action, observation, reward,
   terminated/truncated flags, collision data, and selected info.
4. `summary`: step count, return, terminal flags, and completeness.

Writes are atomic, and malformed or non-finite records fail loudly. The replay
tool accepts the same format and rejects newer/unknown versions instead of
guessing.

## 4. Replaying an episode

```powershell
python ai/replay_episode.py `
  --recording ai/runs/episode.jsonl `
  --godot "C:\path\to\Godot.exe" `
  --atol 1e-6 --rtol 1e-6 `
  --json ai/runs/replay_report.json `
  --write-replay ai/runs/replayed.jsonl
```

Replay reconstructs the environment version, reward configuration, generator,
master/episode seed, and reset options, then applies the recorded actions in
order. It compares initial observations, every observation, reward, terminal
flags, and non-volatile info including collision events.

Exit codes:

* `0` — exact match or match within tolerances;
* `1` — divergence;
* `2` — invalid/incompatible recording or replay infrastructure failure.

The JSON report includes `status` (`exact`, `tolerance`, or `divergence`),
tolerances, maximum numeric error, compared step count, the first divergent
step, and each divergent field with reference/replay values. When `--json` is
requested, incompatible or malformed recordings also write a report with
`status` set to `incompatible` or `error` before exiting with code 2. The first
divergence is never silently accepted.

Example divergence report shape:

```json
{
  "status": "divergence",
  "first_divergence": {
    "step": 2,
    "fields": [
      {"field": "step[2].observation", "indices": [0, 1], "max_abs_error": 0.04},
      {"field": "step[2].reward", "reference": 1.02, "replay": 0.87}
    ]
  }
}
```

## 5. Tests

Run the Python unit suite:

```powershell
python -m unittest discover -s tests -p "test_*.py"
```

Run one Godot headless test:

```powershell
godot --headless --fixed-fps 60 --path . `
  --script res://tests/deterministic_seed_test.gd
```

Run the live Python/Godot record-replay integration:

```powershell
python tests/ai_replay_integration.py --godot "C:\path\to\Godot.exe"
```

Run the combined project runner (Python suite, schema integration, replay
integration, Godot headless scripts/gameplay/smoke):

```powershell
python tests/run_checks.py --godot "C:\path\to\Godot.exe" --full
```

`run_checks.py` reports each failed check, enforces a per-check timeout, kills
the whole child process tree on timeout, and writes `ai/runs/project_checks.json`.
Use `--skip-python` when a separate CI job already ran the unit suite.

The deterministic tests cover seed derivation and worker independence,
global-generator seeding, environment reset seeding, JSONL serialization,
recording validation/version rejection, exact/tolerance/divergence comparison,
first-divergent-step diagnostics, reward/schema/environment compatibility,
manifest seed resume checks, Godot seeded map/episode replay, and live
record-replay plus intentional-action divergence.

## 6. Continuous integration

`.github/workflows/ci.yml` runs on Ubuntu and Windows for pushes and pull
requests. It has three stages:

1. **Python unit tests** — installs pinned `ai/requirements.txt`, validates
   imports, and runs the unit suite.
2. **Godot headless regressions** — installs/caches Godot `4.7.2-stable`, runs
   `tests/run_checks.py --skip-python`, and uploads the check report and Godot
   logs.
3. **Training and replay smoke** — runs 64 PPO steps, evaluates one episode
   with recording, replays it at `atol=1e-5`, `rtol=1e-6`, and uploads the
   model manifest, recording, replay report, and logs.

No full PPO training is run. Caches are keyed by the pinned Godot version and
operating system; dependency caching is keyed by `ai/requirements.txt`.
Failures return non-zero from the runner or CLI and identify the failed stage.
macOS is intentionally omitted until its Godot execution path is verified.

## 7. Known limitations

* Cross-platform replay equality has not been demonstrated; use tolerances.
* Godot process startup and map search rejections can choose a later retry seed;
  recordings store the actual `requested_seed`/map seed and the replay uses the
  explicit episode seed, so retry selection itself is not replayed.
* PPO may use an explicit first reset seed supplied by Stable-Baselines3. The
  worker's pre-seeded stream is used for subsequent unseeded resets; all actual
  reset seeds are recorded in episode info.
* Wall-clock fields are excluded from comparison; they are diagnostics, not
  simulation state.
* Full training determinism depends on PyTorch, CPU/BLAS, and thread settings
  and is weaker than episode replay determinism.
* Replay requires the same environment version, schema, reward configuration,
  generator type, and compatible Godot executable.
