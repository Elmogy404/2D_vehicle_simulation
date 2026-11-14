extends CharacterBody2D


enum CollisionTerminationMode {
	LEGACY_ANY_CONTACT,
	SEVERITY_AWARE,
}

## Collision partner classes. These are strings (not StringName) because the
## same values are written into JSON metadata consumed by the Python side.
const COLLISION_WORLD := "world"
const COLLISION_VEHICLE := "vehicle"
const COLLISION_PEDESTRIAN := "pedestrian"
const COLLISION_OBSTACLE := "obstacle"
const COLLISION_UNKNOWN := "unknown"

# Physics layer bit values used by the project's scenes. Classification checks
# groups first, then these layers, so authored actors keep working even if a
# scene forgets to add the group.
const COLLISION_LAYER_WORLD := 1
const COLLISION_LAYER_VEHICLE := 2
const COLLISION_LAYER_PEDESTRIAN := 4
const COLLISION_LAYER_OBSTACLE := 8

## Bound per-episode history so a long sequence of minor scrapes cannot grow
## without limit. Evaluation uses collision_count for the true total.
const MAX_RECORDED_COLLISIONS := 128


@export_category("Vehicle")

@export var max_speed: float = 500.0
@export var acceleration: float = 250.0
@export var braking: float = 500.0

## Reverse deliberately has a lower ceiling and gentler acceleration than
## forward driving. The brake pedal only selects reverse after the vehicle has
## come to a complete stop, matching an automatic transmission.
@export var max_reverse_speed: float = 95.0
@export var reverse_acceleration: float = 150.0
@export var direction_change_threshold: float = 2.0

## Passive rolling resistance when neither pedal is pressed.
@export var coast_deceleration: float = 75.0

## Axle-to-axle distance used by the kinematic bicycle model.
@export var wheelbase: float = 92.0

## Physical body dimensions, matching the inset collision shape rather than
## the transparent outer edge of the sprite.
@export var vehicle_width: float = 62.0
@export var vehicle_length: float = 122.0

@export var steering_speed: float = 2.5
@export var max_steering_angle: float = 35.0


@export_category("Display")

## Display conversion: world units per second -> km/h.
## The HUD and the Game Over screen both read this value,
## so the two displays can never disagree.
@export var kmh_per_unit: float = 0.3


@export_category("Collision")

## Legacy behaviour terminates on the first slide contact, exactly as before.
## Severity-aware mode records minor contacts but only terminates at/above the
## configured impact thresholds (pedestrian contacts are always safety-critical).
@export var collision_termination_mode: CollisionTerminationMode = \
	CollisionTerminationMode.LEGACY_ANY_CONTACT

## Normal closing speed below which a non-pedestrian contact is classified as
## minor. Units: world units/second. At the scene's 0.3 km/h per unit/s scale,
## 30 units/s = 9 km/h (a parking-lot bump, below airbag/injury thresholds).
@export var minor_contact_speed: float = 30.0

## Normal closing speed at/above which a non-pedestrian contact is a severe,
## terminal collision. Units: world units/second. 120 units/s = 36 km/h, a
## meaningful frontal delta-v and well above the ~30 km/h pedestrian fatality
## risk inflection; this is an engineering default, not a legal threshold.
@export var terminal_impact_speed: float = 120.0

## Pedestrian impacts are safety-critical. The default of 0 units/s makes any
## pedestrian contact terminal in severity-aware mode; raise it only for
## low-speed contact experiments.
@export var pedestrian_terminal_impact_speed: float = 0.0

## Minimum seconds between recorded minor contacts with the same body. Stops a
## car resting against a wall from emitting one event per physics tick.
@export var collision_event_cooldown: float = 0.25


var current_speed: float = 0.0
var steering_input: float = 0.0
var steering_command: float = 0.0
var throttle_input: float = 0.0
var brake_input: float = 0.0

# A controller may inject commands explicitly. When disabled, commands are
# read from any child exposing get_control_command().
var external_control_enabled: bool = false
var control_source: Node

# Crash state. The vehicle itself owns collision detection;
# HUD and Game Over only READ it (see AGENT.md architecture).
var has_crashed: bool = false
var crash_speed: float = 0.0

# Structured collision history for evaluation. Every recorded event is a
# JSON-safe Dictionary; the helper getters below return defensive copies.
var collision_events: Array[Dictionary] = []
var collision_count: int = 0
var collision_events_dropped: int = 0
var last_collision_event: Dictionary = {}
var last_terminal_collision: Dictionary = {}

var _collision_tick: int = 0
var _last_collision_tick: Dictionary = {}

# Emitted once on the first terminal collision, with the actual speed
# the vehicle was travelling at the moment of impact. Kept for Game Over.
signal crashed(crash_speed: float)

# Emitted for every recorded contact, including minor contacts in
# severity-aware mode. Consumers must not assume termination.
signal collision_detected(event: Dictionary)

# Emitted when a contact crosses the terminal threshold. Carries the same
# structured metadata as collision_detected.
signal collision_terminated(event: Dictionary)


func _ready() -> void:
	# NPCs treat the ego as a lane obstacle. This is a
	# read-only tag: ego control stays independent.
	add_to_group("vehicle_obstacle")
	control_source = get_node_or_null("KeyboardController")


func _physics_process(delta: float) -> void:
	_collision_tick += 1
	if has_crashed:
		velocity = Vector2.ZERO
		return

	# --------------------------------------------------------
	# INPUT
	# --------------------------------------------------------
	if not external_control_enabled and control_source != null:
		if control_source.has_method("get_control_command"):
			var command: Vector3 = control_source.get_control_command()
			set_control(command.x, command.y, command.z, false)


	# --------------------------------------------------------
	# ACCELERATION / BRAKING
	# --------------------------------------------------------

	# Braking wins when both pedals are commanded. S first brakes a forward
	# moving car, then engages reverse on a later physics tick after it stops.
	if brake_input > 0.0:
		if current_speed > direction_change_threshold:
			current_speed = move_toward(
				current_speed,
				0.0,
				braking * brake_input * delta
			)
		elif current_speed > 0.0:
			current_speed = 0.0
		else:
			current_speed -= reverse_acceleration * brake_input * delta

	elif throttle_input > 0.0:
		if current_speed < -direction_change_threshold:
			current_speed = move_toward(
				current_speed,
				0.0,
				braking * throttle_input * delta
			)
		elif current_speed < 0.0:
			current_speed = 0.0
		else:
			current_speed += acceleration * throttle_input * delta

	else:
		current_speed = move_toward(
			current_speed,
			0.0,
			coast_deceleration * delta
		)


	current_speed = clamp(
		current_speed,
		-max_reverse_speed,
		max_speed
	)


	# --------------------------------------------------------
	# STEERING INPUT
	# --------------------------------------------------------

	steering_input = move_toward(
		steering_input,
		steering_command,
		steering_speed * delta
	)


	# --------------------------------------------------------
	# VEHICLE ROTATION
	# --------------------------------------------------------

	if absf(current_speed) > 1.0:
		var steering_angle := (
			steering_input
			* deg_to_rad(max_steering_angle)
		)

		var yaw_rate := (
			current_speed / maxf(wheelbase, 1.0)
			* tan(steering_angle)
		)
		rotation += yaw_rate * delta


	# --------------------------------------------------------
	# MOVEMENT
	# --------------------------------------------------------

	# Speed and velocity at the instant before the move, so a collision
	# reports the real impact speed (velocity is altered by
	# move_and_slide() during the contact itself).
	var impact_speed := absf(current_speed)
	var pre_move_velocity := Vector2.UP.rotated(rotation) * current_speed

	velocity = pre_move_velocity

	move_and_slide()

	_process_slide_collisions(pre_move_velocity, impact_speed)


func _process_slide_collisions(pre_move_velocity: Vector2, legacy_impact_speed: float) -> void:
	var slide_count := get_slide_collision_count()
	if slide_count == 0:
		return

	var seen_colliders: Dictionary = {}
	var events: Array[Dictionary] = []

	for collision_index in range(slide_count):
		var collision := get_slide_collision(collision_index)
		if collision == null:
			continue
		var collider := collision.get_collider()
		var collider_key := collider.get_instance_id() if collider != null else 0
		# Multiple contact points against the same body are one event.
		if seen_colliders.has(collider_key):
			continue
		seen_colliders[collider_key] = true

		var event := _build_collision_event(collision, pre_move_velocity)
		if event.is_empty():
			continue

		# Terminal contacts are never suppressed by the minor-contact cooldown.
		if not bool(event["terminal"]) and _is_duplicate_minor_contact(collider_key):
			continue

		_record_collision_event(event, collider_key)
		events.append(event)

	var terminal_event := _select_terminal_event(events)
	if not terminal_event.is_empty():
		_trigger_crash(legacy_impact_speed, terminal_event)


func _build_collision_event(collision: KinematicCollision2D, ego_velocity: Vector2) -> Dictionary:
	var collider := collision.get_collider()
	var partner_type := classify_collision_partner(collider)
	var partner_velocity := _collision_partner_velocity(collider)
	var normal := collision.get_normal()
	if normal.length_squared() < 1.0e-8:
		# Defensive fallback for degenerate contacts; normally the physics
		# server provides a unit normal.
		normal = -ego_velocity.normalized() if ego_velocity.length_squared() > 1.0e-8 else Vector2.ZERO

	var relative_velocity := ego_velocity - partner_velocity
	# Godot's slide normal can be reported in either orientation depending on
	# the contact. Orient it so it opposes the relative approach, then take the
	# normal closing speed: the component of relative motion that actually
	# drives the surfaces together. A glancing scrape has a small value even
	# when the full relative speed is large.
	var normal_speed := relative_velocity.dot(normal)
	if normal_speed > 0.0:
		normal = -normal
		normal_speed = -normal_speed
	var normal_impact_speed := maxf(-normal_speed, 0.0)
	var relative_speed := relative_velocity.length()
	# Static geometry uses the normal closing speed so a high-speed scrape
	# along a wall remains a minor contact. Dynamic actors use total relative
	# speed as a delta-v proxy: a high-speed sideswipe can be severe even when
	# the engine reports a lateral contact normal.
	var impact_speed := normal_impact_speed
	if partner_type == COLLISION_VEHICLE or partner_type == COLLISION_PEDESTRIAN:
		impact_speed = maxf(normal_impact_speed, relative_speed)
	var tangent := Vector2(-normal.y, normal.x)
	var tangential_speed := absf(relative_velocity.dot(tangent))
	var terminal := _event_is_terminal(partner_type, impact_speed)
	var severe := _event_is_severe(partner_type, impact_speed)
	var safety_critical := partner_type == COLLISION_PEDESTRIAN
	var minor := not safety_critical and impact_speed < minor_contact_speed

	var severity := "moderate"
	if safety_critical:
		severity = "safety_critical"
	elif severe:
		severity = "severe"
	elif minor:
		severity = "minor"

	var partner_name := ""
	var partner_path := ""
	var partner_layer := 0
	var partner_groups: Array[String] = []
	if collider is Node:
		var collider_node := collider as Node
		partner_name = String(collider_node.name)
		if collider_node.is_inside_tree():
			partner_path = String(collider_node.get_path())
		for group in collider_node.get_groups():
			partner_groups.append(String(group))
	if collider is CollisionObject2D:
		partner_layer = (collider as CollisionObject2D).collision_layer

	return {
		"partner_type": partner_type,
		"partner_name": partner_name,
		"partner_path": partner_path,
		"partner_layer": partner_layer,
		"partner_groups": partner_groups,
		"impact_speed_units": impact_speed,
		"impact_speed_kmh": impact_speed * kmh_per_unit,
		"normal_impact_speed_units": normal_impact_speed,
		"normal_impact_speed_kmh": normal_impact_speed * kmh_per_unit,
		"relative_speed_units": relative_speed,
		"relative_speed_kmh": relative_speed * kmh_per_unit,
		"tangential_speed_units": tangential_speed,
		"ego_speed_units": ego_velocity.length(),
		"partner_speed_units": partner_velocity.length(),
		"normal": [normal.x, normal.y],
		"normal_degrees": rad_to_deg(normal.angle()),
		"contact_position": [collision.get_position().x, collision.get_position().y],
		"relative_velocity": [relative_velocity.x, relative_velocity.y],
		"ego_velocity": [ego_velocity.x, ego_velocity.y],
		"partner_velocity": [partner_velocity.x, partner_velocity.y],
		"minor": minor,
		"severe": severe,
		"safety_critical": safety_critical,
		"terminal": terminal,
		"severity": severity,
		"physics_frame": Engine.get_physics_frames(),
		"collision_tick": _collision_tick,
		"termination_mode": _collision_mode_name(),
		"thresholds": {
			"minor_contact_speed_units": minor_contact_speed,
			"terminal_impact_speed_units": terminal_impact_speed,
			"pedestrian_terminal_impact_speed_units": pedestrian_terminal_impact_speed,
		},
	}


func _event_is_terminal(partner_type: String, impact_speed: float) -> bool:
	if collision_termination_mode == CollisionTerminationMode.LEGACY_ANY_CONTACT:
		return true
	if partner_type == COLLISION_PEDESTRIAN:
		return impact_speed >= pedestrian_terminal_impact_speed
	return impact_speed >= terminal_impact_speed


func _event_is_severe(partner_type: String, impact_speed: float) -> bool:
	if partner_type == COLLISION_PEDESTRIAN:
		return impact_speed >= pedestrian_terminal_impact_speed
	return impact_speed >= terminal_impact_speed


func _select_terminal_event(events: Array[Dictionary]) -> Dictionary:
	var selected: Dictionary = {}
	for event in events:
		if not bool(event.get("terminal", false)):
			continue
		if selected.is_empty() \
		or float(event["impact_speed_units"]) > float(selected["impact_speed_units"]):
			selected = event
	return selected


func _record_collision_event(event: Dictionary, collider_key: int) -> void:
	collision_count += 1
	last_collision_event = event.duplicate(true)
	if collision_events.size() < MAX_RECORDED_COLLISIONS:
		collision_events.append(event.duplicate(true))
	else:
		collision_events_dropped += 1
	if not bool(event.get("terminal", false)):
		_last_collision_tick[collider_key] = _collision_tick
	collision_detected.emit(event.duplicate(true))


func _is_duplicate_minor_contact(collider_key: int) -> bool:
	if not _last_collision_tick.has(collider_key):
		return false
	var cooldown_ticks := maxi(
		int(ceil(maxf(collision_event_cooldown, 0.0) * float(Engine.physics_ticks_per_second))),
		1
	)
	return _collision_tick - int(_last_collision_tick[collider_key]) < cooldown_ticks


func classify_collision_partner(collider: Object) -> String:
	if collider == null:
		return COLLISION_UNKNOWN

	var layer := 0
	if collider is CollisionObject2D:
		layer = (collider as CollisionObject2D).collision_layer

	# Groups are authoritative because a scene may reuse a layer for a
	# special actor while still wanting the clearer semantic class.
	if collider is Node:
		var collider_node := collider as Node
		if collider_node.is_in_group("pedestrians") \
		or collider_node.is_in_group("crossing_pedestrians"):
			return COLLISION_PEDESTRIAN
		if collider_node.is_in_group("traffic") \
		or collider_node.is_in_group("vehicle_obstacle"):
			return COLLISION_VEHICLE
		if collider_node.is_in_group("obstacles") \
		or collider_node.is_in_group("obstacle"):
			return COLLISION_OBSTACLE

	if layer & COLLISION_LAYER_PEDESTRIAN:
		return COLLISION_PEDESTRIAN
	if layer & COLLISION_LAYER_VEHICLE:
		return COLLISION_VEHICLE
	if layer & COLLISION_LAYER_OBSTACLE:
		return COLLISION_OBSTACLE
	if layer & COLLISION_LAYER_WORLD:
		return COLLISION_WORLD
	return COLLISION_UNKNOWN


func _collision_partner_velocity(collider: Object) -> Vector2:
	if collider is CharacterBody2D:
		return (collider as CharacterBody2D).velocity
	if collider is RigidBody2D:
		return (collider as RigidBody2D).linear_velocity
	return Vector2.ZERO


func _collision_mode_name() -> String:
	if collision_termination_mode == CollisionTerminationMode.SEVERITY_AWARE:
		return "severity_aware"
	return "legacy_any_contact"


func _trigger_crash(at_speed: float, event: Dictionary = {}) -> void:
	if has_crashed:
		return
	has_crashed = true
	crash_speed = at_speed
	if not event.is_empty():
		last_terminal_collision = event.duplicate(true)

	current_speed = 0.0
	steering_input = 0.0
	velocity = Vector2.ZERO

	crashed.emit(crash_speed)
	collision_terminated.emit(last_terminal_collision.duplicate(true))


# ============================================================
# STATE
# ============================================================

## Full vehicle reset used by Restart: no motion, no crash.
func reset_vehicle() -> void:
	has_crashed = false
	crash_speed = 0.0
	current_speed = 0.0
	steering_input = 0.0
	steering_command = 0.0
	throttle_input = 0.0
	brake_input = 0.0
	velocity = Vector2.ZERO
	external_control_enabled = false

	# Collision metadata belongs to one episode. Threshold configuration is
	# intentionally preserved across resets.
	collision_events.clear()
	collision_count = 0
	collision_events_dropped = 0
	last_collision_event = {}
	last_terminal_collision = {}
	_last_collision_tick.clear()
	_collision_tick = 0


## Controller-neutral command API. Values are normalized to 0..1 for pedals
## and -1..1 for steering. Passing external=false is reserved for adapters.
func set_control(
	throttle: float,
	brake_amount: float,
	steering: float,
	external: bool = true
) -> void:
	throttle_input = clampf(throttle, 0.0, 1.0)
	brake_input = clampf(brake_amount, 0.0, 1.0)
	steering_command = clampf(steering, -1.0, 1.0)

	if external:
		external_control_enabled = true


func use_default_controller() -> void:
	external_control_enabled = false
	throttle_input = 0.0
	brake_input = 0.0
	steering_input = 0.0
	steering_command = 0.0


## Live speed for the HUD (reads actual physics velocity).
func get_speed_kmh() -> float:
	return velocity.length() * kmh_per_unit


## Impact speed for the Game Over screen.
func get_crash_kmh() -> float:
	return crash_speed * kmh_per_unit


## Compact, JSON-safe collision metadata for step info and evaluation.
func get_collision_summary() -> Dictionary:
	return {
		"collision_count": collision_count,
		"events_dropped": collision_events_dropped,
		"last_collision": last_collision_event.duplicate(true),
		"terminal_collision": last_terminal_collision.duplicate(true),
		"termination_mode": _collision_mode_name(),
		"thresholds": {
			"minor_contact_speed_units": minor_contact_speed,
			"terminal_impact_speed_units": terminal_impact_speed,
			"pedestrian_terminal_impact_speed_units": pedestrian_terminal_impact_speed,
		},
	}


## Full per-episode history (bounded by MAX_RECORDED_COLLISIONS).
func get_collision_events() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for event in collision_events:
		result.append(event.duplicate(true))
	return result


func get_gear_label() -> String:
	if current_speed < -direction_change_threshold:
		return "R"
	if current_speed > direction_change_threshold:
		return "D"
	return "N"
