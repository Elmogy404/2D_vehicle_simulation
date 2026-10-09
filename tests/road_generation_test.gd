extends Node2D


const TEST_SEEDS: Array[int] = [1, 7, 42, 313, 2048, 9191, 24680, 97531, 333333333]

var checks := 0
var failures := 0


func _ready() -> void:
	var road: Node = load("res://scenes/RoadGenerator.tscn").instantiate()
	road.set("enable_hotkeys", false)
	add_child(road)
	await get_tree().physics_frame

	for seed_value in TEST_SEEDS:
		road.generate_with_seed(seed_value)
		await get_tree().physics_frame
		check_seed(road, seed_value)

	road.generate_with_seed(TEST_SEEDS[0])
	var first_snapshot: Array[Vector2] = road.get_center_points()
	road.generate_with_seed(TEST_SEEDS[0])
	check(
		road.get_center_points() == first_snapshot,
		"same seed reproduces identical modular geometry"
	)

	print("ROAD GENERATION TEST: %d checks, %d failures" % [checks, failures])
	get_tree().quit(0 if failures == 0 else 1)


func check_seed(road: Node, seed_value: int) -> void:
	var types: PackedStringArray = road.get_intersection_types()
	check(
		types.has("t_junction") and types.has("four_way") and types.has("roundabout"),
		"seed %d contains every required junction type" % seed_value
	)
	check(
		road.get_road_network().call("graph_is_connected"),
		"seed %d has one connected navigation graph" % seed_value
	)

	var strips_valid := true
	for strip in road.get_node("RoadSurface").get_children():
		if strip is Polygon2D and Geometry2D.triangulate_polygon(strip.polygon).size() != 6:
			strips_valid = false
	check(strips_valid, "seed %d has no folded asphalt strips" % seed_value)

	var probe_shape := CircleShape2D.new()
	probe_shape.radius = 14.0
	var probe := PhysicsShapeQueryParameters2D.new()
	probe.shape = probe_shape
	probe.collision_mask = 1
	probe.collide_with_areas = false
	var centerlines_clear := true
	for path in road.get_map_paths():
		for point in path:
			probe.transform = Transform2D(0.0, point)
			if not get_world_2d().direct_space_state.intersect_shape(probe, 1).is_empty():
				centerlines_clear = false
				break
		if not centerlines_clear:
			break
	check(
		centerlines_clear,
		"seed %d keeps every mapped centerline physically open" % seed_value
	)


func check(condition: bool, label: String) -> void:
	checks += 1
	if condition:
		print("  PASS  " + label)
	else:
		failures += 1
		printerr("  FAIL  " + label)
