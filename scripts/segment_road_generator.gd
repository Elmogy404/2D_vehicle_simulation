extends Node2D
## Seeded, graph-first urban road builder using the authored road-piece scenes.
## The street plan is chosen before geometry is placed, so the output forms
## connected blocks and road hierarchies instead of unrelated random branches.

signal generation_completed(seed: int, piece_count: int)

const LANE_WIDTH := 90.0
const SIDEWALK_WIDTH := 28.0
const MINIMUM_OVERLAP_AREA := 64.0
const MIN_BLOCK_SPACING := 3900.0
const MAX_BLOCK_SPACING := 5300.0
const LOCAL_STREET_REMOVAL_CHANCE := 0.36
const ROUNDABOUT_CHANCE := 0.16
const MIN_SPLIT_SEGMENT_LENGTH := 600.0
const MIN_PREVIEW_ZOOM := 0.008
const MAX_PREVIEW_ZOOM := 1.0
const PREVIEW_ZOOM_RATE := 1.6
const PREVIEW_PAN_SCREEN_SPEED := 420.0
const SIMULATION_SAMPLE_SPACING := 1500.0
const ROAD_BOUNDARY_THICKNESS := 12.0

@export_range(100, 500, 1) var minimum_piece_count := 200
@export_range(100, 500, 1) var maximum_piece_count := 200
@export var seed_value: int = 20261013
@export var randomize_seed_on_ready := true
@export var generate_on_ready := true

var active_seed: int = 0
var target_piece_count: int = 0
var generation_error := ""
var placed_pieces: Array[Dictionary] = []
var connections: Array[Dictionary] = []
var generation_bounds := Rect2(Vector2.ZERO, Vector2.ZERO)
var grid_size := 0
var removed_local_street_count := 0
var route: RoutePath = RoutePath.new()
var road_network: RoadNetwork = RoadNetwork.new()
var road_width: float = LANE_WIDTH * 4.0
var maximum_road_width: float = LANE_WIDTH * 4.0
var cross_street_width: float = LANE_WIDTH * 2.0
var lane_width: float = LANE_WIDTH
var segment_length: float = SIMULATION_SAMPLE_SPACING
var center_points: Array[Vector2] = []
var intersection_indices := PackedInt32Array()
var intersection_types := PackedStringArray()
var branch_sides := PackedInt32Array()
var obstacle_regions: Array[Dictionary] = []
var _map_paths: Array[PackedVector2Array] = []
var _map_half_width_profiles: Array[PackedFloat32Array] = []
var _map_lane_profiles: Array[PackedFloat32Array] = []
var _map_road_classes := PackedStringArray()
var _map_one_way_paths := PackedByteArray()

var _rng := RandomNumberGenerator.new()
var _generated_root: Node2D


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color("#444648"))
	if not generate_on_ready:
		return
	if randomize_seed_on_ready:
		var seed_rng := RandomNumberGenerator.new()
		seed_rng.randomize()
		generate_with_seed(seed_rng.randi())
	else:
		generate_with_seed(seed_value)


func _process(delta: float) -> void:
	var camera := get_node_or_null("Camera2D") as Camera2D
	if camera == null or not camera.is_current():
		return

	var zoom_direction := 0.0
	if Input.is_key_pressed(KEY_UP):
		zoom_direction += 1.0
	if Input.is_key_pressed(KEY_DOWN):
		zoom_direction -= 1.0
	if not is_zero_approx(zoom_direction):
		var next_zoom := clampf(
			camera.zoom.x * exp(PREVIEW_ZOOM_RATE * zoom_direction * delta),
			MIN_PREVIEW_ZOOM,
			MAX_PREVIEW_ZOOM
		)
		camera.zoom = Vector2.ONE * next_zoom

	var movement := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_A):
		movement.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		movement.x += 1.0
	if Input.is_physical_key_pressed(KEY_W):
		movement.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S):
		movement.y += 1.0
	if movement.length_squared() > 0.0:
		camera.position += movement.normalized() * (PREVIEW_PAN_SCREEN_SPEED / camera.zoom.x) * delta


func generate_with_seed(new_seed: int) -> void:
	_clear_generation()
	generation_error = ""
	active_seed = new_seed
	seed_value = new_seed
	_rng.seed = new_seed
	target_piece_count = _rng.randi_range(
		mini(minimum_piece_count, maximum_piece_count),
		maxi(minimum_piece_count, maximum_piece_count)
	)
	_generated_root = Node2D.new()
	_generated_root.name = "GeneratedRoadPieces"
	add_child(_generated_root)

	grid_size = _choose_grid_size(target_piece_count)
	var grid := _create_city_grid(grid_size)
	var node_plans := _plan_intersections(grid)
	var node_refs := _place_intersections(grid, node_plans)
	if node_refs.is_empty():
		generation_error = "The planned street graph did not contain a placeable starting intersection."
		push_error(generation_error)
		return

	var corridors := _trace_street_corridors(grid, node_refs)
	var segment_tasks := _make_corridor_segment_tasks(corridors, node_refs)
	if not generation_error.is_empty():
		push_error(generation_error)
		return

	var required_segment_pieces := target_piece_count - placed_pieces.size()
	if required_segment_pieces < segment_tasks.size():
		generation_error = "The block plan needs %d connector pieces but the target budget is %d." % [
			segment_tasks.size(), required_segment_pieces
		]
		push_error(generation_error)
		return
	var extra_segment_pieces := required_segment_pieces - segment_tasks.size()
	_distribute_segment_splits(segment_tasks, extra_segment_pieces)
	if not generation_error.is_empty():
		push_error(generation_error)
		return

	for task in segment_tasks:
		if not _place_straight_road_chain(task, int(task["extra_splits"])):
			if generation_error.is_empty():
				generation_error = "A planned straight road segment could not be placed cleanly."
			push_error(generation_error)
			return

	_build_road_edge_collisions()
	_recalculate_generation_bounds()
	_build_simulation_data(grid)
	if not route.is_valid() or road_network.positions.size() < 2:
		generation_error = "The segmented map could not produce a drivable route graph."
		push_error(generation_error)
		return
	var unused_socket_count := _count_unused_sockets()
	if unused_socket_count > 0:
		generation_error = "The city plan left %d road socket(s) disconnected." % unused_socket_count
		push_warning(generation_error)
	if _generated_piece_count() < minimum_piece_count \
	or _generated_piece_count() > maximum_piece_count:
		generation_error = "Generated %d pieces; expected %d–%d." % [
			_generated_piece_count(), minimum_piece_count, maximum_piece_count
		]
		push_warning(generation_error)

	print(
		"CITY ROAD GENERATION: seed=%d, grid=%dx%d, pieces=%d, junctions=%d, dead_ends=%d, local_streets_removed=%d, straight_segments=%d" % [
			active_seed,
			grid_size,
			grid_size,
			_generated_piece_count(),
			_placed_junction_count(),
			_piece_count("u_turn_dead_end_bulb"),
			removed_local_street_count,
			_corridor_segment_count()
		]
	)
	generation_completed.emit(active_seed, _generated_piece_count())
	call_deferred("_fit_preview_camera")


func get_piece_count() -> int:
	return _generated_piece_count()


func get_generation_summary() -> Dictionary:
	var counts: Dictionary = {}
	for piece_data in placed_pieces:
		var piece_id := String(piece_data["piece_id"])
		counts[piece_id] = int(counts.get(piece_id, 0)) + 1
	return {
		"seed": active_seed,
		"target_piece_count": target_piece_count,
		"piece_count": _generated_piece_count(),
		"connection_count": connections.size(),
		"open_socket_count": _count_unused_sockets(),
		"grid_size": grid_size,
		"removed_local_street_count": removed_local_street_count,
		"piece_counts": counts,
		"road_length": road_network.total_unique_length(),
		"intersection_count": road_network.get_intersection_nodes().size(),
		"bounds": generation_bounds,
		"error": generation_error
	}


func get_piece_specs() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for piece_data in placed_pieces:
		result.append({
			"piece_id": piece_data["piece_id"],
			"position": piece_data["position"],
			"rotation": piece_data["rotation"],
			"ports": piece_data["world_ports"]
		})
	return result


## Exposes the crossings and signal anchors drawn by each road asset in world
## space. Gameplay actors use this instead of inventing their own locations.
func get_authored_road_features() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for piece_index in range(placed_pieces.size()):
		var piece_data: Dictionary = placed_pieces[piece_index]
		var piece := piece_data.get("node") as Node2D
		if piece == null or not piece.has_method("get_crosswalks"):
			continue
		var local_ports: Array[Dictionary] = piece.call("get_ports")
		var local_crosswalks: Array[Dictionary] = piece.call("get_crosswalks")
		var local_anchors: Array[Dictionary] = piece.call("get_signal_anchors")
		if local_crosswalks.is_empty() and local_anchors.is_empty():
			continue

		var world_center := piece.to_global(Vector2.ZERO)
		var crosswalks: Array[Dictionary] = []
		for local_crosswalk in local_crosswalks:
			var port_id := String(local_crosswalk.get("port_id", ""))
			var local_axis := _piece_port_outward(local_ports, port_id)
			if local_axis.length_squared() < 0.001 and not local_ports.is_empty():
				local_axis = Vector2(local_ports[0].get("outward", Vector2.UP))
			var world_axis := _piece_world_direction(piece, local_axis)
			crosswalks.append({
				"id": String(local_crosswalk.get("id", port_id)),
				"port_id": port_id,
				"center": piece.to_global(Vector2(local_crosswalk.get("center", Vector2.ZERO))),
				"axis": world_axis,
				"width": float(local_crosswalk.get("width", 0.0)),
				"depth": float(local_crosswalk.get("depth", 0.0))
			})

		var signal_anchors: Array[Dictionary] = []
		for local_anchor in local_anchors:
			var anchor_port_id := String(local_anchor.get("port_id", ""))
			var anchor_port := _piece_port(local_ports, anchor_port_id)
			var half_width := float(anchor_port.get("total_lanes", 2)) * LANE_WIDTH * 0.5
			var local_outward := _piece_port_outward(local_ports, anchor_port_id)
			var local_stop_center: Vector2 = local_anchor.get("stop_line_center", Vector2.ZERO)
			var local_light_anchor: Vector2 = local_anchor.get("light_anchor", local_stop_center)
			signal_anchors.append({
				"port_id": anchor_port_id,
				"incoming_direction": _piece_world_direction(
					piece, Vector2(local_anchor.get("incoming_direction", -local_outward))
				),
				"outward": _piece_world_direction(piece, local_outward),
				"stop_line_center": piece.to_global(local_stop_center),
				"stop_line_direction": _piece_world_direction(
					piece, Vector2(local_anchor.get("stop_line_direction", Vector2.ZERO))
				),
				"light_anchor": piece.to_global(local_light_anchor),
				"half_width": half_width
			})

		result.append({
			"piece_index": piece_index,
			"piece_id": String(piece_data["piece_id"]),
			"center": world_center,
			"crosswalks": crosswalks,
			"signal_anchors": signal_anchors
		})
	return result


func _piece_port(ports: Array[Dictionary], port_id: String) -> Dictionary:
	for port in ports:
		if String(port.get("id", "")) == port_id:
			return port
	return {}


func _piece_port_outward(ports: Array[Dictionary], port_id: String) -> Vector2:
	var port := _piece_port(ports, port_id)
	return Vector2(port.get("outward", Vector2.ZERO))


func _piece_world_direction(piece: Node2D, local_direction: Vector2) -> Vector2:
	if local_direction.length_squared() < 0.001:
		return Vector2.ZERO
	return (piece.to_global(local_direction) - piece.to_global(Vector2.ZERO)).normalized()


## Public surface shared with the original generator so the same gameplay,
## traffic, pedestrian, signal, AI, and minimap systems can consume this map.
func get_route() -> RoutePath:
	return route


func get_road_network() -> RefCounted:
	return road_network


func get_center_points() -> Array[Vector2]:
	return center_points.duplicate()


func get_map_paths() -> Array[PackedVector2Array]:
	return _map_paths.duplicate()


func get_map_path_half_width_profiles() -> Array[PackedFloat32Array]:
	return _map_half_width_profiles.duplicate()


func get_map_bounds() -> Rect2:
	return generation_bounds


func get_obstacle_regions() -> Array[Dictionary]:
	return obstacle_regions.duplicate(true)


func get_intersection_indices() -> PackedInt32Array:
	return intersection_indices.duplicate()


func get_intersection_types() -> PackedStringArray:
	return intersection_types.duplicate()


func get_branch_sides() -> PackedInt32Array:
	return branch_sides.duplicate()


func get_spawn_position() -> Vector2:
	return Vector2.ZERO


func get_spawn_rotation() -> float:
	return PI * 0.5


func get_width_profile() -> PackedFloat32Array:
	var result := PackedFloat32Array()
	for half_width in route.half_widths:
		result.append(half_width * 2.0)
	return result


func get_lane_profile() -> PackedFloat32Array:
	return route.lane_profile.duplicate()


func get_player_spawn_pose(lateral_offset: float) -> Dictionary:
	var direction := Vector2.RIGHT
	var normal := Vector2(-direction.y, direction.x)
	return {
		"position": Vector2.ZERO + normal * lateral_offset,
		"rotation": direction.angle() + PI * 0.5
	}


func _build_simulation_data(grid: Dictionary) -> void:
	_map_paths.clear()
	_map_half_width_profiles.clear()
	_map_lane_profiles.clear()
	_map_road_classes.clear()
	_map_one_way_paths.clear()
	center_points.clear()
	intersection_indices.clear()
	intersection_types.clear()
	branch_sides.clear()
	obstacle_regions.clear()

	for piece_data in placed_pieces:
		var piece: Node2D = piece_data["node"]
		var piece_id := String(piece_data["piece_id"])
		var ports: Array[Dictionary] = piece.call("get_ports")
		var drive_paths: Array[Dictionary] = piece.call("get_drive_paths")
		for drive_path in drive_paths:
			var local_points: PackedVector2Array = drive_path["points"]
			var world_points := PackedVector2Array()
			for local_point in local_points:
				world_points.append(piece.to_global(local_point))
			var fallback_lanes := int(ports[0].get("total_lanes", 2)) if not ports.is_empty() else 2
			var from_lanes := _piece_port_lane_count(piece, String(drive_path.get("from_port", "")), fallback_lanes)
			var to_lanes := _piece_port_lane_count(piece, String(drive_path.get("to_port", "")), from_lanes)
			var sampled := _sample_simulation_path(world_points, from_lanes, to_lanes)
			var sampled_points: PackedVector2Array = sampled["points"]
			if sampled_points.size() < 2:
				continue
			_map_paths.append(sampled_points)
			_map_half_width_profiles.append(sampled["half_widths"])
			_map_lane_profiles.append(sampled["lane_profile"])
			var road_class := String(drive_path.get("route_type", ""))
			if road_class != "roundabout":
				road_class = "arterial" if maxi(from_lanes, to_lanes) >= 4 else "local"
			_map_road_classes.append(road_class)
			_map_one_way_paths.append(1 if bool(drive_path.get("one_way", false)) else 0)

	road_network.build(
		_map_paths,
		_map_half_width_profiles,
		_map_lane_profiles,
		_map_road_classes,
		_map_one_way_paths
	)
	var size := int(grid["size"])
	var middle := int(grid["middle"])
	var coordinates: Array[Vector2] = grid["coordinates"]
	var route_curve := road_network.find_path(
		coordinates[middle * size],
		coordinates[middle * size + size - 1]
	)
	var route_points: Array[Vector2] = []
	var route_half_widths := PackedFloat32Array()
	var route_lanes := PackedFloat32Array()
	for point in route_curve:
		route_points.append(point)
		var node_id := road_network.nearest_node(point)
		var half_width := road_network.get_node_half_width(node_id)
		route_half_widths.append(half_width)
		route_lanes.append(maxf(half_width / LANE_WIDTH, 1.0))

	center_points = route_points.duplicate()
	route.build(route_points, route_half_widths, route_lanes, LANE_WIDTH)
	road_width = LANE_WIDTH * 4.0
	maximum_road_width = LANE_WIDTH * 4.0
	cross_street_width = LANE_WIDTH * 2.0
	for point_index in range(route_points.size()):
		var node_id := road_network.nearest_node(route_points[point_index])
		if node_id < 0 or int(road_network.call("get_node_degree", node_id)) < 3:
			continue
		if intersection_indices.has(point_index):
			continue
		intersection_indices.append(point_index)
		var degree := int(road_network.call("get_node_degree", node_id))
		intersection_types.append("four_way" if degree >= 4 else "t_junction")
		branch_sides.append(0)


func _piece_port_lane_count(piece: Node2D, port_id: String, fallback: int) -> int:
	for port in piece.call("get_ports"):
		if String(port.get("id", "")) == port_id:
			return int(port.get("total_lanes", fallback))
	return fallback


func _sample_simulation_path(
	path: PackedVector2Array,
	start_lanes: int,
	end_lanes: int
) -> Dictionary:
	var points := PackedVector2Array()
	var half_widths := PackedFloat32Array()
	var lane_profile := PackedFloat32Array()
	if path.size() < 2:
		return {"points": points, "half_widths": half_widths, "lane_profile": lane_profile}
	var path_length := _polyline_length(path)
	var travelled := 0.0
	# Preserve every authored corner. Global resampling can reduce a short bend
	# to its endpoint chord, sending navigation through the inside curb.
	for segment_index in range(path.size() - 1):
		var start := path[segment_index]
		var finish := path[segment_index + 1]
		var length := start.distance_to(finish)
		if length < 0.001:
			continue
		var divisions := maxi(1, ceili(length / SIMULATION_SAMPLE_SPACING))
		for sample_index in range(divisions):
			var weight := float(sample_index) / float(divisions)
			var progress := (travelled + length * weight) / maxf(path_length, 0.001)
			var total_lanes := lerpf(float(start_lanes), float(end_lanes), progress)
			points.append(start.lerp(finish, weight))
			half_widths.append(total_lanes * LANE_WIDTH * 0.5)
			lane_profile.append(total_lanes * 0.5)
		travelled += length
	points.append(path[-1])
	half_widths.append(float(end_lanes) * LANE_WIDTH * 0.5)
	lane_profile.append(float(end_lanes) * 0.5)
	return {"points": points, "half_widths": half_widths, "lane_profile": lane_profile}


func _build_road_edge_collisions() -> void:
	var walls := StaticBody2D.new()
	walls.name = "RoadEdgeCollisions"
	walls.collision_layer = 1
	walls.collision_mask = 2
	_generated_root.add_child(walls)
	for piece_data in placed_pieces:
		var piece: Node2D = piece_data["node"]
		var edge_paths: Array[PackedVector2Array] = piece.call("get_road_edge_paths")
		for local_edge in edge_paths:
			for point_index in range(local_edge.size() - 1):
				var start := piece.to_global(local_edge[point_index])
				var finish := piece.to_global(local_edge[point_index + 1])
				var edge_segment := finish - start
				var edge_length := edge_segment.length()
				if edge_length < 1.0:
					continue
				var shape := CollisionShape2D.new()
				var rectangle := RectangleShape2D.new()
				rectangle.size = Vector2(edge_length + ROAD_BOUNDARY_THICKNESS, ROAD_BOUNDARY_THICKNESS)
				shape.shape = rectangle
				shape.position = walls.to_local((start + finish) * 0.5)
				shape.rotation = edge_segment.angle() - walls.global_rotation
				walls.add_child(shape)


func _choose_grid_size(piece_budget: int) -> int:
	var chosen_size := 3
	for candidate_size in [5, 7, 9, 11]:
		if _estimated_full_grid_piece_count(candidate_size) <= piece_budget:
			chosen_size = candidate_size
	# Keep the origin at the geometric center (odd grid sizes), but let a seed
	# select a smaller district footprint when the piece budget allows it.
	if chosen_size >= 7 \
	and piece_budget <= _estimated_full_grid_piece_count(chosen_size - 2) * 2 \
	and _rng.randf() < 0.4:
		return chosen_size - 2
	return chosen_size


func _estimated_full_grid_piece_count(size: int) -> int:
	var node_count := size * size
	var edge_count := 2 * size * (size - 1)
	var lane_transition_count := 4 * size - 4
	# Each transition divides one street connector into two.
	return node_count + edge_count + lane_transition_count * 2


func _create_city_grid(size: int) -> Dictionary:
	var middle := floori(float(size) * 0.5)
	var x_positions: Array[float] = []
	var y_positions: Array[float] = []
	x_positions.resize(size)
	y_positions.resize(size)
	x_positions[middle] = 0.0
	y_positions[middle] = 0.0
	for index in range(middle + 1, size):
		x_positions[index] = x_positions[index - 1] + _random_block_spacing()
		y_positions[index] = y_positions[index - 1] + _random_block_spacing()
	for index in range(middle - 1, -1, -1):
		x_positions[index] = x_positions[index + 1] - _random_block_spacing()
		y_positions[index] = y_positions[index + 1] - _random_block_spacing()

	var adjacency: Array = []
	var coordinates: Array[Vector2] = []
	for row in range(size):
		for column in range(size):
			adjacency.append([])
			coordinates.append(Vector2(x_positions[column], y_positions[row]))
	var edges: Array[Dictionary] = []
	for row in range(size):
		for column in range(size):
			var current := row * size + column
			if column + 1 < size:
				var east := current + 1
				var horizontal_is_arterial := row == middle
				edges.append({"a": current, "b": east, "arterial": horizontal_is_arterial, "enabled": true})
				(adjacency[current] as Array).append(east)
				(adjacency[east] as Array).append(current)
			if row + 1 < size:
				var south := current + size
				var vertical_is_arterial := column == middle
				edges.append({"a": current, "b": south, "arterial": vertical_is_arterial, "enabled": true})
				(adjacency[current] as Array).append(south)
				(adjacency[south] as Array).append(current)

	# Keep the two arterial spines intact, but occasionally remove a local block
	# street. Each removal is accepted only if the whole district stays connected.
	var local_edge_indices: Array[int] = []
	for edge_index in range(edges.size()):
		if not bool(edges[edge_index]["arterial"]):
			local_edge_indices.append(edge_index)
	_shuffle_ints(local_edge_indices)
	for edge_index in local_edge_indices:
		if _rng.randf() >= LOCAL_STREET_REMOVAL_CHANCE:
			continue
		var edge: Dictionary = edges[edge_index]
		var a := int(edge["a"])
		var b := int(edge["b"])
		(adjacency[a] as Array).erase(b)
		(adjacency[b] as Array).erase(a)
		if _graph_is_connected(adjacency):
			edge["enabled"] = false
			edges[edge_index] = edge
			removed_local_street_count += 1
		else:
			(adjacency[a] as Array).append(b)
			(adjacency[b] as Array).append(a)

	# Stable neighbor order is helpful for reproducible road traversal.
	for neighbors in adjacency:
		(neighbors as Array).sort()
	return {
		"size": size,
		"middle": middle,
		"coordinates": coordinates,
		"adjacency": adjacency,
		"edges": edges
	}


func _random_block_spacing() -> float:
	return _rng.randf_range(MIN_BLOCK_SPACING, MAX_BLOCK_SPACING)


func _graph_is_connected(adjacency: Array) -> bool:
	if adjacency.is_empty():
		return false
	var visited: Dictionary = {0: true}
	var queue: Array[int] = [0]
	var cursor := 0
	while cursor < queue.size():
		var current := queue[cursor]
		cursor += 1
		for neighbor_value in adjacency[current]:
			var neighbor := int(neighbor_value)
			if visited.has(neighbor):
				continue
			visited[neighbor] = true
			queue.append(neighbor)
	return visited.size() == adjacency.size()


func _plan_intersections(grid: Dictionary) -> Array[Dictionary]:
	var plans: Array[Dictionary] = []
	var size := int(grid["size"])
	var middle := int(grid["middle"])
	var adjacency: Array = grid["adjacency"]
	var coordinates: Array[Vector2] = grid["coordinates"]
	var center_id := middle * size + middle
	var ordered_ids: Array[int] = []
	for node_id in range(size * size):
		ordered_ids.append(node_id)
	ordered_ids.sort_custom(func(a: int, b: int) -> bool:
		var distance_a := _grid_manhattan_distance(a, center_id, size)
		var distance_b := _grid_manhattan_distance(b, center_id, size)
		if distance_a == distance_b:
			return a < b
		return distance_a < distance_b
	)

	for node_id in ordered_ids:
		var neighbors: Array = adjacency[node_id]
		if neighbors.is_empty() or _is_straight_through_node(node_id, neighbors, size):
			continue
		var directions: Array[Vector2] = []
		var requested_lanes: Dictionary = {}
		for neighbor_value in neighbors:
			var neighbor := int(neighbor_value)
			var direction := _grid_direction(node_id, neighbor, size)
			directions.append(direction)
			requested_lanes[_direction_key(direction)] = _grid_edge_lane_count(node_id, neighbor, size, middle)
		var is_arterial_node := _is_arterial_node(node_id, size, middle)
		var piece_ids := _intersection_candidates(directions.size(), is_arterial_node)
		var selected := _select_intersection_template(piece_ids, directions, requested_lanes)
		if selected.is_empty():
			generation_error = "No authored intersection matches grid node %d with %d approach(es)." % [node_id, directions.size()]
			return []
		plans.append({
			"node_id": node_id,
			"position": coordinates[node_id],
			"piece_id": selected["piece_id"],
			"rotation": selected["rotation"],
			"ports": selected["ports"],
			"directions": directions
		})
	return plans


func _intersection_candidates(degree: int, arterial_node: bool) -> Array[String]:
	match degree:
		1:
			return ["u_turn_dead_end_bulb"]
		2:
			return ["turn_left", "turn_right"]
		3:
			if arterial_node:
				return ["t_junction", "t_junction_2_lane", "bulb_3_road_junction"]
			if _rng.randf() < ROUNDABOUT_CHANCE:
				return ["bulb_3_road_junction", "t_junction_2_lane"]
			return ["t_junction_2_lane", "bulb_3_road_junction"]
		4:
			if arterial_node:
				return ["four_way_intersection", "four_way_intersection_2_lane", "bulb_4_road_junction"]
			if _rng.randf() < ROUNDABOUT_CHANCE:
				return ["bulb_4_road_junction", "four_way_intersection_2_lane"]
			return ["four_way_intersection_2_lane", "bulb_4_road_junction"]
	return []


func _select_intersection_template(
	candidate_ids: Array[String],
	directions: Array[Vector2],
	requested_lanes: Dictionary
) -> Dictionary:
	var best: Dictionary = {}
	var best_score := INF
	for piece_id in candidate_ids:
		var candidate := _instantiate_piece(piece_id)
		if candidate == null:
			continue
		var ports: Array[Dictionary] = candidate.call("get_ports")
		if ports.size() != directions.size():
			candidate.free()
			continue
		for quarter_turn in range(4):
			var rotation := float(quarter_turn) * PI * 0.5
			var matched_directions: Dictionary = {}
			var score := 0.0
			var fits := true
			for port in ports:
				var outward: Vector2 = Vector2(port["outward"]).rotated(rotation).round()
				var direction_key := _direction_key(outward)
				if not requested_lanes.has(direction_key) or matched_directions.has(direction_key):
					fits = false
					break
				matched_directions[direction_key] = true
				score += absf(float(requested_lanes[direction_key]) - float(port["total_lanes"]))
			if not fits or matched_directions.size() != directions.size():
				continue
			# Prefer signalized, conventional arterial crossroads; neighborhood
			# intersections use standard T/four-way junctions most of the time.
			if String(piece_id) == "four_way_intersection" or String(piece_id) == "t_junction":
				score -= 0.1
			if score < best_score:
				best_score = score
				best = {
					"piece_id": piece_id,
					"rotation": rotation,
					"ports": ports
				}
		candidate.free()
	return best


func _place_intersections(grid: Dictionary, plans: Array[Dictionary]) -> Dictionary:
	var refs_by_node: Dictionary = {}
	var coordinates: Array[Vector2] = grid["coordinates"]
	for plan in plans:
		var piece_id := String(plan["piece_id"])
		var rotation := float(plan["rotation"])
		var position: Vector2 = plan["position"]
		if piece_id == "u_turn_dead_end_bulb":
			var terminal_ports: Array[Dictionary] = plan["ports"]
			position = Vector2(plan["position"]) - Vector2(terminal_ports[0]["position"]).rotated(rotation)
		var piece_index := _append_piece(piece_id, position, rotation)
		if piece_index < 0:
			return {}
		var port_by_direction: Dictionary = {}
		var world_ports: Array[Dictionary] = placed_pieces[piece_index]["world_ports"]
		for port_index in range(world_ports.size()):
			var direction_key := _direction_key(Vector2(world_ports[port_index]["outward"]))
			port_by_direction[direction_key] = port_index
		refs_by_node[int(plan["node_id"])] = {
			"piece_index": piece_index,
			"port_by_direction": port_by_direction
		}
	return refs_by_node


func _trace_street_corridors(grid: Dictionary, node_refs: Dictionary) -> Array[Dictionary]:
	var adjacency: Array = grid["adjacency"]
	var size := int(grid["size"])
	var active_nodes: Dictionary = {}
	for node_id in range(adjacency.size()):
		if adjacency[node_id].is_empty() or _is_straight_through_node(node_id, adjacency[node_id], size):
			continue
		active_nodes[node_id] = true

	var visited_edges: Dictionary = {}
	var corridors: Array[Dictionary] = []
	for start_node in active_nodes:
		for first_neighbor_value in adjacency[int(start_node)]:
			var first_neighbor := int(first_neighbor_value)
			var first_key := _grid_edge_key(int(start_node), first_neighbor)
			if visited_edges.has(first_key):
				continue
			var previous := int(start_node)
			var current := first_neighbor
			visited_edges[first_key] = true
			var safety := 0
			while not active_nodes.has(current) and safety < adjacency.size():
				safety += 1
				var next_node := -1
				for neighbor_value in adjacency[current]:
					var neighbor := int(neighbor_value)
					if neighbor != previous:
						next_node = neighbor
						break
				if next_node < 0:
					break
				visited_edges[_grid_edge_key(current, next_node)] = true
				previous = current
				current = next_node
			if current == int(start_node) or not active_nodes.has(current):
				continue
			var start_direction := _grid_direction(int(start_node), first_neighbor, size)
			var end_direction := _grid_direction(current, previous, size)
			var start_ref: Dictionary = node_refs.get(int(start_node), {})
			var end_ref: Dictionary = node_refs.get(current, {})
			if start_ref.is_empty() or end_ref.is_empty():
				generation_error = "A planned road corridor ended at a missing junction."
				return []
			var start_port_index := int(start_ref["port_by_direction"].get(_direction_key(start_direction), -1))
			var end_port_index := int(end_ref["port_by_direction"].get(_direction_key(end_direction), -1))
			if start_port_index < 0 or end_port_index < 0:
				generation_error = "A junction does not provide a socket for its planned street direction."
				return []
			corridors.append({
				"start_piece": int(start_ref["piece_index"]),
				"start_port": start_port_index,
				"end_piece": int(end_ref["piece_index"]),
				"end_port": end_port_index,
				"start_node": int(start_node),
				"end_node": current
			})
	return corridors


func _make_corridor_segment_tasks(corridors: Array[Dictionary], _node_refs: Dictionary) -> Array[Dictionary]:
	var tasks: Array[Dictionary] = []
	for corridor in corridors:
		var start_ref := _piece_port_ref(int(corridor["start_piece"]), int(corridor["start_port"]))
		var end_ref := _piece_port_ref(int(corridor["end_piece"]), int(corridor["end_port"]))
		var start_lanes := int(start_ref["world_port"]["total_lanes"])
		var end_lanes := int(end_ref["world_port"]["total_lanes"])
		if start_lanes == end_lanes:
			tasks.append({
				"start_ref": start_ref,
				"end_ref": end_ref,
				"extra_splits": 0
			})
			continue
		if not [2, 4].has(start_lanes) or not [2, 4].has(end_lanes):
			generation_error = "Unsupported lane change %d → %d in the street graph." % [start_lanes, end_lanes]
			return []
		var transition := _place_lane_transition(start_ref, end_ref, start_lanes, end_lanes)
		if transition.is_empty():
			generation_error = "Could not place a clean %d-to-%d lane transition." % [start_lanes, end_lanes]
			return []
		tasks.append({
			"start_ref": start_ref,
			"end_ref": transition["start_ref"],
			"extra_splits": 0
		})
		tasks.append({
			"start_ref": transition["end_ref"],
			"end_ref": end_ref,
			"extra_splits": 0
		})
	return tasks


func _place_lane_transition(
	start_ref: Dictionary,
	end_ref: Dictionary,
	start_lanes: int,
	end_lanes: int
) -> Dictionary:
	# The current grid has only two- and four-lane edges.
	var transition_id := "lane_transition_4_to_2"
	var start_port: Dictionary = start_ref["world_port"]
	var end_port: Dictionary = end_ref["world_port"]
	var center := (Vector2(start_port["position"]) + Vector2(end_port["position"])) * 0.5
	var transition := _instantiate_piece(transition_id)
	if transition == null:
		return {}
	var local_ports: Array[Dictionary] = transition.call("get_ports")
	var selected_rotation := -1.0
	var selected_start_port := -1
	var selected_end_port := -1
	for quarter_turn in range(4):
		var rotation := float(quarter_turn) * PI * 0.5
		var world_ports := _transform_ports(local_ports, center, rotation)
		for start_index in range(world_ports.size()):
			if int(world_ports[start_index]["total_lanes"]) != start_lanes:
				continue
			if Vector2(start_port["outward"]).dot(-Vector2(world_ports[start_index]["outward"])) < 0.999:
				continue
			for end_index in range(world_ports.size()):
				if end_index == start_index or int(world_ports[end_index]["total_lanes"]) != end_lanes:
					continue
				if Vector2(end_port["outward"]).dot(-Vector2(world_ports[end_index]["outward"])) < 0.999:
					continue
				selected_rotation = rotation
				selected_start_port = start_index
				selected_end_port = end_index
				break
			if selected_rotation >= 0.0:
				break
		if selected_rotation >= 0.0:
			break
	transition.free()
	if selected_rotation < 0.0:
		return {}

	var piece_index := _append_piece(transition_id, center, selected_rotation)
	if piece_index < 0:
		return {}
	return {
		"start_ref": _piece_port_ref(piece_index, selected_start_port),
		"end_ref": _piece_port_ref(piece_index, selected_end_port)
	}


func _distribute_segment_splits(tasks: Array[Dictionary], extra_piece_budget: int) -> void:
	if extra_piece_budget <= 0:
		return
	var eligible: Array[Dictionary] = []
	for task_index in range(tasks.size()):
		var length := _measure_segment_task(tasks[task_index])
		if length < MIN_SPLIT_SEGMENT_LENGTH * 2.0:
			continue
		eligible.append({"task_index": task_index, "length": length, "priority": length + _rng.randf_range(-250.0, 250.0)})
	eligible.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["priority"]) > float(b["priority"])
	)
	var remaining := extra_piece_budget
	while remaining > 0:
		var made_progress := false
		for candidate in eligible:
			var task_index := int(candidate["task_index"])
			var current_splits := int(tasks[task_index]["extra_splits"])
			var segment_count := current_splits + 2
			var segment_length := float(candidate["length"]) / float(segment_count)
			if segment_length < MIN_SPLIT_SEGMENT_LENGTH:
				continue
			tasks[task_index]["extra_splits"] = current_splits + 1
			remaining -= 1
			made_progress = true
			if remaining == 0:
				break
		if not made_progress:
			generation_error = "The planned straight corridors are too short to reach the requested %d-piece map without tiny fragments." % target_piece_count
			return


func _measure_segment_task(task: Dictionary) -> float:
	var start_port: Dictionary = task["start_ref"]["world_port"]
	var end_port: Dictionary = task["end_ref"]["world_port"]
	var start_position: Vector2 = start_port["position"]
	var end_position: Vector2 = end_port["position"]
	var displacement := end_position - start_position
	var length := displacement.length()
	if length < 1.0:
		return 0.0
	var direction := displacement / length
	if Vector2(start_port["outward"]).dot(direction) < 0.999 \
	or Vector2(end_port["outward"]).dot(-direction) < 0.999:
		return 0.0
	return length


func _straight_piece_id_for_lanes(total_lanes: int) -> String:
	match total_lanes:
		2:
			return "straight_2_lane"
		4:
			return "straight_4_lane"
		6:
			return "straight_6_lane"
	return ""


func _place_straight_road_chain(task: Dictionary, extra_splits: int) -> bool:
	var start_ref: Dictionary = task["start_ref"]
	var end_ref: Dictionary = task["end_ref"]
	var start_port: Dictionary = start_ref["world_port"]
	var end_port: Dictionary = end_ref["world_port"]
	var lanes := int(start_port["total_lanes"])
	if lanes != int(end_port["total_lanes"]):
		return false
	var piece_id := _straight_piece_id_for_lanes(lanes)
	if piece_id.is_empty():
		return false
	var start_position: Vector2 = start_port["position"]
	var end_position: Vector2 = end_port["position"]
	var total_length := _measure_segment_task(task)
	if total_length < 1.0:
		generation_error = "A road-piece corridor needs straight, opposing sockets."
		return false
	var direction := (end_position - start_position) / total_length
	var segment_count := extra_splits + 1
	var segment_piece_indices: Array[int] = []
	for segment_index in range(segment_count):
		var segment_start := start_position + direction * total_length \
			* float(segment_index) / float(segment_count)
		var segment_end := start_position + direction * total_length \
			* float(segment_index + 1) / float(segment_count)
		var segment_length := segment_start.distance_to(segment_end)
		var segment := _instantiate_piece(piece_id)
		if segment == null:
			return false
		segment.call("configure_generated_straight", segment_length)
		var segment_origin := (segment_start + segment_end) * 0.5
		var segment_rotation := direction.angle() - PI * 0.5
		var local_bounds := _piece_local_bounds(segment, piece_id)
		var local_footprints := _piece_local_footprints(segment, piece_id)
		var candidate_bounds := _transform_bounds(local_bounds, segment_origin, segment_rotation)
		var candidate_footprints := _transform_polygons(local_footprints, segment_origin, segment_rotation)
		var ignored_indices: Array[int] = []
		if segment_index == 0:
			ignored_indices.append(int(start_ref["owner_index"]))
		else:
			ignored_indices.append(segment_piece_indices[-1])
		if segment_index == segment_count - 1:
			ignored_indices.append(int(end_ref["owner_index"]))
		if not _placement_is_clear_exact(candidate_bounds, candidate_footprints, ignored_indices):
			segment.free()
			return false
		var piece_index := _append_piece_instance(
			segment, piece_id, segment_origin, segment_rotation,
			local_bounds, local_footprints, ignored_indices
		)
		if piece_index < 0:
			return false
		segment_piece_indices.append(piece_index)

	for segment_index in range(segment_piece_indices.size()):
		var segment_piece_index := segment_piece_indices[segment_index]
		if segment_index == 0:
			if not _connect_piece_ports(
				int(start_ref["owner_index"]), int(start_ref["port_index"]), segment_piece_index, 0
			):
				return false
		else:
			if not _connect_piece_ports(segment_piece_indices[segment_index - 1], 1, segment_piece_index, 0):
				return false
		if segment_index == segment_piece_indices.size() - 1:
			if not _connect_piece_ports(
				segment_piece_index, 1, int(end_ref["owner_index"]), int(end_ref["port_index"])
			):
				return false
	return true


func _append_piece(piece_id: String, position: Vector2, rotation: float) -> int:
	var piece := _instantiate_piece(piece_id)
	if piece == null:
		return -1
	var local_bounds := _piece_local_bounds(piece, piece_id)
	var local_footprints := _piece_local_footprints(piece, piece_id)
	return _append_piece_instance(piece, piece_id, position, rotation, local_bounds, local_footprints)


func _append_piece_instance(
	piece: Node2D,
	piece_id: String,
	position: Vector2,
	rotation: float,
	local_bounds: Rect2,
	local_footprints: Array[PackedVector2Array],
	ignored_piece_indices: Array[int] = []
) -> int:
	var ports: Array[Dictionary] = piece.call("get_ports")
	var world_ports := _transform_ports(ports, position, rotation)
	var world_bounds := _transform_bounds(local_bounds, position, rotation)
	var world_footprints := _transform_polygons(local_footprints, position, rotation)
	if not _placement_is_clear_exact(world_bounds, world_footprints, ignored_piece_indices):
		piece.free()
		generation_error = "Piece %s overlaps a previously planned street." % piece_id
		return -1
	piece.position = position
	piece.rotation = rotation
	_generated_root.add_child(piece)
	var used_ports: Array[bool] = []
	used_ports.resize(ports.size())
	var piece_index := placed_pieces.size()
	placed_pieces.append({
		"piece_id": piece_id,
		"position": position,
		"rotation": rotation,
		"node": piece,
		"ports": ports,
		"world_ports": world_ports,
		"used_ports": used_ports,
		"local_bounds": local_bounds,
		"world_bounds": world_bounds,
		"world_footprints": world_footprints
	})
	return piece_index


func _piece_port_ref(piece_index: int, port_index: int) -> Dictionary:
	var piece: Dictionary = placed_pieces[piece_index]
	return {
		"owner_index": piece_index,
		"port_index": port_index,
		"world_port": piece["world_ports"][port_index]
	}


func _connect_piece_ports(piece_a_index: int, port_a_index: int, piece_b_index: int, port_b_index: int) -> bool:
	var piece_a: Dictionary = placed_pieces[piece_a_index]
	var piece_b: Dictionary = placed_pieces[piece_b_index]
	var port_a: Dictionary = piece_a["world_ports"][port_a_index]
	var port_b: Dictionary = piece_b["world_ports"][port_b_index]
	if not _ports_connect(port_a, port_b):
		generation_error = "Socket mismatch between %s.%s and %s.%s." % [
			String(piece_a["piece_id"]), String(piece_a["ports"][port_a_index]["id"]),
			String(piece_b["piece_id"]), String(piece_b["ports"][port_b_index]["id"])
		]
		return false
	var used_a: Array = piece_a["used_ports"]
	var used_b: Array = piece_b["used_ports"]
	if bool(used_a[port_a_index]) or bool(used_b[port_b_index]):
		generation_error = "A road socket was assigned to more than one corridor."
		return false
	used_a[port_a_index] = true
	used_b[port_b_index] = true
	piece_a["used_ports"] = used_a
	piece_b["used_ports"] = used_b
	placed_pieces[piece_a_index] = piece_a
	placed_pieces[piece_b_index] = piece_b
	connections.append({
		"piece_a": piece_a_index,
		"port_a": piece_a["ports"][port_a_index]["id"],
		"piece_b": piece_b_index,
		"port_b": piece_b["ports"][port_b_index]["id"],
		"position": port_a["position"]
	})
	return true


func _instantiate_piece(piece_id: String) -> Node2D:
	var packed := load("res://scenes/road_pieces/%s.tscn" % piece_id) as PackedScene
	if packed == null:
		push_error("Missing authored road piece scene: %s" % piece_id)
		return null
	var piece := packed.instantiate() as Node2D
	if piece == null:
		push_error("Road piece did not instantiate as Node2D: %s" % piece_id)
		return null
	piece.set("piece_id", StringName(piece_id))
	piece.set("debug_ports", false)
	return piece


func _piece_local_bounds(piece: Node2D, piece_id: String) -> Rect2:
	var minimum := Vector2(INF, INF)
	var maximum := Vector2(-INF, -INF)
	var routes: Array[Dictionary] = piece.call("get_drive_paths")
	for route in routes:
		var points: PackedVector2Array = route["points"]
		if points.size() < 2:
			continue
		var port: Dictionary = piece.call("_port_by_id", String(route.get("from_port", "")))
		var edge_offset := float(port.get("total_lanes", 2)) * LANE_WIDTH * 0.5 + SIDEWALK_WIDTH + 6.0
		for side in [-edge_offset, edge_offset]:
			var edge_points: PackedVector2Array = piece.call("_offset_path", points, float(side))
			for point in edge_points:
				minimum.x = minf(minimum.x, point.x)
				minimum.y = minf(minimum.y, point.y)
				maximum.x = maxf(maximum.x, point.x)
				maximum.y = maxf(maximum.y, point.y)

	if piece_id == "bulb_3_road_junction" or piece_id == "bulb_4_road_junction":
		var bulb_rect := Rect2(Vector2(-328.0, -328.0), Vector2.ONE * 656.0)
		var bulb_bounds := _include_rect_in_bounds(bulb_rect, minimum, maximum)
		minimum = bulb_bounds[0]
		maximum = bulb_bounds[1]
	elif piece_id == "u_turn_dead_end_bulb":
		var bulb_rect := Rect2(Vector2(-252.0, -2.0), Vector2(504.0, 504.0))
		var bulb_bounds := _include_rect_in_bounds(bulb_rect, minimum, maximum)
		minimum = bulb_bounds[0]
		maximum = bulb_bounds[1]

	if is_inf(minimum.x) or is_inf(minimum.y):
		return Rect2(Vector2(-100.0, -100.0), Vector2(200.0, 200.0))
	return Rect2(minimum, maximum - minimum).grow(2.0)


func _piece_local_footprints(piece: Node2D, piece_id: String) -> Array[PackedVector2Array]:
	var footprints: Array[PackedVector2Array] = []
	var outer_half_width := LANE_WIDTH + SIDEWALK_WIDTH
	if piece_id == "u_turn_dead_end_bulb":
		footprints.append(_rectangle_polygon(Rect2(Vector2(-outer_half_width, -650.0), Vector2(outer_half_width * 2.0, 698.0))))
		footprints.append(_circle_polygon(Vector2(0.0, 250.0), 252.0))
		return footprints
	if piece_id == "lane_transition_6_to_4" or piece_id == "lane_transition_4_to_2":
		var start_lanes := 6.0 if piece_id == "lane_transition_6_to_4" else 4.0
		var end_lanes := start_lanes - 2.0
		var start_half := start_lanes * LANE_WIDTH * 0.5 + SIDEWALK_WIDTH
		var end_half := end_lanes * LANE_WIDTH * 0.5 + SIDEWALK_WIDTH
		footprints.append(PackedVector2Array([
			Vector2(-start_half, -720.0), Vector2(start_half, -720.0),
			Vector2(end_half, 720.0), Vector2(-end_half, 720.0)
		]))
		return footprints

	if piece_id == "bulb_3_road_junction" or piece_id == "bulb_4_road_junction":
		footprints.append(_circle_polygon(Vector2.ZERO, 328.0))
	var routes: Array[Dictionary] = piece.call("get_drive_paths")
	for route in routes:
		var points: PackedVector2Array = route["points"]
		if points.size() < 2:
			continue
		var port: Dictionary = piece.call("_port_by_id", String(route.get("from_port", "")))
		var half_width := float(port.get("total_lanes", 2)) * LANE_WIDTH * 0.5 + SIDEWALK_WIDTH
		var left: PackedVector2Array = piece.call("_offset_path", points, half_width)
		var right: PackedVector2Array = piece.call("_offset_path", points, -half_width)
		var footprint := PackedVector2Array()
		footprint.append_array(left)
		for point_index in range(right.size() - 1, -1, -1):
			footprint.append(right[point_index])
		if footprint.size() >= 3:
			footprints.append(footprint)
	return footprints


func _placement_is_clear_exact(
	candidate_bounds: Rect2,
	candidate_footprints: Array[PackedVector2Array],
	ignored_piece_indices: Array[int] = []
) -> bool:
	for piece_index in range(placed_pieces.size()):
		if ignored_piece_indices.has(piece_index):
			continue
		var other_piece: Dictionary = placed_pieces[piece_index]
		if _footprints_overlap(candidate_bounds, candidate_footprints, other_piece):
			return false
	return true


func _footprints_overlap(
	candidate_bounds: Rect2,
	candidate_footprints: Array[PackedVector2Array],
	other_piece: Dictionary
) -> bool:
	if not candidate_bounds.intersects(other_piece["world_bounds"]):
		return false
	for candidate_polygon in candidate_footprints:
		for other_polygon in other_piece["world_footprints"]:
			var intersections := Geometry2D.intersect_polygons(candidate_polygon, other_polygon)
			for intersection in intersections:
				if _polygon_area(intersection) > MINIMUM_OVERLAP_AREA:
					return true
	return false


func _ports_connect(a: Dictionary, b: Dictionary) -> bool:
	return int(a["total_lanes"]) == int(b["total_lanes"]) \
	and Vector2(a["position"]).distance_to(Vector2(b["position"])) <= 2.0 \
	and Vector2(a["outward"]).dot(Vector2(b["outward"])) <= -0.999


func _transform_ports(ports: Array[Dictionary], origin: Vector2, rotation: float) -> Array[Dictionary]:
	var transformed: Array[Dictionary] = []
	for port in ports:
		transformed.append({
			"id": String(port["id"]),
			"position": origin + Vector2(port["position"]).rotated(rotation),
			"outward": Vector2(port["outward"]).rotated(rotation).normalized(),
			"total_lanes": int(port["total_lanes"])
		})
	return transformed


func _transform_bounds(local_bounds: Rect2, origin: Vector2, rotation: float) -> Rect2:
	var corners := [
		local_bounds.position,
		Vector2(local_bounds.end.x, local_bounds.position.y),
		local_bounds.end,
		Vector2(local_bounds.position.x, local_bounds.end.y)
	]
	var first: Vector2 = origin + Vector2(corners[0]).rotated(rotation)
	var minimum := first
	var maximum := first
	for corner in corners:
		var world_point := origin + Vector2(corner).rotated(rotation)
		minimum.x = minf(minimum.x, world_point.x)
		minimum.y = minf(minimum.y, world_point.y)
		maximum.x = maxf(maximum.x, world_point.x)
		maximum.y = maxf(maximum.y, world_point.y)
	return Rect2(minimum, maximum - minimum)


func _transform_polygons(polygons: Array[PackedVector2Array], origin: Vector2, rotation: float) -> Array[PackedVector2Array]:
	var transformed: Array[PackedVector2Array] = []
	for polygon in polygons:
		var world_polygon := PackedVector2Array()
		for point in polygon:
			world_polygon.append(origin + point.rotated(rotation))
		transformed.append(world_polygon)
	return transformed


func _include_rect_in_bounds(rect: Rect2, minimum: Vector2, maximum: Vector2) -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(minf(minimum.x, rect.position.x), minf(minimum.y, rect.position.y)),
		Vector2(maxf(maximum.x, rect.end.x), maxf(maximum.y, rect.end.y))
	])


func _rectangle_polygon(rect: Rect2) -> PackedVector2Array:
	return PackedVector2Array([
		rect.position,
		Vector2(rect.end.x, rect.position.y),
		rect.end,
		Vector2(rect.position.x, rect.end.y)
	])


func _circle_polygon(center: Vector2, radius: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for point_index in range(64):
		var angle := TAU * float(point_index) / 64.0
		points.append(center + Vector2(cos(angle), sin(angle)) * radius)
	return points


func _polygon_area(polygon: PackedVector2Array) -> float:
	if polygon.size() < 3:
		return 0.0
	var double_area := 0.0
	for point_index in range(polygon.size()):
		double_area += polygon[point_index].cross(polygon[(point_index + 1) % polygon.size()])
	return absf(double_area) * 0.5


func _polyline_length(points: PackedVector2Array) -> float:
	var total := 0.0
	for point_index in range(points.size() - 1):
		total += points[point_index].distance_to(points[point_index + 1])
	return total


func _sample_polyline(points: PackedVector2Array, requested_distance: float) -> Dictionary:
	var remaining := clampf(requested_distance, 0.0, _polyline_length(points))
	for segment_index in range(points.size() - 1):
		var segment := points[segment_index + 1] - points[segment_index]
		var length := segment.length()
		if remaining <= length or segment_index == points.size() - 2:
			var direction := segment.normalized()
			return {
				"position": points[segment_index] + direction * minf(remaining, length),
				"tangent": direction
			}
		remaining -= length
	return {"position": points[-1], "tangent": (points[-1] - points[-2]).normalized()}


func _is_straight_through_node(node_id: int, neighbors: Array, size: int) -> bool:
	if neighbors.size() != 2:
		return false
	var first := _grid_direction(node_id, int(neighbors[0]), size)
	var second := _grid_direction(node_id, int(neighbors[1]), size)
	return first.dot(second) <= -0.999


func _grid_direction(from_id: int, to_id: int, size: int) -> Vector2:
	var from_row := floori(float(from_id) / float(size))
	var from_column := from_id % size
	var to_row := floori(float(to_id) / float(size))
	var to_column := to_id % size
	if to_column > from_column:
		return Vector2.RIGHT
	if to_column < from_column:
		return Vector2.LEFT
	if to_row > from_row:
		return Vector2.DOWN
	return Vector2.UP


func _grid_edge_lane_count(a: int, b: int, size: int, middle: int) -> int:
	var a_row := floori(float(a) / float(size))
	var a_column := a % size
	var b_row := floori(float(b) / float(size))
	var b_column := b % size
	if a_row == b_row and a_row == middle:
		return 4
	if a_column == b_column and a_column == middle:
		return 4
	return 2


func _is_arterial_node(node_id: int, size: int, middle: int) -> bool:
	return floori(float(node_id) / float(size)) == middle or node_id % size == middle


func _direction_key(direction: Vector2) -> String:
	if absf(direction.x) > absf(direction.y):
		return "east" if direction.x > 0.0 else "west"
	return "south" if direction.y > 0.0 else "north"


func _grid_edge_key(a: int, b: int) -> String:
	return "%d:%d" % [mini(a, b), maxi(a, b)]


func _grid_manhattan_distance(a: int, b: int, size: int) -> int:
	var a_row := floori(float(a) / float(size))
	var b_row := floori(float(b) / float(size))
	return absi(a_row - b_row) + absi(a % size - b % size)


func _count_unused_sockets() -> int:
	var count := 0
	for piece in placed_pieces:
		for used in piece["used_ports"]:
			if not bool(used):
				count += 1
	return count


func _piece_count(piece_id: String) -> int:
	var count := 0
	for piece in placed_pieces:
		if String(piece["piece_id"]) == piece_id:
			count += 1
	return count


func _corridor_segment_count() -> int:
	var count := 0
	for piece in placed_pieces:
		if ["straight_2_lane", "straight_4_lane", "straight_6_lane"].has(
			String(piece["piece_id"])
		):
			count += 1
	return count


func _placed_junction_count() -> int:
	var count := 0
	for piece in placed_pieces:
		if String(piece["piece_id"]).contains("junction") or String(piece["piece_id"]).contains("intersection"):
			count += 1
	return count


func _generated_piece_count() -> int:
	return placed_pieces.size()


func _recalculate_generation_bounds() -> void:
	if placed_pieces.is_empty():
		generation_bounds = Rect2(Vector2.ZERO, Vector2.ZERO)
		return
	generation_bounds = placed_pieces[0]["world_bounds"]
	for piece_index in range(1, placed_pieces.size()):
		generation_bounds = generation_bounds.merge(placed_pieces[piece_index]["world_bounds"])


func _shuffle_ints(values: Array[int]) -> void:
	for index in range(values.size() - 1, 0, -1):
		var swap_index := _rng.randi_range(0, index)
		var held := values[index]
		values[index] = values[swap_index]
		values[swap_index] = held


func _fit_preview_camera() -> void:
	if generation_bounds.size.x <= 0.0 or generation_bounds.size.y <= 0.0:
		return
	var camera := get_node_or_null("Camera2D") as Camera2D
	if camera == null:
		return
	camera.position = generation_bounds.get_center()
	var viewport_size := get_viewport_rect().size - Vector2(96.0, 96.0)
	var padded_size := generation_bounds.size + Vector2(520.0, 520.0)
	var fit_zoom := minf(viewport_size.x / padded_size.x, viewport_size.y / padded_size.y)
	fit_zoom = clampf(fit_zoom, MIN_PREVIEW_ZOOM, 0.4)
	camera.zoom = Vector2.ONE * fit_zoom
	camera.make_current()


func _clear_generation() -> void:
	if _generated_root != null and is_instance_valid(_generated_root):
		if _generated_root.get_parent() != null:
			_generated_root.get_parent().remove_child(_generated_root)
		_generated_root.free()
	_generated_root = null
	placed_pieces.clear()
	connections.clear()
	generation_bounds = Rect2(Vector2.ZERO, Vector2.ZERO)
	grid_size = 0
	removed_local_street_count = 0
	var empty_points: Array[Vector2] = []
	var empty_paths: Array[PackedVector2Array] = []
	var empty_profiles: Array[PackedFloat32Array] = []
	route.build(empty_points)
	road_network.build(empty_paths, empty_profiles, empty_profiles, PackedStringArray())
	center_points.clear()
	intersection_indices.clear()
	intersection_types.clear()
	branch_sides.clear()
	obstacle_regions.clear()
	_map_paths.clear()
	_map_half_width_profiles.clear()
	_map_lane_profiles.clear()
	_map_road_classes.clear()
	_map_one_way_paths.clear()
