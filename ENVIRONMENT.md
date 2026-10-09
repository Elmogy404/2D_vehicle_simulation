# Driving Environment Foundation

The simulation deliberately keeps driving policy separate from vehicle physics.
No AI, reward function, training loop, or automatic driving policy is included.

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

This service does not apply controls or change simulation state.

## Generated world systems

- The ego camera follows the player by default with physics-tick smoothing.
  Press `C` to switch to the free debug camera.
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
  shortest-path lookup for the later destination-routing phase. Identical seeds
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
3. `Pedestrians`: reserved for the pedestrian phase
4. `Triggers`: reserved for signals, checkpoints, and scenario events

## Current boundary

This milestone includes deterministic mixed-road geometry, signals,
pedestrians, priority merges, reverse driving, exploration UI, and a connected
navigation graph with actual alternate road loops. Current NPC traffic follows
the arterial; a future traffic-routing phase can assign destinations across the
existing graph. Weather/surface conditions and training systems remain separate
phases.
