extends Node


# ============================================================
# STEP 1 ACCEPTANCE TEST
# ------------------------------------------------------------
# Run:  godot --headless --path . res://tests/step1_test.tscn
# Exit code 0 = all checks passed, 1 = at least one failed.
#
# Covers:
#   1. RoutePath API (pose / rotation / offset side / nearest)
#   2. Ego placement inside its lane
#   3. Traffic spawn count, bidirectional lanes, lane sides
#   4. Lane containment + separation while driving
#   5. Determinism (same seed -> same road, same spawn state)
#   6. Regeneration rebuilds traffic on the new route
#   7. Re-entry wrap at both route ends
# ============================================================

var failures: int = 0
var checks: int = 0


func _ready() -> void:
	await run_all()

	print("")
	print(
		"STEP1 TEST: %d checks, %d failures -> %s"
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


func run_all() -> void:
	print("== Loading main scene ==")

	var main: Node = load("res://scenes/main.tscn").instantiate()

	add_child(main)

	# Frame 0: road + ego.  Frame 1: traffic spawn.
	await wait_frames(3)

	var road: Node = main.get_node("RoadGenerator")
	var traffic: Node = main.get_node("TrafficManager")
	var ego: Node = main.get_node("EgoVehicle")

	var route: RoutePath = road.get_route()

	check(route != null and route.is_valid(), "route is valid")
	check(route.length > 1000.0, "route has length (%.0f)" % route.length)

	var road_width: float = road.get("road_width")

	# --------------------------------------------------------
	# 1. RoutePath API
	# --------------------------------------------------------
	print("== RoutePath API ==")

	var sample_distance: float = route.length * 0.3

	var center: Vector2 = route.get_position_at(sample_distance)
	var offset_position: Vector2 = route.get_position_at(
		sample_distance,
		50.0
	)

	var direction: Vector2 = route.get_direction_at(sample_distance)
	var right: Vector2 = Vector2(-direction.y, direction.x)

	check(
		(offset_position - center).dot(right) > 40.0,
		"positive offset lands on the right of travel direction"
	)

	var expected_rotation: float = direction.angle() + PI / 2.0

	check(
		absf(route.get_rotation_at(sample_distance) - expected_rotation) < 0.001,
		"rotation follows direction.angle() + PI/2"
	)

	var near: Dictionary = route.nearest(offset_position)

	check(
		absf(float(near["distance"]) - 50.0) < 10.0,
		"nearest() of an offset pose keeps the lateral distance (%.0f)"
		% float(near["distance"])
	)

	check(
		absf(float(near["progress"]) - sample_distance) < 5.0,
		"nearest() progress round-trips (%.1f vs %.1f)"
		% [float(near["progress"]), sample_distance]
	)

	var hinted: Dictionary = route.nearest(
		offset_position,
		sample_distance,
		200.0
	)

	check(
		absf(float(hinted["progress"]) - sample_distance) < 5.0,
		"nearest() with hint finds the same progress"
	)

	var pose: Dictionary = route.get_pose_at(sample_distance, 50.0)

	check(
		pose["position"].distance_to(offset_position) < 0.01
		and absf(float(pose["rotation"]) - route.get_rotation_at(sample_distance)) < 0.001,
		"get_pose_at() matches the individual getters"
	)

	# --------------------------------------------------------
	# 2. Ego placement
	# --------------------------------------------------------
	print("== Ego placement ==")

	check(
		ego.is_in_group("vehicle_obstacle"),
		"ego is tagged as a vehicle obstacle"
	)

	var ego_near: Dictionary = route.nearest(ego.global_position)

	check(
		float(ego_near["distance"]) <= road_width * 0.5,
		"ego is on the road (%.0f <= %.0f)"
		% [float(ego_near["distance"]), road_width * 0.5]
	)

	var ego_lateral_side: float = (
		ego.global_position
		- route.get_position_at(float(ego_near["progress"]))
	).dot(
		(
			route.get_direction_at(float(ego_near["progress"]))
		)
	)

	# Recompute with a proper right vector.
	var ego_dir: Vector2 = route.get_direction_at(
		float(ego_near["progress"])
	)

	ego_lateral_side = (
		ego.global_position
		- route.get_position_at(float(ego_near["progress"]))
	).dot(Vector2(-ego_dir.y, ego_dir.x))

	check(
		ego_lateral_side > 0.0,
		"ego starts on the right-hand (with-traffic) side"
	)

	# --------------------------------------------------------
	# 3. Traffic spawn
	# --------------------------------------------------------
	print("== Traffic spawn ==")

	var cars: Array[Node] = []

	for car in get_tree().get_nodes_in_group("traffic"):
		if is_instance_valid(car) and car.get("route") == route:
			cars.append(car)

	var expected_cars: int = traffic.get("number_of_cars")

	check(
		cars.size() == expected_cars,
		"all %d cars spawned (%d found)"
		% [expected_cars, cars.size()]
	)

	var has_forward: bool = false
	var has_backward: bool = false
	var sides_ok: bool = true

	for car in cars:
		var travel: float = float(car.get("travel_direction"))
		var offset: float = float(car.get("lane_offset"))

		if travel > 0.0:
			has_forward = true

		else:
			has_backward = true

		# Right-hand traffic: with-traffic lane on the right
		# half (positive offset), against-traffic on the left.
		if offset * travel <= 0.0:
			sides_ok = false

	check(has_forward and has_backward, "both travel directions present")
	check(sides_ok, "every lane sits on its correct side of the road")

	# Snapshot initial progress for the movement check.
	var initial_progress: Dictionary = {}

	for car in cars:
		initial_progress[car] = float(car.get("progress"))

	# --------------------------------------------------------
	# 4. Driving: containment + separation
	# --------------------------------------------------------
	print("== Driving (300 frames) ==")

	await wait_frames(300)

	var max_lateral: float = 0.0
	var max_road_overflow: float = -INF
	var moved_count: int = 0

	for car in cars:
		if not is_instance_valid(car):
			continue

		var car_near: Dictionary = route.nearest(
			car.global_position
		)

		max_lateral = maxf(
			max_lateral,
			float(car_near["distance"])
		)
		max_road_overflow = maxf(
			max_road_overflow,
			float(car_near["distance"])
			- route.get_half_width_at(float(car_near["progress"]))
		)

		if absf(
			float(car.get("progress"))
			- float(initial_progress[car])
		) > 100.0:
			moved_count += 1

	check(
		max_road_overflow <= 5.0,
		"no car left the variable-width drivable area (overflow %.0f)"
		% max_road_overflow
	)

	check(
		moved_count >= cars.size() - 1,
		"cars are moving (%d of %d advanced >100 units)"
		% [moved_count, cars.size()]
	)

	var min_same_lane: float = INF
	var min_cross_lane: float = INF
	var ego_min_distance: float = INF

	for i in range(cars.size()):
		if not is_instance_valid(cars[i]):
			continue

		for j in range(i + 1, cars.size()):
			if not is_instance_valid(cars[j]):
				continue

			var a: Node = cars[i]
			var b: Node = cars[j]

			var distance: float = (
				a.global_position.distance_to(b.global_position)
			)

			if int(a.get("lane_id")) == int(b.get("lane_id")):
				var gap: float = absf(
					float(a.get("progress")) - float(b.get("progress"))
				)

				gap = minf(gap, route.length - gap)

				min_same_lane = minf(min_same_lane, gap)

			else:
				min_cross_lane = minf(min_cross_lane, distance)

		ego_min_distance = minf(
			ego_min_distance,
			cars[i].global_position.distance_to(
				ego.global_position
			)
		)

	check(
		min_same_lane >= 100.0,
		"same-lane spacing kept (%.0f >= 100)" % min_same_lane
	)

	check(
		min_cross_lane >= 60.0,
		"opposing lanes kept apart (%.0f >= 60)" % min_cross_lane
	)

	check(
		ego_min_distance >= 100.0,
		"traffic kept distance from the ego (%.0f >= 100)"
		% ego_min_distance
	)

	# --------------------------------------------------------
	# 5. Determinism
	# --------------------------------------------------------
	print("== Determinism ==")

	var center_before: Array[Vector2] = road.get_center_points()

	# Two back-to-back regenerations with the same seed. Both
	# snapshots are taken with zero physics elapsed, so they
	# must match exactly (cross-run determinism is verified by
	# comparing the printed checksum between test runs).
	road.call("generate_with_seed", int(road.get("seed_value")))

	var center_a: Array[Vector2] = road.get_center_points()

	var spawn_a: String = spawn_state_string(
		live_cars_from_tree()
	)

	road.call("generate_with_seed", int(road.get("seed_value")))

	var center_b: Array[Vector2] = road.get_center_points()

	var spawn_b: String = spawn_state_string(
		live_cars_from_tree()
	)

	print("  INFO  spawn checksum: " + spawn_a)

	check(
		center_before == center_a and center_a == center_b,
		"same seed reproduces the identical centerline"
	)

	check(
		spawn_a == spawn_b,
		"same seed reproduces the identical spawn state\n"
		+ "         first:  " + spawn_a + "\n"
		+ "         second: " + spawn_b
	)

	# --------------------------------------------------------
	# 6. Regeneration wiring
	# --------------------------------------------------------
	print("== Regeneration ==")

	route = road.get_route()

	var fresh_cars: Array[Node] = live_cars_from_tree()

	check(
		fresh_cars.size() == expected_cars,
		"traffic rebuilt after regeneration (%d cars)"
		% fresh_cars.size()
	)

	var route_shared: bool = true
	var spawn_on_road: bool = true

	for car in fresh_cars:
		if car.get("route") != route:
			route_shared = false

		var car_near: Dictionary = route.nearest(
			car.global_position
		)

		if float(car_near["distance"]) > route.get_half_width_at(
			float(car_near["progress"])
		) + 5.0:
			spawn_on_road = false

	check(route_shared, "every car follows the current route")
	check(spawn_on_road, "every car spawned on the new road")

	var ego_near2: Dictionary = route.nearest(ego.global_position)

	check(
		float(ego_near2["distance"]) <= road_width * 0.5 + 5.0,
		"ego was re-placed on the new road"
	)

	# --------------------------------------------------------
	# 7. Re-entry wrap (both directions)
	# --------------------------------------------------------
	print("== Re-entry ==")

	await test_reentry()


func test_reentry() -> void:
	var main: Node = get_child(0)

	var road: Node = main.get_node("RoadGenerator")

	var route: RoutePath = road.get_route()

	var ego: Node = main.get_node("EgoVehicle")

	# Park the ego mid-route on lane 0, clear of every spawn
	# point, the parking slots below, and both re-entry zones
	# ([0,222) and (3738,3960)). Orientation must follow the
	# route or the long body clips the road wall on curves.
	var ego_slot: float = route.length * 0.15

	ego.position = route.get_position_at(ego_slot, 50.0)
	ego.rotation = float(route.get_pose_at(ego_slot)["rotation"])

	var chosen: Array[Node] = []
	var directions: Array[float] = [1.0, -1.0]

	for wanted in directions:
		for car in live_cars_from_tree():
			if float(car.get("travel_direction")) == wanted:
				chosen.append(car)
				break

	check(
		chosen.size() == 2,
		"found one car per direction for the wrap test"
	)

	if chosen.size() < 2:
		return

	# Park every non-chosen car at a distinct mid-route slot.
	# Slots run 0.30L..0.80L step 400: clear of the entry
	# zones, of each other (400 > car length), of the ego at
	# 0.15L, and of the chosen cars at either exit.
	var slot: int = 0

	for car in live_cars_from_tree():
		if car in chosen:
			continue

		car.set(
			"progress",
			route.length * 0.30 + float(slot) * 400.0
		)

		car.call("snap_to_route")
		slot += 1

	# Place each test car just before its exit.
	for car in chosen:
		var travel: float = float(car.get("travel_direction"))
		var exit: float = car.call("exit_progress")

		car.set(
			"progress",
			exit - 40.0 * travel
		)

		car.set("speed", 120.0)
		car.set("cruise_speed", 120.0)

		car.call("snap_to_route")

	# Drive: both cars should reach their exit, find the
	# re-entry clear, and wrap to the opposite end.
	await wait_frames(150)

	var wrapped_forward: bool = false
	var wrapped_backward: bool = false

	for car in chosen:
		if not is_instance_valid(car):
			continue

		var progress: float = float(car.get("progress"))
		var travel: float = float(car.get("travel_direction"))

		var car_near: Dictionary = route.nearest(
			car.global_position
		)

		var on_road: bool = (
			float(car_near["distance"]) <= 75.0
		)

		if travel > 0.0:
			# Exited near the end, now near the start.
			wrapped_forward = (
				progress < route.length * 0.25 and on_road
			)

		else:
			# Exited near the start, now near the end.
			wrapped_backward = (
				progress > route.length * 0.75 and on_road
			)

	check(
		wrapped_forward,
		"forward car wrapped to the route start (progress %.0f)"
		% (
			float(chosen[0].get("progress"))
			if is_instance_valid(chosen[0]) else -1.0
		)
	)

	check(
		wrapped_backward,
		"backward car wrapped to the route end (progress %.0f)"
		% (
			float(chosen[1].get("progress"))
			if is_instance_valid(chosen[1]) else -1.0
		)
	)

	# The car must physically match its claimed progress.
	for car in chosen:
		if not is_instance_valid(car):
			continue

		var near: Dictionary = route.nearest(
			car.global_position
		)

		check(
			float(near["distance"]) <= 75.0,
			"wrapped car sits on the road again (%.0f)"
			% float(near["distance"])
		)


# ============================================================
# HELPERS
# ============================================================

func live_cars_from_tree() -> Array[Node]:
	var result: Array[Node] = []
	var main: Node = get_child(0)
	var road: Node = main.get_node("RoadGenerator")
	var route: RoutePath = road.get_route()

	for car in get_tree().get_nodes_in_group("traffic"):
		if is_instance_valid(car) and car.get("route") == route:
			result.append(car)

	return result


# Compact, order-independent description of the spawn state,
# used for determinism comparisons and cross-run checksums.
func spawn_state_string(cars: Array[Node]) -> String:
	var entries: Array[String] = []

	for car in cars:
		if not is_instance_valid(car):
			continue

		entries.append(
			"%d|%d|%.2f|%.2f|%.1f|%.1f"
			% [
				int(car.get("lane_id")),
				int(car.get("travel_direction")),
				float(car.get("lane_offset")),
				float(car.get("progress")),
				snappedf(float(car.get("speed")), 0.01),
				snappedf(float(car.get("cruise_speed")), 0.01)
			]
		)

	entries.sort()
	return ";".join(entries)
