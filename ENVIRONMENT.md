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
- Road asphalt is rendered as independent convex strips to avoid concave
  polygon triangulation artifacts on wide curves.
- Curve radius is constrained using the widest possible road section, keeping
  inside boundaries from folding over on multi-lane bends.
- Intersections are selected from the straightest nearby route segment. Side
  road center markings stop before the conflict area, and each travel direction
  has its own approach stop line.
- Seeded cross streets create traversable four-way intersection openings.
- Widened turnaround bulbs provide enough physical road width for U-turns.
- Traffic signals are placed at generated intersections and use timed
  green/yellow/red cycles with seeded phase offsets.
- NPC traffic stops for red signals, handles yellow based on stopping distance,
  and proceeds on green.
- Seeded pedestrians wait at curbs and cross while vehicle traffic is red.
- Vehicle spawns search for a valid active lane and avoid intersection conflict
  zones. Pedestrians ignore vehicle bodies while walking so an accidental
  overlap cannot deadlock both actors; vehicles still detect and stop for them.
- Vehicle sensors detect road boundaries, traffic, and pedestrians.

## Physics layers

1. `World`: road boundaries and static geometry
2. `Vehicles`: ego and traffic vehicles
3. `Pedestrians`: reserved for the pedestrian phase
4. `Triggers`: reserved for signals, checkpoints, and scenario events

## Current boundary

This milestone includes the first deterministic intersections, signals, and
pedestrians. A future network-routing phase can allow NPCs to choose side-road
branches; current NPC traffic continues along the primary route. Weather/surface
conditions and training systems remain separate phases.
