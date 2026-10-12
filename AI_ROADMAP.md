# Driving AI roadmap

This file is the durable plan for the AI work. Keep the setup order and decisions
here updated as implementation progresses so later work can resume without
depending on chat history.

## Agreed architecture

- Godot remains the simulator and owns vehicle physics, road generation,
  sensors, and episode outcomes.
- PPO is trained in Python and sends controller actions to a headless Godot
  training world over a local JSON-lines connection.
- The in-game monitor uses the same local JSON-lines boundary in the opposite
  direction: Godot sends observations to a small Python policy server. Press I
  to enter/leave its empty-road mode; the live Setup 2 monitor plans over the
  district road graph.
- A deterministic road planner chooses a reachable destination and path. PPO
  learns low-level driving along that path; it does not need to learn global
  street-graph navigation at the same time.
- The policy receives sensor distances, basic ego state, a compact preview of
  the planned road ahead, and relevant traffic-light state/distance when that
  setup introduces signals. Do not feed the rendered HUD/minimap screenshot to
  the first policy; encode only useful road and route information.
- Keep control policy, observations, and rewards separate from `EgoVehicle`
  physics. Preserve the existing `set_control(throttle, brake, steering)` API.

## Setup 1 — Empty-road PPO driving (validated baseline)

Goal: train steering and speed control on a procedural main road without NPC
traffic, pedestrians, or signals. Each episode uses a seeded road, a random
start point, and a reachable goal farther along the main route.

- Action: continuous steering and signed longitudinal command (positive drives,
  negative brakes; the training adapter prevents accidental reverse).
- Observation: nine normalized ray distances; normalized speed, steering,
  heading and lane-centering errors; goal distance; four upcoming route points
  in ego-relative coordinates and their road widths. Traffic-light fields are
  reserved and report “no signal” in this setup.
- Reward: bounded progress shaping, quadratic lane-centering and heading
  penalties, an increasing road-edge penalty, and terminal rewards scaled so
  reaching the goal clearly dominates progress accumulated before a failure.
- Curriculum: use 250–400, 400–650, 600–900, then 800–1,200 world-unit goals;
  each worker advances only after at least 80% success across its latest 20
  completed episodes.
- Episode ends on reaching the goal, a crash/off-road event, or the step limit.
- Periodic checkpoint evaluation uses the same deterministic eight-seed suite
  mixed across all four goal tiers; rank checkpoints by success rate first,
  then crash/off-road rates. Final readiness is a separate 50-seed test with a
  90% success gate.
- Current status: the first 201,728-step run achieved 0/50 successes (49
  off-road terminations, one crash). Diagnosis: its progress reward could
  dominate lane-keeping penalties and terminal failure cost, so high training
  returns did not mean route completion. Reward v2, adaptive goal curriculum,
  and success-based checkpoint selection were then implemented. The v2 run
  completed at 200,100 total timesteps using six parallel Godot worlds at about
  70–72 steps/second. Its first process stopped without a traceback at 55,080;
  training resumed from the latest valid checkpoint at 51,180 and completed
  successfully. Periodic eight-episode mixed-tier evaluations at 50k, 100k,
  150k, and 200k each scored 8/8 successes, with no crashes or off-road ends.
  The separate held-out test used seeds 20,000–20,049 at stage 3 (800–1,200
  world-unit goals): both the final and best-checkpoint policies achieved
  50/50 successes, zero crashes, and zero off-road ends. Mean completion was
  54.4 steps; the 90% gate passed. Results are in `ai/runs/`; weights are in
  `ai/models/`. This validates only empty-road route following, not behavior
  around NPC cars, pedestrians, or signals. Continue with Setup 2 before
  adding those dynamic interactions.

The Setup 1 checkpoint remains a validated short-route baseline, but it is no
longer the checkpoint used by the in-game I-key monitor. That monitor now uses
the Setup 2 checkpoint described below.

## Setup 2 — Map-wide destination routing (trained; weak on long routes)

- `RoadNetwork` now selects seeded shortest paths across the connected map
  graph, checks route distance and turn count, and returns road-width profiles
  with the planned polyline.
- The isolated training world builds its RoutePath from that selected street
  route. The existing 31-value observation now previews the actual upcoming
  route through junction turns and width changes; lane-centering offsets adapt
  to narrower local streets.
- The procedural training map is larger (9,000–12,000-unit arterial), with
  6–9 main junctions and 2–3 collector/local corridors per side. Episodes use
  eight progressive distance tiers, ending at 4,200–5,500 units and requesting
  at least four meaningful turns.
- The route planner reports actual route-turn count and whether it met the
  requested turn target, so evaluations can expose route-selection fallbacks.
- Training now defaults to a distinct `setup2_network_routes_ppo_v1` model and
  a 1,000,000-step cap. Evaluation-gated early stopping requires both the
  overall mixed-tier suite and the longest tier to meet the success threshold,
  plus longest-tier turn-target coverage, for three consecutive evaluation
  rounds. Set `--early-stop-patience 0` to disable it.
- The 280,576-step training run was stopped after the 276,480-step periodic
  checkpoint was written; the separate 150k best-model file was preserved.
  On 16 held-out stage-7 routes, the 276,480-step checkpoint completed 0/16,
  crashed on 4/16, and reached the 1,800-step cap on the other 12, with no
  off-road terminations. See `ai/runs/setup2_network_routes_ppo_v1_276480_stage7_eval.csv`.
- The live monitor defaults to the best checkpoint selected at the 150k
  evaluation; press 1 to run it and 2 to run the 276,480-step checkpoint. Either
  key switches the active model; I toggles the selected model to/from manual
  driving. Both receive Setup 2 route/goal observations, and the minimap
  highlights the selected route and destination. The HUD slider selects a
  250–5,500-unit goal; press R to start a new trip after changing it. This is an
  experimental visualization, not evidence of successful long-route driving.
  NPC traffic, pedestrians, and signals remain disabled in this mode.

## Setup 3 — Dynamic traffic and right-of-way

- Add NPC vehicles, then traffic signals, then pedestrians in curriculum
  stages.
- Expose the nearest relevant signal ahead as state plus route distance (not
  unrelated lights on crossing streets). Keep local obstacle distances from
  `SensorRig`.
- Reward collision avoidance, appropriate stopping/yielding, and safe progress.

## Setup 4 — Generalization and difficult maneuvers

- Evaluate on unseen map seeds, lane additions/merges, curves, roundabouts,
  dead ends, and longer routes; track success, collisions, off-road rate, and
  completion time separately.
- Only introduce reverse/dead-end recovery if the earlier setups show that the
  route planner and forward-driving policy need it.
- Save model checkpoints and evaluation seeds; do not judge progress only by
  training reward.

## Deferred decisions

- PPO hyperparameters and training duration are initial defaults, to be tuned
  from held-out evaluation rather than assumed final.
- Setup 1 deliberately uses forward goals on the main route to isolate basic
  control. Setup 2 owns full-network route planning; it still does not add
  moving traffic, pedestrians, or signal response.
- Signal-state and pedestrian observations are defined when their curriculum
  stage is implemented; Setup 1 keeps stable placeholder observation fields.
