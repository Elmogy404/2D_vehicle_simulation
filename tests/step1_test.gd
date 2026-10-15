extends Node


var checks := 0
var failures := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(main)
	await get_tree().process_frame
	main.call("_on_environment_generate_requested", 13579, false, 0)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var road: Node = main.get_node("RoadGenerator")
	var traffic: Node = main.get_node("TrafficManager")
	var light_manager: Node = main.get_node("TrafficLightManager")
	var pedestrian_manager: Node = main.get_node("PedestrianManager")
	var ego: Node = main.get_node("EgoVehicle")
	var route: RoutePath = road.get_route()
	var network: Object = road.call("get_road_network")
	var layout_summary: Dictionary = road.call("get_layout_summary")

	check(route != null and route.is_valid(), "fixed starting arterial route is valid")
	check(network.call("graph_is_connected"), "generated district is one connected graph")
	check(
		float(layout_summary["length"]) >= float(road.get("minimum_map_length")) - 1.0
		and float(layout_summary["length"]) <= float(road.get("maximum_map_length")) + 1.0,
		"generated arterial length stays within the original map-length range"
	)
	check(road.get("seed_value") == 13579, "requested seed is applied")
	var sample_distance := route.length * 0.3
	var center := route.get_position_at(sample_distance)
	var offset_position := route.get_position_at(sample_distance, 50.0)
	var direction := route.get_direction_at(sample_distance)
	var route_right := Vector2(-direction.y, direction.x)
	check(
		(offset_position - center).dot(route_right) > 40.0,
		"positive route offset follows the right-hand traffic side"
	)
	check(
		absf(route.get_rotation_at(sample_distance) - (direction.angle() + PI * 0.5)) < 0.001,
		"route pose rotation matches the travel direction"
	)
	var nearest := route.nearest(offset_position)
	check(
		absf(float(nearest["distance"]) - 50.0) < 10.0
		and absf(float(nearest["progress"]) - sample_distance) < 5.0,
		"route nearest lookup recovers progress and lane offset"
	)
	var pose := route.get_pose_at(sample_distance, 50.0)
	check(
		pose["position"].distance_to(offset_position) < 0.01
		and absf(float(pose["rotation"]) - route.get_rotation_at(sample_distance)) < 0.001,
		"combined route pose matches the individual getters"
	)

	var cars: Array = traffic.get("traffic_cars")
	check(cars.size() == int(traffic.get("number_of_cars")), "all configured NPC cars deploy")
	var graph_routed_cars := 0
	var cars_on_their_roads := true
	var lane_levels: Dictionary = {}
	for car in cars:
		var car_route: RoutePath = car.get("route")
		if car_route == null or not car_route.is_valid():
			cars_on_their_roads = false
			continue
		if car_route != route:
			graph_routed_cars += 1
		var car_nearest: Dictionary = car_route.nearest(car.global_position)
		if float(car_nearest["distance"]) > car_route.get_half_width_at(float(car_nearest["progress"])) + 5.0:
			cars_on_their_roads = false
		lane_levels[int(car.get("lane_index"))] = true
	check(graph_routed_cars > 0, "NPCs use independent graph-planned trips")
	check(cars_on_their_roads, "NPCs spawn on their assigned road and lane")
	check(not lane_levels.is_empty(), "NPC trips preserve per-road lane data")

	var lights: Array = light_manager.get("lights")
	var pedestrians: Array = pedestrian_manager.get("pedestrians")
	check(not lights.is_empty(), "randomized signalized junctions are deployed")
	check(
		pedestrians.size() == lights.size() * int(pedestrian_manager.get("pedestrians_per_crossing")),
		"pedestrians are deployed after the traffic signals"
	)
	check(
		pedestrian_manager.get_node("Crosswalks").get_child_count() > 0,
		"crosswalk markings are built for the graph junctions"
	)

	var ego_near: Dictionary = route.nearest(ego.global_position)
	check(
		float(ego_near["distance"]) <= route.get_half_width_at(float(ego_near["progress"])),
		"player begins on the generated arterial"
	)
	check(
		ego.get_node("Camera2D").is_current(),
		"camera follows the player after environment generation"
	)

	var centerline_before: PackedVector2Array = road.get_center_points()
	var length_before := float(network.call("total_unique_length"))
	road.call("generate_with_seed", 13579)
	var centerline_after: PackedVector2Array = road.get_center_points()
	var regenerated_network: Object = road.call("get_road_network")
	check(
		centerline_before == centerline_after
		and is_equal_approx(length_before, float(regenerated_network.call("total_unique_length"))),
		"the same seed reproduces the same arterial and street-network length"
	)
	check(
		traffic.get("traffic_cars").size() == int(traffic.get("number_of_cars")),
		"regeneration redeploys NPC traffic on the new graph"
	)

	print("STEP1 GRAPH ENVIRONMENT TEST: %d checks, %d failures -> %s" % [
		checks, failures, "PASS" if failures == 0 else "FAIL"
	])
	get_tree().quit(0 if failures == 0 else 1)


func check(condition: bool, label: String) -> void:
	checks += 1
	if condition:
		print("  PASS  " + label)
	else:
		failures += 1
		printerr("  FAIL  " + label)
