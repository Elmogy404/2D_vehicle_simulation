extends SceneTree

const MAIN_SCENE := preload("res://scenes/main.tscn")

var main_scene: Node


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	main_scene = MAIN_SCENE.instantiate()
	root.add_child(main_scene)
	var settings: Node = main_scene.get_node("SettingsPopup")
	settings.emit_signal("generate_requested", 333333333, false, 0)
	await process_frame
	await process_frame

	var traffic_manager: Node = main_scene.get_node("TrafficManager")
	var lights: Node = main_scene.get_node("TrafficLightManager")
	var pedestrians: Node = main_scene.get_node("PedestrianManager")
	var slider: HSlider = settings.get("target_slider")
	if slider == null or not is_equal_approx(slider.min_value, 250.0) \
	or not is_equal_approx(slider.max_value, 5500.0):
		_fail("AI target-distance slider is missing or has the wrong trained range")
		return
	if not is_equal_approx(float(main_scene.get("ai_target_distance")), 4200.0):
		_fail("default AI target should start at 4,200 units")
		return
	if int(main_scene.get("selected_ai_checkpoint")) != 1 \
	or not String(main_scene.call("_selected_policy_model_path")).ends_with("_best.zip"):
		_fail("the 150k best checkpoint is not the default selection")
		return
	if get_nodes_in_group("traffic").is_empty():
		_fail("precondition failed: normal mode did not spawn traffic")
		return

	_press_main_key(KEY_1)
	if not bool(main_scene.get("ai_mode_active")):
		_fail("key 1 did not start the default checkpoint")
		return
	if not get_nodes_in_group("traffic").is_empty():
		_fail("traffic remained in AI mode")
		return
	if not get_nodes_in_group("pedestrians").is_empty():
		_fail("pedestrians remained in AI mode")
		return
	if not get_nodes_in_group("traffic_lights").is_empty():
		_fail("traffic signals remained in empty-road AI mode")
		return
	var marker: Node = main_scene.get("goal_marker")
	var minimap: Node = main_scene.get("minimap_view")
	if marker == null or not bool(marker.get("active")) \
	or not bool(minimap.get("show_goal")) \
	or not bool(minimap.get("show_planned_route")):
		_fail("AI destination or graph-planned route was not shown")
		return
	var goal_distance := float(main_scene.get("ai_goal_progress")) \
		- float(main_scene.get("ai_last_progress"))
	if not is_equal_approx(goal_distance, 4200.0):
		_fail("AI did not plan the selected 4,200-unit destination")
		return
	if main_scene.get("ai_route") == null or not bool(main_scene.get("ai_route").call("is_valid")):
		_fail("AI did not create a valid map-network route")
		return

	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		if bool(main_scene.get("ai_failed")):
			_fail("AI startup failed: %s" % String(main_scene.get("ai_status")))
			return
		if bool(main_scene.get("ai_ever_connected")) \
		and int(main_scene.get("ai_request_id")) >= 2 \
		and not bool(main_scene.get("ai_request_in_flight")):
			break
		await create_timer(0.05).timeout

	if not bool(main_scene.get("ai_ever_connected")) \
	or int(main_scene.get("ai_request_id")) < 2 \
	or bool(main_scene.get("ai_request_in_flight")):
		_fail("Godot did not receive a Setup 2 PPO action before the timeout (%s)" % _policy_debug_state())
		return

	slider.value = 1000.0
	if not is_equal_approx(float(main_scene.get("ai_target_distance")), 1000.0):
		_fail("moving the slider did not update the selected AI goal length")
		return
	main_scene.call("restart_simulation")
	goal_distance = float(main_scene.get("ai_goal_progress")) \
		- float(main_scene.get("ai_last_progress"))
	if not is_equal_approx(goal_distance, 1000.0):
		_fail("R did not apply the new 1,000-unit slider target")
		return

	_press_main_key(KEY_2)
	if not bool(main_scene.get("ai_mode_active")) \
	or int(main_scene.get("selected_ai_checkpoint")) != 2 \
	or not String(main_scene.call("_selected_policy_model_path")).ends_with("_276480_steps.zip"):
		_fail("key 2 did not select the 276,480-step checkpoint")
		return
	deadline = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		if bool(main_scene.get("ai_failed")):
			_fail("key 2 checkpoint startup failed: %s" % String(main_scene.get("ai_status")))
			return
		if bool(main_scene.get("ai_ever_connected")) \
		and int(main_scene.get("ai_request_id")) >= 2 \
		and not bool(main_scene.get("ai_request_in_flight")):
			break
		await create_timer(0.05).timeout
	if not bool(main_scene.get("ai_ever_connected")) \
	or int(main_scene.get("ai_request_id")) < 2 \
	or bool(main_scene.get("ai_request_in_flight")):
		_fail("key 2 checkpoint did not return a PPO action (%s)" % _policy_debug_state())
		return

	_press_main_key(KEY_I)
	if bool(main_scene.get("ai_mode_active")):
		_fail("I-key toggle did not return to manual mode")
		return
	if not bool(traffic_manager.get("traffic_enabled")) \
	or not bool(lights.get("lights_enabled")) \
	or not bool(pedestrians.get("pedestrians_enabled")):
		_fail("normal traffic, lights, and pedestrians were not restored")
		return
	if get_nodes_in_group("traffic").is_empty():
		_fail("normal mode did not respawn traffic")
		return
	print("AI LIVE MODE PASS: Setup 2 checkpoint, map route, target slider, PPO action, and restoration")
	quit(0)


func _fail(message: String) -> void:
	push_error("AI LIVE MODE FAIL: " + message)
	if main_scene != null and is_instance_valid(main_scene) \
	and bool(main_scene.get("ai_mode_active")):
		main_scene.call("toggle_ai_mode")
	quit(1)


func _policy_debug_state() -> String:
	var peer: StreamPeerTCP = main_scene.get("ai_peer")
	return "status=%s paused=%s request=%d pending=%s peer=%d process=%d" % [
		String(main_scene.get("ai_status")),
		str(paused),
		int(main_scene.get("ai_request_id")),
		str(main_scene.get("ai_request_in_flight")),
		int(peer.get_status()) if peer != null else -1,
		int(main_scene.get("ai_process_id"))
	]


func _press_main_key(key_code: int) -> void:
	var event := InputEventKey.new()
	event.pressed = true
	event.keycode = key_code
	event.physical_keycode = key_code
	main_scene.call("_unhandled_input", event)
