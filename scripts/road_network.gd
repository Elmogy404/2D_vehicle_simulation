class_name RoadNetwork
extends RefCounted


var positions: Array[Vector2] = []
var adjacency: Array = []
var edge_half_widths: Dictionary = {}


func build(
	paths: Array[PackedVector2Array],
	half_width_profiles: Array[PackedFloat32Array] = []
) -> void:
	positions.clear()
	adjacency.clear()
	edge_half_widths.clear()
	var lookup: Dictionary = {}

	for path_index in range(paths.size()):
		var path := paths[path_index]
		var half_widths := PackedFloat32Array()
		if path_index < half_width_profiles.size():
			half_widths = half_width_profiles[path_index]
		var previous := -1
		var previous_half_width := 80.0
		for point_index in range(path.size()):
			var point := path[point_index]
			var half_width := 80.0
			if point_index < half_widths.size():
				half_width = half_widths[point_index]
			var key := "%d:%d" % [roundi(point.x * 10.0), roundi(point.y * 10.0)]
			var index: int
			if lookup.has(key):
				index = int(lookup[key])
			else:
				index = positions.size()
				lookup[key] = index
				positions.append(point)
				adjacency.append([])

			if previous >= 0 and previous != index:
				_add_link(previous, index, previous_half_width, half_width)
			previous = index
			previous_half_width = half_width


func _add_link(a: int, b: int, half_width_a: float, half_width_b: float) -> void:
	if not adjacency[a].has(b):
		adjacency[a].append(b)
	if not adjacency[b].has(a):
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


func _edge_key(a: int, b: int) -> String:
	return "%d:%d" % [mini(a, b), maxi(a, b)]


func _shortest_path_tree(start: int) -> Dictionary:
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
	random: RandomNumberGenerator
) -> Dictionary:
	if positions.size() < 2 or minimum_distance <= 0.0 or maximum_distance < minimum_distance:
		return {}

	var candidates_by_turn: Dictionary = {}
	var source_order: Array[int] = []
	for node_index in range(positions.size()):
		source_order.append(node_index)
	# Use a seeded, without-replacement sample. Three arbitrary starts were not
	# sufficient on long maps: they could all land far from a short curriculum
	# route even though the connected graph contained many valid pairs.
	for i in range(source_order.size() - 1, 0, -1):
		var swap_index := random.randi_range(0, i)
		var swapped := source_order[i]
		source_order[i] = source_order[swap_index]
		source_order[swap_index] = swapped
	var source_attempts := mini(12, source_order.size())
	for attempt in range(source_attempts):
		var start := source_order[attempt]
		var tree := _shortest_path_tree(start)
		var distances: Array[float] = tree["distances"]
		var previous: Array[int] = tree["previous"]
		for goal in range(positions.size()):
			var path_distance := distances[goal]
			if goal == start or path_distance < minimum_distance or path_distance > maximum_distance:
				continue
			var node_path := _reconstruct_node_path(start, goal, previous)
			if node_path.size() < 2:
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
		eligible_turn_counts.append(fallback_turn_count)
	var selected_turn_count := eligible_turn_counts[random.randi_range(0, eligible_turn_counts.size() - 1)]
	var selected_bucket: Array = candidates_by_turn[selected_turn_count]
	var node_path: Array[int] = selected_bucket[random.randi_range(0, selected_bucket.size() - 1)]
	var result_points := PackedVector2Array()
	var result_half_widths := PackedFloat32Array()
	var route_length := 0.0
	for i in range(node_path.size()):
		var node := node_path[i]
		result_points.append(positions[node])
		var half_width := 80.0
		if i == 0:
			var first_widths: Vector2 = edge_half_widths.get(_edge_key(node_path[0], node_path[1]), Vector2(80.0, 80.0))
			half_width = first_widths.x if node_path[0] < node_path[1] else first_widths.y
		elif i == node_path.size() - 1:
			var last_widths: Vector2 = edge_half_widths.get(_edge_key(node_path[i - 1], node), Vector2(80.0, 80.0))
			half_width = last_widths.y if node_path[i - 1] < node else last_widths.x
		else:
			var incoming: Vector2 = edge_half_widths.get(_edge_key(node_path[i - 1], node), Vector2(80.0, 80.0))
			var outgoing: Vector2 = edge_half_widths.get(_edge_key(node, node_path[i + 1]), Vector2(80.0, 80.0))
			var incoming_width := incoming.y if node_path[i - 1] < node else incoming.x
			var outgoing_width := outgoing.x if node < node_path[i + 1] else outgoing.y
			half_width = (incoming_width + outgoing_width) * 0.5
		result_half_widths.append(half_width)
		if i > 0:
			route_length += positions[node_path[i - 1]].distance_to(positions[node])
	return {
		"points": result_points,
		"half_widths": result_half_widths,
		"length": route_length,
		"turns": selected_turn_count,
		"turn_requirement_met": requirement_met
	}


func nearest_node(world_position: Vector2) -> int:
	var best := -1
	var best_distance := INF
	for i in range(positions.size()):
		var distance := positions[i].distance_squared_to(world_position)
		if distance < best_distance:
			best_distance = distance
			best = i
	return best


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
	var directed_total := 0
	for neighbors in adjacency:
		directed_total += neighbors.size()
	return int(directed_total / 2)


func has_alternate_routes() -> bool:
	# A connected undirected graph contains a cycle when E >= V. Cycles are
	# what make this a street network with alternate paths rather than a tree of
	# decorative dead ends.
	return graph_is_connected() and edge_count() >= positions.size()
