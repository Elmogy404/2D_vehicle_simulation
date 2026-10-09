extends CharacterBody2D


@export_category("Vehicle")

@export var max_speed: float = 300.0
@export var acceleration: float = 250.0
@export var braking: float = 500.0

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

# Emitted once on the first collision, with the actual speed
# the vehicle was travelling at the moment of impact.
signal crashed(crash_speed: float)


func _ready() -> void:
	# NPCs treat the ego as a lane obstacle. This is a
	# read-only tag: ego control stays independent.
	add_to_group("vehicle_obstacle")
	control_source = get_node_or_null("KeyboardController")


func _physics_process(delta: float) -> void:
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

	# Braking wins when both pedals are commanded, matching a safe controller
	# contract and avoiding accidental acceleration from conflicting inputs.
	if brake_input > 0.0:
		current_speed -= braking * brake_input * delta

	elif throttle_input > 0.0:
		current_speed += acceleration * throttle_input * delta

	else:
		current_speed = move_toward(
			current_speed,
			0.0,
			coast_deceleration * delta
		)


	current_speed = clamp(
		current_speed,
		0.0,
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

	if current_speed > 1.0:
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

	# Speed at the instant before the move, so a collision
	# reports the real impact speed (velocity is altered by
	# move_and_slide() during the contact itself).
	var impact_speed := current_speed

	velocity = (
		Vector2.UP.rotated(rotation)
		*
		current_speed
	)

	move_and_slide()

	if get_slide_collision_count() > 0:
		_trigger_crash(impact_speed)


func _trigger_crash(at_speed: float) -> void:
	has_crashed = true
	crash_speed = at_speed

	current_speed = 0.0
	steering_input = 0.0
	velocity = Vector2.ZERO

	crashed.emit(crash_speed)


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
