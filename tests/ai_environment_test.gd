extends SceneTree

class TestWorld extends "res://ai/rl_training_world.gd":
	var response: Dictionary = {}
	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		_setup_training_world()
		set_process(false)
	func _send_message(message: Dictionary) -> void:
		response = message

var errors: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _check(value: bool, message: String) -> void:
	if not value:
		errors.append(message)
		printerr("FAIL: ", message)

func _run() -> void:
	# Same 1/60-second integration as production, at ten times wall speed.
	Engine.physics_ticks_per_second = 600
	Engine.time_scale = 10.0
	var world := TestWorld.new()
	root.add_child(world)
	_check(is_zero_approx(world._edge_pressure(35.0, 35.0, 49.0)), "correct target lane receives edge penalty")
	_check(world._edge_pressure(48.0, 35.0, 49.0) > 0.8, "near-curb danger is not penalized")
	var checked := 0
	var replacements := 0
	for offset in range(20):
		for stage in range(8):
			var seed_value := (50000 if OS.get_cmdline_user_args().has("--held-out") else 12000) + offset
			var error: String = await world._reset_episode(seed_value, false, stage)
			_check(error.is_empty(), "reset seed=%d stage=%d: %s" % [seed_value, stage, error])
			if not error.is_empty():
				continue
			replacements += int(int(world.road_generator.get("seed_value")) != seed_value)
			checked += 1
			var label := "seed=%d stage=%d" % [seed_value, stage]
			_check(world._spawn_pose_is_clear(world.route, world.start_progress), label + " spawn")
			_check(world._spawn_pose_is_clear(world.route, world.goal_progress), label + " goal")
			_check(world.episode_turn_requirement_met, label + " turn requirement")
			_check(world.episode_route_turns == world.route.count_completed_turns(world.start_progress, world.goal_progress - world.GOAL_RADIUS), label + " actual completed turns")
			var sample: float = world.start_progress
			while sample <= world.goal_progress:
				if not world._spawn_pose_is_clear(world.route, sample, 0.0):
					_check(false, label + " blocked reference at %.1f" % sample)
					break
				sample += 5.0
			_check(not world._goal_reached(world.start_progress), label + " succeeds at spawn")
		if offset % 5 == 4:
			print("ENVIRONMENT SWEEP: ", checked, " episodes checked")
	# Fixed ticks, repeatable trajectories, and no motion while awaiting Python.
	var baseline: Array[float] = []
	for trial in range(3):
		var error: String = await world._reset_episode(4101, false, 0)
		_check(error.is_empty(), "timing reset")
		for step in range(8):
			await world._step_episode([0.0, 1.0])
			var speed := float(world.ego.get("current_speed"))
			_check(is_equal_approx(speed, float(step + 1) * 250.0 / 15.0), "exact four-tick acceleration")
			_check(world.episode_physics_ticks == (step + 1) * 4, "tick counter")
			if trial == 0:
				baseline.append(speed)
			else:
				_check(is_equal_approx(speed, baseline[step]), "deterministic action trajectory")
		var position: Vector2 = world.ego.global_position
		for _frame in range(8):
			await physics_frame
		_check(world.ego.global_position.is_equal_approx(position), "unrequested vehicle movement")
	# Near the destination in space, but still far behind it along the route.
	world.ego.global_position = world.goal_position
	_check(not world._goal_reached(world.start_progress), "shortcut success")
	_check(world._goal_reached(world.goal_progress), "valid goal rejected")
	world._restore_training_state({"curriculum_stage": 5, "recent_results": [true, false, true]})
	await world._reset_episode(4101, false, 0)
	_check(world.curriculum_stage == 5 and world.curriculum_recent_results.size() == 3, "fixed-stage evaluation changed curriculum")
	world.curriculum_stage = 3
	world.active_episode_stage = 3
	world.turn_level = 0
	world.curriculum_enabled = true
	world.curriculum_recent_results.clear()
	world.active_episode_stage = 1
	for _episode in range(20):
		world._record_curriculum_outcome(true)
	_check(world.curriculum_recent_results.is_empty() and world.turn_level == 0, "easy replay advanced the frontier")
	world.active_episode_stage = 3
	for _episode in range(20):
		world._record_curriculum_outcome(true)
	_check(world.curriculum_stage == 3 and world.turn_level == 1, "first-turn practice skipped its intermediate speed")
	for _episode in range(20):
		world._record_curriculum_outcome(true)
	_check(world.curriculum_stage == 3 and world.turn_level == 2, "turn practice did not reach full speed")
	for _episode in range(20):
		world._record_curriculum_outcome(true)
	_check(world.curriculum_stage == 4, "completed turn practice did not advance distance curriculum")
	world.curriculum_stage = 7
	world.active_episode_stage = 7
	for _episode in range(25):
		world._record_curriculum_outcome(true)
	_check(world.curriculum_stage == 7 and world.curriculum_recent_results.size() == 20, "final-stage recent success telemetry")
	# Repeating previously visited distance must not generate fresh progress reward.
	var forward_rewards: Array[float] = []
	for offset in [30.0, 0.0, 30.0]:
		var progress: float = world.start_progress + offset
		world.ego.global_position = world.route.get_position_at(progress, world._lane_center_offset_at(progress))
		world.ego.global_rotation = world.route.get_rotation_at(progress)
		await world._step_episode([0.0, 0.0])
		if offset > 0.0:
			forward_rewards.append(float(world.response["reward"]))
	_check(forward_rewards[0] > forward_rewards[1] and forward_rewards[1] <= 0.0, "retracing distance farms reward")
	await world._reset_episode(4101, false, 0)
	for _step in range(150):
		await world._step_episode([0.0, 0.0])
	_check(not world.episode_active and bool(world.response["info"]["stalled"]), "stationary episode did not end")
	# A simple controller provides an independent dynamic reachability check.
	for stage in [0, 3, 7]:
		var error: String = await world._reset_episode(12000, false, stage)
		_check(error.is_empty(), "reference controller reset")
		if not error.is_empty():
			continue
		for step in range(1800):
			var state := world._get_route_state()
			var progress := float(state["progress"])
			var target_progress := minf(world.goal_progress, progress + 45.0)
			var target := world.route.get_position_at(target_progress, world._lane_center_offset_at(target_progress))
			var local: Vector2 = world.ego.to_local(target)
			var curvature := 2.0 * local.x / maxf(local.length_squared(), 1.0)
			var steering := clampf(atan(92.0 * curvature) / deg_to_rad(35.0), -1.0, 1.0)
			var pedal := clampf((50.0 - float(world.ego.get("current_speed"))) / 40.0, -1.0, 1.0)
			await world._step_episode([steering, pedal])
			if not world.episode_active:
				_check(bool(world.response["info"]["success"]), "reference controller failed stage=%d info=%s" % [stage, world.response["info"]])
				print("REFERENCE CONTROLLER stage=",stage," steps=",step+1," success=",world.response["info"]["success"])
				break
	print("ENVIRONMENT RESULT episodes=",checked," replacement_maps=",replacements," failures=",errors.size())
	quit(0 if errors.is_empty() else 1)
