extends RefCounted
## The driving task contract shared by the live viewer and training worlds.
const DRIVING_ROUTE = preload("res://scripts/driving_route.gd")
const CLEARANCE = preload("res://scripts/vehicle_clearance.gd")
const ROUTE_ENDPOINT_CLEARANCE := 80.0
const SPAWN_ROUTE_ATTEMPTS := 48
const SPAWN_SAMPLE_SPACING := 40.0
const SPAWN_BODY_MARGIN := 10.0
const ROUTE_SAMPLE_SPACING := 5.0
const PROGRESS_WINDOW := 100.0
const GOAL_RADIUS := 85.0
const MAX_GOAL_DISTANCE := 6000.0
const ROAD_PREVIEW_DISTANCES := [60.0, 120.0, 240.0, 400.0]
const OBSERVATION_SIZE := 31
var ego: CharacterBody2D
var road_generator: Node
var route: RoutePath
var episode_rng := RandomNumberGenerator.new()
var minimum_turns := 0
var last_progress := 0.0
var goal_progress := 0.0
var base_max_speed := 500.0
var validation_cache: Dictionary = {}
var trip_rejections: Dictionary = {}
var clearance_queries: Dictionary = {}

func _select_trip(goal_range: Vector2) -> Dictionary:
	trip_rejections = {"geometry": 0, "spawn": 0, "turns": 0, "goal": 0, "path": 0}
	var network: Object = road_generator.call("get_road_network")
	for _attempt in range(SPAWN_ROUTE_ATTEMPTS):
		var candidate_data: Dictionary = network.call(
			"choose_driving_route",
			goal_range.x + ROUTE_ENDPOINT_CLEARANCE * 8.0,
			goal_range.y + ROUTE_ENDPOINT_CLEARANCE * 15.0,
			minimum_turns,
			episode_rng,
			# The current 125-unit roundabout reference is tighter than this
			# car's 131-unit minimum steering radius. Keep those edges out of
			# training until a wider, feasible roundabout lane is available.
			float(ego.get("wheelbase")) / tan(deg_to_rad(float(ego.get("max_steering_angle"))))
		)
		if candidate_data.is_empty():
			continue
		var candidate_route := DRIVING_ROUTE.new()
		if not candidate_route.build_from_graph(
			candidate_data["points"],
			candidate_data["half_widths"],
			float(road_generator.get("lane_width")),
			float(ego.get("wheelbase")) / tan(deg_to_rad(float(ego.get("max_steering_angle"))))
		):
			trip_rejections["geometry"] += 1
			continue
		var candidate_start := _find_safe_spawn_progress(candidate_route, goal_range.x)
		if candidate_start < 0.0:
			trip_rejections["spawn"] += 1
			continue
		var maximum_distance := minf(goal_range.y, candidate_route.usable_end - candidate_start - ROUTE_ENDPOINT_CLEARANCE * 0.5)
		var minimum_distance := goal_range.x
		var required_turns := minimum_turns
		var seen_turns := 0
		for index in range(candidate_route.turn_starts.size()):
			if candidate_route.turn_starts[index] < candidate_start:
				continue
			seen_turns += 1
			if seen_turns == required_turns:
				minimum_distance = maxf(minimum_distance, candidate_route.turn_ends[index] + GOAL_RADIUS - candidate_start)
				break
		if seen_turns < required_turns or maximum_distance < minimum_distance:
			continue
		for _goal_attempt in range(8):
			var candidate_goal := candidate_start + episode_rng.randf_range(minimum_distance, maximum_distance)
			if _count_trip_turns(candidate_route, candidate_start, candidate_goal) < minimum_turns:
				trip_rejections["turns"] += 1
				continue
			if not _spawn_pose_is_clear(candidate_route, candidate_goal):
				trip_rejections["goal"] += 1
				continue
			if not _trip_is_clear(candidate_route, candidate_start, candidate_goal):
				trip_rejections["path"] += 1
				continue
			route = candidate_route
			return {"start": candidate_start, "goal": candidate_goal}
	return {}


func _count_trip_turns(candidate: RoutePath, first: float, last: float) -> int:
	if candidate.has_method("count_completed_turns"):
		return int(candidate.call("count_completed_turns", first, last - GOAL_RADIUS))
	var turns := 0
	for i in range(1, candidate.points.size() - 1):
		if candidate.cumulative[i] <= first or candidate.cumulative[i] >= last:
			continue
		var incoming := candidate.points[i] - candidate.points[i - 1]
		var outgoing := candidate.points[i + 1] - candidate.points[i]
		if absf(incoming.angle_to(outgoing)) >= deg_to_rad(32.0):
			turns += 1
	return turns


func _trip_is_clear(candidate: RoutePath, first: float, last: float) -> bool:
	var cached: Dictionary = validation_cache.get(candidate.get_instance_id(), {})
	if not cached.is_empty() and not is_equal_approx(float(cached["first"]), first):
		cached = {}
	if not cached.is_empty() and is_equal_approx(float(cached["first"]), first):
		if float(cached.get("blocked", INF)) <= last:
			return false
		if float(cached["until"]) >= last:
			return _spawn_pose_is_clear(candidate, last, 2.0)
	var progress := maxf(first, float(cached.get("until", first)))
	while progress < last:
		if not _spawn_pose_is_clear(candidate, progress, 2.0):
			validation_cache[candidate.get_instance_id()] = {"first": first, "until": maxf(first, progress - ROUTE_SAMPLE_SPACING), "blocked": progress}
			return false
		progress += ROUTE_SAMPLE_SPACING
	validation_cache[candidate.get_instance_id()] = {"first": first, "until": last}
	if not _spawn_pose_is_clear(candidate, last, 2.0):
		validation_cache[candidate.get_instance_id()]["blocked"] = last
		validation_cache[candidate.get_instance_id()]["until"] = maxf(first, last - ROUTE_SAMPLE_SPACING)
		return false
	return true


func _find_safe_spawn_progress(candidate_route: RoutePath, minimum_goal_distance: float) -> float:
	var latest_start := candidate_route.length - minimum_goal_distance \
		- ROUTE_ENDPOINT_CLEARANCE * 0.5
	var earliest_start := minf(ROUTE_ENDPOINT_CLEARANCE, candidate_route.length * 0.1)
	if candidate_route.get("usable_start") != null:
		earliest_start = float(candidate_route.get("usable_start")) + ROUTE_ENDPOINT_CLEARANCE
		latest_start = float(candidate_route.get("usable_end")) - minimum_goal_distance - ROUTE_ENDPOINT_CLEARANCE * 0.5
	if latest_start < earliest_start:
		return -1.0
	for sample_index in range(16):
		var progress := earliest_start + float(sample_index) * SPAWN_SAMPLE_SPACING
		if progress > latest_start:
			break
		if _spawn_pose_is_clear(candidate_route, progress):
			return progress
	return -1.0


func _spawn_pose_is_clear(candidate_route: RoutePath, progress: float, margin: float = SPAWN_BODY_MARGIN) -> bool:
	var body := ego.get_node("CollisionShape2D") as CollisionShape2D
	var vehicle_shape := body.shape as RectangleShape2D
	if vehicle_shape == null:
		return false
	var half_width := candidate_route.get_half_width_at(progress)
	var lane_offset := _lane_center_offset_for_route(candidate_route, progress)
	if half_width - absf(lane_offset) < vehicle_shape.size.x * 0.5 + margin:
		return false
	var space := ego.get_world_2d().direct_space_state
	var position := candidate_route.get_position_at(progress, lane_offset)
	var key := "%s:%s" % [str(vehicle_shape.size), str(margin)]
	if not clearance_queries.has(key):
		clearance_queries[key] = CLEARANCE.new(vehicle_shape.size, margin)
	var clearance: RefCounted = clearance_queries[key]
	return clearance.is_clear(space, position, candidate_route.get_rotation_at(progress))


func _get_route_state() -> Dictionary:
	var nearest: Dictionary = route.nearest(ego.global_position, last_progress, PROGRESS_WINDOW, true)
	var progress := float(nearest["progress"])
	var center: Vector2 = route.get_position_at(progress)
	var direction: Vector2 = route.get_direction_at(progress)
	if route.has_method("get_driving_direction"):
		direction = route.call("get_driving_direction", progress)
	var normal: Vector2 = route.get_normal_at(progress)
	var lateral_offset := (ego.global_position - center).dot(normal)
	var target_lane_offset := _lane_center_offset_at(progress)
	return {
		"progress": progress,
		"lateral_offset": lateral_offset,
		"lane_error": lateral_offset - target_lane_offset,
		"heading_error": direction.angle_to(Vector2.UP.rotated(ego.global_rotation)),
		"half_width": route.get_half_width_at(progress)
	}


func _lane_center_offset_at(progress: float) -> float:
	return _lane_center_offset_for_route(route, progress)


func _lane_center_offset_for_route(candidate_route: RoutePath, progress: float) -> float:
	if candidate_route.has_method("get_driving_offset"):
		return float(candidate_route.call("get_driving_offset", progress))
	var half_width := candidate_route.get_half_width_at(progress)
	var nominal_lane_width := candidate_route.lane_width
	# Keep the ego in its direction's half of narrow local roads while matching
	# the existing lane-center offset on the wider arterial.
	return minf(nominal_lane_width * 0.5, half_width * 0.5)


func _get_observation() -> Array[float]:
	var result: Array[float] = []
	if route == null or not route.is_valid():
		result.resize(OBSERVATION_SIZE)
		result.fill(0.0)
		return result
	var state := _get_route_state()
	var sensors: Node = ego.get_node("SensorRig")
	for distance in sensors.call("get_observation"):
		result.append(clampf(float(distance), 0.0, 1.0))
	result.append(clampf(float(ego.get("current_speed")) / base_max_speed, -1.0, 1.0))
	result.append(clampf(float(ego.get("steering_input")), -1.0, 1.0))
	result.append(clampf(float(state["heading_error"]) / PI, -1.0, 1.0))
	result.append(clampf(float(state["lane_error"]) / route.lane_width, -1.0, 1.0))
	var segmented := bool(road_generator.call("uses_segmented_generation")) if road_generator.has_method("uses_segmented_generation") else road_generator.has_method("get_piece_count")
	var goal_scale := 24000.0 if segmented else MAX_GOAL_DISTANCE
	result.append(clampf((goal_progress - float(state["progress"])) / goal_scale, -1.0, 1.0))
	for lookahead in ROAD_PREVIEW_DISTANCES:
		var preview_progress := minf(float(state["progress"]) + lookahead, goal_progress)
		var lane_offset := _lane_center_offset_at(preview_progress)
		var preview_point: Vector2 = route.get_position_at(preview_progress, lane_offset)
		var local_point: Vector2 = ego.to_local(preview_point)
		result.append(clampf(local_point.x / ROAD_PREVIEW_DISTANCES[-1], -1.0, 1.0))
		result.append(clampf(-local_point.y / ROAD_PREVIEW_DISTANCES[-1], -1.0, 1.0))
	for lookahead in ROAD_PREVIEW_DISTANCES:
		var preview_progress := minf(float(state["progress"]) + lookahead, goal_progress)
		var max_half_width := float(road_generator.get("maximum_road_width")) * 0.5
		result.append(clampf(route.get_half_width_at(preview_progress) / maxf(max_half_width, 1.0), 0.0, 1.0))
	# Signal observation slots are reserved so the PPO model shape remains
	# stable. Setup 1 has no signals; a later curriculum stage fills these in.
	result.append_array([0.0, 0.0, 0.0, 0.0, 1.0])
	return result
