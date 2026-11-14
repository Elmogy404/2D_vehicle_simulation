extends SceneTree
## Identical car/route state must produce identical live and training inputs.
const MAIN = preload("res://scenes/main.tscn")
const TASK = preload("res://scripts/driving_task.gd")
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

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		printerr(message)

func _run() -> void:
	var main := MAIN.instantiate()
	root.add_child(main)
	var world := TestWorld.new()
	root.add_child(world)
	var training_ego := world.ego
	world.ego = main.ego_vehicle
	training_ego.queue_free()
	for mode in [0, 1]:
		main.get_node("SettingsPopup").emit_signal("generate_requested", 20261015, false, mode)
		await main.environment_generated
		await physics_frame
		await physics_frame
		main._set_dynamic_actors_enabled(false)
		main.ai_target_distance = 1000.0
		main._begin_ai_goal()
		check(not main.ai_failed, "live planner could not find a validated route")
		if main.ai_failed:
			continue
		var task := TASK.new()
		task.ego = main.ego_vehicle
		task.road_generator = main.road_generator
		task.route = main.ai_route
		task.last_progress = main.ai_last_progress
		task.goal_progress = main.ai_goal_progress
		task.base_max_speed = float(main.ego_vehicle.max_speed)
		check(task._trip_is_clear(task.route, task.last_progress, task.goal_progress), "live route crosses a collider")
		check(main._get_ai_observation() == task._get_observation(), "live observations differ from training contract")
		world.route = main.ai_route
		world.last_progress = main.ai_last_progress
		world.goal_progress = main.ai_goal_progress
		world.base_max_speed = main.ego_vehicle.max_speed
		world.road_generator = main.road_generator
		check(world._get_observation() == main._get_ai_observation(), "actual training wrapper differs from gameplay")
		check(main._get_ai_route_state() == task._get_route_state(), "live projection differs from training contract")
		check(task._get_observation().size() == 31, "observation ABI changed")
	main.queue_free()
	world.queue_free()
	await process_frame
	paused = false
	world = TestWorld.new()
	root.add_child(world)
	world._set_generator_type("segmented")
	for stage in [0, 3, 5, 7]:
		var error := await world._reset_episode(20261015, false, stage)
		check(error.is_empty(), "segmented training reset failed: " + error)
		if error.is_empty():
			check(world._trip_is_clear(world.route, world.start_progress, world.goal_progress), "unsafe segmented training trip")
			await world._step_episode([0.0, 0.1])
			check(world.episode_physics_ticks == 4, "segmented action stepping differs")
	world.queue_free()
	print("AI GAMEPLAY PARITY: failures=", failures)
	quit(1 if failures else 0)
