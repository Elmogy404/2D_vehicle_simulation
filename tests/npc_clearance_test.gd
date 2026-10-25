extends SceneTree
const MAIN = preload("res://scenes/main.tscn")
const CLEARANCE = preload("res://scripts/vehicle_clearance.gd")
var failures := 0
class RetryManager extends "res://scripts/traffic_manager.gd":
	var requested_distances: Array[float] = []
	func _assign_next_trip_candidate(_car: Node, _start: int, _previous: int,
			minimum: float, _maximum: float, _turns: int) -> bool:
		requested_distances.append(minimum)
		return minimum < 650.0

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		printerr(message)

func _run() -> void:
	var retry_manager := RetryManager.new()
	retry_manager.traffic_enabled = true
	var actor := Node.new()
	check(retry_manager.assign_next_trip(actor, 0, 1), "rejected long route never tried a shorter safe handoff")
	check(retry_manager.requested_distances == [650.0, 650.0, 650.0, 120.0], "handoff fallback was not bounded")
	actor.free()
	retry_manager.free()
	check(not CLEARANCE.bodies_overlap(Vector2.ZERO, 0.0, Vector2(62, 122), Vector2(90, 0), 0.0, Vector2(62, 122)), "adjacent lane falsely blocks handoff")
	check(CLEARANCE.bodies_overlap(Vector2.ZERO, 0.0, Vector2(62, 122), Vector2(0, 140), 0.0, Vector2(62, 122)), "unsafe same-lane entry was accepted")
	check(not CLEARANCE.bodies_overlap(Vector2.ZERO, 0.0, Vector2(62, 122), Vector2(73, 0), 0.0, Vector2(16, 25), Vector2(6, 6)), "waiting curb pedestrian falsely blocks handoff")
	var main := MAIN.instantiate()
	root.add_child(main)
	for mode in [0, 1]:
		main._on_environment_generate_requested(20261015, false, mode)
		await main.environment_generated
		var manager := main.get_node("TrafficManager")
		var cars: Array = manager.traffic_cars
		check(cars.size() == (20 if mode == 1 else 8), "validated spawning lost the configured traffic population")
		for car in cars:
			car.set_physics_process(false)
			var body_size := Vector2(car.vehicle_width, car.vehicle_length)
			var clearance := CLEARANCE.new(body_size, 2.0)
			check(clearance.is_clear(root.get_world_2d().direct_space_state, car.global_position, car.global_rotation), "NPC body spawned in a wall")
			check(manager._route_is_clear(car.route, car.lane_index, body_size, car.progress), "accepted NPC route intersects walls")
	var manager := main.get_node("TrafficManager")
	var sample_trip := {"points": PackedVector2Array([Vector2(-1000, 0), Vector2.ZERO, Vector2(0, 1000)]),
		"half_widths": PackedFloat32Array([180, 180, 180]), "lane_profile": PackedFloat32Array([2, 2, 2])}
	var turn_route: RoutePath = manager._route_from_trip_data(RoadNetwork.new(), sample_trip, 90.0)
	var corner := float(turn_route.nearest(Vector2.ZERO)["progress"])
	check(turn_route.get_lane_count_at(corner) == 1 and turn_route.get_lane_count_at(0.0) == 2, "turning traffic did not prepare a single approach lane")
	check(absf(turn_route.get_lane_offset_at(corner, 0, 1.0) + 15.0) < 0.01, "turn target hugs the inside curb")
	var origin := Vector2(200000, 200000)
	var wall := StaticBody2D.new()
	wall.position = origin + Vector2(300, 45)
	var collider := CollisionShape2D.new()
	var box := RectangleShape2D.new()
	box.size = Vector2(60, 60)
	collider.shape = box
	wall.add_child(collider)
	root.add_child(wall)
	await physics_frame
	await physics_frame
	check(not manager._network_spawn_is_clear(wall.position + Vector2(75, 0), PI * 0.5), "center-clear spawn with overlapping rear bumper was accepted")
	var route := RoutePath.new()
	route.build([origin, origin + Vector2(1000, 0)], PackedFloat32Array([90, 90]))
	check(not manager._route_is_clear(route, 0, Vector2(62, 122), 70.0), "route through an obstacle was accepted")
	check(manager._route_is_clear(route, 0, Vector2(62, 122), 500.0), "clear route after an obstacle was rejected")
	wall.queue_free()
	main.queue_free()
	print("NPC CLEARANCE: failures=", failures)
	quit(1 if failures else 0)
