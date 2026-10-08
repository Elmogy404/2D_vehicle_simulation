extends CharacterBody2D


@export_category("Vehicle")

@export var max_speed: float = 300.0
@export var acceleration: float = 250.0
@export var braking: float = 500.0

@export var steering_speed: float = 2.5
@export var max_steering_angle: float = 35.0


var current_speed: float = 0.0
var steering_input: float = 0.0


func _physics_process(delta: float) -> void:
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

	velocity = (
		Vector2.UP.rotated(rotation)
		*
		current_speed
	)

	move_and_slide()