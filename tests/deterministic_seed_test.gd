extends SceneTree
## Headless checks for seeded map generation and repeatable training stepping.

class TestWorld extends "res://ai/rl_training_world.gd":
	var response: Dictionary = {}

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
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


func _road_snapshot(seed_value: int) -> Dictionary:
	var road: Node = load("res://scenes/RoadGenerator.tscn").instantiate()
	road.set("enable_hotkeys", false)
	road.set("build_visuals", false)
	root.add_child(road)
	road.call("generate_with_seed", seed_value)
	var snapshot := {
		"summary": road.call("get_layout_summary"),
		"points": road.call("get_center_points"),
		"paths": road.call("get_map_paths"),
		"obstacles": road.call("get_obstacle_regions"),
	}
	road.queue_free()
	return snapshot


func _episode_snapshot(seed_value: int) -> Dictionary:
	var world := TestWorld.new()
	root.add_child(world)
	await process_frame
	var error: String = await world._reset_episode(seed_value, false, 0)
	if not error.is_empty():
		world.queue_free()
		await process_frame
		return {"error": error}
	var snapshot := {
		"map_seed": int(world.road_generator.get("seed_value")),
		"start": world.start_progress,
		"goal": world.goal_progress,
		"turns": world.episode_route_turns,
		"observation": world._get_observation(),
		"steps": [],
	}
	for index in range(8):
		await world._step_episode([0.0, 0.35])
		snapshot["steps"].append({
			"observation": world.response["observation"],
			"reward": world.response["reward"],
			"position": world.ego.global_position,
			"physics_ticks": world.episode_physics_ticks,
		})
		if not world.episode_active:
			break
	world.queue_free()
	await process_frame
	return snapshot


func _run() -> void:
	var first_road := _road_snapshot(4101)
	var second_road := _road_snapshot(4101)
	_check(first_road == second_road, "same map seed must reproduce topology, paths, and obstacles")
	var other_road := _road_snapshot(12000)
	_check(first_road != other_road, "different map seeds must produce a different layout")

	var first_episode := await _episode_snapshot(4101)
	var second_episode := await _episode_snapshot(4101)
	_check(not first_episode.has("error"), "seeded training reset failed: %s" % first_episode.get("error", ""))
	_check(first_episode == second_episode, "same seed/actions must reproduce initial state and stepping")
	var other_episode := await _episode_snapshot(12000)
	_check(not other_episode.has("error"), "alternate seeded reset failed: %s" % other_episode.get("error", ""))
	_check(first_episode != other_episode, "different seeds must produce a different episode")

	print("DETERMINISTIC SEED TEST: map replay, episode replay, and seed separation; failures=", failures)
	quit(0 if failures == 0 else 1)
