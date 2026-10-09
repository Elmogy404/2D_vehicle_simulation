extends Control


@export var exploration_radius: float = 360.0

var road: Node
var ego: Node2D
var paths: Array[PackedVector2Array] = []
var discovered: Array[PackedByteArray] = []
var map_bounds := Rect2(Vector2.ZERO, Vector2.ONE)


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
	if road == null:
		return

	paths = road.get_map_paths()
	map_bounds = road.get_map_bounds()
	for path in paths:
		var flags := PackedByteArray()
		flags.resize(path.size())
		discovered.append(flags)
	_reveal_near_ego()
	queue_redraw()


func _process(_delta: float) -> void:
	if ego == null or not is_instance_valid(ego):
		return
	if _reveal_near_ego():
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
