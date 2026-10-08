extends Node


# ============================================================
# GAMEPLAY ACCEPTANCE TEST (AGENT.md changes 1-4)
# ------------------------------------------------------------
# Run:  godot --headless --path . res://tests/gameplay_test.tscn
# Exit code 0 = all checks passed, 1 = at least one failed.
#
# Covers:
#   1. NPCs have different, seeded, stable cruise speeds
#   2. Same seed reproduces the same speed assignments
#   3. Ego accelerates progressively (no instant speed)
#   4. Coast decelerates, braking decelerates faster
#   5. Speed HUD matches actual ego velocity
#   6. Collision triggers Game Over + pause
#   7. Crash speed equals the impact speed
#   8. Restart restores the initial state, driveable again
# ============================================================

var failures: int = 0
var checks: int = 0

var main: Node
var ego: Node
var road: Node
var traffic: Node
var hud: Node
var game_over: Node


func _ready() -> void:
	await run_all()

	print("")
	print(
		"GAMEPLAY TEST: %d checks, %d failures -> %s"
		% [checks, failures, "PASS" if failures == 0 else "FAIL"]
	)

	if failures == 0:
		get_tree().quit(0)

	else:
		get_tree().quit(1)


func check(condition: bool, label: String) -> void:
	checks += 1

	if condition:
		print("  PASS  " + label)

	else:
		failures += 1
		printerr("  FAIL  " + label)


func wait_frames(count: int) -> void:
	for i in range(count):
		await get_tree().process_frame


# Timing-sensitive drive measurements must sample once per
# PHYSICS tick: in headless mode the idle loop runs faster
# than 60 Hz, so process_frame would under-count ticks.
func wait_physics(count: int) -> void:
	for i in range(count):
		await get_tree().physics_frame


func release_inputs() -> void:
	Input.action_release("accelerate")
	Input.action_release("brake")
	Input.action_release("steer_left")
	Input.action_release("steer_right")


func reset_drive_state() -> void:
	release_inputs()

	ego.reset_vehicle()

	main.place_ego()


# The ego spawn sits just past the straight opening section,
# so driving straight there would scrape the curve wall and
# distort the speed measurements. Park it on the straight
# part instead (first ~180 units of the route are straight).
func reset_straight_drive() -> void:
	reset_drive_state()

	var route: RoutePath = road.get_route()
	var distance: float = 80.0

	ego.global_position = route.get_position_at(distance, 50.0)
	ego.rotation = route.get_rotation_at(distance)


func traffic_cars() -> Array[Node]:
	var result: Array[Node] = []

	for car in get_tree().get_nodes_in_group("traffic"):
		if is_instance_valid(car):
			result.append(car)

	return result


func sorted_cruises(cars: Array[Node]) -> Array[float]:
	var values: Array[float] = []

	for car in cars:
		values.append(float(car.get("cruise_speed")))

	values.sort()

	return values


func run_all() -> void:
	print("== Loading main scene ==")

	main = load("res://scenes/main.tscn").instantiate()

	add_child(main)

	await wait_frames(3)

	ego = main.get_node("EgoVehicle")
	road = main.get_node("RoadGenerator")
	traffic = main.get_node("TrafficManager")
	hud = main.get_node("SpeedHud")
	game_over = main.get_node("GameOver")

	check(
		hud != null and game_over != null,
		"HUD and Game Over nodes exist"
	)

	# --------------------------------------------------------
	# CHANGE 1: variable NPC speeds
	# --------------------------------------------------------
	print("== CHANGE 1: NPC speeds ==")

	var cars: Array[Node] = traffic_cars()

	check(cars.size() == 8, "traffic spawned (%d cars)" % cars.size())

	var cruises: Array[float] = sorted_cruises(cars)

	var distinct: Dictionary = {}

	for value in cruises:
		distinct[snappedf(value, 0.01)] = true

	check(
		distinct.size() >= 4,
		"NPC cruise speeds are heterogeneous (%d distinct of %d)"
		% [distinct.size(), cruises.size()]
	)

	var min_speed: float = float(traffic.get("minimum_speed"))
	var max_speed: float = float(traffic.get("maximum_speed"))
	var range_ok: bool = true

	for value in cruises:
		if value < min_speed or value > max_speed:
			range_ok = false

	check(
		range_ok,
		"all cruise speeds inside the configured range [%.0f, %.0f]"
		% [min_speed, max_speed]
	)

	# Cruises must not change while driving (no per-frame RNG).
	await wait_frames(30)

	var cruises_later: Array[float] = sorted_cruises(
		traffic_cars()
	)

	check(
		cruises == cruises_later,
		"cruise speeds stay constant while driving"
	)

	# Same seed -> same assignments.
	traffic.regenerate()

	var cruises_again: Array[float] = sorted_cruises(
		traffic_cars()
	)

	check(
		cruises == cruises_again,
		"same seed reproduces the same speed assignments"
	)

	# --------------------------------------------------------
	# CHANGE 2: progressive acceleration
	# --------------------------------------------------------
	print("== CHANGE 2: ego acceleration ==")

	reset_straight_drive()

	Input.action_press("accelerate")

	var samples: Array[float] = []

	for i in range(12):
		await get_tree().physics_frame
		samples.append(ego.velocity.length())

	Input.action_release("accelerate")

	var increasing: bool = true

	for i in range(1, samples.size()):
		if samples[i] <= samples[i - 1]:
			increasing = false

	check(
		increasing,
		"speed rises frame by frame (%.0f -> %.0f)"
		% [samples[0], samples[samples.size() - 1]]
	)

	check(
		samples[0] < ego.acceleration * 0.5,
		"speed starts from (at most) one tick, not instantly (%.1f)"
		% samples[0]
	)

	check(
		samples[1] > 0.0
		and samples[1] <= ego.acceleration / 60.0 * 2.0,
		"first physics step adds about one tick of speed (%.1f)"
		% samples[1]
	)

	check(
		samples[samples.size() - 1] < ego.max_speed,
		"still below max after 12 frames (%.0f < %.0f)"
		% [samples[samples.size() - 1], ego.max_speed]
	)

	check(
		samples[samples.size() - 1] > 30.0,
		"actually gained speed (%.0f)" % samples[samples.size() - 1]
	)

	# --------------------------------------------------------
	# CHANGE 2: coast vs brake
	# --------------------------------------------------------
	print("== CHANGE 2: coast and brake ==")

	reset_straight_drive()

	Input.action_press("accelerate")

	await wait_physics(15)

	var v_boost: float = ego.velocity.length()

	Input.action_release("accelerate")

	var v_coast_start: float = ego.velocity.length()

	await wait_physics(10)

	var v_coast_end: float = ego.velocity.length()

	check(
		v_coast_end < v_coast_start,
		"coasting decelerates naturally (%.0f -> %.0f)"
		% [v_coast_start, v_coast_end]
	)

	Input.action_press("accelerate")

	await wait_physics(12)

	Input.action_release("accelerate")

	var v_brake_start: float = ego.velocity.length()

	Input.action_press("brake")

	await wait_physics(5)

	var v_brake_end: float = ego.velocity.length()

	Input.action_release("brake")

	var coast_rate: float = (
		(v_coast_start - v_coast_end) / 10.0
	)

	var brake_rate: float = (
		(v_brake_start - v_brake_end) / 5.0
	)

	check(
		v_brake_end < v_brake_start,
		"braking decelerates (%.0f -> %.0f)"
		% [v_brake_start, v_brake_end]
	)

	check(
		brake_rate > coast_rate * 2.0,
		"braking is clearly stronger than coasting "
		+ "(%.0f vs %.0f per frame)"
		% [brake_rate, coast_rate]
	)

	check(
		v_boost > 0.0,
		"accelerate input produced motion (%.0f)" % v_boost
	)

	# --------------------------------------------------------
	# CHANGE 3: speed HUD
	# --------------------------------------------------------
	print("== CHANGE 3: speed HUD ==")

	reset_straight_drive()

	var speed_label: Label = hud.get("speed_label")

	check(speed_label != null, "HUD exposes its speed label")

	Input.action_press("accelerate")

	await wait_physics(20)

	var v_before: float = ego.velocity.length()

	await get_tree().physics_frame

	var v_now: float = ego.velocity.length()

	Input.action_release("accelerate")

	var label_value: int = -1

	if speed_label != null and speed_label.text.contains(" "):
		label_value = int(speed_label.text.split(" ")[0])

	var expected_before: int = roundi(
		v_before * float(ego.get("kmh_per_unit"))
	)

	var expected_now: int = roundi(
		v_now * float(ego.get("kmh_per_unit"))
	)

	check(
		label_value == expected_before
		or label_value == expected_now,
		"HUD shows the real velocity (label %d, expected %d/%d)"
		% [label_value, expected_before, expected_now]
	)

	reset_drive_state()

	await wait_frames(2)

	check(
		speed_label != null and speed_label.text == "0 km/h",
		"HUD reads 0 when stopped"
	)

	# --------------------------------------------------------
	# CHANGE 4: collision -> Game Over
	# --------------------------------------------------------
	print("== CHANGE 4: collision / Game Over ==")

	reset_drive_state()

	# Aim the ego at the right-hand wall of the straight
	# opening section and drive into it.
	ego.global_position = Vector2(60.0, -20.0)
	ego.rotation = PI

	Input.action_press("accelerate")

	var v_prev: float = ego.velocity.length()
	var detected: bool = false

	for i in range(90):
		await get_tree().physics_frame

		if bool(ego.get("has_crashed")):
			detected = true
			break

		v_prev = ego.velocity.length()

	Input.action_release("accelerate")

	check(detected, "ego collision detected")

	check(
		bool(ego.get("has_crashed")),
		"ego reports has_crashed"
	)

	var crash_speed: float = float(ego.get("crash_speed"))

	check(
		crash_speed > 0.0,
		"crash speed is non-zero (%.0f)" % crash_speed
	)

	check(
		absf(crash_speed - v_prev) <= 12.0,
		"crash speed equals the impact speed "
		+ "(%.0f vs %.0f one frame before)"
		% [crash_speed, v_prev]
	)

	check(
		game_over.visible,
		"Game Over UI is shown"
	)

	check(
		get_tree().paused,
		"gameplay is frozen"
	)

	var speed_text: Label = game_over.get("speed_text")

	check(
		speed_text != null
		and speed_text.text
		== "Speed: %d km/h" % roundi(
			crash_speed * float(ego.get("kmh_per_unit"))
		),
		"Game Over shows the actual crash speed (%s)"
		% (speed_text.text if speed_text != null else "missing")
	)

	# --------------------------------------------------------
	# CHANGE 4: restart
	# --------------------------------------------------------
	print("== CHANGE 4: restart ==")

	var original_cruises: Array[float] = cruises

	var button: Button = game_over.find_child(
		"RestartButton",
		true,
		false
	)

	check(button != null, "Restart button exists")

	if button != null:
		button.pressed.emit()

	await wait_frames(2)

	check(
		not get_tree().paused,
		"simulation unpaused after Restart"
	)

	check(
		not game_over.visible,
		"Game Over UI hidden after Restart"
	)

	check(
		not bool(ego.get("has_crashed")),
		"ego crash state cleared"
	)

	check(
		ego.current_speed == 0.0
		and ego.velocity == Vector2.ZERO,
		"ego velocity reset"
	)

	var spawn_pose: Dictionary = traffic.get_ego_spawn_pose()

	check(
		ego.global_position.distance_to(
			spawn_pose["position"]
		) < 0.1,
		"ego back on its spawn pose"
	)

	var restored_cars: Array[Node] = traffic_cars()

	check(
		restored_cars.size() == 8,
		"traffic rebuilt (%d cars)" % restored_cars.size()
	)

	check(
		sorted_cruises(restored_cars) == original_cruises,
		"traffic speeds restored deterministically"
	)

	# The player must be able to drive again.
	Input.action_press("accelerate")

	await wait_physics(10)

	check(
		ego.velocity.length() > 1.0,
		"ego drives again after Restart (%.0f)"
		% ego.velocity.length()
	)

	Input.action_release("accelerate")
