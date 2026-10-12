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
	var main: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main)

	for frame in range(4):
		await get_tree().process_frame

	var road: Node = main.get_node("RoadGenerator")
	var route: RoutePath = road.get_route()
	var cars: Array[Node] = []

	for car in get_tree().get_nodes_in_group("traffic"):
		cars.append(car)

	var valid_strips: bool = true

	for strip in road.get_node("RoadSurface").get_children():
		if not strip is Polygon2D:
			continue

		if Geometry2D.triangulate_polygon(strip.polygon).size() != 6:
			valid_strips = false

	check(valid_strips, "every road strip is a valid convex quad")

	var travelled: Dictionary = {}
	var previous_progress: Dictionary = {}
	var pedestrian_start: Dictionary = {}

	for car in cars:
		travelled[car] = 0.0
		previous_progress[car] = float(car.get("progress"))

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

			var progress: float = float(car.get("progress"))
			var previous: float = float(previous_progress[car])
			var delta_progress: float = absf(progress - previous)

			if delta_progress > route.length * 0.5:
				delta_progress = route.length - delta_progress

			travelled[car] = float(travelled[car]) + maxf(delta_progress, 0.0)
			previous_progress[car] = progress
			var nearest: Dictionary = route.nearest(car.global_position, progress, 260.0)
			max_overflow = maxf(
				max_overflow,
				float(nearest["distance"])
				- route.get_half_width_at(float(nearest["progress"]))
			)

		for i in range(cars.size()):
			for j in range(i + 1, cars.size()):
				if float(cars[i].get("travel_direction")) != float(cars[j].get("travel_direction")):
					continue

				minimum_same_direction_distance = minf(
					minimum_same_direction_distance,
					cars[i].global_position.distance_to(cars[j].global_position)
				)

	var all_cars_progressed: bool = true

	for car in cars:
		if float(travelled[car]) < 500.0:
			all_cars_progressed = false

	var pedestrians_moved: bool = false

	for pedestrian in pedestrian_start:
		if is_instance_valid(pedestrian) and pedestrian.global_position.distance_to(pedestrian_start[pedestrian]) > 30.0:
			pedestrians_moved = true

	check(cars.size() == 8, "all traffic cars survived the stress run")
	check(max_overflow <= 8.0, "traffic stayed inside variable road boundaries")
	check(all_cars_progressed, "no NPC remained permanently frozen")
	check(
		minimum_same_direction_distance >= 45.0,
		"lane merges avoided severe vehicle overlap"
	)
	check(pedestrians_moved, "pedestrians completed movement during signal cycles")

	print("STRESS TEST: %d checks, %d failures" % [checks, failures])
	get_tree().quit(0 if failures == 0 else 1)
