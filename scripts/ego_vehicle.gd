extends CharacterBody2D


@export_category("Vehicle")

@export var max_speed: float = 300.0
@export var acceleration: float = 250.0
@export var braking: float = 500.0

@export var steering_speed: float = 2.5
@export var max_steering_angle: float = 35.0


@export_category("Display")

## Display conversion: world units per second -> km/h.
## The HUD and the Game Over screen both read this value,
## so the two displays can never disagree.
@export var kmh_per_unit: float = 0.3


var current_speed: float = 0.0
var steering_input: float = 0.0

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


func _physics_process(delta: float) -> void:
	if has_crashed:
		velocity = Vector2.ZERO
		return

	# --------------------------------------------------------
	# INPUT
	# --------------------------------------------------------
	var throttle := Input.get_axis(
		"brake",
		"accelerate"
	)

	var steering := Input.get_axis(
		"steer_left",
		"steer_right"
	)


	# --------------------------------------------------------
	# ACCELERATION / BRAKING
	# --------------------------------------------------------

	if throttle > 0.0:
		current_speed += acceleration * throttle * delta

	elif throttle < 0.0:
		current_speed -= braking * abs(throttle) * delta

	else:
		current_speed = move_toward(
			current_speed,
			0.0,
			acceleration * 0.3 * delta
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
		steering,
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

		rotation += (
			steering_angle
			* current_speed
			/ max_speed
			* delta
		)


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
	velocity = Vector2.ZERO


## Live speed for the HUD (reads actual physics velocity).
func get_speed_kmh() -> float:
	return velocity.length() * kmh_per_unit


## Impact speed for the Game Over screen.
func get_crash_kmh() -> float:
	return crash_speed * kmh_per_unit