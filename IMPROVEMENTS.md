# Simulation review improvements — 25 October 2026

Implemented in the requested order, with focused tests before moving to the
next item. No long training job is part of this work.

| Item | Implementation | Focused verification |
|---|---|---|
| 1. Curved navigation | Preserve every authored vertex; subdivide long straight edges without shortcutting bends. | `segment_navigation_test`, five-seed generator checks, physical boundary checks. |
| 2. Circular hubs | Directed counterclockwise ring with radial entrance/exit connections; physical island perimeter. | Every ordered entrance/exit pair on three- and four-arm hubs avoids the island and follows circulation; 16-piece catalog passes. |
| 3. Shared AI contract | `driving_task.gd` owns route selection, body clearance, projection and observations for gameplay/training. Both training interfaces support segmented maps. | Exact observation/projection parity, segmented stages 0/3/5/7, real Python bridge, 160 original-map episodes and reference-controller drives. |
| 4. Authored signals | NPC stopping targets use the asset's stop-line center and incoming direction; passed approaches cannot stop the car again mid-turn. | Rotated turn approaches, exact bumper gap, red stop and post-entry behavior; optimized/full-scan signal parity and gameplay checks. |
| 5. NPC clearance | Shared oriented rectangle checks at spawn and every five units along trips; generation waits for collider registration before actor deployment. | Full traffic population on the tested original/segmented maps, all accepted routes checked, blocked-rear-bumper and blocked-route fixtures, regeneration checks. |
| 6. Evaluation | 128 checkpoint episodes; per-tier sample/success/turn gates; separate 256-episode holdout with disjoint seeds and no influence on checkpoint selection. | Batched/single-worker parity; insufficient samples/failing tiers rejected; holdout cannot modify selected ZIP or evaluation state; actual PPO save/resume unit tests. |
| 7. Performance/maintenance | Spatial broad phase for leaders/crossings/signals, bounded route-clearance cache, delayed blocked-trip retries, shared defaults/checkpoint utilities, pinned core dependencies, reserved run names and source/runtime provenance. | 2,000-actor indexed/full-scan comparisons, cell crossing/removal checks, signal parity, Python suite, real PPO pause/resume/save. |

The in-game legacy checkpoint shortcuts remain available. A viewer can preserve
the selected trip length while reporting fewer turns if the currently generated
map cannot supply the requested number of collision-free turns. Training's
curriculum turn requirements remain strict.

Final stress testing also exposed route-handoff starvation: a rejected long
trip kept demanding an unsafe turn instead of trying shorter safe alternatives.
Handoffs now try a bounded set of alternatives. NPC route targets leave extra
clearance on narrow streets and prepare a single lane for tight turns. Actor
spacing uses oriented body extents, allowing curb pedestrians and adjacent-lane
cars without admitting overlapping bodies. The 30-second traffic/pedestrian
stress scenario passes all six checks, including the no-permanent-freeze check.

The spatial microbenchmark measured approximately 15 ms for 1,000 queries over
2,000 actors versus 566 ms for a complete scan on this machine. This isolates
lookup cost; it is not an end-to-end frame-rate guarantee. Small groups use a
cached linear scan when visiting grid cells would cost more.

Training still excludes traffic, pedestrians, signals and the original tight
roundabout rings. New segmented maps need their own training run, not a resume
of an original-generator experiment. The default Python setup now requires
3.12+ because the tested pinned NumPy version requires it.

Re-run checks with `tests/run_checks.py`; generated reports and test models are
isolated under the ignored `ai/runs` directory. Existing user policies are not
overwritten. The Windows short/full-path test now compares resolved paths.

## Final verification

- Combined runner: **22/22 check groups passed** (`--full --lifecycle`).
- Python: **37/37 tests passed**, including checkpoint save/resume/recovery,
  holdout isolation, run-name protection, shared configuration and path handling.
- Original training environment: **160/160 episodes valid**, zero failures;
  reference controllers reached goals at stages 0, 3 and 7.
- Gameplay acceptance: **89 checks passed**; separate original-environment
  acceptance: **19 checks passed**.
- Traffic/pedestrian stress: **6/6 checks passed**, including no prolonged
  NPC freeze, staying inside road boundaries and avoiding severe overlap.
- Actual isolated PPO lifecycle: start, pause, reconnect, resume, save and stop
  passed. No long training run was started.
- Shared headless/visible-state parity and the live legacy-policy bridge passed.
- Final spatial benchmark: 1,000 queries over 2,000 actors took **11.7 ms indexed
  versus 378.2 ms scanning**, approximately 32 times faster for this lookup task.
- Python compilation and `git diff --check` passed.

The detailed combined output is in `ai/runs/project_checks.json`. Tests were
automated/headless; they do not establish trained-policy accuracy or substitute
for trying the updated simulation interactively.
