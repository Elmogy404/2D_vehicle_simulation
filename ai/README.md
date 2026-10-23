# PPO driving setups

Environment version 2 fixes the driving reference geometry and simulation
stepping. Start a **new training run** after updating; old checkpoints remain
available for inspection but cannot be resumed into version 2. The default CLI
run name is `setup2_network_routes_ppo_v2`.

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
forward progress on the road. Set **Top-speed reward** to zero to disable it.

## Train and evaluate Setup 2

Use Python 3.10+ and Godot 4. Create a virtual environment and install the
dependencies, then set `GODOT_BIN` to your Godot executable:

```powershell
python -m venv .venv-ai
.\.venv-ai\Scripts\Activate.ps1
python -m pip install -r ai/requirements.txt
$env:GODOT_BIN = "C:\path\to\Godot_v4_console.exe"
python ai/smoke_test.py
python ai/train.py --n-envs 6
python ai/evaluate.py --model ai/models/setup2_network_routes_ppo_v2_best.zip --episodes 50 --seed 20000 --curriculum-stage 7
python ai/evaluate.py --model ai/models/setup2_network_routes_ppo_v2_best.zip --episodes 50 --seed 21000 --curriculum-stage 7 --visible
python ai/watch_policy.py --model ai/models/setup2_network_routes_ppo_v2_best.zip --curriculum-stage 7
```

The default training cap is 1,000,000 timesteps. The route-distance curriculum
has eight tiers from 250–400 through 4,200–5,500 units. Longer tiers request
increasingly many meaningful turns. Each training worker advances only after
at least 80% success over its latest 20 completed episodes. Training maps vary
in length, intersections, corridors, and generated seed.

Early stopping is on by default: after an evaluation, training stops only when
both the overall mixed-tier suite and the longest 4,200–5,500-unit tier meet
the configured success threshold, and the longest tier meets its requested
turn count, for three consecutive evaluations. Each
evaluation uses 16 deterministic episodes spanning all eight tiers. Change the
streak with `--early-stop-patience N`, or disable it with
`--early-stop-patience 0`. Increase `--steps` for a larger cap; early stopping
still applies. The best checkpoint is selected by overall success, then crash
and off-road rates. Logs and CSV evaluation results go under `ai/runs/`, while
models and periodic checkpoints go under `ai/models/`.

## Train from the Godot GUI

On a new Windows computer, install Python 3.10+ and Godot 4, then double-click
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

Set the worker count (each worker launches one headless Godot world), total
timesteps, seed, PPO parameters, checkpoint/evaluation intervals, early-stop
threshold, and reward/penalty weights before pressing **Start training**.
**Pause** waits for the current environment step, **Resume** continues, and
**End and save** stops cleanly and saves the latest policy. The progress area
shows training steps and the last evaluation. The run log, control/status
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
