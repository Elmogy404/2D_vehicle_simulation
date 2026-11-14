# Driving Environment Foundation

The simulation deliberately keeps driving policy separate from vehicle physics.
The playable main scene supports manual driving and an optional live PPO
checkpoint viewer. PPO training runs in a separate Godot world; its setup is
documented in `ai/README.md`, and the staged plan is in `AI_ROADMAP.md`.

## Control contract

`EgoVehicle.set_control(throttle, brake, steering)` accepts normalized commands:

- `throttle`: `0.0..1.0`
- `brake`: `0.0..1.0` (takes priority over throttle)
- `steering`: `-1.0..1.0`

Calling `set_control` selects external control. Call
`EgoVehicle.use_default_controller()` to return to the keyboard adapter. A full
vehicle reset also restores keyboard control.

The keyboard adapter is the only vehicle component that reads Godot input. This
keeps the vehicle model reusable by future controllers without changing its
physics implementation.

## Read-only state

`Main/EnvironmentState.get_state()` returns current telemetry:

- speed in world units and km/h
- normalized speed
- transmission gear (`D`, `N`, or `R` is available directly from the ego)
- current steering
- road-relative heading error
- centerline and nearest-lane lateral error
- upcoming road curvature
- absolute and normalized route progress
- crash state
- normalized distance sensor readings

This service does not apply controls or change simulation state. It is retained
as a telemetry interface, although the current HUD and live PPO controller
read their inputs directly rather than calling it.

## Generated world systems

The startup settings select either the original procedural network (described
below) or a 200-piece segmented city built from authored road pieces. Both
connect to the same gameplay systems. The current segmented planner uses two-
and four-lane streets; its six-lane and centered-crosswalk pieces remain in
the asset catalog but are not placed in generated maps yet.

- The ego camera follows the player by default with physics-tick smoothing.
  Press `C` to switch to the free debug camera.
- Press `F` during a drive (or after a crash) to regenerate the selected road
  type with a new seed. The settings gear remains available, and the last seed
  appears in the map notice and seed field so the layout can be reproduced.
- The main road uses a seeded profile ranging from one to three lanes per
  direction. Width, lane centers, and divider markings share the same smooth
  transition data, producing finite tapered lane additions and merges separated
  by constant-width road sections.
- Each seed independently randomizes map length, density, irregularity, road
  count on either side, block spacing, junction count and order, partial road
  extents, local loops, diagonals, lane widths, and obstacle placement. Every
  map still guarantees at least one T-junction, four-way intersection, curved
  section, roundabout, and alternate route.
- Every road is represented by one connected `RoadNetwork`, including
  shortest-path lookup for AI destination routing. Identical seeds
  reproduce the complete topology for debugging; different seeds do not reuse
  one fixed street template.
- The generated district uses a variable hierarchy: a gently curving multi-lane
  arterial, asymmetric collector/local corridors, cross streets, partial roads,
  diagonal shortcuts, neighborhood loops, perimeter connections, irregular
  blocks, and dead ends. The primary road's endpoints connect into perimeter
  streets, so the result has no designated level start or finish.
- Green, labeled `PARK`, `LAKE`, `FIELD`, `CONSTRUCTION`, `RESTRICTED AREA`, and
  `INDUSTRIAL SITE` regions occupy validated road-free blocks. They use simple
  collision geometry rather than art assets and also appear on the minimap.
- Road asphalt is rendered as independent convex strips to avoid concave
  polygon triangulation artifacts on wide curves.
- Curve radius is constrained using the widest possible road section, keeping
  inside boundaries from folding over on multi-lane bends.
- Intersections are selected from the straightest nearby route segment. Side
  road center markings stop before the conflict area, and each travel direction
  has its own approach stop line.
- Seeded cross streets create traversable one-lane side-road openings.
- Widened turnaround bulbs provide enough physical road width for U-turns.
- Traffic signals are placed at generated intersections and use timed
  green/yellow/red cycles with seeded phase offsets.
- NPC traffic stops for red signals, handles yellow based on stopping distance,
  and proceeds on green.
- At a narrowing, the outside lane signals, checks both the front and rear gap,
  and merges gradually. The continuing lane always has priority; if a gap is
  unsafe the merging vehicle stops before its lane ends.
- Seeded pedestrians spawn at marked crosswalks beside side-road mouths, wait
  outside the roadway, and cross only during a red vehicle phase. Once a
  crossing starts, they finish it even if the light changes; at most one
  crossing is started per red phase.
- Vehicle spawns search for a valid active lane and avoid intersection conflict
  zones. Pedestrians ignore vehicle bodies while walking so an accidental
  overlap cannot deadlock both actors; traffic yields to pedestrians only
  during active crossings.
- Vehicle sensors detect road boundaries, traffic, and pedestrians.
- The top-left minimap fits and displays the complete generated road network.
  Press `M` to toggle its expanded view.
- The keyboard transmission uses `W` for drive and `S` for brake/reverse. `S`
  must bring the car to a stop before reverse engages, and reverse has its own
  lower speed/acceleration limits. The speed HUD shows the live gear.

## Physics layers

1. `World`: road boundaries and static geometry
2. `Vehicles`: ego and traffic vehicles
3. `Pedestrians`: pedestrian actors
4. `Triggers`: reserved for signals, checkpoints, and scenario events

## Current boundary

The current simulation includes deterministic mixed-road geometry, signals,
pedestrians, priority merges, reverse driving, exploration UI, and a connected
navigation graph with alternate road loops. PPO training and live checkpoint
viewing exist. Training can select the original or segmented empty-road world;
NPC and signal-aware training are future work. Weather and surface conditions are not
implemented.
