extends SceneTree

## Authoritative drivable-area and footprint acceptance test.
## Run: godot --headless --fixed-fps 60 --path . --script res://tests/drivable_area_test.gd

const ROAD_SCENE := preload("res://scenes/RoadGenerator.tscn")
const SEGMENT_GENERATOR := preload("res://scripts/segment_road_generator.gd")
const EGO_SCENE := preload("res://scenes/EgoVehicle.tscn")
const DRIVING_TASK := preload("res://scripts/driving_task.gd")
const WORLD_SCRIPT := preload("res://ai/rl_training_world.gd")
const CAR_SIZE := Vector2(62.0, 122.0)
const ROAD_HALF_WIDTH := 80.0
const QUERY_MARGIN := 0.5
const QUERY_SPACING := 8.0

var checks := 0
var failures := 0


class NetworkRoadGenerator:
	extends Node
	var network: RefCounted

	func get_road_network() -> RefCounted:
		return network


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, label: String) -> void:
	checks += 1
	if condition:
		print("  PASS  " + label)
	else:
		failures += 1
		printerr("  FAIL  " + label)


func _run() -> void:
	print("== Drivable area query ==")
	_test_straight_lane()
	_test_intersection_and_road_mouth()
	_test_curve()
	await _test_generated_maps()
	await _test_collision_and_off_road_are_independent()
	await _test_gameplay_headless_parity()

	print("")
	print(
		"DRIVABLE AREA TEST: %d checks, %d failures -> %s"
		% [checks, failures, "PASS" if failures == 0 else "FAIL"]
	)
	quit(1 if failures > 0 else 0)


func _straight_network(half_width: float = ROAD_HALF_WIDTH) -> RoadNetwork:
	var network := RoadNetwork.new()
	var paths: Array[PackedVector2Array] = [
		PackedVector2Array([Vector2(0.0, -1200.0), Vector2(0.0, 1200.0)])
	]
	var widths: Array[PackedFloat32Array] = [
		PackedFloat32Array([half_width, half_width])
	]
	network.build(paths, widths)
	return network


func _query(network: RoadNetwork, center: Vector2, rotation: float = 0.0) -> Dictionary:
	return network.query_footprint_drivable(
		center, rotation, CAR_SIZE, QUERY_MARGIN, QUERY_SPACING
	)


func _test_straight_lane() -> void:
	print("-- straight lane and boundary footprint --")
	var network := _straight_network()

	var centered := _query(network, Vector2(0.0, 0.0))
	_check(bool(centered["drivable"]), "centered vehicle is drivable")
	_check(bool(centered["center_drivable"]), "centered point is inside the road")
	_check(int(centered["outside_sample_count"]) == 0, "centered footprint has no outside samples")

	var near_boundary := _query(network, Vector2(47.0, 0.0))
	_check(bool(near_boundary["drivable"]), "vehicle near the boundary remains drivable")
	_check(
		float(near_boundary["min_clearance_units"]) > 0.0
		and float(near_boundary["min_clearance_units"]) < 10.0,
		"near-boundary clearance is small but positive"
	)

	var partial := _query(network, Vector2(55.0, 0.0))
	_check(not bool(partial["drivable"]), "partially outside footprint is off-road")
	_check(bool(partial["center_drivable"]), "partially outside vehicle center is still on-road")
	_check(int(partial["outside_sample_count"]) > 0, "partial footprint reports outside samples")

	var outside := _query(network, Vector2(200.0, 0.0))
	_check(not bool(outside["drivable"]), "fully outside footprint is off-road")
	_check(not bool(outside["center_drivable"]), "fully outside center is off-road")
	_check(int(outside["inside_sample_count"]) == 0, "fully outside footprint has no inside samples")


func _test_intersection_and_road_mouth() -> void:
	print("-- intersection and road mouth --")
	var intersection := RoadNetwork.new()
	var paths: Array[PackedVector2Array] = [
		PackedVector2Array([Vector2(0.0, -900.0), Vector2.ZERO, Vector2(0.0, 900.0)]),
		PackedVector2Array([Vector2(-900.0, 0.0), Vector2.ZERO, Vector2(900.0, 0.0)]),
	]
	var widths: Array[PackedFloat32Array] = [
		PackedFloat32Array([80.0, 80.0]),
		PackedFloat32Array([80.0, 80.0]),
	]
	intersection.build(paths, widths)
	var in_intersection := _query(intersection, Vector2.ZERO, PI * 0.25)
	_check(bool(in_intersection["drivable"]), "vehicle inside an intersection is drivable")
	_check(
		int(intersection.get_intersection_nodes().size()) == 1,
		"crossing roads produce one junction node"
	)

	var mouth := RoadNetwork.new()
	var mouth_paths: Array[PackedVector2Array] = [
		PackedVector2Array([Vector2(0.0, -900.0), Vector2.ZERO, Vector2(0.0, 900.0)]),
		PackedVector2Array([Vector2.ZERO, Vector2(900.0, 0.0)]),
	]
	var mouth_widths: Array[PackedFloat32Array] = [
		PackedFloat32Array([80.0, 80.0]),
		PackedFloat32Array([60.0, 60.0]),
	]
	mouth.build(mouth_paths, mouth_widths)
	var through_mouth := _query(mouth, Vector2(5.0, 0.0), PI * 0.5)
	_check(bool(through_mouth["drivable"]), "vehicle passing through a road mouth is drivable")
	_check(
		int(mouth.get_intersection_nodes().size()) == 1,
		"road mouth joins at a shared junction node"
	)


func _test_curve() -> void:
	print("-- curved segment --")
	var points := PackedVector2Array()
	# Build a real quarter arc around the origin, centered on angle zero.
	for index in range(41):
		var angle := -PI * 0.25 + PI * 0.5 * float(index) / 40.0
		points.append(Vector2(cos(angle), sin(angle)) * 300.0)
	var network := RoadNetwork.new()
	var paths: Array[PackedVector2Array] = [points]
	var widths: Array[PackedFloat32Array] = []
	var profile := PackedFloat32Array()
	for _point in points:
		profile.append(70.0)
	widths.append(profile)
	network.build(paths, widths)

	var on_curve := _query(network, Vector2(300.0, 0.0), PI)
	_check(bool(on_curve["drivable"]), "vehicle on a curved segment is drivable")
	_check(
		float(on_curve["center_clearance_units"]) > 0.0,
		"curved-segment center has positive clearance"
	)
	var off_curve := _query(network, Vector2(390.0, 0.0), PI)
	_check(not bool(off_curve["drivable"]), "vehicle outside a curved segment is off-road")


func _test_generated_maps() -> void:
	print("-- generated road networks --")
	var road := ROAD_SCENE.instantiate()
	road.set("generate_on_ready", false)
	road.set("enable_hotkeys", false)
	root.add_child(road)
	road.call("generate_with_seed", 17)
	await process_frame
	_check_generated_map(road, "original generator")

	var route: RoutePath = road.get_route()
	var network: RoadNetwork = road.get_road_network()
	var route_center := route.get_position_at(route.length * 0.5)
	var route_rotation := route.get_rotation_at(route.length * 0.5)
	var state := _query(network, route_center, route_rotation)
	_check(bool(state["drivable"]), "generated arterial route center is drivable")

	var intersection_nodes := network.get_intersection_nodes()
	if not intersection_nodes.is_empty():
		var node := int(intersection_nodes[0])
		var axis := network.get_node_axis(node)
		var junction_state := _query(
			network,
			network.get_node_position(node),
			axis.angle() + PI * 0.5
		)
		_check(bool(junction_state["drivable"]), "generated intersection is drivable")

	var paths: Array[PackedVector2Array] = road.get_map_paths()
	if paths.size() > 1 and paths[1].size() > 1:
		var mouth: Vector2 = paths[1][0]
		var direction: Vector2 = (paths[1][1] - mouth).normalized()
		var mouth_state := _query(network, mouth, direction.angle() + PI * 0.5)
		_check(bool(mouth_state["drivable"]), "generated secondary road mouth is drivable")

	road.free()

	var segment := SEGMENT_GENERATOR.new() as Node2D
	segment.set("generate_on_ready", false)
	segment.set("minimum_piece_count", 100)
	segment.set("maximum_piece_count", 150)
	root.add_child(segment)
	segment.call("generate_with_seed", 17)
	await process_frame
	_check_generated_map(segment, "segmented generator")

	var pieces: Array[Dictionary] = segment.get("placed_pieces")
	var turn_piece := _find_piece(pieces, "turn_left")
	if turn_piece == null:
		turn_piece = _find_piece(pieces, "turn_right")
	if turn_piece != null:
		var drive_paths: Array[Dictionary] = turn_piece.call("get_drive_paths")
		if not drive_paths.is_empty():
			var local_points: PackedVector2Array = drive_paths[0]["points"]
			var world_points := PackedVector2Array()
			for point in local_points:
				world_points.append(turn_piece.to_global(point))
			var index := world_points.size() / 2
			var tangent := (world_points[mini(index + 1, world_points.size() - 1)]
				- world_points[maxi(index - 1, 0)]).normalized()
			var turn_state := _query(
				segment.get_road_network(),
				world_points[index],
				tangent.angle() + PI * 0.5
			)
			_check(bool(turn_state["drivable"]), "authored curved road piece is drivable")

	var mouth_piece := _find_piece(pieces, "t_junction")
	if mouth_piece == null:
		mouth_piece = _find_piece(pieces, "four_way_intersection")
	if mouth_piece != null:
		var drive_paths: Array[Dictionary] = mouth_piece.call("get_drive_paths")
		if not drive_paths.is_empty():
			var local_points: PackedVector2Array = drive_paths[0]["points"]
			var mouth := mouth_piece.to_global(local_points[0])
			var direction := (mouth_piece.to_global(local_points[1]) - mouth).normalized()
			var mouth_state := _query(
				segment.get_road_network(),
				mouth,
				direction.angle() + PI * 0.5
			)
			_check(bool(mouth_state["drivable"]), "authored road mouth is drivable")

	segment.free()


func _check_generated_map(generator: Node, label: String) -> void:
	var network: RoadNetwork = generator.get_road_network()
	_check(network.positions.size() >= 2, label + " produced a road graph")
	_check(network.edge_count() > 0, label + " produced drivable edges")
	var route: RoutePath = generator.get_route()
	_check(route != null and route.is_valid(), label + " produced a route")
	if route == null or not route.is_valid():
		return
	var progress := route.length * 0.35
	var state := _query(
		network,
		route.get_position_at(progress),
		route.get_rotation_at(progress)
	)
	_check(bool(state["drivable"]), label + " route footprint is drivable")


func _find_piece(pieces: Array[Dictionary], piece_id: String) -> Node2D:
	for piece_data in pieces:
		if String(piece_data.get("piece_id", "")) == piece_id:
			return piece_data.get("node") as Node2D
	return null


func _test_collision_and_off_road_are_independent() -> void:
	print("-- collision and off-road independence --")
	var network := _straight_network()
	var generator := NetworkRoadGenerator.new()
	generator.network = network
	root.add_child(generator)

	var container := Node2D.new()
	root.add_child(container)
	var ego := EGO_SCENE.instantiate() as CharacterBody2D
	container.add_child(ego)
	ego.set_physics_process(false)
	ego.global_position = Vector2(60.0, 0.0)
	ego.global_rotation = 0.0
	ego.set("current_speed", 180.0)
	ego.call("use_default_controller")
	ego.call("set_control", 0.0, 0.0, 0.0)

	var wall := StaticBody2D.new()
	wall.collision_layer = 1
	wall.collision_mask = 2
	var shape := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = Vector2(400.0, 10.0)
	shape.shape = rectangle
	wall.add_child(shape)
	container.add_child(wall)
	wall.global_position = Vector2(60.0, -67.0)

	await physics_frame
	for _step in range(30):
		ego.call("_physics_process", 1.0 / 60.0)
		if bool(ego.get("has_crashed")):
			break

	var task := DRIVING_TASK.new()
	task.ego = ego
	task.road_generator = generator
	var state: Dictionary = task.get_drivable_state()
	_check(bool(ego.get("has_crashed")), "ego records the wall collision")
	_check(bool(state.get("off_road", false)), "off-road state is recorded at the collision tick")
	_check(bool(state.get("center_drivable", false)), "center can remain on-road while footprint is outside")
	_check(
		bool(state.get("off_road", false)) and bool(ego.get("has_crashed")),
		"collision and off-road are independently true"
	)

	var world := WORLD_SCRIPT.new()
	world.set("ego", ego)
	world.set("road_generator", generator)
	var ai_state: Dictionary = world.call("_drivable_state")
	_check(bool(ai_state.get("off_road", false)), "headless RL sees off-road at collision")
	_check(
		bool(world.call("_collision_termination_requested")),
		"headless RL sees terminal collision at the same tick"
	)

	container.queue_free()
	generator.queue_free()
	world.free()
	await process_frame
	await physics_frame


func _test_gameplay_headless_parity() -> void:
	print("-- gameplay / headless RL parity --")
	var road := ROAD_SCENE.instantiate()
	road.set("generate_on_ready", false)
	road.set("enable_hotkeys", false)
	root.add_child(road)
	road.call("generate_with_seed", 29)
	await process_frame

	var ego := EGO_SCENE.instantiate() as CharacterBody2D
	root.add_child(ego)
	var route: RoutePath = road.get_route()
	var progress := route.length * 0.45
	var center := route.get_position_at(progress)
	ego.global_position = center
	ego.global_rotation = route.get_rotation_at(progress)

	var gameplay_task := DRIVING_TASK.new()
	gameplay_task.ego = ego
	gameplay_task.road_generator = road
	var gameplay_state: Dictionary = gameplay_task.get_drivable_state()

	var world := WORLD_SCRIPT.new()
	world.set("ego", ego)
	world.set("road_generator", road)
	var headless_state: Dictionary = world.call("_drivable_state")

	var network: RoadNetwork = road.get_road_network()
	var direct_state := _query(network, ego.global_position, ego.global_rotation)
	_check(
		bool(gameplay_state.get("drivable", false)) == bool(direct_state.get("drivable", false)),
		"gameplay query matches the network query"
	)
	_check(
		bool(headless_state.get("drivable", false)) == bool(direct_state.get("drivable", false)),
		"headless RL query matches the network query"
	)
	_check(
		bool(gameplay_state.get("off_road", false)) == bool(headless_state.get("off_road", false)),
		"gameplay and headless RL agree on off-road state"
	)
	_check(
		int(gameplay_state.get("outside_sample_count", -1))
		== int(headless_state.get("outside_sample_count", -2)),
		"gameplay and headless RL agree on footprint sampling"
	)

	# Move the ego completely off the pavement and repeat the comparison.
	ego.global_position = center + route.get_normal_at(progress) * (route.get_half_width_at(progress) + 300.0)
	gameplay_state = gameplay_task.get_drivable_state()
	headless_state = world.call("_drivable_state")
	direct_state = _query(network, ego.global_position, ego.global_rotation)
	_check(not bool(gameplay_state.get("drivable", true)), "gameplay detects a fully off-road ego")
	_check(not bool(headless_state.get("drivable", true)), "headless RL detects a fully off-road ego")
	_check(
		bool(gameplay_state.get("off_road", false))
		and bool(headless_state.get("off_road", false)),
		"gameplay and RL both record the off-road state"
	)

	ego.queue_free()
	road.queue_free()
	world.free()
	await process_frame
