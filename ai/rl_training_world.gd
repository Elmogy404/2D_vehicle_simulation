extends Node2D

const ROAD_SCENE := preload("res://scenes/RoadGenerator.tscn")
const EGO_SCENE := preload("res://scenes/EgoVehicle.tscn")
const ACTION_REPEAT := 4
const MAX_EPISODE_STEPS := 1800
const MAX_GOAL_DISTANCE := 6000.0
const ROUTE_ENDPOINT_CLEARANCE := 80.0
const SPAWN_ROUTE_ATTEMPTS := 12
const SPAWN_SAMPLE_SPACING := 40.0
const SPAWN_BODY_MARGIN := 10.0
const GOAL_DISTANCE_STAGES := [
	Vector2(250.0, 400.0),
	Vector2(400.0, 650.0),
	Vector2(600.0, 900.0),
	Vector2(800.0, 1200.0),
	Vector2(1200.0, 1800.0),
	Vector2(1800.0, 2700.0),
	Vector2(2700.0, 4000.0),
	Vector2(4200.0, 5500.0),
]
const CURRICULUM_WINDOW := 20
const CURRICULUM_ADVANCE_RATE := 0.8
const GOAL_RADIUS := 85.0
const ROAD_PREVIEW_DISTANCES := [60.0, 120.0, 240.0, 400.0]
const OBSERVATION_SIZE := 31
const DEFAULT_REWARD_CONFIG := {
	"progress_gain": 1.0,
	"max_speed_reward": 0.05,
	"lane_penalty": 0.12,
	"edge_penalty": 0.6,
	"heading_penalty": 0.08,
	"step_penalty": 0.01,
	"crash_penalty": 35.0,
	"off_road_penalty": 35.0,
	"goal_reward": 40.0,
	"timeout_penalty": 20.0,
}

var road_generator: Node
var ego: CharacterBody2D
var tcp_peer := StreamPeerTCP.new()
var tcp_port := 8765
var input_buffer := PackedByteArray()
var pending_lines: Array[String] = []
var request_busy := false

var route: RoutePath
var goal_position := Vector2.ZERO
var start_progress := 0.0
var goal_progress := 0.0
var last_progress := 0.0
var episode_steps := 0
var episode_active := false
var step_in_progress := false
var current_action := Vector2.ZERO
var episode_rng := RandomNumberGenerator.new()
var curriculum_stage := 0
var active_episode_stage := 0
var curriculum_enabled := true
var curriculum_recent_results: Array[bool] = []
var episode_goal_distance := 0.0
var episode_route_turns := 0
var episode_turn_requirement_met := true
var visible_mode := false
var reward_config: Dictionary = DEFAULT_REWARD_CONFIG.duplicate()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_parse_port_argument()
	_setup_training_world()
	visible_mode = OS.get_cmdline_user_args().has("--visible")
	if visible_mode:
		_setup_monitor_hud()
	get_tree().paused = true
	var connect_error := tcp_peer.connect_to_host("127.0.0.1", tcp_port)
	if connect_error != OK:
		push_error("PPO bridge: could not start TCP connection (%s)." % connect_error)


func _parse_port_argument() -> void:
	var arguments := OS.get_cmdline_user_args()
	for argument_index in range(arguments.size()):
		if arguments[argument_index] == "--port" \
		and argument_index + 1 < arguments.size():
			tcp_port = clampi(int(arguments[argument_index + 1]), 1024, 65535)
		elif arguments[argument_index].begins_with("--port="):
			tcp_port = clampi(int(arguments[argument_index].trim_prefix("--port=")), 1024, 65535)


func _setup_training_world() -> void:
	road_generator = ROAD_SCENE.instantiate()
	road_generator.set("enable_hotkeys", false)
	# Setup 2 trains on the complete connected district instead of the arterial
	# alone. Longer arterials and several collector/local corridors make 5,000+
	# unit routes with multiple junction turns available to the planner.
	road_generator.set("minimum_map_length", 9000.0)
	road_generator.set("maximum_map_length", 12000.0)
	road_generator.set("minimum_intersections", 6)
	road_generator.set("maximum_intersections", 9)
	road_generator.set("minimum_corridors_per_side", 2)
	road_generator.set("maximum_corridors_per_side", 3)
	add_child(road_generator)

	ego = EGO_SCENE.instantiate() as CharacterBody2D
	add_child(ego)
	var sensor_rig: Node = ego.get_node("SensorRig")
	sensor_rig.set("show_rays", false)
	ego.use_default_controller()


func _setup_monitor_hud() -> void:
	var speed_hud := CanvasLayer.new()
	speed_hud.name = "SpeedHud"
	speed_hud.set_script(load("res://scripts/speed_hud.gd"))
	add_child(speed_hud)

	var map_hud := CanvasLayer.new()
	map_hud.name = "Minimap"
	map_hud.set_script(load("res://scripts/minimap.gd"))
	add_child(map_hud)


func _process(_delta: float) -> void:
	tcp_peer.poll()
	if tcp_peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		var available_bytes := tcp_peer.get_available_bytes()
		if available_bytes > 0:
			var received: Array = tcp_peer.get_data(available_bytes)
			if received[0] == OK:
				input_buffer.append_array(received[1])
				_extract_complete_lines()

	if not request_busy and not pending_lines.is_empty():
		request_busy = true
		_handle_request(pending_lines.pop_front())


func _extract_complete_lines() -> void:
	var newline_index := input_buffer.find(10)
	while newline_index >= 0:
		var line := input_buffer.slice(0, newline_index).get_string_from_utf8()
		input_buffer = input_buffer.slice(newline_index + 1)
		if not line.is_empty():
			pending_lines.append(line)
		newline_index = input_buffer.find(10)


func _handle_request(line: String) -> void:
	var parsed: Variant = JSON.parse_string(line)
	if typeof(parsed) != TYPE_DICTIONARY:
		_send_message({"error": "request must be a JSON object"})
		request_busy = false
		return

	var message: Dictionary = parsed
	match String(message.get("type", "")):
		"reset":
			var options_value: Variant = message.get("options", {})
			var reset_options: Dictionary = options_value if options_value is Dictionary else {}
			var reward_error := _set_reward_config(reset_options.get("reward_config", {}))
			if not reward_error.is_empty():
				_send_message({"error": reward_error})
				request_busy = false
				return
			var requested_stage := int(reset_options.get("curriculum_stage", -1))
			var use_curriculum := bool(reset_options.get("curriculum", true))
			var reset_error: String = await _reset_episode(
				int(message.get("seed", 1)),
				use_curriculum,
				requested_stage
			)
			if not reset_error.is_empty():
				get_tree().paused = true
				_send_message({"error": reset_error})
				request_busy = false
				return
			get_tree().paused = true
			_send_message({
				"observation": _get_observation(),
				"info": {
					"seed": int(road_generator.get("seed_value")),
					"start_progress": start_progress,
					"goal_progress": goal_progress,
					"goal_distance": episode_goal_distance,
					"spawn_clear": true,
					"curriculum_stage": active_episode_stage,
					"route_turns": episode_route_turns,
					"turn_requirement_met": episode_turn_requirement_met
				}
			})
		"step":
			await _step_episode(message.get("action", []))
		"close":
			_send_message({"closed": true})
			request_busy = false
			if not visible_mode:
				get_tree().quit()
			return
		_:
			_send_message({"error": "unknown request type"})
	request_busy = false


func _set_reward_config(value: Variant) -> String:
	if not value is Dictionary:
		return "reward_config must be an object"
	var supplied: Dictionary = value
	reward_config = DEFAULT_REWARD_CONFIG.duplicate()
	for key in supplied:
		if not reward_config.has(key):
			return "unknown reward setting: %s" % String(key)
		if typeof(supplied[key]) != TYPE_FLOAT and typeof(supplied[key]) != TYPE_INT:
			return "reward setting %s must be numeric" % String(key)
		var numeric := float(supplied[key])
		if is_nan(numeric) or is_inf(numeric) or numeric < 0.0 or numeric > 1000.0:
			return "reward setting %s must be finite and between 0 and 1000" % String(key)
		reward_config[key] = numeric
	return ""


func _reset_episode(
	new_seed: int,
	use_curriculum: bool = true,
	requested_stage: int = -1
) -> String:
	get_tree().paused = false
	episode_active = false
	step_in_progress = false
	current_action = Vector2.ZERO
	episode_steps = 0
	curriculum_enabled = use_curriculum and requested_stage < 0
	if requested_stage >= 0:
		curriculum_stage = clampi(requested_stage, 0, GOAL_DISTANCE_STAGES.size() - 1)
	elif not curriculum_enabled:
		curriculum_stage = 0
	active_episode_stage = curriculum_stage
	road_generator.call("generate_with_seed", new_seed)
	await get_tree().physics_frame
	episode_rng.seed = posmod(new_seed ^ 0x5EED123, 2147483647)
	var goal_range: Vector2 = GOAL_DISTANCE_STAGES[active_episode_stage]
	var network: Object = road_generator.call("get_road_network")
	var route_data: Dictionary = {}
	var valid_start := -1.0
	for _attempt in range(SPAWN_ROUTE_ATTEMPTS):
		var candidate_data: Dictionary = network.call(
			"choose_random_route",
			goal_range.x + ROUTE_ENDPOINT_CLEARANCE * 2.0,
			goal_range.y + ROUTE_ENDPOINT_CLEARANCE * 3.0,
			_minimum_turns_for_stage(active_episode_stage),
			episode_rng
		)
		if candidate_data.is_empty():
			continue
		var candidate_route := RoutePath.new()
		candidate_route.build(
			candidate_data["points"],
			candidate_data["half_widths"],
			PackedFloat32Array(),
			float(road_generator.get("lane_width"))
		)
		if not candidate_route.is_valid():
			continue
		var candidate_start := _find_safe_spawn_progress(candidate_route, goal_range.x)
		if candidate_start < 0.0:
			continue
		route = candidate_route
		route_data = candidate_data
		valid_start = candidate_start
		break
	if valid_start < 0.0:
		return "no collision-free spawn was found for seed %d at curriculum stage %d" % [
			new_seed, active_episode_stage
		]
	episode_route_turns = int(route_data["turns"])
	episode_turn_requirement_met = bool(route_data["turn_requirement_met"])
	start_progress = valid_start
	var available_goal_distance := route.length - start_progress - ROUTE_ENDPOINT_CLEARANCE * 0.5
	var maximum_goal_distance := minf(goal_range.y, available_goal_distance)
	if maximum_goal_distance < goal_range.x:
		return "route planner returned a route shorter than curriculum stage %d" % active_episode_stage
	episode_goal_distance = episode_rng.randf_range(goal_range.x, maximum_goal_distance)
	goal_progress = start_progress + episode_goal_distance
	var lane_offset := _lane_center_offset_at(start_progress)
	var goal_lane_offset := _lane_center_offset_at(goal_progress)
	goal_position = route.get_position_at(goal_progress, goal_lane_offset)
	last_progress = start_progress
	ego.reset_vehicle()
	ego.global_position = route.get_position_at(start_progress, lane_offset)
	ego.global_rotation = route.get_rotation_at(start_progress)
	ego.set_control(0.0, 0.0, 0.0)
	await get_tree().physics_frame
	if bool(ego.get("has_crashed")) or not _spawn_pose_is_clear(route, start_progress):
		return "selected spawn became obstructed for seed %d" % new_seed
	var sensors: Node = ego.get_node("SensorRig")
	sensors.call("update_sensors")
	episode_active = true
	queue_redraw()
	return ""


func _find_safe_spawn_progress(candidate_route: RoutePath, minimum_goal_distance: float) -> float:
	var latest_start := candidate_route.length - minimum_goal_distance \
		- ROUTE_ENDPOINT_CLEARANCE * 0.5
	var earliest_start := minf(ROUTE_ENDPOINT_CLEARANCE, candidate_route.length * 0.1)
	if latest_start < earliest_start:
		return -1.0
	for sample_index in range(16):
		var progress := earliest_start + float(sample_index) * SPAWN_SAMPLE_SPACING
		if progress > latest_start:
			break
		if _spawn_pose_is_clear(candidate_route, progress):
			return progress
	return -1.0


func _spawn_pose_is_clear(candidate_route: RoutePath, progress: float) -> bool:
	var body := ego.get_node("CollisionShape2D") as CollisionShape2D
	var vehicle_shape := body.shape as RectangleShape2D
	if vehicle_shape == null:
		return false
	var half_width := candidate_route.get_half_width_at(progress)
	var lane_offset := _lane_center_offset_for_route(candidate_route, progress)
	if half_width - absf(lane_offset) < vehicle_shape.size.x * 0.5 + SPAWN_BODY_MARGIN:
		return false
	var clearance_shape := RectangleShape2D.new()
	clearance_shape.size = vehicle_shape.size + Vector2.ONE * SPAWN_BODY_MARGIN * 2.0
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = clearance_shape
	query.collision_mask = 1
	query.collide_with_areas = false
	query.exclude = [ego.get_rid()]
	var space := get_world_2d().direct_space_state
	var position := candidate_route.get_position_at(progress, lane_offset)
	query.transform = Transform2D(candidate_route.get_rotation_at(progress), position)
	return space.intersect_shape(query, 1).is_empty()


func _step_episode(action_value: Variant) -> void:
	if not episode_active:
		_send_message({"error": "reset must be called before step"})
		return
	if not action_value is Array or action_value.size() != 2:
		_send_message({"error": "action must be [steering, signed_acceleration]"})
		return
	current_action = Vector2(
		clampf(float(action_value[0]), -1.0, 1.0),
		clampf(float(action_value[1]), -1.0, 1.0)
	)
	step_in_progress = true
	get_tree().paused = false
	for _frame in range(ACTION_REPEAT):
		await get_tree().physics_frame
	step_in_progress = false
	episode_steps += 1

	var state := _get_route_state()
	var current_progress: float = state["progress"]
	var progress_delta := current_progress - last_progress
	var lane_error: float = state["lane_error"]
	var lane_error_ratio := absf(lane_error) / maxf(route.lane_width, 1.0)
	var vehicle_half_width := float(ego.get("vehicle_width")) * 0.5
	var safe_half_width := maxf(
		float(state["half_width"]) - vehicle_half_width,
		1.0
	)
	var edge_ratio := absf(float(state["lateral_offset"])) / safe_half_width
	var edge_pressure := clampf((edge_ratio - 0.55) / 0.45, 0.0, 1.0)
	var heading_ratio := clampf(absf(float(state["heading_error"])) / (PI * 0.5), 0.0, 1.0)
	# Progress shaping is intentionally bounded: completing the route must be
	# worth more than accumulating distance before leaving the pavement.
	var reward := float(reward_config["progress_gain"]) * clampf(progress_delta / 100.0, -0.25, 0.5)
	reward -= float(reward_config["lane_penalty"]) * pow(minf(lane_error_ratio, 2.0), 2.0)
	reward -= float(reward_config["edge_penalty"]) * pow(edge_pressure, 2.0)
	reward -= float(reward_config["heading_penalty"]) * pow(heading_ratio, 2.0)
	reward -= float(reward_config["step_penalty"])

	var terminated := false
	var truncated := false
	var success := false
	var off_road := absf(float(state["lateral_offset"])) \
		> float(state["half_width"]) - float(ego.get("vehicle_width")) * 0.5
	if bool(ego.get("has_crashed")):
		reward -= float(reward_config["crash_penalty"])
		terminated = true
	elif off_road:
		reward -= float(reward_config["off_road_penalty"])
		terminated = true
	elif ego.global_position.distance_to(goal_position) <= GOAL_RADIUS:
		reward += float(reward_config["goal_reward"])
		terminated = true
		success = true
	elif episode_steps >= MAX_EPISODE_STEPS:
		reward -= float(reward_config["timeout_penalty"])
		truncated = true
	if not terminated and not truncated:
		reward += _max_speed_bonus(progress_delta, off_road)

	last_progress = current_progress
	if terminated or truncated:
		_record_curriculum_outcome(success)
		episode_active = false
		current_action = Vector2.ZERO
		ego.set_control(0.0, 0.0, 0.0)
	var observation := _get_observation()
	get_tree().paused = true
	_send_message({
		"observation": observation,
		"reward": reward,
		"terminated": terminated,
		"truncated": truncated,
		"info": {
			"success": success,
			"crashed": bool(ego.get("has_crashed")),
			"off_road": off_road,
			"progress": current_progress,
			"goal_progress": goal_progress,
			"goal_distance": episode_goal_distance,
			"curriculum_stage": active_episode_stage,
			"route_turns": episode_route_turns,
			"turn_requirement_met": episode_turn_requirement_met,
			"episode_steps": episode_steps
		}
	})


func _max_speed_bonus(progress_delta: float, off_road: bool) -> float:
	# A small per-step bonus for forward driving at (or very near) the speed
	# limiter. Do not pay it for crashes, leaving the road, or stationary spins.
	if ego == null or off_road or bool(ego.get("has_crashed")) or progress_delta <= 0.0:
		return 0.0
	var speed_limit := float(ego.get("max_speed"))
	if speed_limit <= 0.0 or float(ego.get("current_speed")) < speed_limit * 0.98:
		return 0.0
	return float(reward_config["max_speed_reward"])


func _record_curriculum_outcome(success: bool) -> void:
	if not curriculum_enabled or curriculum_stage >= GOAL_DISTANCE_STAGES.size() - 1:
		return
	curriculum_recent_results.append(success)
	if curriculum_recent_results.size() > CURRICULUM_WINDOW:
		curriculum_recent_results.pop_front()
	if curriculum_recent_results.size() < CURRICULUM_WINDOW:
		return
	var successes := 0
	for result in curriculum_recent_results:
		if result:
			successes += 1
	var success_rate := float(successes) / float(curriculum_recent_results.size())
	if success_rate >= CURRICULUM_ADVANCE_RATE:
		curriculum_stage += 1
		curriculum_recent_results.clear()
		print(
			"[PPO curriculum] advanced to stage %d after %.0f%% success over %d episodes"
			% [curriculum_stage, success_rate * 100.0, CURRICULUM_WINDOW]
		)


func _physics_process(_delta: float) -> void:
	if not step_in_progress or not episode_active:
		return
	var steering := current_action.x
	var throttle := maxf(current_action.y, 0.0)
	var brake := maxf(-current_action.y, 0.0)
	# EgoVehicle's brake pedal selects reverse after stopping. Setup 1 is
	# forward-only, so release the brake at standstill instead of reversing.
	if float(ego.get("current_speed")) <= float(ego.get("direction_change_threshold")):
		brake = 0.0
	ego.set_control(throttle, brake, steering)


func _get_route_state() -> Dictionary:
	var nearest: Dictionary = route.nearest(ego.global_position, last_progress, 1800.0)
	var progress := float(nearest["progress"])
	var center: Vector2 = route.get_position_at(progress)
	var direction: Vector2 = route.get_direction_at(progress)
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


func _minimum_turns_for_stage(stage: int) -> int:
	if stage >= 7:
		return 4
	if stage >= 6:
		return 3
	if stage >= 5:
		return 2
	if stage >= 3:
		return 1
	return 0


func _lane_center_offset_at(progress: float) -> float:
	return _lane_center_offset_for_route(route, progress)


func _lane_center_offset_for_route(candidate_route: RoutePath, progress: float) -> float:
	var half_width := candidate_route.get_half_width_at(progress)
	var nominal_lane_width := float(road_generator.get("lane_width"))
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
	result.append(clampf(float(ego.get("current_speed")) / float(ego.get("max_speed")), -1.0, 1.0))
	result.append(clampf(float(ego.get("steering_input")), -1.0, 1.0))
	result.append(clampf(float(state["heading_error"]) / PI, -1.0, 1.0))
	result.append(clampf(float(state["lane_error"]) / route.lane_width, -1.0, 1.0))
	result.append(clampf((goal_progress - float(state["progress"])) / MAX_GOAL_DISTANCE, -1.0, 1.0))
	for lookahead in ROAD_PREVIEW_DISTANCES:
		var preview_progress := minf(float(state["progress"]) + lookahead, route.length)
		var lane_offset := _lane_center_offset_at(preview_progress)
		var preview_point: Vector2 = route.get_position_at(preview_progress, lane_offset)
		var local_point: Vector2 = ego.to_local(preview_point)
		result.append(clampf(local_point.x / ROAD_PREVIEW_DISTANCES[-1], -1.0, 1.0))
		result.append(clampf(-local_point.y / ROAD_PREVIEW_DISTANCES[-1], -1.0, 1.0))
	for lookahead in ROAD_PREVIEW_DISTANCES:
		var preview_progress := minf(float(state["progress"]) + lookahead, route.length)
		var max_half_width := float(road_generator.get("maximum_road_width")) * 0.5
		result.append(clampf(route.get_half_width_at(preview_progress) / maxf(max_half_width, 1.0), 0.0, 1.0))
	# Signal observation slots are reserved so the PPO model shape remains
	# stable. Setup 1 has no signals; a later curriculum stage fills these in.
	result.append_array([0.0, 0.0, 0.0, 0.0, 1.0])
	return result


func _send_message(message: Dictionary) -> void:
	if tcp_peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	tcp_peer.put_data((JSON.stringify(message) + "\n").to_utf8_buffer())


func _unhandled_input(event: InputEvent) -> void:
	if visible_mode and event is InputEventKey and event.pressed \
	and not event.echo and event.keycode == KEY_ESCAPE:
		get_tree().quit()


func _draw() -> void:
	if not visible_mode or route == null or not route.is_valid():
		return
	# A visible target makes it easy to verify the route-following objective.
	draw_circle(goal_position, GOAL_RADIUS, Color(0.12, 0.9, 0.35, 0.2))
	draw_arc(goal_position, GOAL_RADIUS, 0.0, TAU, 48, Color(0.2, 1.0, 0.48, 0.95), 4.0)
