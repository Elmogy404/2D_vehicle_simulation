class_name RoadNetwork
extends RefCounted


var positions: Array[Vector2] = []
var adjacency: Array = []


func build(paths: Array[PackedVector2Array]) -> void:
	positions.clear()
	adjacency.clear()
	var lookup: Dictionary = {}

	for path in paths:
		var previous := -1
		for point in path:
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
				_add_link(previous, index)
			previous = index


func _add_link(a: int, b: int) -> void:
	if not adjacency[a].has(b):
		adjacency[a].append(b)
	if not adjacency[b].has(a):
		adjacency[b].append(a)


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
