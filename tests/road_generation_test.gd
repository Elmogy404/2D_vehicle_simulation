extends Node2D


const TEST_SEEDS: Array[int] = [
	0, 1, 2, 3, 7, 11, 19, 42, 99, 313,
	777, 1024, 2048, 4096, 9191, 24680, 55555,
	97531, 123456789, 333333333
]

var checks := 0
var failures := 0


func _ready() -> void:
	var road: Node = load("res://scenes/RoadGenerator.tscn").instantiate()
	road.set("enable_hotkeys", false)
	add_child(road)
	await get_tree().physics_frame
	var layout_signatures: Dictionary = {}

	for seed_value in TEST_SEEDS:
		road.generate_with_seed(seed_value)
		await get_tree().physics_frame
		var summary: Dictionary = road.get_layout_summary()
		var signature := "%d:%d:%d:%d:%d" % [
			roundi(float(summary["length"]) / 100.0),
			int(summary["intersections"]),
			int(summary["left_corridors"]),
			int(summary["right_corridors"]),
			road.get_map_paths().size()
		]
		layout_signatures[signature] = true
		check_seed(road, seed_value)
	check(
		layout_signatures.size() >= TEST_SEEDS.size() - 1,
		"different seeds produce substantially different topology profiles"
	)

	road.generate_with_seed(TEST_SEEDS[0])
	var first_snapshot: Array[Vector2] = road.get_center_points()
	var first_paths: Array[PackedVector2Array] = road.get_map_paths()
	var first_obstacles: Array[Dictionary] = road.get_obstacle_regions()
	road.generate_with_seed(TEST_SEEDS[0])
	check(
		road.get_center_points() == first_snapshot,
		"same seed reproduces identical modular geometry"
	)
	check(
		road.get_map_paths() == first_paths and road.get_obstacle_regions() == first_obstacles,
		"same seed reproduces the complete topology and obstacle layout"
	)

	print("ROAD GENERATION TEST: %d checks, %d failures" % [checks, failures])
	get_tree().quit(0 if failures == 0 else 1)


func check_seed(road: Node, seed_value: int) -> void:
	var summary: Dictionary = road.get_layout_summary()
	var types: PackedStringArray = road.get_intersection_types()
	check(
		types.has("t_junction") and types.has("four_way") and types.has("roundabout"),
		"seed %d contains every required junction type" % seed_value
	)
	check(
		road.get_road_network().call("graph_is_connected"),
		"seed %d has one connected navigation graph" % seed_value
	)
	check(
		road.get_road_network().call("has_alternate_routes"),
		"seed %d contains loops and alternate routes" % seed_value
	)
	var long_secondary_roads := 0
	var map_paths: Array[PackedVector2Array] = road.get_map_paths()
	for path_index in range(1, map_paths.size()):
		var path_length := 0.0
		for point_index in range(map_paths[path_index].size() - 1):
			path_length += map_paths[path_index][point_index].distance_to(
				map_paths[path_index][point_index + 1]
			)
		if path_length > 900.0:
			long_secondary_roads += 1
	check(
		long_secondary_roads >= 4,
		"seed %d generates four or more continuous secondary roads" % seed_value
	)
	check(
		map_paths.size() >= 12,
		"seed %d generates a dense collection of connected streets" % seed_value
	)
	var bounds: Rect2 = road.get_map_bounds()
	check(
		maxf(bounds.size.x, bounds.size.y) > 5200.0
		and minf(bounds.size.x, bounds.size.y) > 1750.0,
		"seed %d generates a large variable-size district" % seed_value
	)
	check(
		int(summary["intersections"]) >= int(road.get("minimum_intersections"))
		and int(summary["intersections"]) <= int(road.get("maximum_intersections")),
		"seed %d keeps randomized junction counts inside configured limits" % seed_value
	)
	var obstacles: Array[Dictionary] = road.get_obstacle_regions()
	var obstacles_valid := not obstacles.is_empty()
	for obstacle in obstacles:
		var obstacle_size: Vector2 = obstacle.get("size", Vector2.ZERO)
		if String(obstacle.get("label", "")).is_empty() or obstacle_size.x <= 0.0:
			obstacles_valid = false
	check(
		obstacles_valid,
		"seed %d generates labeled non-drivable obstacle regions" % seed_value
	)

	var strips_valid := true
	for strip in road.get_node("RoadSurface").get_children():
		if strip is Polygon2D and Geometry2D.triangulate_polygon(strip.polygon).size() != 6:
			strips_valid = false
	check(strips_valid, "seed %d has no folded asphalt strips" % seed_value)
	check_boundary_chains(road, seed_value)
	check_secondary_boundary_chains(road, seed_value)

	var probe_shape := CircleShape2D.new()
	probe_shape.radius = 14.0
	var probe := PhysicsShapeQueryParameters2D.new()
	probe.shape = probe_shape
	probe.collision_mask = 1
	probe.collide_with_areas = false
	var centerlines_clear := true
	var blocked := ""
	var paths: Array[PackedVector2Array] = road.get_map_paths()
	var road_classes: PackedStringArray = road.get_layout_summary()["road_classes"]
	for path_index in range(paths.size()):
		for point_index in range(paths[path_index].size()):
			var point: Vector2 = paths[path_index][point_index]
			probe.transform = Transform2D(0.0, point)
			var hits: Array[Dictionary] = get_world_2d().direct_space_state.intersect_shape(probe, 1)
			if not hits.is_empty():
				centerlines_clear = false
				var collider: Node = hits[0].get("collider")
				var path_class := "arterial" if path_index == 0 else road_classes[path_index - 1]
				blocked = " path %d (%s) point %d at %s collider %s" % [
					path_index, path_class, point_index, point,
					collider.get_path() if collider != null else "unknown"
				]
				break
		if not centerlines_clear:
			break
	check(
		centerlines_clear,
		"seed %d keeps every mapped centerline physically open%s" % [seed_value, blocked]
	)


func check_boundary_chains(road: Node, seed_value: int) -> void:
	var edge_container: Node = road.get_node("EdgeMarkings")
	var left: Array[Vector2] = road.get("left_points")
	var right: Array[Vector2] = road.get("right_points")
	var centers: Array[Vector2] = road.get_center_points()
	var inset_left: Array[Vector2] = road.call("_inset_boundary_points", left, centers)
	var inset_right: Array[Vector2] = road.call("_inset_boundary_points", right, centers)
	var expected_segments := (left.size() - 1) * 2
	var bands := 0
	var aligned := true
	var seen_segments: Dictionary = {}
	for band in edge_container.get_children():
		if not band is Polygon2D or not band.is_in_group("main_road_outlines"):
			aligned = false
			continue
		var segment_index := int(band.get_meta("segment_index"))
		var boundary_side := float(band.get_meta("boundary_side"))
		if segment_index < 0 or segment_index >= left.size() - 1 \
		or not is_equal_approx(absf(boundary_side), 1.0):
			aligned = false
			continue
		var segment_key := "%d:%d" % [segment_index, int(boundary_side)]
		if seen_segments.has(segment_key):
			aligned = false
		seen_segments[segment_key] = true
		var outer: Array[Vector2] = left if boundary_side > 0.0 else right
		var inner: Array[Vector2] = inset_left if boundary_side > 0.0 else inset_right
		var expected := PackedVector2Array([
			outer[segment_index], outer[segment_index + 1],
			inner[segment_index + 1], inner[segment_index]
		])
		if band.polygon.size() != 4 or float(band.get_meta("outline_inset")) != 4.0:
			aligned = false
			continue
		for vertex_index in range(4):
			if band.polygon[vertex_index].distance_squared_to(expected[vertex_index]) > 0.001:
				aligned = false
		bands += 1
	var cross_streets: Node = road.get_node("CrossStreets")
	var junctions_draw_over_outline := edge_container.get_index() < cross_streets.get_index()
	check(
		aligned and bands == expected_segments and seen_segments.size() == expected_segments \
		and junctions_draw_over_outline,
		"seed %d keeps continuous exact-edge outlines; junction asphalt masks only real overlaps"
		% seed_value
	)


func check_secondary_boundary_chains(road: Node, seed_value: int) -> void:
	var paths: Array[PackedVector2Array] = road.get_map_paths()
	var widths: PackedFloat32Array = road.get("secondary_path_widths")
	var edge_container: Node = road.get_node("CrossStreets")
	var edge_bands: Array[Polygon2D] = []
	for child in edge_container.get_children():
		if child is Polygon2D and child.is_in_group("secondary_road_outlines"):
			edge_bands.append(child)
	var aligned := not edge_bands.is_empty()
	for band in edge_bands:
		var path_index := int(band.get_meta("path_index")) + 1
		var segment_index := int(band.get_meta("segment_index"))
		var side_index := int(band.get_meta("side_index"))
		if path_index <= 0 or path_index >= paths.size():
			aligned = false
			continue
		var path := paths[path_index]
		if segment_index < 0 or segment_index >= path.size() - 1:
			aligned = false
			continue
		var half_width := widths[path_index - 1] * 0.5
		var is_ring := path.size() > 12 and path[0].distance_squared_to(path[-1]) < 1.0
		var start := path[segment_index]
		var finish := path[segment_index + 1]
		var segment := finish - start
		var start_trim := 0.0 if is_ring else float(road.call("_junction_clearance", start, half_width))
		var finish_trim := 0.0 if is_ring else float(road.call("_junction_clearance", finish, half_width))
		if segment.length() < 1.0 or start_trim + finish_trim >= segment.length() - 12.0 \
		or (not is_ring and road.call("_segment_inside_roundabout", start, finish)):
			aligned = false
			continue
		var start_t := start_trim / segment.length()
		var finish_t := 1.0 - finish_trim / segment.length()
		var edges: Dictionary = road.call("_get_secondary_path_edges", path, half_width, is_ring)
		var side_edges: Array[Vector2] = edges["left"] if side_index == 0 else edges["right"]
		var edge_start := side_edges[segment_index].lerp(side_edges[segment_index + 1], start_t)
		var edge_finish := side_edges[segment_index + 1].lerp(
			side_edges[segment_index], 1.0 - finish_t
		)
		var direction := segment.normalized()
		var start_reference := start + direction * start_trim
		var finish_reference := finish - direction * finish_trim
		var inset := float(band.get_meta("outline_inset"))
		var expected := PackedVector2Array([
			edge_start, edge_finish,
			edge_finish + (finish_reference - edge_finish).normalized() * inset,
			edge_start + (start_reference - edge_start).normalized() * inset
		])
		if band.polygon.size() != 4 or inset != 4.0:
			aligned = false
			continue
		for vertex_index in range(4):
			if band.polygon[vertex_index].distance_squared_to(expected[vertex_index]) > 0.001:
				aligned = false
	check(
		aligned,
		"seed %d secondary outline polygons match mitered and trimmed asphalt edges" % seed_value
	)


func check(condition: bool, label: String) -> void:
	checks += 1
	if condition:
		print("  PASS  " + label)
	else:
		failures += 1
		printerr("  FAIL  " + label)
