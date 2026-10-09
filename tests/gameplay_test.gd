extends Node


# ============================================================
# GAMEPLAY ACCEPTANCE TEST (AGENT.md changes 1-4)
# ------------------------------------------------------------
# Run:  godot --headless --path . res://tests/gameplay_test.tscn
# Exit code 0 = all checks passed, 1 = at least one failed.
#
# Covers:
#   1. NPCs have different, seeded, stable cruise speeds
#   2. Same seed reproduces the same speed assignments
#   3. Ego accelerates progressively (no instant speed)
#   4. Coast decelerates, braking decelerates faster
#   5. Speed HUD matches actual ego velocity
#   6. Collision triggers Game Over + pause
#   7. Crash speed equals the impact speed
#   8. Restart restores the initial state, driveable again
# ============================================================

var failures: int = 0
var checks: int = 0

var main: Node
var ego: Node
var road: Node
var traffic: Node
var hud: Node
var game_over: Node


func _ready() -> void:
	await run_all()

	print("")
	print(
		"GAMEPLAY TEST: %d checks, %d failures -> %s"
		% [checks, failures, "PASS" if failures == 0 else "FAIL"]
	)

	if failures == 0:
		get_tree().quit(0)

	else:
		get_tree().quit(1)


func check(condition: bool, label: String) -> void:
	checks += 1

	if condition:
		print("  PASS  " + label)

	else:
		failures += 1
		printerr("  FAIL  " + label)


func wait_frames(count: int) -> void:
	for i in range(count):
		await get_tree().process_frame


# Timing-sensitive drive measurements must sample once per
# PHYSICS tick: in headless mode the idle loop runs faster
# than 60 Hz, so process_frame would under-count ticks.
func wait_physics(count: int) -> void:
	for i in range(count):
		await get_tree().physics_frame


func release_inputs() -> void:
	Input.action_release("accelerate")
	Input.action_release("brake")
	Input.action_release("steer_left")
	Input.action_release("steer_right")


func reset_drive_state() -> void:
	release_inputs()

	ego.reset_vehicle()

	main.place_ego()


# The ego spawn sits just past the straight opening section,
# so driving straight there would scrape the curve wall and
# distort the speed measurements. Park it on the straight
# part instead (first ~180 units of the route are straight).
func reset_straight_drive() -> void:
	reset_drive_state()

	var route: RoutePath = road.get_route()
	var distance: float = 80.0

	ego.global_position = route.get_position_at(distance, 50.0)
	ego.rotation = route.get_rotation_at(distance)


func traffic_cars() -> Array[Node]:
	var result: Array[Node] = []

	for car in get_tree().get_nodes_in_group("traffic"):
		if is_instance_valid(car):
			result.append(car)

	return result


func sorted_cruises(cars: Array[Node]) -> Array[float]:
	var values: Array[float] = []

	for car in cars:
		values.append(float(car.get("cruise_speed")))

	values.sort()

	return values


func run_all() -> void:
	print("== Loading main scene ==")

	main = load("res://scenes/main.tscn").instantiate()

	add_child(main)

	await wait_frames(3)

	ego = main.get_node("EgoVehicle")
	road = main.get_node("RoadGenerator")
	traffic = main.get_node("TrafficManager")
	hud = main.get_node("SpeedHud")
	game_over = main.get_node("GameOver")
	var light_manager: Node = main.get_node("TrafficLightManager")
	var pedestrian_manager: Node = main.get_node("PedestrianManager")
	var environment_state: Node = main.get_node("EnvironmentState")

	check(
		hud != null and game_over != null,
		"HUD and Game Over nodes exist"
	)

	check(
		environment_state != null,
		"read-only environment state exists"
	)

	check(
		ego.collision_layer == 2 and ego.collision_mask == 7,
		"ego detects world, vehicles, and pedestrians"
	)

	var ego_camera: Camera2D = ego.get_node("Camera2D")

	check(ego_camera.is_current(), "gameplay camera follows the ego by default")
	check(
		ego_camera.position_smoothing_enabled,
		"ego camera uses position smoothing"
	)

	# --------------------------------------------------------
	# SEEDED TRAFFIC LIGHTS
	# --------------------------------------------------------
	print("== Traffic lights ==")

	var light_snapshot: PackedFloat32Array = light_manager.progress_snapshot()

	check(
		light_snapshot.size() >= int(light_manager.get("minimum_lights")),
		"random traffic lights were generated"
	)

	light_manager.regenerate()

	check(
		light_manager.progress_snapshot() == light_snapshot,
		"same light seed reproduces identical positions"
	)
	var signal_types: PackedStringArray = road.get_intersection_types()
	var signal_indices: PackedInt32Array = road.get_intersection_indices()
	var roundabout_feature := signal_types.find("roundabout")
	var roundabout_progress: float = float(
		road.get_route().cumulative[signal_indices[roundabout_feature]]
	)
	check(
		light_manager.light_for_progress(roundabout_progress) == null,
		"roundabout uses circulating priority instead of a traffic signal"
	)
	check(
		light_snapshot.size() == signal_indices.size() - signal_types.count("roundabout"),
		"all signalized junctions receive one seeded traffic-light phase"
	)

	# --------------------------------------------------------
	# COMPLEX ROAD + PEDESTRIANS
	# --------------------------------------------------------
	print("== Road features and pedestrians ==")

	var widths: PackedFloat32Array = road.get_width_profile()
	var width_min: float = INF
	var width_max: float = 0.0

	for width in widths:
		width_min = minf(width_min, width)
		width_max = maxf(width_max, width)

	check(width_max - width_min > 25.0, "road widens and narrows")

	var lane_profile: PackedFloat32Array = road.get_lane_profile()
	var minimum_lanes: int = 99
	var maximum_lanes: int = 0

	for lane_value in lane_profile:
		minimum_lanes = mini(minimum_lanes, maxi(1, int(floor(lane_value + 0.05))))
		maximum_lanes = maxi(maximum_lanes, maxi(1, int(floor(lane_value + 0.05))))

	check(
		minimum_lanes == 1 and maximum_lanes == 3,
		"main road transitions between 1 and 3 lanes per direction"
	)
	check(
		road.get_node("Road").polygon.is_empty(),
		"legacy concave road polygon is disabled"
	)
	check(
		road.get_node("RoadSurface").get_child_count()
		== road.get_center_points().size() - 1,
		"road surface uses artifact-free convex strips"
	)
	check(
		road.get_intersection_indices().size()
		== int(road.get_layout_summary()["intersections"]),
		"seeded variable-count intersections were generated"
	)
	check(
		road.get_turnaround_indices().size() == int(road.get("turnaround_count")),
		"seeded U-turn areas were generated"
	)
	check(
		road.get_node("CrossStreets").get_child_count() > 0,
		"intersections have traversable cross-street geometry"
	)
	check(
		road.get_obstacle_regions().size() > 0
		and road.get_node("ObstacleAreas").get_child_count() > 0,
		"labeled obstacle regions were generated and rendered"
	)

	var junction_types: PackedStringArray = road.get_intersection_types()
	check(
		junction_types.has("t_junction")
		and junction_types.has("four_way")
		and junction_types.has("roundabout"),
		"map guarantees T, four-way, and roundabout pieces"
	)
	check(
		road.get_map_paths().size() > 4,
		"map exposes arterial, side-road, dead-end, and roundabout paths"
	)
	var network: RefCounted = road.get_road_network()
	check(
		network.call("graph_is_connected"),
		"road centerlines form one connected navigation graph"
	)
	check(
		network.call("has_alternate_routes"),
		"road graph contains real loops and alternate paths"
	)
	var graph_positions: Array = network.get("positions")
	var graph_route: PackedVector2Array = network.call(
		"find_path", graph_positions[0], graph_positions[graph_positions.size() - 1]
	)
	check(graph_route.size() > 2, "navigation graph finds a route across the map")

	var probe_shape := CircleShape2D.new()
	probe_shape.radius = 18.0
	var probe := PhysicsShapeQueryParameters2D.new()
	probe.shape = probe_shape
	probe.collision_mask = 1
	probe.collide_with_areas = false
	var centerlines_clear := true
	var blocked_centerline := ""
	var map_paths: Array[PackedVector2Array] = road.get_map_paths()
	for path_index in range(map_paths.size()):
		for point_index in range(map_paths[path_index].size()):
			var map_point: Vector2 = map_paths[path_index][point_index]
			probe.transform = Transform2D(0.0, map_point)
			var hits: Array[Dictionary] = main.get_world_2d().direct_space_state.intersect_shape(probe, 1)
			if not hits.is_empty():
				centerlines_clear = false
				var hit_collider: Node = hits[0].get("collider")
				blocked_centerline = "path %d point %d at %s (%s)" % [
					path_index, point_index, map_point,
					hit_collider.get_path() if hit_collider != null else "unknown"
				]
				break
	check(
		centerlines_clear,
		"all mapped road centerlines are physically traversable" + (
			"" if centerlines_clear else ": " + blocked_centerline
		)
	)

	var minimap: Node = main.get_node("Minimap")
	var minimap_view: Control = minimap.get_node("View")
	var reveal_count := 0
	var point_count := 0
	for flags in minimap_view.get("discovered"):
		point_count += flags.size()
		for flag in flags:
			reveal_count += int(flag)
	check(
		minimap_view.position == Vector2(16.0, 16.0),
		"minimap is anchored in the top-left corner"
	)
	check(
		reveal_count == point_count,
		"minimap displays the complete generated road network"
	)
	var minimap_obstacles: Array = minimap_view.get("obstacles")
	check(
		minimap_obstacles.size() == road.get_obstacle_regions().size(),
		"minimap includes every generated obstacle region"
	)

	var pedestrians: Array = pedestrian_manager.get("pedestrians")
	var expected_pedestrians: int = (
		road.get_intersection_indices().size()
		* int(pedestrian_manager.get("pedestrians_per_intersection"))
	)

	check(
		pedestrians.size() == expected_pedestrians,
		"pedestrians generated at every intersection"
	)

	var pedestrian_layers_ok: bool = true

	for pedestrian in pedestrians:
		if pedestrian.collision_layer != 4 or pedestrian.collision_mask != 1:
			pedestrian_layers_ok = false

	check(pedestrian_layers_ok, "pedestrians use dedicated collision layers")

	var pedestrian_waiting_zones_clear := true
	var pedestrians_per_intersection := int(pedestrian_manager.get("pedestrians_per_intersection"))
	var side_road_half_width := float(road.get("cross_street_width")) * 0.5
	var required_side_clearance := float(pedestrian_manager.get("side_road_clearance"))
	var route: RoutePath = road.get_route()
	var intersection_indices: PackedInt32Array = road.get_intersection_indices()
	for pedestrian_index in range(pedestrians.size()):
		var intersection_number := int(pedestrian_index / pedestrians_per_intersection)
		var route_index := intersection_indices[intersection_number]
		var progress := float(route.cumulative[route_index])
		var center := route.get_position_at(progress)
		var tangent := route.get_direction_at(progress)
		var endpoint: Vector2 = pedestrians[pedestrian_index].get("endpoint_a")
		var along_offset := absf((endpoint - center).dot(tangent))
		if along_offset < side_road_half_width + required_side_clearance - 1.0:
			pedestrian_waiting_zones_clear = false
			break
	check(
		pedestrian_waiting_zones_clear,
		"pedestrians wait beside side-road mouths instead of blocking them"
	)

	if not pedestrians.is_empty():
		var pedestrian: CharacterBody2D = pedestrians[0]
		var linked_light: Node = pedestrian.get("traffic_light")
		linked_light.force_state(2)
		var blocker := CharacterBody2D.new()
		blocker.collision_layer = 2
		blocker.collision_mask = 0
		var blocker_shape := CollisionShape2D.new()
		var blocker_rectangle := RectangleShape2D.new()
		blocker_rectangle.size = Vector2(50.0, 80.0)
		blocker_shape.shape = blocker_rectangle
		blocker.add_child(blocker_shape)
		main.add_child(blocker)
		blocker.global_position = pedestrian.global_position
		var pedestrian_start: Vector2 = pedestrian.global_position
		await wait_physics(5)
		check(
			pedestrian.global_position.distance_to(pedestrian_start) > 1.0,
			"pedestrian clears accidental vehicle overlap without deadlocking"
		)
		blocker.queue_free()

	# --------------------------------------------------------
	# CHANGE 1: variable NPC speeds
	# --------------------------------------------------------
	print("== CHANGE 1: NPC speeds ==")

	var cars: Array[Node] = traffic_cars()

	check(cars.size() == 8, "traffic spawned (%d cars)" % cars.size())

	var ego_rectangle := (
		ego.get_node("CollisionShape2D").shape as RectangleShape2D
	)

	check(
		ego_rectangle != null
		and ego_rectangle.size == Vector2(62.0, 122.0),
		"ego hitbox fits inside its 70x131 sprite"
	)

	var variants: Dictionary = {}
	var npc_hitboxes_fit: bool = true

	for car in cars:
		var sprite: Sprite2D = car.get_node("Sprite2D")
		var shape := (
			car.get_node("CollisionShape2D").shape as RectangleShape2D
		)

		variants[sprite.texture.resource_path] = true

		if shape == null:
			npc_hitboxes_fit = false
			continue

		if shape.size.x > sprite.texture.get_width():
			npc_hitboxes_fit = false

		if shape.size.y > sprite.texture.get_height():
			npc_hitboxes_fit = false

		if not is_equal_approx(
			shape.size.y,
			float(car.get("vehicle_length"))
		):
			npc_hitboxes_fit = false

	check(npc_hitboxes_fit, "NPC hitboxes fit their visible sprites")
	check(variants.size() == 3, "NPC traffic uses 3 deterministic variants")

	if not cars.is_empty():
		var sample_car: Node = cars[0]
		var safe_gap: float = float(sample_car.get("safe_distance"))
		var cruise: float = float(sample_car.get("cruise_speed"))
		var stopped_target: float = sample_car.follow_speed(
			safe_gap,
			0.0
		)
		var open_target: float = sample_car.follow_speed(
			1000.0,
			0.0
		)

		check(stopped_target == 0.0, "NPC stops at its minimum bumper gap")
		check(
			is_equal_approx(open_target, cruise),
			"NPC returns to cruise speed with an open road"
		)

		var lights: Array = light_manager.get("lights")

		if not lights.is_empty():
			var test_light: Node = lights[0]
			test_light.force_state(2)
			sample_car.set("travel_direction", 1.0)
			sample_car.set(
				"progress",
				test_light.stop_progress_for(1.0) - 100.0
			)
			sample_car.set("speed", 100.0)
			var red_limit: float = sample_car.traffic_light_speed_limit()

			check(red_limit < cruise, "NPC brakes for a red traffic light")
			test_light.force_state(0)
			check(
				is_equal_approx(
					sample_car.traffic_light_speed_limit(),
					cruise
				),
				"NPC proceeds through a green traffic light"
			)

			traffic.regenerate()
			cars = traffic_cars()

	var cruises: Array[float] = sorted_cruises(cars)
	var used_lane_indices: Dictionary = {}
	var spawns_avoid_intersections: bool = true

	for car in cars:
		used_lane_indices[int(car.get("lane_index"))] = true

		if traffic.is_near_intersection(float(car.get("progress"))):
			spawns_avoid_intersections = false

	check(used_lane_indices.size() == 3, "NPCs use all three lane levels")
	check(spawns_avoid_intersections, "NPCs do not spawn inside intersections")

	var distinct: Dictionary = {}

	for value in cruises:
		distinct[snappedf(value, 0.01)] = true

	check(
		distinct.size() >= 4,
		"NPC cruise speeds are heterogeneous (%d distinct of %d)"
		% [distinct.size(), cruises.size()]
	)

	var min_speed: float = float(traffic.get("minimum_speed"))
	var max_speed: float = float(traffic.get("maximum_speed"))
	var range_ok: bool = true

	for value in cruises:
		if value < min_speed or value > max_speed:
			range_ok = false

	check(
		range_ok,
		"all cruise speeds inside the configured range [%.0f, %.0f]"
		% [min_speed, max_speed]
	)

	# Cruises must not change while driving (no per-frame RNG).
	await wait_frames(30)

	var cruises_later: Array[float] = sorted_cruises(
		traffic_cars()
	)

	check(
		cruises == cruises_later,
		"cruise speeds stay constant while driving"
	)

	# Same seed -> same assignments.
	traffic.regenerate()

	var cruises_again: Array[float] = sorted_cruises(
		traffic_cars()
	)

	check(
		cruises == cruises_again,
		"same seed reproduces the same speed assignments"
	)

	# --------------------------------------------------------
	# PRIORITY MERGE: ending outside lane yields to through lane
	# --------------------------------------------------------
	print("== Priority lane merge ==")
	traffic.clear_traffic()
	var active_route: RoutePath = road.get_route()
	var merge_progress := -1.0
	for sample in range(0, int(active_route.length) - 350, 25):
		if active_route.get_lane_count_at(float(sample)) == 3 \
		and active_route.get_lane_count_at(float(sample + 300)) < 3:
			merge_progress = float(sample)
			break

	var traffic_scene: PackedScene = load("res://scenes/traffic_car.tscn")
	var merging_car: Node = traffic_scene.instantiate()
	var through_car: Node = traffic_scene.instantiate()
	traffic.add_child(merging_car)
	traffic.add_child(through_car)
	merging_car.setup(active_route, 90, 2, 225.0, 1.0, merge_progress, 110.0)
	through_car.setup(active_route, 91, 1, 135.0, 1.0, merge_progress - 80.0, 125.0)
	merging_car.call("_update_lane_merge", 0.016)
	check(merge_progress >= 0.0, "test located a generated outside-lane ending")
	check(
		bool(merging_car.get("merge_signal_active")),
		"ending-lane car signals before merging"
	)
	check(
		not bool(merging_car.get("lane_change_active")),
		"ending-lane car waits when the continuing lane gap is unsafe"
	)
	check(
		is_equal_approx(float(through_car.call("merge_speed_limit")), float(through_car.get("cruise_speed"))),
		"continuing lane keeps priority and does not yield"
	)

	through_car.set("progress", maxf(merge_progress - 400.0, 0.0))
	through_car.call("snap_to_route")
	merging_car.call("_update_lane_merge", 0.016)
	check(
		bool(merging_car.get("lane_change_active")),
		"ending-lane car accepts a safe gap"
	)
	merging_car.call("_update_lane_merge", float(merging_car.get("merge_duration")) + 0.1)
	check(
		int(merging_car.get("lane_index")) == 1,
		"outside-lane merge completes into the adjacent lane"
	)
	traffic.remove_child(merging_car)
	traffic.remove_child(through_car)
	merging_car.queue_free()
	through_car.queue_free()
	traffic.regenerate()

	# --------------------------------------------------------
	# CHANGE 2: progressive acceleration
	# --------------------------------------------------------
	print("== CHANGE 2: ego acceleration ==")

	reset_straight_drive()

	Input.action_press("accelerate")

	var samples: Array[float] = []

	for i in range(12):
		await get_tree().physics_frame
		samples.append(ego.velocity.length())

	Input.action_release("accelerate")

	var increasing: bool = true

	for i in range(1, samples.size()):
		if samples[i] <= samples[i - 1]:
			increasing = false

	check(
		increasing,
		"speed rises frame by frame (%.0f -> %.0f)"
		% [samples[0], samples[samples.size() - 1]]
	)

	check(
		samples[0] < ego.acceleration * 0.5,
		"speed starts from (at most) one tick, not instantly (%.1f)"
		% samples[0]
	)

	check(
		samples[1] > 0.0
		and samples[1] <= ego.acceleration / 60.0 * 2.0,
		"first physics step adds about one tick of speed (%.1f)"
		% samples[1]
	)

	check(
		samples[samples.size() - 1] < ego.max_speed,
		"still below max after 12 frames (%.0f < %.0f)"
		% [samples[samples.size() - 1], ego.max_speed]
	)

	check(
		samples[samples.size() - 1] > 30.0,
		"actually gained speed (%.0f)" % samples[samples.size() - 1]
	)

	# --------------------------------------------------------
	# CHANGE 2: coast vs brake
	# --------------------------------------------------------
	print("== CHANGE 2: coast and brake ==")

	reset_straight_drive()

	Input.action_press("accelerate")

	await wait_physics(15)

	var v_boost: float = ego.velocity.length()

	Input.action_release("accelerate")

	var v_coast_start: float = ego.velocity.length()

	await wait_physics(10)

	var v_coast_end: float = ego.velocity.length()

	check(
		v_coast_end < v_coast_start,
		"coasting decelerates naturally (%.0f -> %.0f)"
		% [v_coast_start, v_coast_end]
	)

	Input.action_press("accelerate")

	await wait_physics(12)

	Input.action_release("accelerate")

	var v_brake_start: float = ego.velocity.length()

	Input.action_press("brake")

	await wait_physics(5)

	var v_brake_end: float = ego.velocity.length()

	Input.action_release("brake")

	var coast_rate: float = (
		(v_coast_start - v_coast_end) / 10.0
	)

	var brake_rate: float = (
		(v_brake_start - v_brake_end) / 5.0
	)

	check(
		v_brake_end < v_brake_start,
		"braking decelerates (%.0f -> %.0f)"
		% [v_brake_start, v_brake_end]
	)

	check(
		brake_rate > coast_rate * 2.0,
		"braking is clearly stronger than coasting "
		+ "(%.0f vs %.0f per frame)"
		% [brake_rate, coast_rate]
	)

	check(
		v_boost > 0.0,
		"accelerate input produced motion (%.0f)" % v_boost
	)

	# S behaves like an automatic gearbox: brake while moving, then reverse.
	reset_straight_drive()
	Input.action_press("brake")
	await wait_physics(20)
	Input.action_release("brake")
	check(ego.current_speed < 0.0, "brake input engages reverse after stopping")
	check(
		absf(ego.current_speed) <= float(ego.get("max_reverse_speed")),
		"reverse speed obeys its lower configured limit"
	)
	check(ego.get_gear_label() == "R", "vehicle reports reverse gear")
	reset_drive_state()
	check(ego.get_gear_label() == "N", "stopped vehicle reports neutral gear")

	# --------------------------------------------------------
	# CONTROLLER-NEUTRAL COMMANDS + BICYCLE STEERING
	# --------------------------------------------------------
	print("== Vehicle command interface ==")

	reset_straight_drive()
	ego.set_control(1.0, 0.0, 0.0)
	await wait_physics(12)

	check(
		ego.velocity.length() > 30.0,
		"external throttle command drives the vehicle"
	)

	var rotation_before: float = ego.rotation
	ego.set_control(1.0, 0.0, 1.0)
	await wait_physics(15)

	check(
		absf(angle_difference(rotation_before, ego.rotation)) > 0.01,
		"bicycle steering changes heading while moving"
	)

	ego.set_control(0.0, 1.0, 0.0)
	var command_brake_start: float = ego.current_speed
	await wait_physics(5)

	check(
		ego.current_speed < command_brake_start,
		"external brake command reduces speed"
	)

	var state: Dictionary = environment_state.get_state()

	check(
		state.has("speed")
		and state.has("heading_error")
		and state.has("lane_center_error")
		and state.has("road_curvature")
		and state.has("sensor_distances"),
		"environment exposes vehicle, lane, road, and sensor state"
	)

	check(
		float(state.get("normalized_speed", -1.0)) >= 0.0
		and float(state.get("normalized_speed", 2.0)) <= 1.0,
		"environment speed is normalized"
	)

	reset_drive_state()

	# --------------------------------------------------------
	# CHANGE 3: speed HUD
	# --------------------------------------------------------
	print("== CHANGE 3: speed HUD ==")

	reset_straight_drive()

	var speed_label: Label = hud.get("speed_label")

	check(speed_label != null, "HUD exposes its speed label")

	Input.action_press("accelerate")

	await wait_physics(20)

	var v_before: float = ego.velocity.length()

	await get_tree().physics_frame

	var v_now: float = ego.velocity.length()

	Input.action_release("accelerate")

	var label_value: int = -1

	if speed_label != null and speed_label.text.contains(" "):
		label_value = int(speed_label.text.split(" ")[0])

	var expected_before: int = roundi(
		v_before * float(ego.get("kmh_per_unit"))
	)

	var expected_now: int = roundi(
		v_now * float(ego.get("kmh_per_unit"))
	)

	check(
		label_value == expected_before
		or label_value == expected_now,
		"HUD shows the real velocity (label %d, expected %d/%d)"
		% [label_value, expected_before, expected_now]
	)

	reset_drive_state()

	await wait_frames(2)

	check(
		speed_label != null and speed_label.text == "0 km/h",
		"HUD reads 0 when stopped"
	)

	# --------------------------------------------------------
	# CHANGE 4: collision -> Game Over
	# --------------------------------------------------------
	print("== CHANGE 4: collision / Game Over ==")

	reset_drive_state()

	# Aim the ego at the right-hand wall of the straight
	# opening section and drive into it.
	ego.global_position = Vector2(60.0, -20.0)
	ego.rotation = PI

	Input.action_press("accelerate")

	var v_prev: float = ego.velocity.length()
	var detected: bool = false

	for i in range(90):
		await get_tree().physics_frame

		if bool(ego.get("has_crashed")):
			detected = true
			break

		v_prev = ego.velocity.length()

	Input.action_release("accelerate")

	check(detected, "ego collision detected")

	check(
		bool(ego.get("has_crashed")),
		"ego reports has_crashed"
	)

	var crash_speed: float = float(ego.get("crash_speed"))

	check(
		crash_speed > 0.0,
		"crash speed is non-zero (%.0f)" % crash_speed
	)

	check(
		absf(crash_speed - v_prev) <= 12.0,
		"crash speed equals the impact speed "
		+ "(%.0f vs %.0f one frame before)"
		% [crash_speed, v_prev]
	)

	check(
		game_over.visible,
		"Game Over UI is shown"
	)

	check(
		get_tree().paused,
		"gameplay is frozen"
	)

	var speed_text: Label = game_over.get("speed_text")

	check(
		speed_text != null
		and speed_text.text
		== "Speed: %d km/h" % roundi(
			crash_speed * float(ego.get("kmh_per_unit"))
		),
		"Game Over shows the actual crash speed (%s)"
		% (speed_text.text if speed_text != null else "missing")
	)

	# --------------------------------------------------------
	# CHANGE 4: restart
	# --------------------------------------------------------
	print("== CHANGE 4: restart ==")

	var original_cruises: Array[float] = cruises

	var button: Button = game_over.find_child(
		"RestartButton",
		true,
		false
	)

	check(button != null, "Restart button exists")

	if button != null:
		button.pressed.emit()

	await wait_frames(2)

	check(
		not get_tree().paused,
		"simulation unpaused after Restart"
	)

	check(
		not game_over.visible,
		"Game Over UI hidden after Restart"
	)

	check(
		not bool(ego.get("has_crashed")),
		"ego crash state cleared"
	)

	check(
		ego.current_speed == 0.0
		and ego.velocity == Vector2.ZERO,
		"ego velocity reset"
	)

	var spawn_pose: Dictionary = traffic.get_ego_spawn_pose()

	check(
		ego.global_position.distance_to(
			spawn_pose["position"]
		) < 0.1,
		"ego back on its spawn pose"
	)

	var restored_cars: Array[Node] = traffic_cars()

	check(
		restored_cars.size() == 8,
		"traffic rebuilt (%d cars)" % restored_cars.size()
	)

	check(
		sorted_cruises(restored_cars) == original_cruises,
		"traffic speeds restored deterministically"
	)

	# The player must be able to drive again.
	Input.action_press("accelerate")

	await wait_physics(10)

	check(
		ego.velocity.length() > 1.0,
		"ego drives again after Restart (%.0f)"
		% ego.velocity.length()
	)

	Input.action_release("accelerate")
