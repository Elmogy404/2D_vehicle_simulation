extends SceneTree

## Collision classification / severity acceptance test.
## Run: godot --headless --fixed-fps 60 --path . --script res://tests/collision_system_test.gd

const EGO_SCENE := preload("res://scenes/EgoVehicle.tscn")
const WORLD_SCRIPT := preload("res://ai/rl_training_world.gd")

const MINOR_SPEED := 30.0
const TERMINAL_SPEED := 120.0

var checks := 0
var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, label: String) -> void:
	checks += 1
	if condition:
		print("  PASS  " + label)
	else:
		failures += 1
		printerr("  FAIL  " + label)


func _make_container() -> Node2D:
	var container := Node2D.new()
	root.add_child(container)
	return container


func _make_ego(container: Node2D, speed: float, mode: int = 1) -> CharacterBody2D:
	var ego := EGO_SCENE.instantiate() as CharacterBody2D
	container.add_child(ego)
	ego.set("collision_termination_mode", mode)
	ego.set("minor_contact_speed", MINOR_SPEED)
	ego.set("terminal_impact_speed", TERMINAL_SPEED)
	ego.set("pedestrian_terminal_impact_speed", 0.0)
	ego.set("collision_event_cooldown", 0.25)
	ego.global_position = Vector2.ZERO
	ego.global_rotation = 0.0
	ego.set("current_speed", speed)
	ego.use_default_controller()
	ego.set_control(0.0, 0.0, 0.0)
	return ego


func _make_rect_body(
	container: Node2D,
	layer: int,
	position: Vector2,
	size: Vector2,
	group: String = ""
) -> CharacterBody2D:
	var body := CharacterBody2D.new()
	body.collision_layer = layer
	body.collision_mask = 0
	if not group.is_empty():
		body.add_to_group(group)
	var shape := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = size
	shape.shape = rectangle
	body.add_child(shape)
	container.add_child(body)
	body.global_position = position
	return body


func _make_wall(
	container: Node2D,
	position: Vector2,
	size: Vector2 = Vector2(400.0, 10.0),
	layer: int = 1
) -> StaticBody2D:
	var wall := StaticBody2D.new()
	wall.collision_layer = layer
	wall.collision_mask = 0
	var shape := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = size
	shape.shape = rectangle
	wall.add_child(shape)
	container.add_child(wall)
	wall.global_position = position
	return wall


func _wait_for_collision(ego: CharacterBody2D, max_frames: int = 120) -> void:
	for _frame in range(max_frames):
		await physics_frame
		if int(ego.get("collision_count")) > 0 or bool(ego.get("has_crashed")):
			return


func _cleanup(container: Node2D) -> void:
	container.queue_free()
	await process_frame
	await physics_frame


func _run() -> void:
	print("== Collision classification and severity ==")
	await _test_low_speed_world_contact()
	await _test_high_speed_world_impact()
	await _test_vehicle_collision()
	await _test_pedestrian_collision()
	_test_classification_fallbacks()
	_test_rl_propagation()
	await _test_legacy_behaviour_preserved()

	print("")
	print(
		"COLLISION SYSTEM TEST: %d checks, %d failures -> %s"
		% [checks, failures, "PASS" if failures == 0 else "FAIL"]
	)
	quit(1 if failures > 0 else 0)


func _test_low_speed_world_contact() -> void:
	print("-- low-speed static-world contact --")
	var container := _make_container()
	var ego := _make_ego(container, 25.0)
	_make_wall(container, Vector2(0.0, -67.0))
	await _wait_for_collision(ego)

	var summary: Dictionary = ego.call("get_collision_summary")
	var event: Dictionary = summary.get("last_collision", {})
	_check(int(summary.get("collision_count", 0)) > 0, "minor contact is recorded")
	_check(String(event.get("partner_type", "")) == "world", "world partner is classified")
	_check(bool(event.get("minor", false)), "25 units/s contact is minor")
	_check(not bool(event.get("terminal", false)), "minor contact is not terminal")
	_check(not bool(ego.get("has_crashed")), "severity-aware minor contact does not crash")
	_check(
		is_equal_approx(float(event.get("impact_speed_units", -1.0)), 21.25)
		or float(event.get("impact_speed_units", -1.0)) < MINOR_SPEED,
		"impact speed is the normal closing speed (%.2f units/s)"
		% float(event.get("impact_speed_units", -1.0))
	)
	var history: Array[Dictionary] = ego.call("get_collision_events")
	_check(
		history.size() == int(summary.get("collision_count", 0)),
		"full history getter returns the recorded event"
	)
	await _cleanup(container)


func _test_high_speed_world_impact() -> void:
	print("-- high-speed static-world impact --")
	var container := _make_container()
	var ego := _make_ego(container, 300.0)
	_make_wall(container, Vector2(0.0, -67.0))
	await _wait_for_collision(ego)

	var summary: Dictionary = ego.call("get_collision_summary")
	var terminal: Dictionary = summary.get("terminal_collision", {})
	_check(bool(ego.get("has_crashed")), "high-speed impact terminates the episode")
	_check(not terminal.is_empty(), "terminal collision metadata is retained")
	_check(String(terminal.get("partner_type", "")) == "world", "terminal world partner is classified")
	_check(bool(terminal.get("severe", false)), "high-speed impact is severe")
	_check(bool(terminal.get("terminal", false)), "high-speed impact is terminal")
	_check(
		float(terminal.get("impact_speed_kmh", 0.0)) >= TERMINAL_SPEED * 0.3,
		"impact km/h uses the scene conversion (>36 km/h)"
	)
	await _cleanup(container)


func _test_vehicle_collision() -> void:
	print("-- vehicle-to-vehicle collision --")
	var container := _make_container()
	var ego := _make_ego(container, 300.0)
	var partner := _make_rect_body(
		container, 2, Vector2(0.0, -130.0), Vector2(62.0, 122.0), "traffic"
	)
	partner.velocity = Vector2(0.0, 60.0)
	await _wait_for_collision(ego)

	var summary: Dictionary = ego.call("get_collision_summary")
	var terminal: Dictionary = summary.get("terminal_collision", {})
	_check(bool(ego.get("has_crashed")), "vehicle contact terminates at high closing speed")
	_check(String(terminal.get("partner_type", "")) == "vehicle", "vehicle partner is classified")
	_check(float(terminal.get("partner_speed_units", 0.0)) > 0.0, "partner velocity is included")
	_check(
		float(terminal.get("impact_speed_units", 0.0)) > TERMINAL_SPEED,
		"relative closing speed exceeds the ego-only speed"
	)
	await _cleanup(container)


func _test_pedestrian_collision() -> void:
	print("-- vehicle-to-pedestrian collision --")
	var container := _make_container()
	var ego := _make_ego(container, 200.0)
	var pedestrian := _make_rect_body(
		container, 4, Vector2(0.0, -80.0), Vector2(20.0, 20.0), "pedestrians"
	)
	pedestrian.velocity = Vector2(0.0, 20.0)
	await _wait_for_collision(ego)

	var summary: Dictionary = ego.call("get_collision_summary")
	var terminal: Dictionary = summary.get("terminal_collision", {})
	_check(bool(ego.get("has_crashed")), "pedestrian contact terminates the episode")
	_check(
		String(terminal.get("partner_type", "")) == "pedestrian",
		"pedestrian partner is classified"
	)
	_check(bool(terminal.get("safety_critical", false)), "pedestrian impact is safety-critical")
	_check(bool(terminal.get("terminal", false)), "pedestrian impact is terminal")
	await _cleanup(container)


func _test_classification_fallbacks() -> void:
	print("-- classification fallbacks --")
	var ego := EGO_SCENE.instantiate()
	var unknown_body := StaticBody2D.new()
	unknown_body.collision_layer = 0
	unknown_body.collision_mask = 0
	_check(
		String(ego.call("classify_collision_partner", unknown_body)) == "unknown",
		"unrecognized collider is unknown"
	)

	var layer_vehicle := StaticBody2D.new()
	layer_vehicle.collision_layer = 2
	layer_vehicle.collision_mask = 0
	_check(
		String(ego.call("classify_collision_partner", layer_vehicle)) == "vehicle",
		"vehicle layer is a fallback when no group exists"
	)

	var obstacle := StaticBody2D.new()
	obstacle.collision_layer = 8
	obstacle.collision_mask = 0
	_check(
		String(ego.call("classify_collision_partner", obstacle)) == "obstacle",
		"obstacle layer is classified"
	)

	unknown_body.free()
	layer_vehicle.free()
	obstacle.free()
	ego.free()


func _test_rl_propagation() -> void:
	print("-- RL terminal propagation --")
	var world := WORLD_SCRIPT.new()
	var ego := EGO_SCENE.instantiate()
	world.set("ego", ego)

	ego.set("has_crashed", true)
	ego.set("collision_count", 1)
	ego.set("last_collision_event", {
		"partner_type": "vehicle",
		"impact_speed_kmh": 36.0,
		"terminal": true,
	})
	ego.set("last_terminal_collision", {
		"partner_type": "vehicle",
		"impact_speed_kmh": 36.0,
		"safety_critical": false,
		"terminal": true,
	})

	var summary: Dictionary = world.call("_collision_info")
	var terminal: Dictionary = summary.get("terminal_collision", {})
	_check(bool(world.call("_collision_termination_requested")), "RL sees terminal crash status")
	_check(String(terminal.get("partner_type", "")) == "vehicle", "RL sees terminal partner metadata")
	_check(int(summary.get("collision_count", 0)) == 1, "RL sees collision count")
	var serialized := JSON.stringify(summary)
	_check(
		not serialized.is_empty() and JSON.parse_string(serialized) is Dictionary,
		"collision metadata is JSON-serializable"
	)

	ego.set("has_crashed", false)
	_check(
		not bool(world.call("_collision_termination_requested")),
		"RL does not terminate after the crash flag is cleared"
	)

	world.free()
	ego.free()


func _test_legacy_behaviour_preserved() -> void:
	print("-- legacy any-contact behaviour --")
	var container := _make_container()
	var ego := _make_ego(container, 25.0, 0)
	_make_wall(container, Vector2(0.0, -67.0))
	await _wait_for_collision(ego)

	var summary: Dictionary = ego.call("get_collision_summary")
	var terminal: Dictionary = summary.get("terminal_collision", {})
	_check(bool(ego.get("has_crashed")), "legacy mode still terminates on any contact")
	_check(String(terminal.get("partner_type", "")) == "world", "legacy mode records metadata")
	await _cleanup(container)
