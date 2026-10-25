extends SceneTree

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TEST_SEED := 20261015


func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	var main := MAIN_SCENE.instantiate() as Node2D
	root.add_child(main)
	main.get_node("SettingsPopup").emit_signal("generate_requested", TEST_SEED, false, 1)
	await main.environment_generated
	var cars: Array = main.get_node("TrafficManager").get("traffic_cars")
	var lights: Array = main.get_node("TrafficLightManager").get("lights")
	var view: Control = main.get_node("Minimap/View")
	if cars.size() != 20 or lights.is_empty() or view == null:
		push_error("The optimization test could not deploy the segmented simulation.")
		quit(1)
		return
	var source_paths: Array[PackedVector2Array] = view.get("paths")
	var mapped_paths: Array[PackedVector2Array] = view.get("mapped_paths")
	if mapped_paths.size() != source_paths.size():
		push_error("The minimap did not cache every road path.")
		quit(1)
		return
	for path_index in range(source_paths.size()):
		if source_paths[path_index].size() != mapped_paths[path_index].size():
			push_error("A cached minimap road path lost points.")
			quit(1)
			return
		if not source_paths[path_index].is_empty() \
		and mapped_paths[path_index][0].distance_to(view.call("_world_to_map", source_paths[path_index][0])) > 0.01:
			push_error("A cached minimap road point is misplaced.")
			quit(1)
			return
	view.size = Vector2(620.0, 450.0)
	mapped_paths = view.get("mapped_paths")
	if mapped_paths[0][0].distance_to(view.call("_world_to_map", source_paths[0][0])) > 0.01:
		push_error("The minimap cache did not update when expanded.")
		quit(1)
		return
	var checked_light_decisions := 0
	for car in cars:
		var previous_progress: float = car.get("progress")
		var route: RoutePath = car.get("route")
		for fraction in [0.0, 0.2, 0.5, 0.8, 0.98]:
			car.set("progress", route.length * fraction)
			car.call("snap_to_route")
			var expected := _reference_traffic_light_speed_limit(car)
			var actual := float(car.call("traffic_light_speed_limit"))
			if absf(expected - actual) > 0.001:
				push_error("Traffic-light decision changed at route fraction %.2f: %.2f vs %.2f." % [fraction, actual, expected])
				quit(1)
				return
			checked_light_decisions += 1
		car.set("progress", previous_progress)
		car.call("snap_to_route")
	var started := Time.get_ticks_usec()
	var checksum := 0.0
	for repetition in range(100):
		for car in cars:
			checksum += float(car.call("traffic_light_speed_limit"))
	var light_time_ms := float(Time.get_ticks_usec() - started) / 1000.0
	started = Time.get_ticks_usec()
	var reference_checksum := 0.0
	for repetition in range(100):
		for car in cars:
			reference_checksum += _reference_traffic_light_speed_limit(car)
	var reference_time_ms := float(Time.get_ticks_usec() - started) / 1000.0
	if absf(checksum - reference_checksum) > 0.01:
		push_error("Optimized traffic-light decisions differ from the reference calculation.")
		quit(1)
		return
	print("OPTIMIZATION SMOKE PASSED: %d light decisions match; 2000 queries optimized %.1f ms vs reference %.1f ms; %d cached minimap paths." % [checked_light_decisions, light_time_ms, reference_time_ms, mapped_paths.size()])
	quit(0)


func _reference_traffic_light_speed_limit(car: Node) -> float:
	var route: RoutePath = car.get("route")
	var progress: float = car.get("progress")
	var travel_direction: float = car.get("travel_direction")
	var detection_distance: float = car.get("detection_distance")
	var vehicle_length: float = car.get("vehicle_length")
	var nearest_gap := INF
	var nearest_light: Node
	var nearest_heading := Vector2.ZERO
	for candidate in get_nodes_in_group("traffic_lights"):
		var light := candidate as Node
		if light == null or not light.has_method("requires_stop_for_heading"):
			continue
		var target: Dictionary = light.call("get_stop_target", route, progress, travel_direction, vehicle_length, detection_distance + 500.0)
		if target.is_empty():
			continue
		var bumper_gap := float(target["gap"])
		if bumper_gap >= 0.0 and bumper_gap < nearest_gap:
			nearest_gap = bumper_gap
			nearest_light = light
			nearest_heading = target["heading"]
	if nearest_light == null or not nearest_light.requires_stop_for_heading(
		nearest_heading, float(car.get("speed")), nearest_gap, float(car.get("braking"))
	):
		return float(car.get("cruise_speed"))
	var safe_distance: float = car.get("safe_distance")
	if nearest_gap <= safe_distance:
		return 0.0
	return sqrt(2.0 * float(car.get("braking")) * maxf(nearest_gap - safe_distance, 0.0))
