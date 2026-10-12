extends Camera2D


@export_category("Zoom")

@export var zoom_step: float = 0.1
@export var min_zoom: float = 0.5
@export var max_zoom: float = 2.5

@export var zoom_speed: float = 8.0


var target_zoom: float = 1.0


func _ready() -> void:
	target_zoom = zoom.x
	position_smoothing_enabled = true
	position_smoothing_speed = 7.0
	ignore_rotation = true
	process_callback = Camera2D.CAMERA2D_PROCESS_PHYSICS
	make_current()


func _process(delta: float) -> void:
	zoom = zoom.lerp(
		Vector2.ONE * target_zoom,
		minf(zoom_speed * delta, 1.0)
	)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if not event.pressed:
			return


		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			target_zoom += zoom_step


		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			target_zoom -= zoom_step


		target_zoom = clamp(
			target_zoom,
			min_zoom,
			max_zoom
		)
