extends Control


@export var exploration_radius: float = 360.0
@export var reveal_entire_map: bool = true

var road: Node
var ego: Node2D
var paths: Array[PackedVector2Array] = []
var discovered: Array[PackedByteArray] = []
var obstacles: Array[Dictionary] = []
var map_bounds := Rect2(Vector2.ZERO, Vector2.ONE)
var goal_position := Vector2.ZERO
var show_goal: bool = false
var planned_route := PackedVector2Array()
var show_planned_route: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	set_process(true)


func set_sources(new_road: Node, new_ego: Node2D) -> void:
	road = new_road
	ego = new_ego
	reset_map()


func reset_map() -> void:
	paths.clear()
	discovered.clear()
	obstacles.clear()
	if road == null:
		return

	paths = road.get_map_paths()
	obstacles = road.get_obstacle_regions()
	map_bounds = road.get_map_bounds()
	for path in paths:
		var flags := PackedByteArray()
		flags.resize(path.size())
		if reveal_entire_map:
			flags.fill(1)
		discovered.append(flags)
	if not reveal_entire_map:
		_reveal_near_ego()
	queue_redraw()


func set_goal_position(position: Vector2, enabled: bool) -> void:
	goal_position = position
	show_goal = enabled
	queue_redraw()


func set_planned_route(points: Array, enabled: bool) -> void:
	planned_route.clear()
	for point in points:
		planned_route.append(point)
	show_planned_route = enabled and planned_route.size() >= 2
	queue_redraw()


func _process(_delta: float) -> void:
	if ego == null or not is_instance_valid(ego):
		return
	if not reveal_entire_map and _reveal_near_ego():
		queue_redraw()
	else:
		# The player marker and nearby traffic still move on revealed roads.
		queue_redraw()


func _reveal_near_ego() -> bool:
	if ego == null:
		return false
	var changed := false
	var radius_squared := exploration_radius * exploration_radius
	for path_index in range(paths.size()):
		for point_index in range(paths[path_index].size()):
			if discovered[path_index][point_index] != 0:
				continue
			if ego.global_position.distance_squared_to(paths[path_index][point_index]) <= radius_squared:
				discovered[path_index][point_index] = 1
				changed = true
	return changed


func _draw() -> void:
	var panel := Rect2(Vector2.ZERO, size)
	draw_style_box(_panel_style(), panel)
	draw_string(
		ThemeDB.fallback_font,
		Vector2(12.0, 20.0),
		"AREA MAP  •  M TO EXPAND",
		HORIZONTAL_ALIGNMENT_LEFT,
		-1.0,
		12,
		Color(0.76, 0.84, 0.88)
	)
	for obstacle in obstacles:
		var center: Vector2 = obstacle["center"]
		var obstacle_size: Vector2 = obstacle["size"]
		var rotation: float = obstacle["rotation"]
		var tangent := Vector2.from_angle(rotation)
		var normal := Vector2(-tangent.y, tangent.x)
		var half_x := tangent * obstacle_size.x * 0.5
		var half_y := normal * obstacle_size.y * 0.5
		draw_colored_polygon(PackedVector2Array([
			_world_to_map(center - half_x - half_y),
			_world_to_map(center + half_x - half_y),
			_world_to_map(center + half_x + half_y),
			_world_to_map(center - half_x + half_y)
		]), Color(0.13, 0.31, 0.16))

	for path_index in range(paths.size()):
		var path := paths[path_index]
		if path.size() < 2:
			continue
		for i in range(path.size() - 1):
			if discovered[path_index][i] == 0 and discovered[path_index][i + 1] == 0:
				continue
			draw_line(
				_world_to_map(path[i]),
				_world_to_map(path[i + 1]),
				Color(0.62, 0.66, 0.68),
				4.0 if path_index == 0 else 3.0,
				true
			)

	if show_planned_route:
		var route_on_map := PackedVector2Array()
		for point in planned_route:
			route_on_map.append(_world_to_map(point))
		draw_polyline(route_on_map, Color(0.18, 0.9, 1.0, 0.95), 2.5, true)

	if show_goal:
		var goal := _world_to_map(goal_position)
		draw_circle(goal, 5.0, Color(0.18, 0.95, 0.52))
		draw_arc(goal, 8.0, 0.0, TAU, 24, Color(0.55, 1.0, 0.72), 2.0)

	if ego != null and is_instance_valid(ego):
		var player := _world_to_map(ego.global_position)
		var heading := Vector2.UP.rotated(ego.global_rotation)
		var side := heading.rotated(PI * 0.5)
		draw_colored_polygon(PackedVector2Array([
			player + heading * 7.0,
			player - heading * 5.0 + side * 4.5,
			player - heading * 5.0 - side * 4.5
		]), Color(0.98, 0.72, 0.18))

	for car in get_tree().get_nodes_in_group("traffic"):
		if is_instance_valid(car) and ego != null \
		and car.global_position.distance_to(ego.global_position) <= exploration_radius:
			draw_circle(_world_to_map(car.global_position), 2.5, Color(0.30, 0.72, 0.95))


func _world_to_map(world: Vector2) -> Vector2:
	var inner := Rect2(Vector2(10.0, 28.0), size - Vector2(20.0, 38.0))
	var safe_size := Vector2(maxf(map_bounds.size.x, 1.0), maxf(map_bounds.size.y, 1.0))
	var scale_value := minf(inner.size.x / safe_size.x, inner.size.y / safe_size.y)
	var used := safe_size * scale_value
	var origin := inner.position + (inner.size - used) * 0.5
	return origin + (world - map_bounds.position) * scale_value


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.055, 0.07, 0.92)
	style.border_color = Color(0.30, 0.42, 0.48, 0.95)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	return style
