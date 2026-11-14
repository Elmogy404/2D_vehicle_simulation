extends SceneTree

const TEST_SEEDS: Array[int] = [17, 2026, 61307, 7, 99]
const GENERATOR_SCRIPT := preload("res://scripts/segment_road_generator.gd")
const MINIMUM_OVERLAP_AREA := 64.0

var _failures: Array[String] = []
var _aggregate_piece_counts: Dictionary = {}
var _aggregate_removed_streets := 0
var _removed_street_variants: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	var seam_network := RoadNetwork.new()
	seam_network.build([
		PackedVector2Array([Vector2(-10.0, 0.0), Vector2(0.049, 0.0)]),
		PackedVector2Array([Vector2(0.051, 0.0), Vector2(10.0, 0.0)])
	])
	_check(seam_network.graph_is_connected(),
		"centerlines join when floating-point coordinates straddle a rounding bucket")

	var deterministic_specs: Array[Dictionary] = []
	for test_seed in TEST_SEEDS:
		var generator := _generate(test_seed)
		if generator == null:
			continue
		var summary: Dictionary = generator.call("get_generation_summary")
		var specs: Array[Dictionary] = generator.call("get_piece_specs")
		var piece_counts: Dictionary = summary["piece_counts"]
		_check(int(summary["piece_count"]) >= 100 and int(summary["piece_count"]) <= 150,
			"seed %d stays within the configured 100–150 piece budget" % test_seed)
		_check(int(summary["open_socket_count"]) == 0,
			"seed %d leaves no disconnected road sockets" % test_seed)
		_check(String(summary["error"]).is_empty(),
			"seed %d completes without generator errors" % test_seed)
		_check(int(summary["grid_size"]) >= 3,
			"seed %d contains a multi-block street grid" % test_seed)
		_check(not specs.is_empty(), "seed %d creates a non-empty map" % test_seed)
		if not specs.is_empty():
			_check(String(specs[0]["piece_id"]) == "four_way_intersection",
				"seed %d begins at the authored arterial crossing" % test_seed)
			_check(Vector2(specs[0]["position"]).is_zero_approx(),
				"seed %d centers its fixed starting point at the origin" % test_seed)
		_check(not piece_counts.has("dead_end"),
			"seed %d does not place the removed flat dead-end piece" % test_seed)
		if String(summary["error"]).is_empty():
			var road_network: RoadNetwork = generator.get("road_network")
			var route: RoutePath = generator.get("route")
			_check(road_network.graph_is_connected(),
				"seed %d creates one connected drivable centerline graph" % test_seed)
			_check(route.is_valid(),
				"seed %d creates a valid player route" % test_seed)
			_check_all_connections_are_valid(generator, specs, test_seed)
			_check_no_piece_overlays(generator, test_seed)
			_check_uses_piece_owned_straights(generator, test_seed)
		_aggregate_removed_streets += int(summary["removed_local_street_count"])
		_removed_street_variants[int(summary["removed_local_street_count"])] = true
		for piece_id in piece_counts:
			_aggregate_piece_counts[piece_id] = int(_aggregate_piece_counts.get(piece_id, 0)) + int(piece_counts[piece_id])
		if test_seed == TEST_SEEDS[1]:
			deterministic_specs = specs
		print("GRAPH MAP CHECK: seed=%d grid=%dx%d pieces=%d junctions=%d local_edges_removed=%d types=%s" % [
			test_seed,
			int(summary["grid_size"]),
			int(summary["grid_size"]),
			int(summary["piece_count"]),
			int(summary["connection_count"]),
			int(summary["removed_local_street_count"]),
			str(piece_counts)
		])
		generator.free()

	_check(int(_aggregate_piece_counts.get("four_way_intersection", 0)) > 0,
		"the generated map set uses a four-lane arterial crossing")
	_check(int(_aggregate_piece_counts.get("four_way_intersection_2_lane", 0)) > 0,
		"the generated map set uses neighborhood four-way intersections")
	_check(int(_aggregate_piece_counts.get("t_junction_2_lane", 0)) > 0,
		"the generated map set uses neighborhood T-junctions")
	_check(int(_aggregate_piece_counts.get("turn_left", 0)) + int(_aggregate_piece_counts.get("turn_right", 0)) > 0,
		"the generated map set contains curved street corners")
	_check(int(_aggregate_piece_counts.get("lane_transition_4_to_2", 0)) > 0,
		"the arterial/local street hierarchy uses explicit lane transitions")
	_check(int(_aggregate_piece_counts.get("bulb_3_road_junction", 0))
		+ int(_aggregate_piece_counts.get("bulb_4_road_junction", 0)) > 0,
		"the generated map set varies junction geometry with paved bulb hubs")
	_check(_aggregate_removed_streets > 0,
		"the generated map set omits some local streets to vary the block pattern")

	var repeated := _generate(TEST_SEEDS[1])
	if repeated != null:
		var repeated_specs: Array[Dictionary] = repeated.call("get_piece_specs")
		_check(_specs_match(deterministic_specs, repeated_specs),
			"the same seed reproduces the same piece IDs and placements")
		repeated.free()

	_check(_removed_street_variants.size() > 1,
		"different seeds create measurably different neighborhood street patterns")

	if _failures.is_empty():
		print("SEGMENT ROAD GENERATOR TEST PASSED: %d graph seeds, piece-owned straight corridors, topology variety, socket alignment, overlays, and deterministic replay validated." % TEST_SEEDS.size())
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _generate(test_seed: int, minimum_count: int = 100, maximum_count: int = 150) -> Node:
	var generator := GENERATOR_SCRIPT.new() as Node
	if generator == null:
		_check(false, "generator script instantiates")
		return null
	generator.set("generate_on_ready", false)
	generator.set("minimum_piece_count", minimum_count)
	generator.set("maximum_piece_count", maximum_count)
	root.add_child(generator)
	generator.call("generate_with_seed", test_seed)
	return generator


func _check_all_connections_are_valid(generator: Node, specs: Array[Dictionary], test_seed: int) -> void:
	var pieces: Array = generator.get("placed_pieces")
	for piece_index in range(pieces.size()):
		var piece: Dictionary = pieces[piece_index]
		for port_index in range(piece["used_ports"].size()):
			_check(bool(piece["used_ports"][port_index]),
				"seed %d piece %d port %d belongs to a completed road" % [test_seed, piece_index, port_index])

	for connection in generator.get("connections"):
		var piece_a := int(connection["piece_a"])
		var piece_b := int(connection["piece_b"])
		var port_a := _find_port(specs[piece_a], String(connection["port_a"]))
		var port_b := _find_port(specs[piece_b], String(connection["port_b"]))
		_check(not port_a.is_empty() and not port_b.is_empty(),
			"seed %d connection references existing pieces and ports" % test_seed)
		if port_a.is_empty() or port_b.is_empty():
			continue
		_check(Vector2(port_a["position"]).distance_to(Vector2(port_b["position"])) <= 2.0,
			"seed %d joined socket centers align" % test_seed)
		_check(Vector2(port_a["outward"]).dot(Vector2(port_b["outward"])) <= -0.999,
			"seed %d joined sockets face each other" % test_seed)
		_check(int(port_a["total_lanes"]) == int(port_b["total_lanes"]),
			"seed %d joined sockets have equal lane counts" % test_seed)


func _find_port(piece: Dictionary, port_id: String) -> Dictionary:
	for port in piece["ports"]:
		if String(port["id"]) == port_id:
			return port
	return {}


func _check_no_piece_overlays(generator: Node, test_seed: int) -> void:
	var pieces: Array = generator.get("placed_pieces")
	var overlap: String = ""
	var connected_pairs: Dictionary = {}
	for connection in generator.get("connections"):
		var first_piece := mini(int(connection["piece_a"]), int(connection["piece_b"]))
		var second_piece := maxi(int(connection["piece_a"]), int(connection["piece_b"]))
		connected_pairs["%d:%d" % [first_piece, second_piece]] = true
	for first_index in range(pieces.size()):
		var first: Dictionary = pieces[first_index]
		for second_index in range(first_index + 1, pieces.size()):
			if connected_pairs.has("%d:%d" % [first_index, second_index]):
				continue
			var second: Dictionary = pieces[second_index]
			if not first["world_bounds"].intersects(second["world_bounds"]):
				continue
			for first_polygon in first["world_footprints"]:
				for second_polygon in second["world_footprints"]:
					for intersection in Geometry2D.intersect_polygons(first_polygon, second_polygon):
						if _polygon_area(intersection) > MINIMUM_OVERLAP_AREA:
							overlap = "%s[%s] / %s[%s]" % [
								String(first["piece_id"]), str(first["position"]),
								String(second["piece_id"]), str(second["position"])
							]
							break
					if not overlap.is_empty():
						break
				if not overlap.is_empty():
					break
			if not overlap.is_empty():
				break
		if not overlap.is_empty():
			break
	_check(overlap.is_empty(), "seed %d has no unplanned street overlaps (%s)" % [test_seed, overlap])


func _check_uses_piece_owned_straights(generator: Node, test_seed: int) -> void:
	var found_straight_segment := false
	var found_runtime_bezier_link := false
	for piece_data in generator.get("placed_pieces"):
		var piece_id := String(piece_data["piece_id"])
		if piece_id == "road_link":
			found_runtime_bezier_link = true
		if not ["straight_2_lane", "straight_4_lane", "straight_6_lane"].has(piece_id):
			continue
		found_straight_segment = true
		var piece: Node2D = piece_data["node"]
		var ports: Array[Dictionary] = piece.call("get_ports")
		var paths: Array[Dictionary] = piece.call("get_drive_paths")
		_check(ports.size() == 2 and paths.size() == 1,
			"seed %d straight corridor piece owns two sockets and one drive path" % test_seed)
		if ports.size() != 2 or paths.size() != 1:
			continue
		var path: PackedVector2Array = paths[0]["points"]
		_check(path.size() == 2 and is_zero_approx(path[0].x - path[1].x),
			"seed %d generated corridor uses a true local straight-piece surface" % test_seed)
		_check(path[0].is_equal_approx(Vector2(ports[0]["position"]))
			and path[-1].is_equal_approx(Vector2(ports[1]["position"])),
			"seed %d straight surface terminates exactly at its authored sockets" % test_seed)
	_check(found_straight_segment,
		"seed %d builds corridors from its authored straight road pieces" % test_seed)
	_check(not found_runtime_bezier_link,
		"seed %d does not use runtime Bézier road links" % test_seed)


func _polygon_area(polygon: PackedVector2Array) -> float:
	if polygon.size() < 3:
		return 0.0
	var double_area := 0.0
	for point_index in range(polygon.size()):
		double_area += polygon[point_index].cross(polygon[(point_index + 1) % polygon.size()])
	return absf(double_area) * 0.5


func _specs_match(a: Array[Dictionary], b: Array[Dictionary]) -> bool:
	if a.size() != b.size():
		return false
	for index in range(a.size()):
		if String(a[index]["piece_id"]) != String(b[index]["piece_id"]):
			return false
		if not Vector2(a[index]["position"]).is_equal_approx(Vector2(b[index]["position"])):
			return false
		if not is_equal_approx(float(a[index]["rotation"]), float(b[index]["rotation"])):
			return false
	return true


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
