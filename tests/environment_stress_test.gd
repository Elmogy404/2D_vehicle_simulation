extends Node

var checks: int = 0
var failures: int = 0


func check(condition: bool, label: String) -> void:
	checks += 1

	if condition:
		print("  PASS  " + label)
	else:
		failures += 1
		printerr("  FAIL  " + label)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(main)
	await get_tree().process_frame
	main.call("_on_environment_generate_requested", 97531, false, 0)
	for frame in range(4):
		await get_tree().process_frame
	# This is a traffic-only stress run. Move the parked player out of the
	# generated district so NPCs are not correctly queued behind a stationary ego.
	var ego: Node2D = main.get_node("EgoVehicle")
	ego.global_position = Vector2(-100000.0, -100000.0)

	var road: Node = main.get_node("RoadGenerator")
	var cars: Array[Node] = []

	for car in get_tree().get_nodes_in_group("traffic"):
		cars.append(car)

	var valid_strips: bool = true

	for strip in road.get_node("OriginalRoadGenerator/RoadSurface").get_children():
		if not strip is Polygon2D:
			continue

		if Geometry2D.triangulate_polygon(strip.polygon).size() != 6:
			valid_strips = false

	check(valid_strips, "every road strip is a valid convex quad")

	var travelled: Dictionary = {}
	var previous_position: Dictionary = {}
	var stationary_frames: Dictionary = {}
	var pedestrian_start: Dictionary = {}

	for car in cars:
		travelled[car] = 0.0
		previous_position[car] = car.global_position
		stationary_frames[car] = 0

	for pedestrian in get_tree().get_nodes_in_group("pedestrians"):
		pedestrian_start[pedestrian] = pedestrian.global_position

	var max_overflow: float = -INF
	var minimum_same_direction_distance: float = INF

	# Thirty simulated seconds covers several signal phases and the important
	# 3->2->1 lane merges.
	for frame in range(1800):
		await get_tree().physics_frame

		for car in cars:
			if not is_instance_valid(car):
				continue
			var frame_distance := Vector2(previous_position[car]).distance_to(car.global_position)
			travelled[car] = float(travelled[car]) + frame_distance
			# Slow crawl speeds move less than 0.5 units per 60 Hz frame, so use
			# a small epsilon rather than mistaking deliberate low-speed movement
			# for a freeze.
			stationary_frames[car] = 0 if frame_distance > 0.01 else int(stationary_frames[car]) + 1
			previous_position[car] = car.global_position
			var car_route: RoutePath = car.get("route")
			if car_route == null or not car_route.is_valid():
				max_overflow = INF
				continue
			var nearest: Dictionary = car_route.nearest(car.global_position)
			var overflow := float(nearest["distance"]) \
				- car_route.get_half_width_at(float(nearest["progress"]))
			max_overflow = maxf(max_overflow, overflow)

		for i in range(cars.size()):
			for j in range(i + 1, cars.size()):
				if float(cars[i].get("travel_direction")) != float(cars[j].get("travel_direction")):
					continue

				minimum_same_direction_distance = minf(
					minimum_same_direction_distance,
					cars[i].global_position.distance_to(cars[j].global_position)
				)

	var no_permanently_frozen_cars := true
	for car in cars:
		if int(stationary_frames[car]) >= 1200:
			no_permanently_frozen_cars = false
			printerr("LONG STOP id=%s stationary=%d travel=%.1f speed=%.1f progress=%.1f/%.1f leader=%s light=%.1f" % [
				str(car.get_instance_id()), int(stationary_frames[car]), float(travelled[car]),
				float(car.get("speed")), float(car.get("progress")), float(car.get("route").length),
				str(car.call("leader_state")), float(car.call("traffic_light_speed_limit"))
			])
	var pedestrians_moved: bool = false

	for pedestrian in pedestrian_start:
		if is_instance_valid(pedestrian) and pedestrian.global_position.distance_to(pedestrian_start[pedestrian]) > 30.0:
			pedestrians_moved = true

	check(cars.size() == 8, "all traffic cars survived the stress run")
	check(max_overflow <= 8.0, "traffic stayed inside variable road boundaries")
	check(no_permanently_frozen_cars, "no NPC remained stopped for 20 simulated seconds")
	check(
		minimum_same_direction_distance >= 45.0,
		"lane merges avoided severe vehicle overlap"
	)
	check(pedestrians_moved, "pedestrians completed movement during signal cycles")

	print("STRESS TEST: %d checks, %d failures" % [checks, failures])
	get_tree().quit(0 if failures == 0 else 1)
