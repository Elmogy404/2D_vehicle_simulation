extends SceneTree

const ROAD_SCENE := preload("res://scenes/RoadGenerator.tscn")

const TEST_SEEDS := [14021, 20711, 39017, 55103]
const MINIMUM_ROUTE_DISTANCE := 5000.0
const MAXIMUM_ROUTE_DISTANCE := 5900.0
const MINIMUM_ROUTE_TURNS := 3


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var road := ROAD_SCENE.instantiate()
	road.set("minimum_map_length", 9000.0)
	road.set("maximum_map_length", 12000.0)
	road.set("minimum_intersections", 6)
	road.set("maximum_intersections", 9)
	road.set("minimum_corridors_per_side", 2)
	road.set("maximum_corridors_per_side", 3)
	road.set("enable_hotkeys", false)
	root.add_child(road)
	await process_frame
	var random := RandomNumberGenerator.new()

	for seed_value in TEST_SEEDS:
		road.call("generate_with_seed", seed_value)
		var network: Object = road.call("get_road_network")
		random.seed = seed_value
		var planned: Dictionary = network.call(
			"choose_random_route",
			MINIMUM_ROUTE_DISTANCE,
			MAXIMUM_ROUTE_DISTANCE,
			MINIMUM_ROUTE_TURNS,
			random
		)
		if planned.is_empty():
			_fail("seed %d did not produce a 5,000-unit route" % seed_value)
			return
		var points: PackedVector2Array = planned["points"]
		var half_widths: PackedFloat32Array = planned["half_widths"]
		if points.size() < 2 or points.size() != half_widths.size():
			_fail("seed %d returned mismatched route geometry/width data" % seed_value)
			return
		if float(planned["length"]) < MINIMUM_ROUTE_DISTANCE:
			_fail("seed %d returned a route below the requested distance" % seed_value)
			return
		if int(planned["turns"]) < MINIMUM_ROUTE_TURNS:
			_fail("seed %d returned %d turns over %.0f units (required %d)" % [
				seed_value, int(planned["turns"]), float(planned["length"]), MINIMUM_ROUTE_TURNS
			])
			return
		if not bool(planned["turn_requirement_met"]):
			_fail("seed %d fell back below its requested turn count" % seed_value)
			return
		for half_width in half_widths:
			if not is_finite(half_width) or half_width < 20.0:
				_fail("seed %d returned an invalid road width" % seed_value)
				return
		print(
			"ROUTE PASS seed=%d length=%.1f turns=%d nodes=%d"
			% [seed_value, planned["length"], planned["turns"], points.size()]
		)

	# Regression for a training rollout that previously sampled three starts
	# with no matching short trip despite having a connected street network.
	road.call("generate_with_seed", 157421314)
	random.seed = 157421314
	var short_network: Object = road.call("get_road_network")
	var short_route: Dictionary = short_network.call(
		"choose_random_route", 410.0, 640.0, 0, random
	)
	if short_route.is_empty():
		_fail("known connected map seed did not produce a short curriculum route")
		return

	print("AI ROUTE PLANNER PASS: long multi-turn routes and sampled-source fallback")
	quit(0)


func _fail(message: String) -> void:
	push_error("AI ROUTE PLANNER FAIL: " + message)
	quit(1)
