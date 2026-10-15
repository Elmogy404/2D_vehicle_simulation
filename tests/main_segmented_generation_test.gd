extends SceneTree

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TEST_SEED := 20261015


func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	var main := MAIN_SCENE.instantiate() as Node2D
	if main == null:
		push_error("Could not instantiate the main simulation scene.")
		quit(1)
		return
	root.add_child(main)
	var settings: Node = main.get_node("SettingsPopup")
	settings.emit_signal("generate_requested", TEST_SEED, false, 1)
	var roads: Node = main.get_node("RoadGenerator")
	var route: RoutePath = roads.call("get_route")
	var debug_camera: Camera2D = main.get_node("DebugCamera")
	var ego_camera: Camera2D = main.get_node("EgoVehicle/Camera2D")
	var traffic: Node = main.get_node("TrafficManager")
	var lights: Node = main.get_node("TrafficLightManager")
	var pedestrians: Node = main.get_node("PedestrianManager")
	var authored_features: Array[Dictionary] = roads.call("get_authored_road_features")
	var expected_crossings := 0
	var expected_lights := 0
	var pedestrians_per_authored_crossing := int(
		pedestrians.get("authored_pedestrians_per_crossing")
	)
	var expected_pedestrian_poses: Array[Dictionary] = []
	var signal_anchors_match := true
	for feature in authored_features:
		var feature_crosswalks: Array = feature.get("crosswalks", [])
		var piece_index := int(feature.get("piece_index", -1))
		expected_crossings += feature_crosswalks.size()
		var feature_center: Vector2 = feature.get("center", Vector2.ZERO)
		for crossing in feature_crosswalks:
			var axis: Vector2 = Vector2(crossing.get("axis", Vector2.ZERO)).normalized()
			var across := axis.rotated(PI * 0.5)
			var reach := float(crossing.get("width", 0.0)) * 0.5 \
				+ float(pedestrians.get("curb_margin"))
			for pedestrian_index in range(pedestrians_per_authored_crossing):
				var offset := (
					float(pedestrian_index)
					- float(pedestrians_per_authored_crossing - 1) * 0.5
				) * float(pedestrians.get("group_spacing"))
				expected_pedestrian_poses.append({
					"start": Vector2(crossing["center"]) + across * reach + axis * offset,
					"finish": Vector2(crossing["center"]) - across * reach + axis * offset,
					"piece_index": piece_index
				})
		var feature_anchors: Array = feature.get("signal_anchors", [])
		if not feature_anchors.is_empty():
			expected_lights += 1
			var light: Node = lights.call("light_for_piece", piece_index)
			if light == null or light.global_position.distance_to(feature_center) > 0.1:
				signal_anchors_match = false
				continue
			var actual_arms: Array = light.get("approach_arms")
			if actual_arms.size() != feature_anchors.size():
				signal_anchors_match = false
				continue
			for anchor_index in range(feature_anchors.size()):
				var anchor: Dictionary = feature_anchors[anchor_index]
				var arm: Dictionary = actual_arms[anchor_index]
				var expected_stop: Vector2 = (
					Vector2(anchor["stop_line_center"]) - feature_center
				).rotated(-float(light.get("axis_rotation")))
				var expected_lamp: Vector2 = (
					Vector2(anchor["light_anchor"]) - feature_center
				).rotated(-float(light.get("axis_rotation")))
				if Vector2(arm["stop_center_local"]).distance_to(expected_stop) > 0.1 \
				or Vector2(arm["lamp_position_local"]).distance_to(expected_lamp) > 0.1:
					signal_anchors_match = false
	var expected_pedestrians := expected_crossings * pedestrians_per_authored_crossing
	var pedestrians_match_authored_positions := true
	var active_pedestrians := 0
	var unmatched_poses := expected_pedestrian_poses.duplicate()
	for pedestrian in pedestrians.get("pedestrians"):
		if pedestrian.is_physics_processing():
			active_pedestrians += 1
		var match_index := -1
		for pose_index in range(unmatched_poses.size()):
			var pose: Dictionary = unmatched_poses[pose_index]
			if pedestrian.endpoint_a.distance_to(Vector2(pose["start"])) < 0.1 \
				and pedestrian.endpoint_b.distance_to(Vector2(pose["finish"])) < 0.1:
				match_index = pose_index
				break
		if match_index < 0:
			pedestrians_match_authored_positions = false
		else:
			unmatched_poses.remove_at(match_index)
	var unsignalized_pedestrian_can_cross := false
	for pedestrian in pedestrians.get("pedestrians"):
		if pedestrian.get("traffic_light") != null:
			continue
		pedestrian.call("_physics_process", 0.01)
		unsignalized_pedestrian_can_cross = bool(pedestrian.get("is_crossing"))
		break
	var c_key := InputEventKey.new()
	c_key.pressed = true
	c_key.keycode = KEY_C
	c_key.physical_keycode = KEY_C
	main.call("_unhandled_input", c_key)
	var debug_camera_toggled := debug_camera.is_current() and bool(debug_camera.get("debug_mode"))
	var initial_debug_zoom := float(debug_camera.get("target_zoom"))
	var i_key := InputEventKey.new()
	i_key.pressed = true
	i_key.keycode = KEY_I
	i_key.physical_keycode = KEY_I
	main.call("_unhandled_input", i_key)
	var i_key_zooms_in := float(debug_camera.get("target_zoom")) > initial_debug_zoom
	var zoomed_in := float(debug_camera.get("target_zoom"))
	var o_key := InputEventKey.new()
	o_key.pressed = true
	o_key.keycode = KEY_O
	o_key.physical_keycode = KEY_O
	main.call("_unhandled_input", o_key)
	var o_key_zooms_out := float(debug_camera.get("target_zoom")) < zoomed_in
	var debug_zoom_controls_work := i_key_zooms_in and o_key_zooms_out \
		and absf(float(debug_camera.get("target_zoom")) - initial_debug_zoom) < 0.001
	main.call("_unhandled_input", c_key)
	var follow_camera_restored := ego_camera.is_current() and not bool(debug_camera.get("debug_mode"))
	var success: bool = route != null and route.is_valid() \
		and debug_camera_toggled and follow_camera_restored \
		and debug_zoom_controls_work \
		and int(roads.call("get_piece_count")) == 200 \
		and int(traffic.get("number_of_cars")) == 20 \
		and traffic.get("traffic_cars").size() == 20 \
		and lights.get("lights").size() == expected_lights \
		and signal_anchors_match \
		and pedestrians.get("pedestrians").size() == expected_pedestrians \
		and active_pedestrians < expected_pedestrians \
		and pedestrians_match_authored_positions \
		and unmatched_poses.is_empty() \
		and unsignalized_pedestrian_can_cross \
		and expected_crossings > 0 \
		and pedestrians.get_node_or_null("Crosswalks") == null \
		and roads.get_node_or_null(
			"SegmentedRoadGenerator/GeneratedRoadPieces/RoadEdgeCollisions"
		) != null
	if not success:
		push_error("Main simulation did not complete 200-piece segmented deployment.")
		quit(1)
		return
	print("MAIN SEGMENTED GENERATION TEST PASSED: C toggles both cameras; I/O zoom the debug camera; 200 pieces, %d authored crossings, %d aligned signals, %d pedestrians (%d active nearby), and 20 NPC cars." % [expected_crossings, expected_lights, expected_pedestrians, active_pedestrians])
	quit(0)
