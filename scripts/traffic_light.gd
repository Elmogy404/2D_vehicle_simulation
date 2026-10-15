class_name TrafficLight
extends Node2D


enum SignalState { GREEN, YELLOW, RED }

@export var green_duration: float = 8.0
@export var yellow_duration: float = 2.0
@export var red_duration: float = 7.0

## Kept for the legacy main-route API; graph lights use position + axis instead.
var route: RoutePath
var progress: float = 0.0
var phase_time: float = 0.0
var state: SignalState = SignalState.GREEN
var intersection_width: float = 190.0
var axis_rotation: float = 0.0
var graph_node_id: int = -1
var authored_piece_index: int = -1
var approach_arms: Array[Dictionary] = []


func configure(
	new_route: RoutePath,
	new_progress: float,
	initial_phase: float,
	new_intersection_width: float = 190.0,
	new_arms: Array[Dictionary] = []
) -> void:
	route = new_route
	progress = new_progress
	intersection_width = new_intersection_width
	approach_arms = new_arms.duplicate(true)
	if route != null and route.is_valid():
		axis_rotation = route.get_direction_at(progress).angle()
		global_position = route.get_position_at(progress)
		global_rotation = axis_rotation
	phase_time = fposmod(initial_phase, cycle_duration() * 2.0)
	_update_state()
	add_to_group("traffic_lights")
	queue_redraw()


func configure_network(
	position: Vector2,
	axis: Vector2,
	initial_phase: float,
	new_intersection_width: float,
	node_id: int,
	new_arms: Array[Dictionary] = []
) -> void:
	route = null
	progress = 0.0
	global_position = position
	axis_rotation = 0.0
	if axis.length_squared() > 0.001:
		axis_rotation = axis.angle()
	global_rotation = axis_rotation
	phase_time = fposmod(initial_phase, cycle_duration() * 2.0)
	intersection_width = new_intersection_width
	graph_node_id = node_id
	approach_arms = new_arms.duplicate(true)
	_update_state()
	add_to_group("traffic_lights")
	queue_redraw()


func _process(delta: float) -> void:
	var axis_heading := Vector2.RIGHT.rotated(axis_rotation)
	var cross_heading := axis_heading.rotated(PI * 0.5)
	var previous_axis_state := state_for_heading(axis_heading)
	var previous_cross_state := state_for_heading(cross_heading)
	phase_time = fposmod(phase_time + delta, cycle_duration() * 2.0)
	_update_state()
	if previous_axis_state != state_for_heading(axis_heading) \
	or previous_cross_state != state_for_heading(cross_heading):
		queue_redraw()


func cycle_duration() -> float:
	return green_duration + yellow_duration + red_duration


func _update_state() -> void:
	var phase := fposmod(phase_time, cycle_duration() * 2.0)
	if phase < green_duration:
		state = SignalState.GREEN
	elif phase < green_duration + yellow_duration:
		state = SignalState.YELLOW
	else:
		state = SignalState.RED


func state_for_heading(heading: Vector2) -> SignalState:
	var heading_angle := heading.angle()
	var axis_difference := absf(wrapf(heading_angle - axis_rotation, -PI, PI))
	var primary_axis := axis_difference < PI * 0.25 \
		or axis_difference > PI * 0.75
	var axis_phase := fposmod(phase_time, cycle_duration() * 2.0)
	if not primary_axis:
		if axis_phase < cycle_duration():
			return SignalState.RED
		axis_phase -= cycle_duration()
	if axis_phase < green_duration:
		return SignalState.GREEN
	if axis_phase < green_duration + yellow_duration:
		return SignalState.YELLOW
	return SignalState.RED


func requires_stop(vehicle_speed: float, gap: float, braking: float) -> bool:
	return _state_requires_stop(state, vehicle_speed, gap, braking)


func requires_stop_for_heading(
	heading: Vector2,
	vehicle_speed: float,
	gap: float,
	braking: float
) -> bool:
	return _state_requires_stop(state_for_heading(heading), vehicle_speed, gap, braking)


func _state_requires_stop(
	light_state: SignalState,
	vehicle_speed: float,
	gap: float,
	braking: float
) -> bool:
	if light_state == SignalState.RED:
		return true
	if light_state != SignalState.YELLOW:
		return false
	var stopping_distance := vehicle_speed * vehicle_speed / maxf(2.0 * braking, 0.001)
	return gap > stopping_distance + 12.0


func stop_progress_for(travel_direction: float) -> float:
	if route == null or not route.is_valid():
		return 0.0
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
	var half_road := intersection_width * 0.5
	if route != null and route.is_valid():
		half_road = route.get_half_width_at(progress)
	var drawing_arms := approach_arms
	if drawing_arms.is_empty():
		for outward in [Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT, Vector2.UP]:
			drawing_arms.append({"outward": outward.rotated(axis_rotation), "half_width": half_road})
	for arm in drawing_arms:
		var outward_world: Vector2 = arm.get("outward", Vector2.RIGHT)
		if outward_world.length_squared() < 0.001:
			continue
		outward_world = outward_world.normalized()
		var arm_half_width := float(arm.get("half_width", half_road))
		var outward := outward_world.rotated(-axis_rotation)
		var approach_heading := -outward_world
		var across := outward.rotated(PI * 0.5)
		var stop_center := outward * (arm_half_width + 18.0)
		if arm.has("stop_center_local"):
			stop_center = Vector2(arm["stop_center_local"])
		if not bool(arm.get("stop_line_is_authored", false)):
			draw_line(
				stop_center - across * arm_half_width,
				stop_center + across * arm_half_width,
				Color(0.92, 0.93, 0.9),
				5.0
			)
		var lamp_position := stop_center + across * (arm_half_width + 22.0)
		if arm.has("lamp_position_local"):
			lamp_position = Vector2(arm["lamp_position_local"])
		draw_rect(
			Rect2(lamp_position - Vector2(11.0, 15.0), Vector2(22.0, 30.0)),
			Color(0.07, 0.08, 0.09)
		)
		var lamp_color := Color(1.0, 0.12, 0.08)
		match state_for_heading(approach_heading):
			SignalState.GREEN:
				lamp_color = Color(0.15, 0.95, 0.28)
			SignalState.YELLOW:
				lamp_color = Color(1.0, 0.75, 0.08)
		draw_circle(lamp_position, 6.0, lamp_color)
