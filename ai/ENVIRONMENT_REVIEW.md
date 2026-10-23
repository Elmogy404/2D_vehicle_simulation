# Training environment fixes and deeper checks

This records the version 2 geometry/stepping baseline. Version 3 builds on
these fixes; see [the current changes and validation](TRAINING_V3.md).

Reviewed and verified on 23 October 2026. Version 2 required a new run.
The network still has 31 inputs and two continuous
actions, but its route previews, stepping, and rewards have changed.

## Fixes

- Training uses a rounded driving path rather than interpolating corner
  headings across long, straight graph edges. Corner construction accounts
  for wheelbase and maximum steering angle. Dense arterial samples near
  junctions cannot impose an artificial 30-unit turning radius.
- Spawn, goal, and the whole reference trip are checked with the real vehicle
  rectangle against world colliders. Trip sampling is every five units with a
  two-unit body margin; spawn and goal use the existing ten-unit margin.
- The lane target leaves enough body clearance on narrow roads. Smooth lane
  transitions and wider corner approaches avoid sending the car through the
  inside curb. Construction extensions at sampled graph endpoints are excluded
  from the usable trip, and previews stop at the actual destination.
- One environment action advances exactly four completed vehicle physics
  updates. The car and sensors have no independent physics updates during
  training, eliminating movement between requests and pause/await races.
- Meaningful turns must be completed inside the actual trip, before the goal
  success radius. Goal placement enforces the requested number of turns.
- Random route sampling cannot revisit nodes. Nearest-route projection is
  limited to a local progress interval, and success requires both destination
  proximity and route progress.
- Reward cannot be farmed by driving back and forth over the same distance.
  Stationary/no-progress episodes terminate after 150 steps without gaining
  two new units. The top-speed bonus also requires new progress.
- The world deterministically searches alternative maps when a candidate is
  invalid. Reset metadata identifies the requested and actual seeds and map
  attempts. Further Python retries are bounded and limited to recoverable,
  unseeded training resets; explicit evaluation failures remain visible.
- Checkpoints preserve each worker's curriculum history and RNG state.
  Evaluation with a fixed difficulty does not overwrite training curriculum.
  Resume requires the original worker count and compatible run settings.
- Best-score records and early-stop state survive resume. An evaluation with
  a worse score cannot replace the prior best policy. Unexpected exceptions
  and keyboard interruption save a separate recovery policy.

## Deeper geometry limitation

The car's bicycle model has a minimum turning radius of approximately
131 units. The current roundabout ring reference has a radius of 125 units.
Ring edges are excluded from version 2 training rather than credited as
drivable routes. The original road generator now supplies road-class metadata
to the graph, so this exclusion is effective. All eight curriculum stages,
including four completed turns on the longest stage, remain required.

The historical in-game checkpoint monitor still demonstrates its original
models. Use `ai/watch_policy.py --model <new-checkpoint.zip>` to inspect a new
policy in the corrected training environment.

## Verification

| Check | Result |
|---|---|
| Seeds 12000–12019, every stage 0–7 | 160/160 valid trips; zero failures |
| Separate seeds 50000–50019, every stage 0–7 | 160/160 valid trips; zero failures |
| Dense full-body checks along accepted trips | No blocked reference poses or goals in 320 episodes |
| Replacement maps during those sweeps | 16 and 12 episodes respectively; distance/turn requirements retained |
| Repeated action sequences | Exactly four ticks per action and repeatable acceleration |
| Waiting between requests | No unrequested vehicle movement |
| Shortcut, retraced-distance reward, stall and curriculum checks | Passed in both sweeps |
| Independent pure-pursuit controller, stages 0/3/7 | All three goals reached: 69/228/1302 steps |
| Python tests | 13 passed, including real PPO callback/checkpoint tests |
| Worse evaluation after resume | Prior best ZIP preserved byte for byte |
| Injected environment failure | Recovery ZIP saved and successfully loaded |
| Actual two-worker Godot/PPO run and resume | Saved at 1024 steps; resumed and saved at 2048 steps |
| Existing smoke, route-planner and speed-reward tests | Passed |

Run the sweeps from the project folder:

```powershell
& $env:GODOT_BIN --headless --path . --script res://tests/ai_environment_test.gd
& $env:GODOT_BIN --headless --path . --script res://tests/ai_environment_test.gd -- --held-out
.\.venv-ai\Scripts\python.exe -m unittest discover -s tests -p "test_*.py"
```

The sweep runs the same 1/60-second vehicle integration at an accelerated wall
clock rate. Version 2 training retained the project's regular wall-clock rate;
version 3 accelerates headless training with the same fixed simulation timestep.

These checks establish sampled reference clearance, deterministic stepping,
and dynamic reachability examples. They do not establish that a trained PPO
policy succeeds on all generated roads. A fresh training run and independent
evaluation of its learned policy are still needed. Traffic, pedestrians,
signals, and driving on the excluded roundabout rings remain outside this
empty-road training setup.
