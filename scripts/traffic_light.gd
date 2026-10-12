class_name TrafficLight
extends Node2D


enum SignalState { GREEN, YELLOW, RED }

@export var green_duration: float = 8.0
@export var yellow_duration: float = 2.0
@export var red_duration: float = 7.0

var route: RoutePath
var progress: float = 0.0
var phase_time: float = 0.0
var state: SignalState = SignalState.GREEN
var intersection_width: float = 190.0


func configure(
	new_route: RoutePath,
	new_progress: float,
	initial_phase: float,
	new_intersection_width: float = 190.0
) -> void:
	route = new_route
	progress = new_progress
	phase_time = fposmod(initial_phase, cycle_duration())
	intersection_width = new_intersection_width
	_update_state()
	_snap_to_route()
	add_to_group("traffic_lights")


func _process(delta: float) -> void:
	phase_time = fposmod(phase_time + delta, cycle_duration())
	var old_state := state
	_update_state()

	if state != old_state:
		queue_redraw()


func cycle_duration() -> float:
	return green_duration + yellow_duration + red_duration


func _update_state() -> void:
	if phase_time < green_duration:
		state = SignalState.GREEN
	elif phase_time < green_duration + yellow_duration:
		state = SignalState.YELLOW
	else:
		state = SignalState.RED


func _snap_to_route() -> void:
	if route == null or not route.is_valid():
		return

	global_position = route.get_position_at(progress)
	global_rotation = route.get_rotation_at(progress)
	queue_redraw()


func requires_stop(vehicle_speed: float, gap: float, braking: float) -> bool:
	if state == SignalState.RED:
		return true

	if state != SignalState.YELLOW:
		return false

	# Continue through yellow only when braking now would require more road than
	# remains. This prevents impossible last-moment stops.
	var stopping_distance := (
		vehicle_speed * vehicle_speed / maxf(2.0 * braking, 0.001)
	)
	return gap > stopping_distance + 12.0


func stop_progress_for(travel_direction: float) -> float:
	var stop_offset := intersection_width * 0.5 + 18.0
	return clampf(
		progress - (1.0 if travel_direction >= 0.0 else -1.0) * stop_offset,
		0.0,
		route.length
	)


func force_state(new_state: SignalState) -> void:
	state = new_state

	match new_state:
		SignalState.GREEN:
			phase_time = 0.0
		SignalState.YELLOW:
			phase_time = green_duration
		SignalState.RED:
			phase_time = green_duration + yellow_duration

	queue_redraw()


func _draw() -> void:
	var half_road := route.get_half_width_at(progress)
	var stop_offset := intersection_width * 0.5 + 18.0

	# One correctly positioned signal and stop line for each approach.
	for direction in [-1.0, 1.0]:
		var side: float = float(direction)
		var approach_y: float = stop_offset * float(direction)
		var base := Vector2(side * (half_road + 20.0), approach_y)
		draw_line(base, base + Vector2(side * 28.0, 0.0), Color(0.18, 0.20, 0.22), 7.0)
		draw_rect(Rect2(base + Vector2(side * 12.0 - 12.0, -16.0), Vector2(24.0, 32.0)), Color(0.07, 0.08, 0.09))
		var lamp_color := Color(0.18, 0.20, 0.20)

		match state:
			SignalState.GREEN:
				lamp_color = Color(0.15, 0.95, 0.28)
			SignalState.YELLOW:
				lamp_color = Color(1.0, 0.75, 0.08)
			SignalState.RED:
				lamp_color = Color(1.0, 0.12, 0.08)

		draw_circle(base + Vector2(side * 12.0, 0.0), 7.0, lamp_color)

	# Right-hand traffic occupies +X in the forward approach and -X in reverse.
	draw_line(Vector2(0.0, stop_offset), Vector2(half_road, stop_offset), Color(0.95, 0.95, 0.9), 5.0)
	draw_line(Vector2(-half_road, -stop_offset), Vector2(0.0, -stop_offset), Color(0.95, 0.95, 0.9), 5.0)
