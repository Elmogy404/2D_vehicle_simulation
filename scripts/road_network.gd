class_name RoadNetwork
extends RefCounted


const POSITION_KEY_SCALE := 10.0
const POSITION_JOIN_TOLERANCE_SQUARED := 0.01

## Drivable-area query geometry.
##
## Coordinate system: Godot 2D world coordinates (+X right, +Y down), angles in
## radians. This project uses abstract "world units"; vehicle body dimensions,
## road half-widths, and all query distances are in those same units.
##
## The union of the graph's straight centerline segments, each widened to the
## authored half-width profile, is the authoritative drivable surface. Curves
## are represented by their rendered polyline segments; intersections and road
## mouths are the union of the incident corridors plus a junction pad at nodes
## with three or more incident roads.
const DRIVABLE_GRID_CELL_SIZE := 250.0
const DRIVABLE_QUERY_SAMPLE_SPACING := 8.0

var positions: Array[Vector2] = []
var adjacency: Array = []
var edge_half_widths: Dictionary = {}
var edge_lane_counts: Dictionary = {}
var edge_road_classes: Dictionary = {}
var roundabout_nodes: PackedByteArray = PackedByteArray()

var _drivable_edges: Array[Dictionary] = []
var _drivable_nodes: Array[Dictionary] = []
var _drivable_edge_grid: Dictionary = {}
var _drivable_node_grid: Dictionary = {}


func build(
	paths: Array[PackedVector2Array],
	half_width_profiles: Array[PackedFloat32Array] = [],
	lane_profiles: Array[PackedFloat32Array] = [],
	road_classes: PackedStringArray = PackedStringArray(),
	one_way_paths: PackedByteArray = PackedByteArray()
) -> void:
	positions.clear()
	adjacency.clear()
	edge_half_widths.clear()
	edge_lane_counts.clear()
	edge_road_classes.clear()
	roundabout_nodes.clear()
	var lookup: Dictionary = {}

	for path_index in range(paths.size()):
		var path := paths[path_index]
		var half_widths := PackedFloat32Array()
		if path_index < half_width_profiles.size():
			half_widths = half_width_profiles[path_index]
		var lane_profile := PackedFloat32Array()
		if path_index < lane_profiles.size():
			lane_profile = lane_profiles[path_index]
		var road_class := "local"
		if path_index < road_classes.size():
			road_class = road_classes[path_index]
		var previous := -1
		var previous_half_width := 80.0
		var previous_lane_count := 1.0
		for point_index in range(path.size()):
			var point := path[point_index]
			var half_width := 80.0
			if point_index < half_widths.size():
				half_width = half_widths[point_index]
			var lane_count := 1.0
			if point_index < lane_profile.size():
				lane_count = lane_profile[point_index]
			var key_x := roundi(point.x * POSITION_KEY_SCALE)
			var key_y := roundi(point.y * POSITION_KEY_SCALE)
			var key := _position_key(key_x, key_y)
			var index := -1
			if lookup.has(key):
				index = int(lookup[key])
			else:
				index = _find_nearby_position_node(point, key_x, key_y, lookup)
				if index >= 0:
					# A coordinate just over a quantization boundary must still join
					# the node made by the adjoining piece's socket.
					lookup[key] = index
				else:
					index = positions.size()
					lookup[key] = index
					positions.append(point)
					adjacency.append([])
					roundabout_nodes.append(1 if road_class == "roundabout" else 0)
			if road_class == "roundabout":
				roundabout_nodes[index] = 1

			if previous >= 0 and previous != index:
				_add_link(
					previous, index, previous_half_width, half_width,
					previous_lane_count, lane_count, road_class,
					path_index < one_way_paths.size() and one_way_paths[path_index] != 0
				)
			previous = index
			previous_half_width = half_width
			previous_lane_count = lane_count

	_rebuild_drivable_index()


func _find_nearby_position_node(
	point: Vector2,
	key_x: int,
	key_y: int,
	lookup: Dictionary
) -> int:
	var best_index := -1
	var best_distance_squared := POSITION_JOIN_TOLERANCE_SQUARED
	for neighbor_x in range(key_x - 1, key_x + 2):
		for neighbor_y in range(key_y - 1, key_y + 2):
			var neighbor_key := _position_key(neighbor_x, neighbor_y)
			if not lookup.has(neighbor_key):
				continue
			var candidate_index := int(lookup[neighbor_key])
			var distance_squared := positions[candidate_index].distance_squared_to(point)
			if distance_squared <= best_distance_squared:
				best_distance_squared = distance_squared
				best_index = candidate_index
	return best_index


func _position_key(key_x: int, key_y: int) -> String:
	return "%d:%d" % [key_x, key_y]


func _add_link(
	a: int,
	b: int,
	half_width_a: float,
	half_width_b: float,
	lane_count_a: float,
	lane_count_b: float,
	road_class: String,
	one_way: bool = false
) -> void:
	if not adjacency[a].has(b):
		adjacency[a].append(b)
	if not one_way and not adjacency[b].has(a):
		adjacency[b].append(a)
	var key := _edge_key(a, b)
	var endpoint_widths := Vector2(half_width_a, half_width_b)
	if a > b:
		endpoint_widths = Vector2(half_width_b, half_width_a)
	if edge_half_widths.has(key):
		var existing: Vector2 = edge_half_widths[key]
		endpoint_widths.x = maxf(existing.x, endpoint_widths.x)
		endpoint_widths.y = maxf(existing.y, endpoint_widths.y)
	edge_half_widths[key] = endpoint_widths
	var endpoint_lanes := Vector2(lane_count_a, lane_count_b)
	if a > b:
		endpoint_lanes = Vector2(lane_count_b, lane_count_a)
	if edge_lane_counts.has(key):
		var existing_lanes: Vector2 = edge_lane_counts[key]
		endpoint_lanes.x = maxf(existing_lanes.x, endpoint_lanes.x)
		endpoint_lanes.y = maxf(existing_lanes.y, endpoint_lanes.y)
	edge_lane_counts[key] = endpoint_lanes
	if not edge_road_classes.has(key):
		edge_road_classes[key] = road_class


func _edge_key(a: int, b: int) -> String:
	return "%d:%d" % [mini(a, b), maxi(a, b)]


func _shortest_path_tree(
	start: int,
	forbidden_road_classes: PackedStringArray = PackedStringArray()
) -> Dictionary:
	var distances: Array[float] = []
	var previous: Array[int] = []
	var visited := PackedByteArray()
	visited.resize(positions.size())
	for i in range(positions.size()):
		distances.append(INF)
		previous.append(-1)
	distances[start] = 0.0

	for _iteration in range(positions.size()):
		var current := -1
		var current_distance := INF
		for i in range(positions.size()):
			if visited[i] == 0 and distances[i] < current_distance:
				current = i
				current_distance = distances[i]
		if current < 0:
			break
		visited[current] = 1
		for neighbor_value in adjacency[current]:
			var neighbor := int(neighbor_value)
			if forbidden_road_classes.has(String(
				edge_road_classes.get(_edge_key(current, neighbor), "")
			)):
				continue
			var candidate := current_distance + positions[current].distance_to(positions[neighbor])
			if candidate < distances[neighbor]:
				distances[neighbor] = candidate
				previous[neighbor] = current
	return {"distances": distances, "previous": previous}


func _reconstruct_node_path(start: int, goal: int, previous: Array[int]) -> Array[int]:
	var reversed: Array[int] = []
	var cursor := goal
	while cursor >= 0:
		reversed.append(cursor)
		if cursor == start:
			break
		cursor = previous[cursor]
	if reversed.is_empty() or reversed[-1] != start:
		return []
	var result: Array[int] = []
	for i in range(reversed.size() - 1, -1, -1):
		result.append(reversed[i])
	return result


func _count_route_turns(node_path: Array[int]) -> int:
	var turns := 0
	var last_direction := Vector2.ZERO
	for i in range(node_path.size() - 1):
		var direction: Vector2 = (
			positions[node_path[i + 1]] - positions[node_path[i]]
		).normalized()
		if last_direction != Vector2.ZERO and absf(last_direction.angle_to(direction)) >= deg_to_rad(32.0):
			turns += 1
		last_direction = direction
	return turns


## Select a seeded shortest path with a requested travel length and turn count.
## If no sampled route satisfies the turn target, the longest-turn route in the
## requested distance band is returned and the caller can record that fallback.
func choose_random_route(
	minimum_distance: float,
	maximum_distance: float,
	minimum_turns: int,
	random: RandomNumberGenerator,
	forbidden_road_classes: PackedStringArray = PackedStringArray(),
	source_attempt_limit: int = 24
) -> Dictionary:
	if positions.size() < 2 or minimum_distance <= 0.0 or maximum_distance < minimum_distance:
		return {}

	var candidates_by_turn: Dictionary = {}
	var source_order: Array[int] = []
	for node_index in range(positions.size()):
		source_order.append(node_index)
	# Use a seeded, without-replacement sample. A wider sample finds long,
	# multi-turn curriculum routes reliably after the procedural layout changes.
	for i in range(source_order.size() - 1, 0, -1):
		var swap_index := random.randi_range(0, i)
		var swapped := source_order[i]
		source_order[i] = source_order[swap_index]
		source_order[swap_index] = swapped
	var source_attempts := mini(clampi(source_attempt_limit, 1, 24), source_order.size())
	for attempt in range(source_attempts):
		var start := source_order[attempt]
		var tree := _shortest_path_tree(start, forbidden_road_classes)
		var distances: Array[float] = tree["distances"]
		var previous: Array[int] = tree["previous"]
		for goal in range(positions.size()):
			var path_distance := distances[goal]
			if goal == start or path_distance < minimum_distance or path_distance > maximum_distance:
				continue
			var node_path := _reconstruct_node_path(start, goal, previous)
			if node_path.size() < 2:
				continue
			if _path_uses_forbidden_road_classes(node_path, forbidden_road_classes):
				continue
			var turns := _count_route_turns(node_path)
			if not candidates_by_turn.has(turns):
				candidates_by_turn[turns] = []
			var bucket: Array = candidates_by_turn[turns]
			# Keep a bounded but varied sample rather than materializing every pair.
			if bucket.size() < 48:
				bucket.append(node_path)
				candidates_by_turn[turns] = bucket

	if candidates_by_turn.is_empty():
		return {}

	var eligible_turn_counts: Array[int] = []
	var fallback_turn_count := -1
	for turn_key in candidates_by_turn:
		var turn_count := int(turn_key)
		fallback_turn_count = maxi(fallback_turn_count, turn_count)
		if turn_count >= minimum_turns:
			eligible_turn_counts.append(turn_count)
	var requirement_met := not eligible_turn_counts.is_empty()
	if not requirement_met:
		var sampled_route := _sample_random_route_with_turns(
			minimum_distance, maximum_distance, minimum_turns,
			random, forbidden_road_classes
		)
		if not sampled_route.is_empty():
			return sampled_route
		eligible_turn_counts.append(fallback_turn_count)
	var selected_turn_count := eligible_turn_counts[random.randi_range(0, eligible_turn_counts.size() - 1)]
	var selected_bucket: Array = candidates_by_turn[selected_turn_count]
	var node_path: Array[int] = selected_bucket[random.randi_range(0, selected_bucket.size() - 1)]
	return _route_data_for_node_path(
		node_path, selected_turn_count, requirement_met
	)


func _sample_random_route_with_turns(
	minimum_distance: float,
	maximum_distance: float,
	minimum_turns: int,
	random: RandomNumberGenerator,
	forbidden_road_classes: PackedStringArray,
	minimum_turn_spacing: float = 0.0,
	terminal_clearance: float = 0.0,
	attempt_limit: int = 1024
) -> Dictionary:
	var matches: Array[Array] = []
	var attempts := mini(maxi(128, positions.size() * 4), attempt_limit)
	for _attempt in range(attempts):
		var start := random.randi_range(0, positions.size() - 1)
		var node_path: Array[int] = [start]
		var current := start
		var previous := -1
		var distance := 0.0
		var turns := 0
		var previous_direction := Vector2.ZERO
		var previous_turn_distance := 0.0
		for _step in range(positions.size() * 2):
			var next_nodes: Array[int] = []
			for neighbor_value in adjacency[current]:
				var neighbor := int(neighbor_value)
				# Never revisit a node: repeated sections make route progress and
				# destination proximity ambiguous for a driving episode.
				if neighbor == previous or node_path.has(neighbor):
					continue
				var road_class := String(edge_road_classes.get(
					_edge_key(current, neighbor), ""
				))
				if forbidden_road_classes.has(road_class):
					continue
				var next_direction := (positions[neighbor] - positions[current]).normalized()
				if previous_direction != Vector2.ZERO:
					var angle := absf(previous_direction.angle_to(next_direction))
					if minimum_turn_spacing > 0.0 and angle >= deg_to_rad(145.0):
						continue
					if angle >= deg_to_rad(32.0) and distance - previous_turn_distance < minimum_turn_spacing:
						continue
				if distance + positions[current].distance_to(positions[neighbor]) \
				> maximum_distance:
					continue
				next_nodes.append(neighbor)
			if next_nodes.is_empty():
				break
			var next_node := next_nodes[random.randi_range(0, next_nodes.size() - 1)]
			var direction := (positions[next_node] - positions[current]).normalized()
			if previous_direction != Vector2.ZERO \
			and absf(previous_direction.angle_to(direction)) >= deg_to_rad(32.0):
				turns += 1
				previous_turn_distance = distance
			distance += positions[current].distance_to(positions[next_node])
			node_path.append(next_node)
			previous = current
			current = next_node
			previous_direction = direction
			if distance >= minimum_distance and turns >= minimum_turns and distance - previous_turn_distance >= terminal_clearance:
				matches.append(node_path)
				break
	if matches.is_empty():
		return {}
	var chosen: Array[int] = matches[random.randi_range(0, matches.size() - 1)]
	return _route_data_for_node_path(chosen, _count_route_turns(chosen), true)


func choose_driving_route(minimum_distance: float, maximum_distance: float, minimum_turns: int, random: RandomNumberGenerator, minimum_radius: float) -> Dictionary:
	return _sample_random_route_with_turns(minimum_distance, maximum_distance, minimum_turns, random, PackedStringArray(["roundabout"]), minimum_radius * 2.0, 180.0, 128)


func choose_random_route_from_node(
	start_node: int,
	previous_node: int,
	minimum_distance: float,
	maximum_distance: float,
	random: RandomNumberGenerator,
	minimum_turns: int = 0,
	forbidden_road_classes: PackedStringArray = PackedStringArray()
) -> Dictionary:
	if start_node < 0 or start_node >= positions.size():
		return {}
	if minimum_distance <= 0.0 or maximum_distance < minimum_distance:
		return {}
	var tree := _shortest_path_tree(start_node, forbidden_road_classes)
	var distances: Array[float] = tree["distances"]
	var previous: Array[int] = tree["previous"]
	var candidates: Array[Array] = []
	for goal in range(positions.size()):
		var distance := distances[goal]
		if goal == start_node or distance < minimum_distance or distance > maximum_distance:
			continue
		var node_path := _reconstruct_node_path(start_node, goal, previous)
		if node_path.size() < 2:
			continue
		if _path_uses_forbidden_road_classes(node_path, forbidden_road_classes):
			continue
		if previous_node >= 0 and node_path[1] == previous_node:
			continue
		if _count_route_turns(node_path) < minimum_turns:
			continue
		candidates.append(node_path)
	if candidates.is_empty() and minimum_turns > 0:
		return choose_random_route_from_node(
			start_node, previous_node, minimum_distance, maximum_distance, random, 0,
			forbidden_road_classes
		)
	if candidates.is_empty() and previous_node >= 0:
		return choose_random_route_from_node(
			start_node, -1, minimum_distance, maximum_distance, random, minimum_turns,
			forbidden_road_classes
		)
	if candidates.is_empty():
		return {}
	var chosen: Array[int] = candidates[random.randi_range(0, candidates.size() - 1)]
	return _route_data_for_node_path(chosen, _count_route_turns(chosen), true)


func _path_uses_forbidden_road_classes(
	node_path: Array[int],
	forbidden_road_classes: PackedStringArray
) -> bool:
	if forbidden_road_classes.is_empty():
		return false
	for edge_index in range(node_path.size() - 1):
		var edge_class := String(edge_road_classes.get(
			_edge_key(node_path[edge_index], node_path[edge_index + 1]), ""
		))
		if forbidden_road_classes.has(edge_class):
			return true
	return false


func _route_data_for_node_path(
	node_path: Array[int],
	turn_count: int,
	turn_requirement_met: bool
) -> Dictionary:
	if node_path.size() < 2:
		return {}
	var result_points := PackedVector2Array()
	var result_half_widths := PackedFloat32Array()
	var result_lane_profile := PackedFloat32Array()
	var route_length := 0.0
	for i in range(node_path.size()):
		var node := node_path[i]
		result_points.append(positions[node])
		var half_width := 80.0
		var lane_count := 1.0
		if i == 0:
			half_width = _edge_value_at_node(
				edge_half_widths, node_path[0], node_path[1], 80.0
			)
			lane_count = _edge_value_at_node(
				edge_lane_counts, node_path[0], node_path[1], 1.0
			)
		elif i == node_path.size() - 1:
			half_width = _edge_value_at_node(
				edge_half_widths, node_path[i - 1], node, 80.0
			)
			lane_count = _edge_value_at_node(
				edge_lane_counts, node_path[i - 1], node, 1.0
			)
		else:
			var incoming_width := _edge_value_at_node(
				edge_half_widths, node_path[i - 1], node, 80.0
			)
			var outgoing_width := _edge_value_at_node(
				edge_half_widths, node, node_path[i + 1], 80.0
			)
			half_width = (incoming_width + outgoing_width) * 0.5
			var incoming_lanes := _edge_value_at_node(
				edge_lane_counts, node_path[i - 1], node, 1.0
			)
			var outgoing_lanes := _edge_value_at_node(
				edge_lane_counts, node, node_path[i + 1], 1.0
			)
			lane_count = minf(incoming_lanes, outgoing_lanes)
		result_half_widths.append(half_width)
		result_lane_profile.append(lane_count)
		if i > 0:
			route_length += positions[node_path[i - 1]].distance_to(positions[node])
	return {
		"points": result_points,
		"half_widths": result_half_widths,
		"lane_profile": result_lane_profile,
		"nodes": node_path.duplicate(),
		"start_node": node_path[0],
		"end_node": node_path[-1],
		"length": route_length,
		"turns": turn_count,
		"turn_requirement_met": turn_requirement_met
	}


func _edge_value_at_node(
	values: Dictionary,
	from_node: int,
	to_node: int,
	default_value: float
) -> float:
	var value: Vector2 = values.get(
		_edge_key(from_node, to_node),
		Vector2(default_value, default_value)
	)
	if from_node < to_node:
		return value.x
	return value.y


func smooth_route_data(route_data: Dictionary, corner_radius: float = 120.0) -> Dictionary:
	var points: PackedVector2Array = route_data.get("points", PackedVector2Array())
	var widths: PackedFloat32Array = route_data.get("half_widths", PackedFloat32Array())
	var lanes: PackedFloat32Array = route_data.get("lane_profile", PackedFloat32Array())
	if points.size() < 3 or widths.size() != points.size() or lanes.size() != points.size():
		return route_data.duplicate(true)
	var smoothed_points: Array[Vector2] = [points[0]]
	var smoothed_widths: Array[float] = [widths[0]]
	var smoothed_lanes: Array[float] = [lanes[0]]
	for point_index in range(1, points.size() - 1):
		var previous := points[point_index - 1]
		var pivot := points[point_index]
		var next := points[point_index + 1]
		var incoming_vector := pivot - previous
		var outgoing_vector := next - pivot
		var incoming_length := incoming_vector.length()
		var outgoing_length := outgoing_vector.length()
		if incoming_length < 1.0 or outgoing_length < 1.0:
			continue
		var incoming := incoming_vector / incoming_length
		var outgoing := outgoing_vector / outgoing_length
		var turn_angle := absf(incoming.angle_to(outgoing))
		if turn_angle < deg_to_rad(24.0) or turn_angle > deg_to_rad(150.0):
			smoothed_points.append(pivot)
			smoothed_widths.append(widths[point_index])
			smoothed_lanes.append(lanes[point_index])
			continue
		var trim := minf(corner_radius, minf(incoming_length, outgoing_length) * 0.34)
		var before := pivot - incoming * trim
		var after := pivot + outgoing * trim
		var before_ratio := (incoming_length - trim) / incoming_length
		var after_ratio := trim / outgoing_length
		var before_width := lerpf(widths[point_index - 1], widths[point_index], before_ratio)
		var after_width := lerpf(widths[point_index], widths[point_index + 1], after_ratio)
		var lane_count := minf(lanes[point_index - 1], minf(lanes[point_index], lanes[point_index + 1]))
		_smoothed_append(smoothed_points, smoothed_widths, smoothed_lanes, before, before_width, lane_count)
		for sample_index in range(1, 5):
			var t := float(sample_index) / 5.0
			var curve_point := before.lerp(pivot, t) * (1.0 - t) + pivot.lerp(after, t) * t
			_smoothed_append(
				smoothed_points, smoothed_widths, smoothed_lanes,
				curve_point, lerpf(before_width, after_width, t), lane_count
			)
		_smoothed_append(smoothed_points, smoothed_widths, smoothed_lanes, after, after_width, lane_count)
	var last := points[-1]
	_smoothed_append(smoothed_points, smoothed_widths, smoothed_lanes, last, widths[-1], lanes[-1])
	var result := route_data.duplicate(true)
	result["points"] = PackedVector2Array(smoothed_points)
	result["half_widths"] = PackedFloat32Array(smoothed_widths)
	result["lane_profile"] = PackedFloat32Array(smoothed_lanes)
	return result


func _smoothed_append(
	points: Array[Vector2],
	widths: Array[float],
	lanes: Array[float],
	point: Vector2,
	half_width: float,
	lane_count: float
) -> void:
	if not points.is_empty() and points[-1].distance_squared_to(point) < 1.0:
		return
	points.append(point)
	widths.append(half_width)
	lanes.append(lane_count)


# ============================================================
# DRIVABLE AREA
# ============================================================

func _rebuild_drivable_index() -> void:
	_drivable_edges.clear()
	_drivable_nodes.clear()
	_drivable_edge_grid.clear()
	_drivable_node_grid.clear()

	for key in edge_half_widths:
		var parts := String(key).split(":")
		if parts.size() != 2:
			continue
		var a := int(parts[0])
		var b := int(parts[1])
		if a < 0 or b < 0 or a >= positions.size() or b >= positions.size() or a == b:
			continue
		var start := positions[a]
		var finish := positions[b]
		if start.distance_squared_to(finish) < 1.0e-6:
			continue
		var endpoint_widths: Vector2 = edge_half_widths[key]
		var start_half_width := endpoint_widths.x if a < b else endpoint_widths.y
		var end_half_width := endpoint_widths.y if a < b else endpoint_widths.x
		var edge := {
			"start": start,
			"end": finish,
			"start_half_width": start_half_width,
			"end_half_width": end_half_width,
		}
		var edge_index := _drivable_edges.size()
		_drivable_edges.append(edge)
		var radius := maxf(start_half_width, end_half_width)
		_insert_drivable_region(
			_drivable_edge_grid,
			Vector2(minf(start.x, finish.x), minf(start.y, finish.y)) - Vector2.ONE * radius,
			Vector2(maxf(start.x, finish.x), maxf(start.y, finish.y)) + Vector2.ONE * radius,
			edge_index
		)

	# A junction node is more than the meeting point of its arms: the rendered
	# asphalt also fills the corner between adjacent arms. A circular pad with
	# the widest incident half-width covers that junction box for vehicle
	# footprints without extending the query beyond the road ends.
	for node_index in range(adjacency.size()):
		if adjacency[node_index].size() < 3:
			continue
		var junction_radius := get_node_half_width(node_index)
		if junction_radius <= 0.0:
			continue
		var node_position := positions[node_index]
		var node_index_in_query := _drivable_nodes.size()
		_drivable_nodes.append({"position": node_position, "radius": junction_radius})
		_insert_drivable_region(
			_drivable_node_grid,
			node_position - Vector2.ONE * junction_radius,
			node_position + Vector2.ONE * junction_radius,
			node_index_in_query
		)


func _insert_drivable_region(
	grid: Dictionary,
	minimum: Vector2,
	maximum: Vector2,
	index: int
) -> void:
	var min_x := floori(minimum.x / DRIVABLE_GRID_CELL_SIZE)
	var max_x := floori(maximum.x / DRIVABLE_GRID_CELL_SIZE)
	var min_y := floori(minimum.y / DRIVABLE_GRID_CELL_SIZE)
	var max_y := floori(maximum.y / DRIVABLE_GRID_CELL_SIZE)
	for cell_x in range(min_x, max_x + 1):
		for cell_y in range(min_y, max_y + 1):
			var key := _drivable_cell_key(cell_x, cell_y)
			if not grid.has(key):
				grid[key] = []
			var bucket: Array = grid[key]
			bucket.append(index)


func _drivable_cell_key(cell_x: int, cell_y: int) -> String:
	return "%d:%d" % [cell_x, cell_y]


## Signed distance from the nearest drivable boundary. Positive values are
## inside the road surface, negative values are outside. Distances are in world
## units. Returns -INF when no road corridor is nearby.
func get_drivable_clearance(point: Vector2) -> float:
	var key := _drivable_cell_key(
		floori(point.x / DRIVABLE_GRID_CELL_SIZE),
		floori(point.y / DRIVABLE_GRID_CELL_SIZE)
	)
	var edge_indices: Array = _drivable_edge_grid.get(key, [])
	var node_indices: Array = _drivable_node_grid.get(key, [])
	return _clearance_from_candidate_indices(point, edge_indices, node_indices)


func is_point_drivable(point: Vector2, margin: float = 0.0) -> bool:
	return get_drivable_clearance(point) >= -margin


## Evaluate the oriented vehicle rectangle against the road-corridor union.
## `size` is (width, length) in world units. `margin` permits that many units
## of the footprint outside the road, which is useful for boundary float error
## and authored curb insets. The rectangle is sampled on its perimeter plus a
## coarse interior lattice; `sample_spacing_units` bounds the sampling error.
func query_footprint_drivable(
	center: Vector2,
	rotation: float,
	size: Vector2,
	margin: float = 0.0,
	sample_spacing_units: float = DRIVABLE_QUERY_SAMPLE_SPACING
) -> Dictionary:
	if size.x <= 0.0 or size.y <= 0.0:
		return {
			"drivable": false,
			"center_drivable": false,
			"inside_sample_count": 0,
			"outside_sample_count": 0,
			"sample_count": 0,
			"inside_fraction": 0.0,
			"min_clearance_units": null,
			"max_outside_depth_units": null,
			"center_clearance_units": null,
			"footprint_size": [size.x, size.y],
			"margin_units": margin,
			"sample_spacing_units": sample_spacing_units,
		}

	var right := Vector2.RIGHT.rotated(rotation)
	var forward := Vector2.UP.rotated(rotation)
	var half_width := size.x * 0.5
	var half_length := size.y * 0.5
	var corners := PackedVector2Array([
		center - right * half_width - forward * half_length,
		center + right * half_width - forward * half_length,
		center + right * half_width + forward * half_length,
		center - right * half_width + forward * half_length,
	])
	var minimum := corners[0]
	var maximum := corners[0]
	for corner in corners:
		minimum.x = minf(minimum.x, corner.x)
		minimum.y = minf(minimum.y, corner.y)
		maximum.x = maxf(maximum.x, corner.x)
		maximum.y = maxf(maximum.y, corner.y)

	var edge_candidates: Dictionary = {}
	var node_candidates: Dictionary = {}
	_collect_region_candidates(minimum, maximum, edge_candidates, node_candidates)
	var edge_indices: Array = edge_candidates.keys()
	var node_indices: Array = node_candidates.keys()

	var spacing := maxf(sample_spacing_units, 1.0)
	var samples := _footprint_samples(center, right, forward, half_width, half_length, spacing)
	var inside_count := 0
	var min_clearance := INF
	for sample in samples:
		var clearance := _clearance_from_candidate_indices(sample, edge_indices, node_indices)
		min_clearance = minf(min_clearance, clearance)
		if clearance >= -margin:
			inside_count += 1

	var center_clearance := _clearance_from_candidate_indices(center, edge_indices, node_indices)
	var sample_count := samples.size()
	return {
		"drivable": inside_count == sample_count,
		"center_drivable": center_clearance >= -margin,
		"inside_sample_count": inside_count,
		"outside_sample_count": sample_count - inside_count,
		"sample_count": sample_count,
		"inside_fraction": float(inside_count) / float(maxi(sample_count, 1)),
		"min_clearance_units": min_clearance if is_finite(min_clearance) else null,
		"max_outside_depth_units": (
			maxf(0.0, -min_clearance) if is_finite(min_clearance) else null
		),
		"center_clearance_units": center_clearance if is_finite(center_clearance) else null,
		"footprint_size": [size.x, size.y],
		"margin_units": margin,
		"sample_spacing_units": spacing,
	}


func is_footprint_drivable(
	center: Vector2,
	rotation: float,
	size: Vector2,
	margin: float = 0.0,
	sample_spacing_units: float = DRIVABLE_QUERY_SAMPLE_SPACING
) -> bool:
	return bool(query_footprint_drivable(
		center, rotation, size, margin, sample_spacing_units
	).get("drivable", false))


func _footprint_samples(
	center: Vector2,
	right: Vector2,
	forward: Vector2,
	half_width: float,
	half_length: float,
	spacing: float
) -> PackedVector2Array:
	var result := PackedVector2Array()
	var x_steps := maxi(1, ceili((half_width * 2.0) / spacing))
	var y_steps := maxi(1, ceili((half_length * 2.0) / spacing))
	for x_index in range(x_steps + 1):
		var x := -half_width + (half_width * 2.0) * float(x_index) / float(x_steps)
		result.append(center + right * x - forward * half_length)
		result.append(center + right * x + forward * half_length)
	for y_index in range(1, y_steps):
		var y := -half_length + (half_length * 2.0) * float(y_index) / float(y_steps)
		result.append(center - right * half_width + forward * y)
		result.append(center + right * half_width + forward * y)
	# A coarse interior lattice catches a footprint straddling a non-drivable
	# gap while its perimeter happens to lie on two separate road corridors.
	for y_index in range(1, y_steps, 2):
		var y := -half_length + (half_length * 2.0) * float(y_index) / float(y_steps)
		for x_index in range(1, x_steps, 2):
			var x := -half_width + (half_width * 2.0) * float(x_index) / float(x_steps)
			result.append(center + right * x + forward * y)
	result.append(center)
	return result


func _collect_region_candidates(
	minimum: Vector2,
	maximum: Vector2,
	edge_candidates: Dictionary,
	node_candidates: Dictionary
) -> void:
	var min_x := floori(minimum.x / DRIVABLE_GRID_CELL_SIZE)
	var max_x := floori(maximum.x / DRIVABLE_GRID_CELL_SIZE)
	var min_y := floori(minimum.y / DRIVABLE_GRID_CELL_SIZE)
	var max_y := floori(maximum.y / DRIVABLE_GRID_CELL_SIZE)
	for cell_x in range(min_x, max_x + 1):
		for cell_y in range(min_y, max_y + 1):
			var key := _drivable_cell_key(cell_x, cell_y)
			for index in _drivable_edge_grid.get(key, []):
				edge_candidates[int(index)] = true
			for index in _drivable_node_grid.get(key, []):
				node_candidates[int(index)] = true


func _clearance_from_candidate_indices(
	point: Vector2,
	edge_indices: Array,
	node_indices: Array
) -> float:
	var best := -INF
	for index in edge_indices:
		best = maxf(best, _edge_clearance(_drivable_edges[int(index)], point))
	for index in node_indices:
		var node: Dictionary = _drivable_nodes[int(index)]
		var node_distance: float = point.distance_to(node["position"])
		best = maxf(best, float(node["radius"]) - node_distance)
	return best


func _edge_clearance(edge: Dictionary, point: Vector2) -> float:
	var start: Vector2 = edge["start"]
	var finish: Vector2 = edge["end"]
	var segment := finish - start
	var length_squared := segment.length_squared()
	var weight := 0.0
	if length_squared > 0.0:
		weight = clampf((point - start).dot(segment) / length_squared, 0.0, 1.0)
	var closest := start + segment * weight
	var half_width := lerpf(
		float(edge["start_half_width"]),
		float(edge["end_half_width"]),
		weight
	)
	return half_width - point.distance_to(closest)


func nearest_node(world_position: Vector2) -> int:
	var best := -1
	var best_distance := INF
	for i in range(positions.size()):
		var distance := positions[i].distance_squared_to(world_position)
		if distance < best_distance:
			best_distance = distance
			best = i
	return best


func get_intersection_nodes() -> Array[int]:
	var result: Array[int] = []
	for node_index in range(adjacency.size()):
		if adjacency[node_index].size() >= 3 and roundabout_nodes[node_index] == 0:
			result.append(node_index)
	return result


func get_node_degree(node_index: int) -> int:
	if node_index < 0 or node_index >= adjacency.size():
		return 0
	return adjacency[node_index].size()


func get_node_half_width(node_index: int) -> float:
	if node_index < 0 or node_index >= adjacency.size():
		return 80.0
	var widest := 0.0
	for neighbor_value in adjacency[node_index]:
		var neighbor := int(neighbor_value)
		widest = maxf(widest, _edge_value_at_node(
			edge_half_widths, node_index, neighbor, 80.0
		))
	if is_zero_approx(widest):
		return 80.0
	return widest


func get_node_position(node_index: int) -> Vector2:
	if node_index < 0 or node_index >= positions.size():
		return Vector2.ZERO
	return positions[node_index]


func total_unique_length() -> float:
	var total := 0.0
	for key in edge_half_widths:
		var endpoints := String(key).split(":")
		if endpoints.size() != 2:
			continue
		var a := int(endpoints[0])
		var b := int(endpoints[1])
		if a >= 0 and b >= 0 and a < positions.size() and b < positions.size():
			total += positions[a].distance_to(positions[b])
	return total


func get_node_axis(node_index: int) -> Vector2:
	if node_index < 0 or node_index >= adjacency.size():
		return Vector2.RIGHT
	var neighbors: Array = adjacency[node_index]
	if neighbors.size() < 2:
		return Vector2.RIGHT
	var best_dot := 1.0
	var axis := Vector2.RIGHT
	for i in range(neighbors.size()):
		var first_direction: Vector2 = (
			positions[int(neighbors[i])] - positions[node_index]
		).normalized()
		for j in range(i + 1, neighbors.size()):
			var second_direction: Vector2 = (
				positions[int(neighbors[j])] - positions[node_index]
			).normalized()
			var alignment := first_direction.dot(second_direction)
			if alignment < best_dot:
				best_dot = alignment
				axis = (first_direction - second_direction).normalized()
	return axis if axis.length_squared() > 0.001 else Vector2.RIGHT


func get_node_arms(node_index: int) -> Array[Dictionary]:
	var arms: Array[Dictionary] = []
	if node_index < 0 or node_index >= positions.size():
		return arms
	for neighbor_value in adjacency[node_index]:
		var neighbor := int(neighbor_value)
		var delta := positions[neighbor] - positions[node_index]
		if delta.length_squared() < 0.001:
			continue
		arms.append({
			"outward": delta.normalized(),
			"half_width": _edge_value_at_node(
				edge_half_widths, node_index, neighbor, 80.0
			),
			"neighbor": neighbor
		})
	return arms


func get_node_branch_direction(node_index: int) -> Vector2:
	if get_node_degree(node_index) != 3:
		return Vector2.ZERO
	var axis := get_node_axis(node_index)
	var branch := Vector2.ZERO
	var least_aligned := INF
	for arm in get_node_arms(node_index):
		var outward: Vector2 = arm["outward"]
		var alignment := absf(outward.dot(axis))
		if alignment < least_aligned:
			least_aligned = alignment
			branch = outward
	return branch


## Dijkstra path over the connected centerlines rendered by the map.
func find_path(from_position: Vector2, to_position: Vector2) -> PackedVector2Array:
	var start := nearest_node(from_position)
	var goal := nearest_node(to_position)
	var result := PackedVector2Array()
	if start < 0 or goal < 0:
		return result

	var distance: Array[float] = []
	var previous: Array[int] = []
	var visited := PackedByteArray()
	visited.resize(positions.size())
	for i in range(positions.size()):
		distance.append(INF)
		previous.append(-1)
	distance[start] = 0.0

	for iteration in range(positions.size()):
		var current := -1
		var current_distance := INF
		for i in range(positions.size()):
			if visited[i] == 0 and distance[i] < current_distance:
				current = i
				current_distance = distance[i]
		if current < 0 or current == goal:
			break
		visited[current] = 1
		for neighbor_value in adjacency[current]:
			var neighbor := int(neighbor_value)
			var candidate := current_distance + positions[current].distance_to(positions[neighbor])
			if candidate < distance[neighbor]:
				distance[neighbor] = candidate
				previous[neighbor] = current

	if start != goal and previous[goal] < 0:
		return result
	var reversed: Array[Vector2] = []
	var cursor := goal
	while cursor >= 0:
		reversed.append(positions[cursor])
		if cursor == start:
			break
		cursor = previous[cursor]
	for i in range(reversed.size() - 1, -1, -1):
		result.append(reversed[i])
	return result


func graph_is_connected() -> bool:
	if positions.is_empty():
		return false
	var visited: Dictionary = {0: true}
	var queue: Array[int] = [0]
	while not queue.is_empty():
		var current: int = queue.pop_front()
		for neighbor_value in adjacency[current]:
			var neighbor := int(neighbor_value)
			if not visited.has(neighbor):
				visited[neighbor] = true
				queue.append(neighbor)
	return visited.size() == positions.size()


func edge_count() -> int:
	return edge_half_widths.size()


func has_alternate_routes() -> bool:
	# A connected undirected graph contains a cycle when E >= V. Cycles are
	# what make this a street network with alternate paths rather than a tree of
	# decorative dead ends.
	return graph_is_connected() and edge_count() >= positions.size()
