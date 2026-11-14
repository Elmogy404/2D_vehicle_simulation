# Historical Step 1 implementation brief

This file records the original Step 1 acceptance criteria. They have since
been implemented, and the project has moved on to traffic, intersections,
segmented road generation, and PPO training. The old instruction to postpone
Step 2 is no longer applicable. For current behavior, see `ENVIRONMENT.md`,
`AI_ROADMAP.md`, and `ai/README.md`.

# CHANGE 1 — Variable NPC Speeds

NPC traffic cars must NOT all travel at the same speed.

Each NPC should have its own deterministic cruising speed generated from the simulation seed.

Conceptually:

```text
NPC 1 → 65 km/h
NPC 2 → 78 km/h
NPC 3 → 91 km/h
NPC 4 → 72 km/h
```

The exact range should be configurable.

Requirements:

* Each car gets a `cruise_speed`.
* Speed assignment must be deterministic for the same seed.
* Do NOT randomize speed every frame.
* `target_speed` can change dynamically based on:

  * vehicle ahead
  * curve slowdown
  * later traffic lights
* Preserve the existing acceleration/braking behavior.

The important thing is that the traffic should look heterogeneous rather than every NPC moving at the same speed.

---

# CHANGE 2 — Ego Vehicle Speed + Acceleration

The ego vehicle should have proper variable-speed behavior.

It should have:

* current speed
* acceleration
* braking/deceleration
* maximum speed
* configurable acceleration rate
* configurable brake rate

The vehicle should accelerate progressively rather than instantly changing to a fixed speed.

For example:

```text
0
↓
10
↓
20
↓
30
↓
40
```

When acceleration is released, the vehicle should decelerate naturally.

When braking is applied, it should decelerate faster.

Do NOT make this arcade-like with instant speed changes.

Keep the current steering/control behavior unless a change is required.

---

# CHANGE 3 — Ego Speed HUD

Add a simple speed display on the side of the screen.

Example:

```text
SPEED
72 km/h
```

It should update every frame from the ego vehicle's actual velocity.

The displayed value must NOT be a fake/random value.

Prefer a simple CanvasLayer/Control UI.

If the current project already has an appropriate UI structure, reuse it.

If a new scene is necessary, explain why.

Do not unnecessarily modify unrelated scenes.

---

# CHANGE 4 — Collision / Game Over

When the ego vehicle collides with an obstacle/vehicle/wall:

```text
Ego collision
      ↓
Game Over
      ↓
Stop/freeze gameplay
      ↓
Show Game Over UI
```

The Game Over UI should contain at minimum:

```text
GAME OVER

Speed: XX km/h

[ Restart ]
```

The displayed crash speed should be the actual ego speed at the moment of collision.

The Restart action should:

* reset the ego position
* reset ego velocity
* reset ego state
* rebuild/reset traffic if necessary
* restore the simulation to its initial state
* allow the player to drive again

If a full UI button is unnecessarily complex at this stage, a keyboard restart key is acceptable as a fallback, but prefer a simple visible Restart button.

---

# IMPORTANT — AUTONOMOUS VEHICLE ARCHITECTURE

Do not couple Game Over or HUD logic directly into the ML/sensor architecture.

Keep:

```text
EgoVehicle
    ↓
movement / physics / collision state

SensorRig
    ↓
observations

Future ML Controller
    ↓
control commands
```

The HUD should only READ the ego state.

The Game Over system should react to the ego's collision/state.

Do not modify SensorRig unless absolutely necessary.

---

# SCENE VS SCRIPT CHANGES

Scripts can be modified freely where required.

Modify `.tscn` files only when actually necessary.

For example:

* `route_path.gd` → script only, no scene.
* `traffic_car.gd` → script.
* `traffic_manager.gd` → script.
* `ego_vehicle.gd` → script.
* HUD → may require CanvasLayer/Control nodes.
* Game Over UI → may require UI nodes.

Do not create unnecessary scenes.

At the end, explicitly report:

```text
Scripts changed:
...

Scenes changed:
...

New files:
...

New nodes:
...

Behavior changed:
...

Tests:
...
```

---

# TESTING

Add or update automated tests where practical.

Verify:

1. NPCs have different deterministic speeds.
2. Same seed produces the same NPC speed assignments.
3. Ego accelerates progressively.
4. Ego braking works.
5. Speed HUD matches actual ego velocity.
6. Collision triggers Game Over.
7. Crash speed is correct.
8. Restart restores the initial state.
9. Existing Step 1 tests still pass.
10. No regression in lane following or bidirectional traffic.

Run both headless tests and an actual Godot editor/play test.

Do NOT proceed to traffic lights/intersections until these changes are stable.
