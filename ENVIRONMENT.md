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
- The compact map guarantees a seeded T-junction, four-way intersection,
  roundabout branch, and cul-de-sac/dead-end bulbs. The arterial and every side
  road are also represented by one connected `RoadNetwork`, including shortest
  path lookup for the later destination-routing phase.
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
- Seeded pedestrians wait at curbs and cross while vehicle traffic is red.
- Vehicle spawns search for a valid active lane and avoid intersection conflict
  zones. Pedestrians ignore vehicle bodies while walking so an accidental
  overlap cannot deadlock both actors; vehicles still detect and stop for them.
- Vehicle sensors detect road boundaries, traffic, and pedestrians.
- The top-left minimap uncovers roads only as the player explores them. Press
  `M` to toggle its expanded view.
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
navigation graph. Current NPC traffic continues along the primary route; a
future traffic-routing phase can assign destinations across the existing graph.
Weather/surface conditions and training systems remain separate phases.
