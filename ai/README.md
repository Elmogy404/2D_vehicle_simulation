# PPO driving setups

## Current training and verification

The CLI, Godot training tab, and Training Studio share defaults in
`training_defaults.json`. Core dependency versions are pinned in
`requirements.txt`; setup requires Python 3.12 or newer.

Choose `original` or `segmented` roads in either interface, or pass
`--generator-type segmented` to `train.py`. Evaluation and model presentation
discover the generator from the checkpoint's adjacent training manifest.
Keep that manifest with a checkpoint when copying it to another computer.
Original-road version 3 runs retain their existing observation semantics.
Segmented runs use the same shared route/observation implementation as gameplay,
but longer multi-turn goals: their last stage covers 16,000–22,000 units because
authored city blocks are 3,900–5,300 units apart. Training remains empty-road.

Checkpoint evaluation defaults to 128 episodes, evenly covering eight stages.
Early stopping requires the requested success and turn-coverage threshold in
every stage, with at least 16 samples per stage. Smaller evaluation batches can
still measure progress but cannot satisfy that default early-stop requirement.
After normal completion, the best checkpoint is evaluated on 256 independent
episodes starting at seed 1,000,000. This final suite cannot select or replace
the best model. Both dashboards show its result, and per-episode details are
saved as `runs/<run_name>_holdout.json`. Manual End and save skips this extra
evaluation. Configure these settings in either interface or with
`--min-eval-stage-episodes`, `--final-eval-episodes`, and `--final-eval-seed`.

New runs reserve their names before launching workers and record the tested
package versions and simulation source fingerprint. Resume preserves the
generator and existing experiment settings; changed simulation fingerprints
require a new experiment. Legacy manifests without fingerprints retain their
existing compatibility checks. Never reuse a run name to start from scratch.

Run the combined regression suite from the project folder:

```powershell
.\.venv-ai\Scripts\python.exe tests\run_checks.py --godot "C:\path\to\Godot.exe" --full --lifecycle
```

The optional lifecycle test starts an isolated short PPO run and checks
pause/resume/save. Results and full output go to `ai/runs/project_checks.json`.
See `../IMPROVEMENTS.md` for the seven-part implementation and verification.

Environment version 3 accelerates headless simulation, removes a conflicting
lane/edge reward, and introduces gradual first-turn practice. Start a **new
training run** after updating; earlier checkpoints remain available for
inspection but cannot be resumed into version 3. The default CLI run name is
`setup2_network_routes_ppo_v3`. See [the changes and validation](TRAINING_V3.md).

Training now builds rounded, car-feasible driving paths from the street graph,
keeps heading changes local, and adjusts lane position for body clearance and
wide turns. Every accepted trip is checked against the actual world colliders
at five-unit intervals, with extra clearance at spawn and goal. The current
125-unit roundabout reference is below the car's 131-unit minimum turning
radius, so training excludes those ring edges; all eight distance tiers and
their required turn counts remain enforced.

Each action advances exactly four completed vehicle physics ticks. The car
does not move while Python is thinking or training is paused. Destination
success also requires route progress, and turns are counted only when they
can be completed before the goal's success radius. Progress reward is paid
once per newly reached distance; 150 steps without two units of new progress
end a stalled episode. Route previews stop at the actual goal.

Invalid trips trigger a bounded, deterministic search for another map. Reset
information records the requested seed, actual map seed, and map attempts.
If this search still fails, unseeded training retries a bounded set of episode
seeds; explicitly seeded evaluation reports the failure. Curriculum stage,
recent outcomes, and each worker's random generator state are stored in policy
checkpoints. Resume starts new episodes with those states and requires the
original worker count. Best-model scores survive resume, and unexpected
training failures save a separate recovery policy without replacing the last
completed model.

Run the extended environment checks with Godot's `--headless --path . --script
res://tests/ai_environment_test.gd` (add `-- --held-out` for a separate seed
range), and Python checks with `python -m unittest discover -s tests -p
"test_*.py"`.

Setup 1 proved basic empty-road lane following. Setup 2 now trains an empty-road
policy to follow planned trips through the connected district street graph,
including intersections, turns, changing widths, and 4,200–5,500-unit routes.
The staged plan is in [`AI_ROADMAP.md`](../AI_ROADMAP.md).

## Architecture and observation

- `rl_training_world.gd` owns the generated district, road-graph route choice,
  episode rewards, and terminal conditions.
- `road_network.gd` runs shortest-path routing on the generated street graph;
  the selected polyline and per-edge road widths become PPO's route preview.
- `godot_bridge.py` starts an isolated Godot process and exchanges JSON lines
  with Python. `godot_gym_env.py` adapts it to Gymnasium.
- `train.py` trains PPO with Stable-Baselines3, periodic evaluation, best-model
  selection, checkpoints, and evaluation-gated early stopping.

The observation remains 31 values: nine normalized sensor distances; speed,
steering, heading error, lane error, and remaining trip distance; four upcoming
planned-road points in ego coordinates; road half-width at those points; and
five reserved traffic-light slots. Setup 2 still has no cars, pedestrians, or
signals, so the reserved slots indicate “no signal.” PPO controls steering and
signed acceleration/braking; the training adapter prevents unintended reverse.
The shared ego car now tops out at 150 km/h (500 world units/s), and training
can award a small per-step bonus at 98% of that speed or higher while making
forward progress on the road. **Top-speed reward** defaults to zero so turning
and braking do not compete with a reward for reaching the speed limiter.

## Train and evaluate Setup 2

Use Python 3.12+ and Godot 4. Create a virtual environment and install the
dependencies, then set `GODOT_BIN` to your Godot executable:

```powershell
python -m venv .venv-ai
.\.venv-ai\Scripts\Activate.ps1
python -m pip install -r ai/requirements.txt
$env:GODOT_BIN = "C:\path\to\Godot_v4_console.exe"
python ai/smoke_test.py
python ai/train.py --n-envs 6
python ai/evaluate.py --model ai/models/setup2_network_routes_ppo_v3_best.zip --episodes 50 --seed 20000 --curriculum-stage 7
python ai/evaluate.py --model ai/models/setup2_network_routes_ppo_v3_best.zip --episodes 50 --seed 21000 --curriculum-stage 7 --visible
python ai/watch_policy.py --model ai/models/setup2_network_routes_ppo_v3_best.zip --curriculum-stage 7
```

The default training cap is 1,000,000 timesteps. The route-distance curriculum
has eight tiers from 250–400 through 4,200–5,500 units. Longer tiers request
increasingly many meaningful turns. Each training worker advances only after
at least 80% success over its latest 20 completed episodes. Training maps vary
in length, intersections, corridors, and generated seed. Stage 3 first learns
turns with 45 km/h, then 75 km/h, then the full 150 km/h speed limit; each level
requires the same success gate. From stage 3 onward, 20% of trips replay an
easier stage to retain earlier skills. Replay does not advance the frontier.
The default discount factor is 0.999 for the longer trips.

Headless worlds run without waiting for real time while retaining exactly
four 1/60-second physics updates per action. They omit artwork, update sensors
once per action, and reuse a generated map for at most eight training episodes.
Every new trip still passes collision/turn validation. Explicitly seeded
evaluation regenerates its map. PPO uses one CPU thread by default; tune it
with `--torch-threads`. Visible watch/evaluation runs at normal speed.

Early stopping is on by default: after an evaluation, training stops only when
both the overall mixed-tier suite and the longest 4,200–5,500-unit tier meet
the configured success threshold, and the longest tier meets its requested
turn count, for three consecutive evaluations. Each
evaluation uses 64 deterministic episodes spanning all eight tiers, run across
four evaluation worlds with batched policy inference. Use `--eval-workers` to
adjust concurrency. Stage reports include sample counts and Wilson 95% success
intervals; eight episodes per stage still give a wide interval. Change the
streak with `--early-stop-patience N`, or disable it with
`--early-stop-patience 0`. Increase `--steps` for a larger cap; early stopping
still applies. Best selection prioritizes longest-stage success and valid turn
coverage, then overall success, crash/off-road rates, and return. Logs, CSV
summaries and detailed per-stage evaluation JSON go under `ai/runs/`, while
models and periodic checkpoints go under `ai/models/`.

## Standalone training GUI

Double-click `start_training_gui.cmd` after running `setup_ai_training.cmd`.
The standalone app provides a shared run setup, training dashboard, model
presentation, and a live grid of every training worker on Windows. Eight
workers produce eight actual Godot views. See
[AI Training Studio](../enhanced_training_gui/README.md) for controls,
resume behavior and requirements. Visual training uses more GPU resources and
runs slower than headless training.

## Train from the Godot GUI

On a new Windows computer, install Python 3.12+ and Godot 4, then double-click
`setup_ai_training.cmd` in the project folder. It creates a local `.venv-ai`
and downloads the AI dependencies; internet access is required. An incompatible
copied environment is moved to a dated `.venv-ai-backup-*` folder, never deleted.
When sharing the project, omit `.venv-ai`, `.venv-ai-backup-*`, and `.godot`:
these are local installations/caches and should be recreated on the other computer.
Set the AI Training tab's Godot executable to the installed Godot engine `.exe`.
Training requires the full source project, not only an exported game executable.

Open the top-right settings button and choose the **AI Training** tab. The
**Main** tab keeps map generation and live checkpoint viewing. Training uses a
separate Python process, so the game can stay paused or be closed while PPO
runs. The tab finds `.venv-ai/Scripts/python.exe` and the running Godot
executable by default; edit either path if your installation differs.

Open **Run setup** to set the worker count (each worker launches one headless Godot world), total
timesteps, seed, PPO parameters, checkpoint/evaluation intervals, early-stop
threshold, and reward/penalty weights before pressing **Start training**.

The training worker count has no configured upper cap and defaults to 1.
Selecting more than 32 displays a warning about CPU/RAM usage and possible
slowdowns or memory exhaustion; the warning does not block starting training.
When resuming a checkpoint, keep its original worker count.

**Pause** waits for the current environment step, **Resume** continues, and
**End and save** stops cleanly and saves the latest policy. **Overview** shows
steps/second, elapsed time and training ETA, recent success/crash/stall/timeout,
mean return and progress, a success trend, each worker's curriculum and speed,
reset timings, per-stage evaluation counts and confidence intervals, optimizer
diagnostics, and checkpoint/log links. Training ETA excludes future evaluation
time. Live training statistics cover the last 200 completed episodes; checkpoint
evaluation uses a separate fixed full-speed suite. The run log, control/status
files, and a JSON copy of the reward weights are saved under `ai/runs/`;
models and a reproducibility manifest are saved under `ai/models/` unless an
output folder is set. Reopening the project reconnects to an active GUI run.

Startup logs include the actual Python and trainer paths and the trainer's SHA256
to identify different copies. Python tracebacks are preserved, and dependency
failures appear directly in the training status with setup instructions.

Changing reward or PPO settings is a new experiment. To resume, provide the
checkpoint `.zip`, use its original run name, keep the original reward/PPO
settings, and set total timesteps above the checkpoint's current step count.
The trainer rejects a mismatch when a run manifest is available.

Episode spawning now checks the *whole car body plus margin* against road
colliders and retries seeded route/start candidates. A reset reports an error
instead of placing the car on an obstructed curb if no safe start exists.

Use a fresh held-out seed range for final evaluation. `--output-csv` saves
per-episode outcomes, including the selected route's turn count. `--visible`
opens the same empty-road training world with a camera, speed display, minimap,
and goal marker. Close the window or press Escape to stop a visible watch.

## In-game checkpoint monitor

Press **1** to run the default `setup2_network_routes_ppo_v1_best.zip` model
(the 150k best checkpoint); press **2** to switch to
`setup2_network_routes_ppo_v1_276480_steps.zip`. Either key starts the selected
model, or switches models while AI mode is active. **I** toggles between manual
driving and the currently selected model. The planner selects a multi-turn
route; the HUD and minimap show the goal and highlight the planned path. The
HUD slider sets goal length from 250 to 5,500 world units; after changing it
during a run, press **R** to start a new trip at that distance. Traffic,
pedestrians, crosswalks, and signals are disabled during this monitor and
restored when returning to manual mode.

Treat this as an experimental live demonstration, not a validated autonomous
driver: the 276,480-step checkpoint reached 0/16 goals on the held-out longest
route tier. Detailed results are in
`ai/runs/setup2_network_routes_ppo_v1_276480_stage7_eval.csv`.
