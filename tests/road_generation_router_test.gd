extends SceneTree

const ROUTER_SCRIPT := preload("res://scripts/road_generation_router.gd")
const SEGMENTED_MODE := 1
const ORIGINAL_MODE := 0
const TEST_SEED := 20261015

var failures: Array[String] = []
var regeneration_count := 0
var router: Node2D


func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	router = ROUTER_SCRIPT.new() as Node2D
	if router == null:
		push_error("Could not instantiate the road-generation router.")
		quit(1)
		return
	root.add_child(router)
	router.connect("road_regenerated", _on_road_regenerated)

	router.call("set_generator_type", SEGMENTED_MODE)
	router.call("generate_with_seed", TEST_SEED)
	_check_active_generator("segmented", 200)
	var segmented_spawn: Dictionary = router.call("get_player_spawn_pose", 45.0)
	_check(
		segmented_spawn.has("position")
		and Vector2(segmented_spawn.get("position", Vector2.ONE)).distance_to(Vector2(0.0, 45.0)) < 0.1,
		"segmented mode provides a player start beside the fixed map-centre point"
	)
	var route_rng := RandomNumberGenerator.new()
	route_rng.seed = TEST_SEED
	var segmented_trip: Dictionary = router_network().call(
		"choose_random_route", 4360.0, 4440.0, 1, route_rng
	)
	_check(not segmented_trip.is_empty(),
		"segmented mode can plan a long destination route containing a turn")
	var maximum_distance_rng := RandomNumberGenerator.new()
	maximum_distance_rng.seed = TEST_SEED + 1
	var maximum_distance_trip: Dictionary = router_network().call(
		"choose_random_route", 5660.0, 5740.0, 1, maximum_distance_rng
	)
	_check(not maximum_distance_trip.is_empty(),
		"segmented mode can plan a route near the AI target slider maximum")

	router.call("set_generator_type", ORIGINAL_MODE)
	router.call("generate_with_seed", TEST_SEED)
	_check_active_generator("original", -1)
	_check(regeneration_count == 2, "both selected generators emit the shared regeneration signal")

	if failures.is_empty():
		print("ROAD GENERATION ROUTER TEST PASSED: both map modes expose the simulation road API.")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _check_active_generator(label: String, expected_pieces: int) -> void:
	var route: RoutePath = router_route()
	var network: Object = router_network()
	_check(route != null and route.is_valid(), "%s mode provides a valid player route" % label)
	_check(network != null and network.get("positions").size() > 2,
		"%s mode provides a connected road graph" % label)
	if network != null and network.has_method("graph_is_connected"):
		_check(bool(network.call("graph_is_connected")), "%s mode's road graph is connected" % label)
	_check(not router_paths().is_empty(), "%s mode exposes map roads to the minimap" % label)
	var width_profile: PackedFloat32Array = router.call("get_width_profile")
	var lane_profile: PackedFloat32Array = router.call("get_lane_profile")
	_check(not width_profile.is_empty() and width_profile.size() == lane_profile.size(),
		"%s mode exposes matched road-width and lane profiles" % label)
	var summary: Dictionary = router.call("get_generation_summary")
	_check(String(summary.get("error", "")).is_empty(), "%s mode reports no generation error" % label)
	if expected_pieces >= 0:
		_check(int(router.call("get_piece_count")) == expected_pieces,
			"segmented mode generates exactly %d road pieces" % expected_pieces)
	_check(float(router.get("lane_width")) > 0.0,
		"%s mode exposes lane width to gameplay systems" % label)


func router_route() -> RoutePath:
	return router.call("get_route") as RoutePath


func router_network() -> Object:
	return router.call("get_road_network") as Object


func router_paths() -> Array[PackedVector2Array]:
	return router.call("get_map_paths")


func _on_road_regenerated() -> void:
	regeneration_count += 1


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	failures.append(description)
