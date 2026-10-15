extends Camera2D


@export_category("Movement")

@export var move_speed: float = 600.0
@export var fast_move_multiplier: float = 3.0


@export_category("Zoom")

@export var zoom_step: float = 0.1
@export var min_zoom: float = 0.25
@export var max_zoom: float = 4.0
@export var zoom_smoothness: float = 8.0


var target_zoom: float = 1.0
var debug_mode: bool = false

var ego_camera: Camera2D


func _ready() -> void:
	# Find the normal camera inside EgoVehicle
	ego_camera = get_parent().get_node(
		"EgoVehicle/Camera2D"
	) as Camera2D

	target_zoom = zoom.x

	# Gameplay starts by following the ego vehicle. The free debug camera is
	# still available with C for inspecting the generated environment.
	ego_camera.make_current()


func _process(delta: float) -> void:
	# --------------------------------------------------------
	# DEBUG CAMERA MOVEMENT
	# --------------------------------------------------------
	if debug_mode:
		var direction := Input.get_vector(
			"camera_left",
			"camera_right",
			"camera_up",
			"camera_down"
		)
		if Input.is_physical_key_pressed(KEY_A):
			direction.x -= 1.0
		if Input.is_physical_key_pressed(KEY_D):
			direction.x += 1.0
		if Input.is_physical_key_pressed(KEY_W):
			direction.y -= 1.0
		if Input.is_physical_key_pressed(KEY_S):
			direction.y += 1.0
		direction = direction.limit_length()

		var current_speed := move_speed


		if Input.is_key_pressed(KEY_SHIFT):
			current_speed *= fast_move_multiplier


		position += direction * current_speed * delta / maxf(zoom.x, 0.01)


	# --------------------------------------------------------
	# SMOOTH ZOOM
	# --------------------------------------------------------

	zoom = zoom.lerp(
		Vector2.ONE * target_zoom,
		minf(zoom_smoothness * delta, 1.0)
	)


func _unhandled_input(event: InputEvent) -> void:
	# --------------------------------------------------------
	# SWITCH CAMERA
	# --------------------------------------------------------
	if event is InputEventKey:
		if event.pressed and not event.echo:
			if event.keycode == KEY_R or event.physical_keycode == KEY_R:
				reset_debug_camera()


	# --------------------------------------------------------
	# DEBUG ZOOM
	# --------------------------------------------------------

	if not debug_mode:
		return


	if event is InputEventMouseButton:
		if not event.pressed:
			return


		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			adjust_zoom(zoom_step)


		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			adjust_zoom(-zoom_step)


func adjust_zoom(amount: float) -> void:
	target_zoom = clampf(target_zoom + amount, min_zoom, max_zoom)


# ============================================================
# CAMERA SWITCH
# ============================================================

func toggle_camera() -> void:
	if debug_mode:
		# Switch to ego camera
		debug_mode = false

		ego_camera.make_current()

		print("Camera: EGO")


	else:
		# Switch back to debug camera
		debug_mode = true

		make_current()

		print("Camera: DEBUG")


# ============================================================
# RESET DEBUG CAMERA
# ============================================================

func reset_debug_camera() -> void:
	position = Vector2.ZERO

	target_zoom = 1.0

	print("Debug camera reset")
