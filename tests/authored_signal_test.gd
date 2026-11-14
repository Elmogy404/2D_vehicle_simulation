extends SceneTree
const LIGHT = preload("res://scripts/traffic_light.gd")
const CAR = preload("res://scenes/traffic_car.tscn")
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		printerr(message)

func _run() -> void:
	for angle in [0.0, PI * 0.5, 0.37]:
		var light := LIGHT.new()
		root.add_child(light)
		var outward := Vector2.UP.rotated(angle)
		var axis := Vector2.RIGHT.rotated(angle)
		light.configure_network(Vector2(1600, 900), axis, 0, 1000.0, 0, [{
			"outward": outward, "half_width": 180.0,
			"stop_center_local": Vector2(0, -330), "stop_line_is_authored": true}])
		light.set_process(false)
		light.force_state(TrafficLight.SignalState.RED)
		var stop := light.to_global(Vector2(0, -330))
		var route := RoutePath.new()
		route.build([stop + outward * 600.0, light.global_position, light.global_position + axis * 600.0])
		route.direction_blend_distance = 0.0
		var car := CAR.instantiate()
		root.add_child(car)
		car.set_physics_process(false)
		car.route = route
		car.travel_direction = 1.0
		car.cruise_speed = 100.0
		car.progress = 600.0 - car.vehicle_length * 0.5 - 20.0
		car.snap_to_route()
		var target := light.get_stop_target(route, car.progress, 1.0, car.vehicle_length, 820.0)
		check(not target.is_empty(), "authored incoming approach was missed")
		if not target.is_empty():
			check(absf(float(target["gap"]) - 20.0) < 0.01, "stop line was shifted by estimated intersection width")
			check(Vector2(target["heading"]).dot(-outward) > 0.99, "signal used outgoing turn heading")
			check(car.traffic_light_speed_limit() == 0.0, "NPC did not stop at authored red line")
		car.progress = 750.0
		check(light.get_stop_target(route, car.progress, 1.0, car.vehicle_length, 820.0).is_empty(), "car inside junction was stopped again")
		car.free()
		light.free()
	print("AUTHORED SIGNALS: failures=", failures)
	quit(1 if failures else 0)
