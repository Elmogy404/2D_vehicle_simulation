# Version 3 training and dashboard

Reviewed on 23 October 2026. Use a fresh run name and leave the resume path
empty when starting this environment. The trainer rejects version 1/2 resume
because rewards, observations' speed normalization, and curriculum behavior
have changed. Existing model files remain available for inspection.

## Training changes

| Finding | Change |
|---|---|
| Real-time headless engine limited each worker to 15 actions/second | Run headless with `--fixed-fps 60 --disable-render-loop`; each action still advances four 1/60-second vehicle ticks |
| TCP latency and repeated raycasts added per-action work | Enable TCP_NODELAY at both ends and sample sensors once after the action's last physics tick |
| Resets generated artwork and an unused initial map | Build only graph/colliders in headless mode; generate the first map on the first reset |
| Full regeneration and repeated route queries cost time | Reuse a map for up to eight training episodes, cache validated route prefixes and lane-offset samples; retain full-body clearance checks for every accepted trip |
| Correct lane position incurred an edge penalty | Start edge pressure outside the safe target lane, retain increasing curb penalties |
| First mandatory turn was a sudden difficulty increase | Stage 3 practices turns at 45, 75, then 150 km/h; require 80% success over 20 frontier episodes at each level |
| More difficult stages displaced easier skills | Replay an earlier stage in 20% of later training episodes; exclude replay from frontier advancement |
| Terminal goal reward was heavily discounted on long trips | Change default gamma from 0.995 to 0.999; the discount after 1,000 steps changes from approximately 0.0067 to 0.368 |
| Speed-limiter reward competed with braking for turns | Disable the optional top-speed bonus by default; keep forward-progress and goal rewards |
| Small CPU network used excessive threading overhead | Default PyTorch to one CPU thread; expose thread count in CLI and GUI |
| Sequential evaluation blocked training and had only two samples per stage | Default to 64 episodes, four parallel worlds and batched inference; keep deterministic seeds, full speed and all eight stages |
| Headless workers could busy-spin during policy updates | Briefly yield the engine when no action/request is pending |

Map reuse is restricted to unseeded training. Explicit evaluation seeds always
regenerate maps and report exhausted reset searches. Resume regenerates a map
while restoring curriculum/history and RNG; it does not resume a car mid-trip.
Speed observation normalization always uses the vehicle's full speed limit,
including during capped turn practice.

Evaluation remains synchronous with respect to PPO updates: its four worlds
run concurrently, and the training policy stays fixed for the entire suite.
This avoids mixing different policy weights in a checkpoint score. Evaluation
still takes time; increase its interval to reduce overhead if needed.

## Dashboard

Open Settings → AI Training. The fixed header shows phase, run name, step
progress, recent throughput, active elapsed time and training ETA, with the
start/pause/resume/save controls always available. ETA estimates the remaining
training work; future evaluation time is additional. Pauses are excluded from
elapsed/rate statistics, and evaluation time is reported separately.

Overview contains live recent-episode statistics, a success chart, worker
frontier/trip stages, turn-practice level, speed/progress, recent frontier
success, reset timings, per-stage evaluation results and Wilson 95% success
intervals, PPO diagnostics, and checkpoint/log links. Run setup contains all
launch/PPO/reward options, including evaluation concurrency and CPU threads.
Missing measurements display a dash instead of a fabricated zero.

On Windows, reconnection probes external trainer PIDs through the lightweight
Python launcher. Godot's own process-handle tracking is used for processes the
current instance launched. This prevents another game window from marking an
active trainer as failed. Integration-test status/control files are isolated
from the user's actual GUI run.

Windows status updates retry brief file-sharing conflicts while retaining the
previous complete JSON. If status publication still fails, it logs a warning
and defers the update without aborting PPO or model saving. Paused training
retries its status periodically. The GUI closes read handles before parsing
JSON, and the startup launcher uses the same retrying writer for failures.
This fixes the observed `WinError 5` crash when replacing the GUI status file.
The training environment remains version 3; existing version 3 checkpoints
can resume with their original run name, worker count, and saved settings.

## Validation

- The standalone training GUI embeds every visual worker in a native Windows
  grid. The eight-worker desktop test passed distinct live-window checks,
  pause/resume, save/stop, child cleanup, visual-to-headless checkpoint resume,
  and model presentation/stop. Its actual rendered grid was inspected.
- Two independent 160-episode sweeps: zero invalid spawn/reference/goal poses
  across all eight stages; alternative maps selected in 16 and 12 episodes.
- Independent controller reached goals at stages 0, 3 and 7 in 69, 228 and
  1,302 actions respectively. Fixed four-tick stepping and idle stability pass.
- Six headless/visual comparisons: identical colliders, graph, selected route,
  observations, rewards and trajectories. Eight-episode map reuse/refresh passed.
- All 32 Python tests passed, covering Godot editor-path discovery and presentation setup,
  reset recovery, version/resume guards, real PPO checkpoint
  callbacks, failure recovery, timeout telemetry, binomial intervals, external
  process detection, and exact seed/stage accounting with unequal parallel
  episode lengths. Single- and four-worker evaluation results match.
- Status-file regressions include an actual Windows handle denying delete
  sharing, transient retry/atomicity, persistent write failures, and real PPO
  learning/model saving with an entirely unavailable GUI status file. An
  isolated 10-worker recovery resumed from 30,730 to 34,570 steps and saved
  successfully while 443 Windows reader locks were applied to its status file.
- Real four-worker PPO run completed 8,192 steps, two 64-episode evaluations,
  checkpoint/best saves, then resumed successfully to 9,216 steps.
- GUI lifecycle test passed start, pause, controller reconnection, resume,
  clean stop and saved-model verification. GUI, route-planner and optional
  speed-bonus checks passed. The main scene's environment smoke test passed
  all 16 checks. Rendered dashboard previews were inspected.
- Six-worker learning check completed 100,224 training steps and two
  64-episode evaluations in 155 seconds of active time (startup excluded),
  about 647 training steps/second including evaluation time. At the last
  checkpoint, the fixed full-speed suite scored 35/64 (54.7%); stages 0–2
  scored 8/8 each, stage 3 scored 4/8, and stage 7 scored 0/8. Three workers
  advanced from 45 to 75 km/h turn practice. This is a short functional
  learning check, not a comparison against a matched baseline or proof of
  convergence. Its artifacts are isolated in `ai/runs/v3_learning_check/`.

An isolated 48-action benchmark retained 192 physics ticks while wall time
changed from about 3.20 seconds to 0.025 seconds with accelerated engine flags.
Actual short PPO collection measured roughly 1,000–1,700 aggregate steps/second
with four/six workers on this machine; full-run throughput is lower because
updates, resets, startup and evaluations also consume time. These measurements
are workload-specific, not a promised speedup on every computer.

The checks establish environment validity and working training/control paths.
They do not establish a fully learned driving policy. Full-speed difficult
turns and longest-route success still require a longer run and evaluation on
fresh seeds. Roundabout ring edges remain excluded because the current
reference radius is below the vehicle's turning radius. Traffic, pedestrians,
and signals remain outside this training task.
