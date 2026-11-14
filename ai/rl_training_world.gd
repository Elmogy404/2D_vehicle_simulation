extends Node2D

const ROAD_SCENE := preload("res://scenes/RoadGenerator.tscn")
const EGO_SCENE := preload("res://scenes/EgoVehicle.tscn")
const DRIVING_TASK = preload("res://scripts/driving_task.gd")
var driving_task := DRIVING_TASK.new()
const SEGMENTED_GENERATOR = preload("res://scripts/segment_road_generator.gd")
var generator_type := "original"
const ACTION_REPEAT := 4
const MAX_EPISODE_STEPS := 1800
const SPAWN_BODY_MARGIN := 10.0
const MAP_ATTEMPTS := 32

signal action_completed
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
const SEGMENTED_GOAL_STAGES := [
	Vector2(250.0, 400.0), Vector2(400.0, 650.0), Vector2(600.0, 900.0),
	Vector2(800.0, 1200.0), Vector2(3000.0, 5500.0),
	Vector2(8000.0, 12000.0), Vector2(12000.0, 16000.0), Vector2(16000.0, 22000.0),
]
const CURRICULUM_WINDOW := 20
const CURRICULUM_ADVANCE_RATE := 0.8
const GOAL_RADIUS := 85.0
const OBSERVATION_SIZE := 31
static var DEFAULT_REWARD_CONFIG: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://ai/training_defaults.json"))["reward_config"]

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
var remaining_physics_ticks := 0
var episode_physics_ticks := 0
var furthest_progress := 0.0
var idle_steps := 0
var idle_anchor := 0.0
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
var owned_training_view := false
var embedded_training_view := false
var reward_config: Dictionary = DEFAULT_REWARD_CONFIG.duplicate()
var trip_rejections: Dictionary = {}
var episode_map_attempts := 0
var map_episodes := 0
var validation_cache: Dictionary = {}
var turn_level := 0
var base_max_speed := 500.0
var episode_reset_ms := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_parse_port_argument()
	visible_mode = OS.get_cmdline_user_args().has("--visible")
	owned_training_view = OS.get_cmdline_user_args().has("--owned-training-view")
	embedded_training_view = OS.get_cmdline_user_args().has("--embedded-training-view")
	_setup_training_world()
	if visible_mode and not embedded_training_view:
		_setup_monitor_hud()
	# Static worlds keep running; only this node advances the car, and only
	# while a requested action is pending. Pausing at physics_frame signals
	# races with the actual vehicle update and changes action duration.
	get_tree().paused = false
	var connect_error := tcp_peer.connect_to_host("127.0.0.1", tcp_port)
	tcp_peer.set_no_delay(true)
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
	road_generator.set("generate_on_ready", false)
	road_generator.set("build_visuals", visible_mode)
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
	ego.set_physics_process(false)
	base_max_speed = float(ego.get("max_speed"))
	if not visible_mode:
		ego.get_node("Camera2D").set_process(false)
	var sensor_rig: Node = ego.get_node("SensorRig")
	sensor_rig.set("show_rays", false)
	sensor_rig.set_physics_process(false)
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
	# Accelerated worlds otherwise spin at full CPU while PPO updates weights.
	if not step_in_progress and pending_lines.is_empty():
		OS.delay_usec(500)
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
			var selected_generator := String(reset_options.get("generator_type", "original"))
			if selected_generator not in ["original", "segmented"]:
				_send_message({"error": "generator_type must be original or segmented"})
				request_busy = false
				return
			_set_generator_type(selected_generator)
			var reward_error := _set_reward_config(reset_options.get("reward_config", {}))
			if not reward_error.is_empty():
				_send_message({"error": reward_error})
				request_busy = false
				return
			var requested_stage := int(reset_options.get("curriculum_stage", -1))
			var use_curriculum := bool(reset_options.get("curriculum", true))
			if reset_options.has("training_state"):
				_restore_training_state(reset_options["training_state"])
			var reset_error: String = await _reset_episode(
				int(message.get("seed", 1)),
				use_curriculum,
				requested_stage,
				bool(reset_options.get("reuse_map", false))
			)
			if not reset_error.is_empty():
				_send_message({"error": reset_error, "recoverable_reset": true})
				request_busy = false
				return
			_send_message({
				"observation": _get_observation(),
				"info": {
					"seed": int(road_generator.get("seed_value")),
					"requested_seed": int(message.get("seed", 1)),
					"map_attempts": episode_map_attempts,
					"reset_ms": episode_reset_ms,
					"map_reused": map_episodes > 1,
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
		"training_state":
			_send_message(_training_state())
		"close":
			_send_message({"closed": true})
			request_busy = false
			if not visible_mode or owned_training_view:
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


func _set_generator_type(selected: String) -> void:
	if selected == generator_type:
		return
	if road_generator != null:
		remove_child(road_generator)
		road_generator.queue_free()
	generator_type = selected
	if selected == "segmented":
		road_generator = SEGMENTED_GENERATOR.new()
		road_generator.set("generate_on_ready", false)
	else:
		road_generator = ROAD_SCENE.instantiate()
		road_generator.set("generate_on_ready", false)
		road_generator.set("enable_hotkeys", false)
		road_generator.set("build_visuals", visible_mode)
		road_generator.set("minimum_map_length", 9000.0)
		road_generator.set("maximum_map_length", 12000.0)
		road_generator.set("minimum_intersections", 6)
		road_generator.set("maximum_intersections", 9)
		road_generator.set("minimum_corridors_per_side", 2)
		road_generator.set("maximum_corridors_per_side", 3)
	add_child(road_generator)
	map_episodes = 0
	validation_cache.clear()


func _reset_episode(
	new_seed: int,
	use_curriculum: bool = true,
	requested_stage: int = -1,
	reuse_map: bool = false
) -> String:
	var reset_started := Time.get_ticks_usec()
	get_tree().paused = false
	episode_active = false
	step_in_progress = false
	current_action = Vector2.ZERO
	episode_steps = 0
	episode_physics_ticks = 0
	idle_steps = 0
	curriculum_enabled = use_curriculum and requested_stage < 0
	if requested_stage >= 0:
		active_episode_stage = clampi(requested_stage, 0, GOAL_DISTANCE_STAGES.size() - 1)
	else:
		active_episode_stage = curriculum_stage if curriculum_enabled else 0
	episode_rng.seed = posmod(new_seed ^ 0x5EED123, 2147483647)
	if curriculum_enabled and curriculum_stage >= 3 and episode_rng.randf() < 0.2:
		active_episode_stage = maxi(0, curriculum_stage - episode_rng.randi_range(1, 2))
	var speed_caps := [150.0, 250.0, base_max_speed]
	var cap: float = speed_caps[turn_level] if curriculum_enabled and active_episode_stage == 3 else base_max_speed
	ego.set("max_speed", cap)
	var goal_range: Vector2 = GOAL_DISTANCE_STAGES[active_episode_stage]
	if generator_type == "segmented":
		# Authored city blocks are 3,900–5,300 units long. Multi-turn trips
		# need longer goals than the original compact district curriculum.
		goal_range = SEGMENTED_GOAL_STAGES[active_episode_stage]
	var valid_start := -1.0
	var selected_goal := -1.0
	var cached_selection: Dictionary = {}
	episode_map_attempts = 0
	if reuse_map and map_episodes > 0 and map_episodes < 8:
		cached_selection = _select_trip(goal_range)
	if not cached_selection.is_empty():
		valid_start = float(cached_selection["start"])
		selected_goal = float(cached_selection["goal"])
		map_episodes += 1
	for map_attempt in range(MAP_ATTEMPTS if valid_start < 0.0 else 0):
		episode_map_attempts = map_attempt + 1
		validation_cache.clear()
		road_generator.call("generate_with_seed", new_seed + map_attempt * 104729)
		await get_tree().physics_frame
		await get_tree().physics_frame
		var selection := _select_trip(goal_range)
		if not selection.is_empty():
			valid_start = float(selection["start"])
			selected_goal = float(selection["goal"])
			map_episodes = 1
			break
	if valid_start < 0.0:
		return "no collision-free trip was found for seed %d at curriculum stage %d: %s" % [new_seed, active_episode_stage, trip_rejections]
	start_progress = valid_start
	goal_progress = selected_goal
	episode_goal_distance = goal_progress - start_progress
	episode_route_turns = _count_trip_turns(route, start_progress, goal_progress)
	episode_turn_requirement_met = episode_route_turns >= _minimum_turns_for_stage(active_episode_stage)
	goal_position = route.get_position_at(goal_progress, _lane_center_offset_at(goal_progress))
	last_progress = start_progress
	furthest_progress = start_progress
	idle_anchor = start_progress
	ego.reset_vehicle()
	ego.global_position = route.get_position_at(start_progress, _lane_center_offset_at(start_progress))
	ego.global_rotation = route.get_rotation_at(start_progress)
	ego.set_control(0.0, 0.0, 0.0)
	var sensors: Node = ego.get_node("SensorRig")
	sensors.call("update_sensors")
	episode_active = true
	episode_reset_ms = float(Time.get_ticks_usec() - reset_started) / 1000.0
	queue_redraw()
	return ""


func _select_trip(goal_range: Vector2) -> Dictionary:
	driving_task.ego = ego
	driving_task.road_generator = road_generator
	driving_task.episode_rng = episode_rng
	driving_task.minimum_turns = _minimum_turns_for_stage(active_episode_stage)
	driving_task.validation_cache = validation_cache
	var selection := driving_task._select_trip(goal_range)
	trip_rejections = driving_task.trip_rejections
	route = driving_task.route
	return selection


func _count_trip_turns(candidate: RoutePath, first: float, last: float) -> int:
	driving_task.ego = ego
	driving_task.road_generator = road_generator
	driving_task.route = route
	return driving_task._count_trip_turns(candidate, first, last)


func _trip_is_clear(candidate: RoutePath, first: float, last: float) -> bool:
	driving_task.ego = ego
	driving_task.road_generator = road_generator
	driving_task.route = route
	return driving_task._trip_is_clear(candidate, first, last)


func _find_safe_spawn_progress(candidate_route: RoutePath, minimum_goal_distance: float) -> float:
	driving_task.ego = ego
	driving_task.road_generator = road_generator
	driving_task.route = route
	return driving_task._find_safe_spawn_progress(candidate_route, minimum_goal_distance)


func _spawn_pose_is_clear(candidate_route: RoutePath, progress: float, margin: float = SPAWN_BODY_MARGIN) -> bool:
	driving_task.ego = ego
	driving_task.road_generator = road_generator
	driving_task.route = route
	return driving_task._spawn_pose_is_clear(candidate_route, progress, margin)


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
	remaining_physics_ticks = ACTION_REPEAT
	step_in_progress = true
	await action_completed
	ego.get_node("SensorRig").call("update_sensors")
	episode_steps += 1

	var state := _get_route_state()
	var current_progress: float = state["progress"]
	var progress_delta := current_progress - last_progress
	var new_progress := maxf(0.0, current_progress - furthest_progress)
	furthest_progress = maxf(furthest_progress, current_progress)
	if furthest_progress >= idle_anchor + 2.0:
		idle_steps = 0
		idle_anchor = furthest_progress
	else:
		idle_steps += 1
	var lane_error: float = state["lane_error"]
	var lane_error_ratio := absf(lane_error) / maxf(route.lane_width, 1.0)
	var vehicle_half_width := float(ego.get("vehicle_width")) * 0.5
	var safe_half_width := maxf(
		float(state["half_width"]) - vehicle_half_width,
		1.0
	)
	var edge_pressure := _edge_pressure(float(state["lateral_offset"]), _lane_center_offset_at(current_progress), safe_half_width)
	var heading_ratio := clampf(absf(float(state["heading_error"])) / (PI * 0.5), 0.0, 1.0)
	# Progress shaping is intentionally bounded: completing the route must be
	# worth more than accumulating distance before leaving the pavement.
	var reward := float(reward_config["progress_gain"]) * (clampf(new_progress / 100.0, 0.0, 0.5) + clampf(progress_delta / 100.0, -0.25, 0.0))
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
	elif _goal_reached(current_progress):
		reward += float(reward_config["goal_reward"])
		terminated = true
		success = true
	elif idle_steps >= 150:
		reward -= float(reward_config["timeout_penalty"])
		terminated = true
	elif episode_steps >= MAX_EPISODE_STEPS:
		reward -= float(reward_config["timeout_penalty"])
		truncated = true
	if not terminated and not truncated:
		reward += _max_speed_bonus(new_progress, off_road)

	last_progress = current_progress
	if terminated or truncated:
		_record_curriculum_outcome(success)
		episode_active = false
		current_action = Vector2.ZERO
		ego.set_control(0.0, 0.0, 0.0)
	var observation := _get_observation()
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
			"episode_steps": episode_steps,
			"physics_ticks": episode_physics_ticks,
			"stalled": idle_steps >= 150,
			"speed_kmh": float(ego.get("current_speed")) * 0.3,
			"speed_cap_kmh": float(ego.get("max_speed")) * 0.3,
			"progress_fraction": clampf((current_progress - start_progress) / maxf(episode_goal_distance, 1.0), 0.0, 1.0),
			"reset_ms": episode_reset_ms,
			"map_attempts": episode_map_attempts,
			"map_reused": map_episodes > 1,
			"training_state": _training_state()
		}
	})


func _edge_pressure(lateral_offset: float, target_offset: float, safe_half_width: float) -> float:
	var safe_target := minf(absf(target_offset), maxf(0.0, safe_half_width - 1.0))
	var onset := maxf(safe_target, safe_half_width * 0.7)
	return clampf((absf(lateral_offset) - onset) / maxf(safe_half_width - onset, 1.0), 0.0, 1.0)


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
	if not curriculum_enabled or active_episode_stage != curriculum_stage:
		return
	curriculum_recent_results.append(success)
	if curriculum_recent_results.size() > CURRICULUM_WINDOW:
		curriculum_recent_results.pop_front()
	if curriculum_recent_results.size() < CURRICULUM_WINDOW:
		return
	if curriculum_stage >= GOAL_DISTANCE_STAGES.size() - 1:
		return
	var successes := 0
	for result in curriculum_recent_results:
		if result:
			successes += 1
	var success_rate := float(successes) / float(curriculum_recent_results.size())
	if success_rate >= CURRICULUM_ADVANCE_RATE:
		if curriculum_stage == 3 and turn_level < 2:
			turn_level += 1
		else:
			curriculum_stage += 1
		curriculum_recent_results.clear()
		print(
			"[PPO curriculum] advanced to stage %d after %.0f%% success over %d episodes"
			% [curriculum_stage, success_rate * 100.0, CURRICULUM_WINDOW]
		)


func _physics_process(delta: float) -> void:
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
	ego.call("_physics_process", delta)
	episode_physics_ticks += 1
	remaining_physics_ticks -= 1
	if remaining_physics_ticks == 0:
		step_in_progress = false
		action_completed.emit()


func _goal_reached(progress: float) -> bool:
	return progress >= goal_progress - GOAL_RADIUS and ego.global_position.distance_to(goal_position) <= GOAL_RADIUS


func _training_state() -> Dictionary:
	return {"curriculum_stage": curriculum_stage, "turn_level": turn_level, "recent_results": curriculum_recent_results.duplicate()}


func _restore_training_state(value: Variant) -> void:
	if not value is Dictionary:
		return
	curriculum_stage = clampi(int(value.get("curriculum_stage", 0)), 0, GOAL_DISTANCE_STAGES.size() - 1)
	turn_level = clampi(int(value.get("turn_level", 2 if curriculum_stage > 3 else 0)), 0, 2)
	curriculum_recent_results.clear()
	for result in value.get("recent_results", []).slice(-CURRICULUM_WINDOW):
		curriculum_recent_results.append(bool(result))


func _get_route_state() -> Dictionary:
	driving_task.route = route
	driving_task.last_progress = last_progress
	return driving_task._get_route_state()


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
	driving_task.ego = ego
	driving_task.road_generator = road_generator
	driving_task.route = route
	return driving_task._lane_center_offset_at(progress)


func _lane_center_offset_for_route(candidate_route: RoutePath, progress: float) -> float:
	driving_task.ego = ego
	driving_task.road_generator = road_generator
	driving_task.route = route
	return driving_task._lane_center_offset_for_route(candidate_route, progress)


func _get_observation() -> Array[float]:
	driving_task.ego = ego
	driving_task.road_generator = road_generator
	driving_task.route = route
	driving_task.last_progress = last_progress
	driving_task.goal_progress = goal_progress
	driving_task.base_max_speed = base_max_speed
	return driving_task._get_observation()


func _send_message(message: Dictionary) -> void:
	if tcp_peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	tcp_peer.put_data((JSON.stringify(message) + "\n").to_utf8_buffer())


func _unhandled_input(event: InputEvent) -> void:
	if visible_mode and not embedded_training_view and event is InputEventKey and event.pressed \
	and not event.echo and event.keycode == KEY_ESCAPE:
		get_tree().quit()


func _draw() -> void:
	if not visible_mode or route == null or not route.is_valid():
		return
	# A visible target makes it easy to verify the route-following objective.
	draw_circle(goal_position, GOAL_RADIUS, Color(0.12, 0.9, 0.35, 0.2))
	draw_arc(goal_position, GOAL_RADIUS, 0.0, TAU, 48, Color(0.2, 1.0, 0.48, 0.95), 4.0)
