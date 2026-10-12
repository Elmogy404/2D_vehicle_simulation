class_name KeyboardVehicleController
extends Node


## Human-input adapter. The vehicle consumes this small command API and never
## reads Input directly, so another controller can be substituted later.
func get_control_command() -> Vector3:
	return Vector3(
		Input.get_action_strength("accelerate"),
		Input.get_action_strength("brake"),
		Input.get_axis("steer_left", "steer_right")
	)
