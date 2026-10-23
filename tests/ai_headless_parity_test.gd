extends SceneTree
## Removing artwork must preserve physics, route choice, and action results.

class TestWorld extends "res://ai/rl_training_world.gd":
	var response: Dictionary = {}
	func _ready() -> void:
		_setup_training_world()
		set_process(false)
	func _send_message(message: Dictionary) -> void:
		response = message

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		printerr("FAIL: ", message)

func _colliders(node: Node, result: Array) -> void:
	if node is CollisionShape2D:
		var shape: Shape2D = node.shape
		var geometry: Variant = shape.size if shape is RectangleShape2D else shape.radius
		result.append([node.global_transform, shape.get_class(), geometry])
	for child in node.get_children():
		_colliders(child, result)

func _snapshot(seed_value: int, stage: int, visuals: bool) -> Dictionary:
	var world := TestWorld.new()
	world.visible_mode = visuals
	root.add_child(world)
	var error: String = await world._reset_episode(seed_value, false, stage)
	_check(error.is_empty(), "reset for visual parity")
	var colliders := []
	_colliders(world.road_generator, colliders)
	var network: Object = world.road_generator.get_road_network()
	var snapshot := {"colliders": colliders, "points": world.route.points.duplicate(),
		"graph": network.get("positions").duplicate(), "start": world.start_progress,
		"goal": world.goal_progress, "steps": []}
	for i in range(12):
		await world._step_episode([0.0, 0.5])
		snapshot["steps"].append([world.response["observation"], world.response["reward"],
			world.ego.global_position, world.episode_physics_ticks])
	world.queue_free()
	await physics_frame
	await physics_frame
	return snapshot

func _run() -> void:
	for seed_value in [4101, 12000]:
		for stage in [0, 3, 7]:
			var headless: Dictionary = await _snapshot(seed_value, stage, false)
			var visible: Dictionary = await _snapshot(seed_value, stage, true)
			_check(headless == visible, "artwork changed colliders/graph/route/trajectory: seed=%d stage=%d" % [seed_value, stage])
	var world := TestWorld.new()
	root.add_child(world)
	await world._reset_episode(4101, false, 0)
	var first_seed: int = world.road_generator.get("seed_value")
	for i in range(7):
		await world._reset_episode(4102 + i, false, 0, true)
		_check(world.road_generator.get("seed_value") == first_seed, "training map was not reused")
		_check(world._trip_is_clear(world.route, world.start_progress, world.goal_progress), "cached map admitted an unsafe trip")
	_check(world.map_episodes == 8, "map reuse episode limit")
	await world._reset_episode(4200, false, 0, true)
	_check(world.road_generator.get("seed_value") != first_seed, "training map was not refreshed after eight episodes")
	world.queue_free()
	print("HEADLESS PARITY: six visual/physics comparisons, bounded map reuse; failures=", failures)
	quit(1 if failures else 0)
