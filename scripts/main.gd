extends Node2D

const DRIVING_TASK = preload("res://scripts/driving_task.gd")
const SPATIAL_INDEX = preload("res://scripts/simulation_spatial_index.gd")
var live_driving_task := DRIVING_TASK.new()

const POLICY_SERVER_PORT := 8766
const POLICY_SERVER_START_TIMEOUT_MSEC := 20000
const POLICY_ACTION_REPEAT := 4
const MIN_GOAL_DISTANCE := 250.0
const DEFAULT_GOAL_DISTANCE := 4200.0
const GOAL_RADIUS := 85.0
const OBSERVATION_SIZE := 31
const DEFAULT_AI_CHECKPOINT := 1
const ORIGINAL_GENERATOR_TRAFFIC_COUNT := 8
const SEGMENTED_GENERATOR_TRAFFIC_COUNT := 20
const POLICY_MODEL_PATHS := {
	1: "res://ai/models/setup2_network_routes_ppo_v1_best.zip",
	2: "res://ai/models/checkpoints/setup2_network_routes_ppo_v1_276480_steps.zip"
}
const POLICY_SERVER_PATH := "res://ai/live_policy_server.py"

@onready var road_generator: Node = $RoadGenerator
@onready var ego_vehicle: CharacterBody2D = $EgoVehicle
@onready var traffic_manager: Node = $TrafficManager
@onready var traffic_light_manager: Node = $TrafficLightManager
@onready var pedestrian_manager: Node = $PedestrianManager
@onready var debug_camera: Camera2D = $DebugCamera
@onready var minimap_view: Control = $Minimap/View
@onready var ai_mode_hud: CanvasLayer = $AiModeHud
@onready var game_over: CanvasLayer = $GameOver
@onready var settings_popup: CanvasLayer = $SettingsPopup

var goal_marker: Node2D
var ai_mode_active := false
var ai_status := ""
var ai_goal_position := Vector2.ZERO
var ai_goal_progress := 0.0
var ai_last_progress := 0.0
var ai_target_distance := DEFAULT_GOAL_DISTANCE
var selected_ai_checkpoint := DEFAULT_AI_CHECKPOINT
var ai_route_turns := 0
var ai_turn_requirement_met := false
var ai_goal_reached := false
var ai_failed := false
var ai_route: RoutePath
var ai_rng := RandomNumberGenerator.new()
var ai_action := Vector2.ZERO
var ai_action_clock := 0
var ai_request_in_flight := false
var ai_request_id := 0
var ai_peer: StreamPeerTCP
var ai_peer_buffer := PackedByteArray()
var ai_process_id := -1
var ai_started_at_msec := 0
var ai_next_connect_msec := 0
var ai_connect_pending := false
var ai_ever_connected := false
var ai_python_executable := ""
var saved_road_hotkeys := true
var saved_manual_position := Vector2.ZERO
var saved_manual_rotation := 0.0
var saved_manual_speed := 0.0
var saved_manual_steering := 0.0
var saved_manual_crashed := false
var saved_debug_camera_mode := false
var environment_ready := false
var environment_building := false
signal environment_generated


func _ready() -> void:
	var spatial_index := SPATIAL_INDEX.new()
	spatial_index.name = "SpatialIndex"
	add_child(spatial_index)
	goal_marker = Node2D.new()
	goal_marker.name = "AiGoalMarker"
	goal_marker.set_script(load("res://scripts/goal_marker.gd"))
	goal_marker.z_index = 20
	add_child(goal_marker)
	ai_mode_hud.call("set_checkpoint_label", _selected_checkpoint_label())
	settings_popup.call("set_target_distance", ai_target_distance)
	settings_popup.call("set_checkpoint_label", _selected_checkpoint_label())
	settings_popup.connect("generate_requested", _on_environment_generate_requested)
	settings_popup.connect("quick_generate_requested", _on_quick_generate_requested)
	settings_popup.connect("checkpoint_requested", select_ai_checkpoint)
	settings_popup.connect("target_distance_changed", _on_ai_target_distance_changed)
	settings_popup.connect("popup_visibility_changed", _on_settings_visibility_changed)
	road_generator.road_regenerated.connect(_on_road_regenerated)
	environment_ready = road_generator.get_route() != null and road_generator.get_route().is_valid()
	if environment_ready:
		place_ego()
	else:
		get_tree().paused = true
	_update_mode_hud()


func _exit_tree() -> void:
	_shutdown_policy_service()


func _process(_delta: float) -> void:
	if not ai_mode_active:
		return
	_poll_policy_server()
	_update_mode_hud()


func _physics_process(_delta: float) -> void:
	if not ai_mode_active:
		return
	if ai_failed:
		_stop_vehicle_for_ai_result()
		return
	if bool(ego_vehicle.get("has_crashed")):
		ai_failed = true
		ai_status = "The AI crashed. Press R to retry or I to return to manual driving."
		ai_mode_hud.call("set_mode", true, ai_status, _goal_distance_remaining())
		return
	if ai_goal_reached:
		_stop_vehicle_for_ai_result()
		return
	if ai_route == null or not ai_route.is_valid():
		return

	var route_state := _get_ai_route_state()
	var safe_half_width: float = maxf(
		float(route_state["half_width"]) - float(ego_vehicle.get("vehicle_width")) * 0.5,
		1.0
	)
	if absf(float(route_state["lateral_offset"])) > safe_half_width:
		ai_failed = true
		ai_status = "The AI left the drivable road. Press R to retry or I to return."
		_stop_vehicle_for_ai_result()
		return

	if float(route_state["progress"]) >= ai_goal_progress - GOAL_RADIUS \
	and ego_vehicle.global_position.distance_to(ai_goal_position) <= GOAL_RADIUS:
		ai_goal_reached = true
		ai_status = "Destination reached! Press R for another goal or I to return."
		_stop_vehicle_for_ai_result()
		return

	ai_last_progress = float(route_state["progress"])
	_apply_ai_action()
	ai_action_clock += 1
	if ai_action_clock >= POLICY_ACTION_REPEAT:
		ai_action_clock = 0
		_send_policy_observation()


func _unhandled_input(event: InputEvent) -> void:
	if settings_popup != null and bool(settings_popup.get("popup_open")):
		return
	if not environment_ready:
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_C or key.physical_keycode == KEY_C:
		debug_camera.call("toggle_camera")
		get_viewport().set_input_as_handled()
	elif key.keycode == KEY_1 or key.physical_keycode == KEY_1:
		select_ai_checkpoint(1)
		get_viewport().set_input_as_handled()
	elif key.keycode == KEY_2 or key.physical_keycode == KEY_2:
		select_ai_checkpoint(2)
		get_viewport().set_input_as_handled()
	elif bool(debug_camera.get("debug_mode")) and (key.keycode == KEY_I or key.physical_keycode == KEY_I):
		debug_camera.call("adjust_zoom", float(debug_camera.get("zoom_step")))
		get_viewport().set_input_as_handled()
	elif bool(debug_camera.get("debug_mode")) and (key.keycode == KEY_O or key.physical_keycode == KEY_O):
		debug_camera.call("adjust_zoom", -float(debug_camera.get("zoom_step")))
		get_viewport().set_input_as_handled()
	elif key.keycode == KEY_I or key.physical_keycode == KEY_I:
		toggle_ai_mode()
		get_viewport().set_input_as_handled()
	elif ai_mode_active and (key.keycode == KEY_R or key.physical_keycode == KEY_R):
		restart_simulation()
		get_viewport().set_input_as_handled()


func toggle_ai_mode() -> void:
	if ai_mode_active:
		_leave_ai_mode()
	else:
		_enter_ai_mode()


func select_ai_checkpoint(checkpoint_id: int) -> void:
	if not POLICY_MODEL_PATHS.has(checkpoint_id):
		return
	if not environment_ready:
		settings_popup.call("set_status", "Generate a map before starting the AI drive.")
		return
	var checkpoint_changed := selected_ai_checkpoint != checkpoint_id
	selected_ai_checkpoint = checkpoint_id
	ai_mode_hud.call("set_checkpoint_label", _selected_checkpoint_label())
	settings_popup.call("set_checkpoint_label", _selected_checkpoint_label())
	if not ai_mode_active:
		_enter_ai_mode()
		return
	if not checkpoint_changed:
		restart_simulation()
		return

	if get_tree().paused:
		get_tree().paused = false
	_shutdown_policy_service()
	ai_failed = false
	ai_goal_reached = false
	ai_action = Vector2.ZERO
	ai_action_clock = 0
	ai_request_id = 0
	ai_request_in_flight = false
	ai_peer_buffer.clear()
	_begin_ai_goal()
	if ai_failed:
		_update_mode_hud()
		return
	ai_status = "Loading %s PPO policy..." % _selected_checkpoint_label()
	_update_mode_hud()
	_start_policy_service()


func _enter_ai_mode() -> void:
	if not environment_ready:
		ai_status = "Generate a map before starting the AI drive."
		settings_popup.call("set_status", ai_status)
		_update_mode_hud()
		return
	var model_path := _selected_policy_model_path()
	if not FileAccess.file_exists(model_path):
		ai_status = "AI model not found: %s" % model_path
		_update_mode_hud()
		return
	if not FileAccess.file_exists(POLICY_SERVER_PATH):
		ai_status = "AI policy service is missing."
		_update_mode_hud()
		return

	_save_manual_state()
	saved_debug_camera_mode = bool(debug_camera.get("debug_mode"))
	if saved_debug_camera_mode:
		debug_camera.call("toggle_camera")
	ai_mode_active = true
	ai_goal_reached = false
	ai_failed = false
	ai_action = Vector2.ZERO
	ai_action_clock = 0
	ai_request_in_flight = false
	ai_request_id = 0
	ai_peer_buffer.clear()
	saved_road_hotkeys = bool(road_generator.get("enable_hotkeys"))
	road_generator.set("enable_hotkeys", false)
	_set_dynamic_actors_enabled(false)
	if get_tree().paused:
		get_tree().paused = false
	game_over.visible = false
	_begin_ai_goal()
	if ai_failed:
		_update_mode_hud()
		return
	ai_status = "Loading PPO policy..."
	_update_mode_hud()
	_start_policy_service()


func _leave_ai_mode() -> void:
	ai_mode_active = false
	_shutdown_policy_service()
	road_generator.set("enable_hotkeys", saved_road_hotkeys)
	if get_tree().paused:
		get_tree().paused = false
	game_over.visible = false
	minimap_view.call("set_goal_position", Vector2.ZERO, false)
	minimap_view.call("set_planned_route", [], false)
	goal_marker.call("set_goal", Vector2.ZERO, false)
	queue_redraw()

	ego_vehicle.reset_vehicle()
	if saved_manual_crashed:
		place_ego()
	else:
		ego_vehicle.global_position = saved_manual_position
		ego_vehicle.global_rotation = saved_manual_rotation
		ego_vehicle.set("current_speed", saved_manual_speed)
		ego_vehicle.set("steering_input", saved_manual_steering)
		ego_vehicle.use_default_controller()
	_set_dynamic_actors_enabled(true)
	if saved_debug_camera_mode:
		debug_camera.call("toggle_camera")
	ai_route = null
	ai_status = "Manual driving restored. Press I to watch the Setup 2 checkpoint."
	_update_mode_hud()


func _save_manual_state() -> void:
	saved_manual_position = ego_vehicle.global_position
	saved_manual_rotation = ego_vehicle.global_rotation
	saved_manual_speed = float(ego_vehicle.get("current_speed"))
	saved_manual_steering = float(ego_vehicle.get("steering_input"))
	saved_manual_crashed = bool(ego_vehicle.get("has_crashed"))


func _set_dynamic_actors_enabled(enabled: bool) -> void:
	if enabled:
		traffic_light_manager.call("set_lights_enabled", true)
		pedestrian_manager.call("set_pedestrians_enabled", true)
		traffic_manager.call("set_traffic_enabled", true)
	else:
		traffic_manager.call("set_traffic_enabled", false)
		pedestrian_manager.call("set_pedestrians_enabled", false)
		traffic_light_manager.call("set_lights_enabled", false)


func _on_quick_generate_requested() -> void:
	if environment_ready:
		_on_environment_generate_requested(
			0, true, int(road_generator.call("get_generator_type"))
		)


func _on_environment_generate_requested(
	requested_seed: int,
	randomize_seed: bool,
	generator_type: int
) -> void:
	if environment_building:
		return
	var chosen_seed := requested_seed
	if randomize_seed:
		var seed_rng := RandomNumberGenerator.new()
		seed_rng.randomize()
		chosen_seed = seed_rng.randi_range(1, 2147483646)
		if chosen_seed == int(road_generator.get("seed_value")):
			chosen_seed = 1 if chosen_seed == 2147483646 else chosen_seed + 1
	if chosen_seed <= 0:
		settings_popup.call("set_status", "Use a positive seed so this map can be reproduced.")
		return
	environment_building = true
	environment_ready = false
	get_tree().paused = true

	road_generator.call("set_generator_type", generator_type)
	var is_segmented_generation := bool(road_generator.call("uses_segmented_generation"))
	traffic_manager.set(
		"number_of_cars",
		SEGMENTED_GENERATOR_TRAFFIC_COUNT
		if is_segmented_generation
		else ORIGINAL_GENERATOR_TRAFFIC_COUNT
	)
	var generator_label: String = road_generator.call("get_generator_label")
	settings_popup.call("set_status", "Building %s…" % generator_label)
	_set_dynamic_actors_enabled(false)
	game_over.visible = false
	if not ai_mode_active:
		ego_vehicle.reset_vehicle()
	road_generator.set("enable_hotkeys", false)
	traffic_manager.set("randomize_seed", false)
	traffic_manager.set("seed_value", posmod(chosen_seed + 196613, 2147483647))
	traffic_light_manager.set("seed_value", posmod(chosen_seed + 104729, 2147483647))
	pedestrian_manager.set("seed_value", posmod(chosen_seed + 130363, 2147483647))
	road_generator.call("generate_with_seed", chosen_seed)
	# Physics queries must see the new walls, with the previous map removed,
	# before validating spawns or deploying any dynamic actors.
	await get_tree().physics_frame
	await get_tree().physics_frame
	var route: RoutePath = road_generator.get_route()
	var route_length := route.length if route != null else 0.0
	if route == null or not route.is_valid():
		environment_building = false
		environment_ready = false
		settings_popup.call("set_map_generated", false)
		settings_popup.call("set_popup_open", true)
		get_tree().paused = true
		settings_popup.call("set_status", "This seed did not produce a valid road (%.0f units). Try another seed." % route_length)
		environment_generated.emit()
		return
	environment_ready = true
	environment_building = false
	if ai_mode_active:
		_begin_ai_goal()
	else:
		place_ego()
	if ai_mode_active:
		# The old manual pose belongs to the previous map. Leaving AI mode must
		# restore the player at a valid spawn on this newly generated one.
		var manual_spawn: Dictionary = traffic_manager.get_ego_spawn_pose()
		saved_manual_position = manual_spawn["position"]
		saved_manual_rotation = manual_spawn["rotation"]
		saved_manual_speed = 0.0
		saved_manual_steering = 0.0
		saved_manual_crashed = false
	_set_dynamic_actors_enabled(not ai_mode_active)
	settings_popup.call("set_map_generated", true, chosen_seed, generator_label)
	get_tree().paused = false
	if ai_mode_active:
		ai_status = "Map regenerated. AI goal replanned."
		_update_mode_hud()
	environment_generated.emit()


func _on_settings_visibility_changed(is_open: bool) -> void:
	if is_open:
		get_tree().paused = true
	elif environment_ready:
		get_tree().paused = false
	else:
		get_tree().paused = true


func _begin_ai_goal() -> void:
	var network: Object = road_generator.call("get_road_network")
	if network == null:
		ai_status = "The generated road network is unavailable. Press I to return."
		ai_failed = true
		return

	ai_rng.randomize()
	var task := live_driving_task
	task.validation_cache.clear()
	task.ego = ego_vehicle
	task.road_generator = road_generator
	task.episode_rng = ai_rng
	var requested_turns := _minimum_turns_for_target_distance(ai_target_distance)
	var selection := {}
	# A playable seed need not support the training district's full turn
	# curriculum. Preserve clearance and distance, and disclose fewer turns.
	for turns in range(requested_turns, -1, -1):
		task.minimum_turns = turns
		selection = task._select_trip(Vector2(ai_target_distance, ai_target_distance))
		if not selection.is_empty():
			break
	if selection.is_empty():
		ai_status = "No safe route fits this goal. Lower the target and press R."
		ai_failed = true
		return
	ai_route = task.route
	var start_progress := float(selection["start"])
	ai_goal_progress = float(selection["goal"])
	ai_route_turns = task._count_trip_turns(ai_route, start_progress, ai_goal_progress)
	ai_turn_requirement_met = ai_route_turns >= requested_turns
	ai_goal_position = ai_route.get_position_at(ai_goal_progress, _ai_lane_center_offset_at(ai_goal_progress))
	ai_last_progress = start_progress
	ai_goal_reached = false
	ai_failed = false
	ai_request_id += 1
	ai_request_in_flight = false
	ai_action = Vector2.ZERO
	ego_vehicle.reset_vehicle()
	ego_vehicle.global_position = ai_route.get_position_at(
		start_progress,
		_ai_lane_center_offset_at(start_progress)
	)
	ego_vehicle.global_rotation = ai_route.get_rotation_at(start_progress)
	ego_vehicle.set_control(0.0, 0.0, 0.0)
	ego_vehicle.get_node("SensorRig").call("update_sensors")
	minimap_view.call("set_goal_position", ai_goal_position, true)
	minimap_view.call("set_planned_route", ai_route.points, true)
	goal_marker.call("set_goal", ai_goal_position, true)
	ai_status = _ai_driving_status() if _policy_is_connected() else "Loading PPO policy..."
	queue_redraw()
	_update_mode_hud()


func _start_policy_service() -> void:
	ai_python_executable = OS.get_environment("AI_PYTHON")
	if ai_python_executable.is_empty():
		var project_venv_python := ProjectSettings.globalize_path("res://.venv-ai/Scripts/python.exe")
		var ai_venv_python := ProjectSettings.globalize_path("res://ai/.venv/Scripts/python.exe")
		if FileAccess.file_exists(project_venv_python):
			ai_python_executable = project_venv_python
		elif FileAccess.file_exists(ai_venv_python):
			ai_python_executable = ai_venv_python
		else:
			ai_python_executable = "python"
	var model_path := ProjectSettings.globalize_path(_selected_policy_model_path())
	var server_path := ProjectSettings.globalize_path(POLICY_SERVER_PATH)
	var process_args := PackedStringArray([
		"-u",
		server_path,
		"--model",
		model_path,
		"--port",
		str(POLICY_SERVER_PORT)
	])
	ai_process_id = OS.create_process(ai_python_executable, process_args, false)
	if ai_process_id <= 0:
		ai_process_id = -1
		ai_status = "Could not start Python. Set AI_PYTHON or add Python to PATH."
		ai_failed = true
		ai_started_at_msec = Time.get_ticks_msec()
		return
	ai_peer_buffer.clear()
	ai_peer = null
	ai_connect_pending = false
	ai_ever_connected = false
	ai_started_at_msec = Time.get_ticks_msec()
	ai_next_connect_msec = 0
	_try_connect_policy_server()


func _try_connect_policy_server() -> void:
	if not ai_mode_active or ai_connect_pending:
		return
	ai_peer = StreamPeerTCP.new()
	var connect_error: int = ai_peer.connect_to_host("127.0.0.1", POLICY_SERVER_PORT)
	if connect_error == OK:
		ai_connect_pending = true
	else:
		ai_peer = null
		ai_next_connect_msec = Time.get_ticks_msec() + 250


func _poll_policy_server() -> void:
	if ai_failed:
		return
	var now := Time.get_ticks_msec()
	if ai_peer != null:
		ai_peer.poll()
		if ai_peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			ai_connect_pending = false
			ai_ever_connected = true
			if ai_status.begins_with("Loading") or ai_status.begins_with("Connecting"):
				ai_status = _ai_driving_status()
			var available := ai_peer.get_available_bytes()
			if available > 0:
				var received: Array = ai_peer.get_data(available)
				if received[0] == OK:
					ai_peer_buffer.append_array(received[1])
					_extract_policy_responses()
		elif ai_peer.get_status() == StreamPeerTCP.STATUS_NONE \
		or ai_peer.get_status() == StreamPeerTCP.STATUS_ERROR:
			if ai_ever_connected:
				ai_failed = true
				ai_status = "Lost the PPO connection. Press I to return to manual driving."
			elif ai_connect_pending:
				ai_connect_pending = false
				ai_peer = null
				ai_next_connect_msec = now + 250

	if ai_peer == null and now >= ai_next_connect_msec:
		if now - ai_started_at_msec > POLICY_SERVER_START_TIMEOUT_MSEC:
			ai_failed = true
			ai_status = "Python policy did not start. Check ai/runs/live_policy.log, then press I to return."
			return
		ai_status = "Connecting to the PPO policy..."
		_try_connect_policy_server()


func _extract_policy_responses() -> void:
	var newline_index := ai_peer_buffer.find(10)
	while newline_index >= 0:
		var line := ai_peer_buffer.slice(0, newline_index).get_string_from_utf8()
		ai_peer_buffer = ai_peer_buffer.slice(newline_index + 1)
		if not line.is_empty():
			var parsed: Variant = JSON.parse_string(line)
			if parsed is Dictionary:
				var response: Dictionary = parsed
				var response_id := int(response.get("request_id", -1))
				if response_id == ai_request_id:
					var action: Variant = response.get("action", [])
					if action is Array and action.size() == 2:
						ai_action = Vector2(
							clampf(float(action[0]), -1.0, 1.0),
							clampf(float(action[1]), -1.0, 1.0)
						)
						ai_request_in_flight = false
					elif response.has("error"):
						ai_request_in_flight = false
						ai_status = "Policy error: %s" % String(response["error"])
		newline_index = ai_peer_buffer.find(10)


func _send_policy_observation() -> void:
	if ai_request_in_flight or ai_peer == null \
	or ai_peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	var observation := _get_ai_observation()
	if observation.size() != OBSERVATION_SIZE:
		ai_failed = true
		ai_status = "AI observation size mismatch; press I to return."
		return
	ai_request_id += 1
	var message := {
		"type": "predict",
		"request_id": ai_request_id,
		"observation": observation
	}
	var write_error := ai_peer.put_data((JSON.stringify(message) + "\n").to_utf8_buffer())
	if write_error == OK:
		ai_request_in_flight = true
	else:
		ai_status = "Lost connection to the PPO policy. Press I to return."
		ai_failed = true


func _apply_ai_action() -> void:
	if ai_peer == null or ai_peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		ego_vehicle.set_control(0.0, 0.0, 0.0)
		return
	var throttle := maxf(ai_action.y, 0.0)
	var brake := maxf(-ai_action.y, 0.0)
	if float(ego_vehicle.get("current_speed")) <= float(ego_vehicle.get("direction_change_threshold")):
		brake = 0.0
	ego_vehicle.set_control(throttle, brake, ai_action.x)


func _stop_vehicle_for_ai_result() -> void:
	var current_speed := float(ego_vehicle.get("current_speed"))
	if current_speed > float(ego_vehicle.get("direction_change_threshold")):
		ego_vehicle.set_control(0.0, 1.0, 0.0)
	else:
		ego_vehicle.set_control(0.0, 0.0, 0.0)


func _get_ai_route_state() -> Dictionary:
	var task := live_driving_task
	task.ego = ego_vehicle
	task.route = ai_route
	task.last_progress = ai_last_progress
	return task._get_route_state()


func _get_ai_observation() -> Array[float]:
	var task := live_driving_task
	task.ego = ego_vehicle
	task.road_generator = road_generator
	task.route = ai_route
	task.last_progress = ai_last_progress
	task.goal_progress = ai_goal_progress
	task.base_max_speed = float(ego_vehicle.get("max_speed"))
	ego_vehicle.get_node("SensorRig").call("update_sensors")
	return task._get_observation()


func _goal_distance_remaining() -> float:
	if ai_route == null or not ai_route.is_valid():
		return 0.0
	var route_state := _get_ai_route_state()
	return maxf(ai_goal_progress - float(route_state["progress"]), 0.0)


func _ai_lane_center_offset_at(progress: float) -> float:
	var task := live_driving_task
	return task._lane_center_offset_for_route(ai_route, progress)


func _policy_is_connected() -> bool:
	return ai_peer != null and ai_peer.get_status() == StreamPeerTCP.STATUS_CONNECTED


func _selected_policy_model_path() -> String:
	return String(POLICY_MODEL_PATHS.get(selected_ai_checkpoint, POLICY_MODEL_PATHS[DEFAULT_AI_CHECKPOINT]))


func _selected_checkpoint_label() -> String:
	if selected_ai_checkpoint == 2:
		return "276,480-step checkpoint [2]"
	return "150k best checkpoint [1]"


func _ai_driving_status() -> String:
	var route_note := "%d route turns" % ai_route_turns
	if not ai_turn_requirement_met:
		route_note += " (fewer than requested)"
	return "AI driving — %d-unit goal, %s. Destination marked green." % [
		roundi(ai_target_distance),
		route_note
	]


func _minimum_turns_for_target_distance(distance: float) -> int:
	if int(road_generator.call("get_generator_type")) == 1:
		return 1 if distance >= 800.0 else 0
	if distance >= 4200.0:
		return 4
	if distance >= 2700.0:
		return 3
	if distance >= 1800.0:
		return 2
	if distance >= 800.0:
		return 1
	return 0


func _on_ai_target_distance_changed(distance: float) -> void:
	ai_target_distance = clampf(distance, MIN_GOAL_DISTANCE, 5500.0)
	if ai_mode_active:
		ai_status = "Target set to %d units. Press R to start a new trip at that length." % roundi(ai_target_distance)
	else:
		ai_status = "AI target set to %d units. Press I to watch the checkpoint drive." % roundi(ai_target_distance)
	_update_mode_hud()


func _update_mode_hud() -> void:
	if ai_mode_hud == null:
		return
	ai_mode_hud.call("set_mode", ai_mode_active, ai_status, _goal_distance_remaining())


func _on_road_regenerated() -> void:
	if environment_building:
		return
	environment_ready = road_generator.get_route() != null \
		and road_generator.get_route().is_valid()
	if ai_mode_active:
		_begin_ai_goal()
	else:
		place_ego()


func _shutdown_policy_service() -> void:
	if ai_peer != null and ai_peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		ai_peer.put_data((JSON.stringify({"type": "shutdown"}) + "\n").to_utf8_buffer())
		ai_peer.disconnect_from_host()
	ai_peer = null
	ai_connect_pending = false
	ai_request_in_flight = false
	if ai_process_id > 0 and OS.is_process_running(ai_process_id):
		OS.kill(ai_process_id)
	ai_process_id = -1


func place_ego() -> void:
	var pose: Dictionary = traffic_manager.get_ego_spawn_pose()
	ego_vehicle.position = pose["position"]
	ego_vehicle.rotation = pose["rotation"]


func restart_simulation() -> void:
	if not environment_ready:
		settings_popup.call("set_status", "Generate a map before starting a drive.")
		return
	if ai_mode_active:
		if get_tree().paused:
			get_tree().paused = false
		game_over.visible = false
		_begin_ai_goal()
		if not ai_failed and ai_process_id <= 0:
			ai_status = "Loading PPO policy..."
			_start_policy_service()
		return
	ego_vehicle.reset_vehicle()
	place_ego()
	traffic_manager.regenerate()
	traffic_light_manager.regenerate()
