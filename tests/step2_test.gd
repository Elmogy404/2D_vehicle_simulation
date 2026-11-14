extends Node


# ============================================================
# STEP 2 ACCEPTANCE TEST
# ------------------------------------------------------------
# Run:  godot --headless --path . res://tests/step2_test.tscn
# Exit code 0 = all checks passed, 1 = at least one failed.
#
# Covers:
#   1. Light inventory (lines, directions, groups)
#   2. Timing: 24 s cycle, 8/2/14 phases, 12 s group offset,
#      phase offset, simulation-clock integration
#   3. Stop-line geometry from route + car dimensions
#   4. No collision bodies on lights
#   5. Green: vehicle passes
#   6. Yellow: far vehicle brakes, close vehicle runs
#   7. Red: stops before the line, stays, green resumes
#   8. Queue: several vehicles stop in order, green releases
#   9. Determinism: same seed + same time -> same state
# ============================================================

var failures: int = 0
var checks: int = 0

var main: Node
var road: Node
var traffic: Node
var route: RoutePath

const LINE_A: float = 1700.0
const LINE_B: float = 3100.0

const CAR_LENGTH: float = 144.0
const LANE_OFFSET: float = 50.0
const LANE_ID: int = 0


func _ready() -> void:
	await run_all()

	print("")
	print(
		"STEP2 TEST: %d checks, %d failures -> %s"
		% [
			checks,
			failures,
			"PASS" if failures == 0 else "FAIL"
		]
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


func wait_physics(count: int) -> void:
	for i in range(count):
		await get_tree().physics_frame


func run_all() -> void:
	print("== Loading main scene ==")

	main = load("res://scenes/main.tscn").instantiate()

	add_child(main)

	# Frame 0: road + ego.  Frame 1: traffic spawn.
	await wait_frames(3)
	await wait_physics(3)

	road = main.get_node("RoadGenerator")
	traffic = main.get_node("TrafficManager")
	route = road.get_route()

	check(route != null and route.is_valid(), "route is valid")

	# --------------------------------------------------------
	# 1. Light inventory
	# --------------------------------------------------------
	print("== Light inventory ==")

	var lights: Array = traffic.get("lights")

	check(lights.size() == 4, "4 signal heads (2 lines x 2 directions)")

	var lines_seen: Array[float] = []
	var groups_seen: Array[int] = []

	for light in lights:
		var line: float = float(light.get("stop_line_progress"))

		if not line in lines_seen:
			lines_seen.append(line)

		var group: int = int(light.get("group"))

		if not group in groups_seen:
			groups_seen.append(group)

	lines_seen.sort()
	groups_seen.sort()

	check(
		lines_seen == [LINE_A, LINE_B],
		"stop lines at %s" % str(lines_seen)
	)
	check(
		groups_seen == [0, 1],
		"one group per line (%s)" % str(groups_seen)
	)

	# --------------------------------------------------------
	# 2. Timing
	# --------------------------------------------------------
	print("== Light timing ==")

	var g0: Node = find_light(LINE_A, 1.0)
	var g1: Node = find_light(LINE_B, 1.0)

	check(g0 != null and g1 != null, "found both dir+1 heads")

	# 0-8 green, 8-10 yellow, 10-24 red, repeating.
	check(
		g0.state_at(0.0) == TrafficLight.LightState.GREEN
		and g0.state_at(7.999) == TrafficLight.LightState.GREEN,
		"0..8 s is green"
	)
	check(
		g0.state_at(8.0) == TrafficLight.LightState.YELLOW
		and g0.state_at(9.999) == TrafficLight.LightState.YELLOW,
		"8..10 s is yellow"
	)
	check(
		g0.state_at(10.0) == TrafficLight.LightState.RED
		and g0.state_at(23.999) == TrafficLight.LightState.RED,
		"10..24 s is red"
	)
	check(
		g0.state_at(24.0) == TrafficLight.LightState.GREEN
		and g0.state_at(32.0) == TrafficLight.LightState.YELLOW
		and g0.state_at(34.0) == TrafficLight.LightState.RED,
		"cycle repeats after 24 s"
	)

	# 12-second group offset: group 1 lags group 0 by 12 s.
	var offset_ok: bool = true

	for t in [0.0, 5.0, 12.0, 19.9, 20.0, 30.5, 47.0, 55.0]:
		if g1.state_at(t) != g0.state_at(t - 12.0):
			offset_ok = false

	check(offset_ok, "group 1 runs 12 s behind group 0")

	# Configurable phase offset: state_at(t) with offset p
	# equals the unshifted state_at(t + p).
	var saved_offset: float = float(g0.get("phase_offset"))
	var sample_times: Array[float] = [0.0, 2.0, 7.0, 15.0]
	var with_offset: Array[int] = []
	var unshifted_later: Array[int] = []

	g0.phase_offset = 6.0

	for t in sample_times:
		with_offset.append(g0.state_at(t))

	g0.phase_offset = 0.0

	for t in sample_times:
		unshifted_later.append(g0.state_at(t + 6.0))

	g0.phase_offset = saved_offset

	var shifted: bool = true

	for i in range(sample_times.size()):
		if with_offset[i] != unshifted_later[i]:
			shifted = false

	check(shifted, "phase_offset shifts the cycle")

	# Simulation clock drives the lights (no per-light clock).
	var clock_before: float = float(traffic.get("sim_time"))

	await wait_physics(30)

	var clock_after: float = float(traffic.get("sim_time"))
	var synced: bool = true

	for light in lights:
		if int(light.get("state")) != int(light.state_at(clock_after)):
			synced = false

	check(
		clock_after > clock_before,
		"simulation clock advances with physics (%.2f s)"
		% clock_after
	)
	check(
		synced,
		"every light state matches state_at(sim_time)"
	)

	# --------------------------------------------------------
	# 3. Stop-line geometry
	# --------------------------------------------------------
	print("== Stop-line geometry ==")

	var geometry_ok: bool = true

	for light in lights:
		var line: float = float(light.get("stop_line_progress"))
		var dir: float = float(light.get("direction"))

		var expected: float = line - dir * (CAR_LENGTH * 0.5 + 5.0)

		if absf(
			float(light.bumper_stop_progress(CAR_LENGTH)) - expected
		) > 0.01:
			geometry_ok = false

	check(
		geometry_ok,
		"bumper stop = line - direction * (length/2 + 5)"
	)

	var near_line: Dictionary = route.nearest(
		route.get_position_at(LINE_A)
	)

	check(
		float(near_line["distance"]) < 1.0,
		"stop line sits on the route centerline"
	)

	# --------------------------------------------------------
	# 4. No collision bodies
	# --------------------------------------------------------
	print("== Collision safety ==")

	var collider_free: bool = true

	for light in lights:
		if light is CollisionObject2D:
			collider_free = false

		for child in light.get_children():
			if child is CollisionObject2D:
				collider_free = false

	check(
		collider_free,
		"lights carry no collider (never obstacles)"
	)

	# --------------------------------------------------------
	# 5. Green: vehicle passes
	# --------------------------------------------------------
	print("== Green ==")

	await free_all_cars()
	await set_clock(0.0)

	var green_light: Node = find_light(LINE_A, 1.0)

	check(
		int(green_light.get("state")) == TrafficLight.LightState.GREEN,
		"clock 0 -> green"
	)

	var stop: float = green_light.bumper_stop_progress(CAR_LENGTH)
	var passer: Node = make_car(stop - 300.0, 120.0)

	var passed: bool = false
	var slow_on_green: bool = true

	while float(traffic.get("sim_time")) < 7.5:
		await get_tree().physics_frame

		if float(passer.get("progress")) > stop + 5.0:
			passed = true
			break

		if float(passer.get("speed")) < 60.0:
			slow_on_green = false

	check(passed, "green: vehicle crossed the stop line")

	check(
		slow_on_green and float(passer.get("speed")) >= 60.0,
		"green: no braking needed (%.0f km-units/s)"
		% float(passer.get("speed"))
	)

	# --------------------------------------------------------
	# 6. Yellow
	# --------------------------------------------------------
	print("== Yellow ==")

	await free_all_cars()
	await set_clock(8.2)

	check(
		int(green_light.get("state"))
		== TrafficLight.LightState.YELLOW,
		"clock 8.2 -> yellow"
	)

	# Far vehicle: a safe stop still fits -> brakes.
	stop = green_light.bumper_stop_progress(CAR_LENGTH)

	var far_car: Node = make_car(stop - 200.0, 120.0)
	var start_speed: float = float(far_car.get("speed"))
	var far_crossed: bool = false

	while float(traffic.get("sim_time")) < 9.9:
		await get_tree().physics_frame

		if float(far_car.get("progress")) > stop + 0.5:
			far_crossed = true

	var end_speed: float = float(far_car.get("speed"))

	check(
		not far_crossed,
		"yellow (far): stayed behind the stop line"
	)
	check(
		end_speed < start_speed - 30.0,
		"yellow (far): began braking (%.0f -> %.0f)"
		% [start_speed, end_speed]
	)

	# Close vehicle: the stop no longer fits -> runs it.
	await free_all_cars()
	await set_clock(8.2)

	stop = green_light.bumper_stop_progress(CAR_LENGTH)

	var close_car: Node = make_car(stop - 20.0, 160.0)
	var ran: bool = false

	for i in range(60):
		await get_tree().physics_frame

		if float(close_car.get("progress")) > stop + 5.0:
			ran = true
			break

	check(
		ran,
		"yellow (close): committed and crossed the line"
	)
	check(
		float(close_car.get("speed")) > 60.0,
		"yellow (close): kept rolling (%.0f)"
		% float(close_car.get("speed"))
	)

	# --------------------------------------------------------
	# 7. Red: stop, stay, resume
	# --------------------------------------------------------
	print("== Red ==")

	await free_all_cars()
	await set_clock(10.0)

	check(
		int(green_light.get("state")) == TrafficLight.LightState.RED,
		"clock 10 -> red"
	)

	stop = green_light.bumper_stop_progress(CAR_LENGTH)

	var stopper: Node = make_car(stop - 150.0, 120.0)
	var red_crossed: bool = false
	var came_to_rest: bool = false

	while float(traffic.get("sim_time")) < 20.0:
		await get_tree().physics_frame

		if float(stopper.get("progress")) > stop + 0.5:
			red_crossed = true
			break

		if (
			float(stopper.get("speed")) <= 1.0
			and float(traffic.get("sim_time")) > 11.0
		):
			came_to_rest = true
			break

	check(not red_crossed, "red: never crossed the stop line")
	check(came_to_rest, "red: came to a complete stop")

	var rest_position: float = float(stopper.get("progress"))

	check(
		rest_position >= stop - 15.0 and rest_position <= stop + 2.0,
		"red: stopped at the line (gap %.1f)"
		% (stop - rest_position)
	)

	await wait_physics(60)

	check(
		absf(float(stopper.get("progress")) - rest_position) < 1.0
		and float(stopper.get("speed")) <= 1.0,
		"red: stayed stopped"
	)

	# Green release: jump the shared clock back to a green
	# phase and the car must pull away smoothly.
	await set_clock(0.0)

	check(
		int(green_light.get("state"))
		== TrafficLight.LightState.GREEN,
		"light turns green again"
	)

	var resume_position: float = float(stopper.get("progress"))

	await wait_physics(120)

	check(
		float(stopper.get("progress")) > resume_position + 20.0
		and float(stopper.get("speed")) > 10.0,
		"green: resumed smoothly (+%.0f units, speed %.0f)"
		% [
			float(stopper.get("progress")) - resume_position,
			float(stopper.get("speed"))
		]
	)

	# --------------------------------------------------------
	# 8. Queue
	# --------------------------------------------------------
	print("== Queue ==")

	await free_all_cars()
	await set_clock(10.0)

	stop = green_light.bumper_stop_progress(CAR_LENGTH)

	# Arrive as an already-formed pack: the lead brakes to the
	# line, the followers close their small gaps well inside the
	# red window (10 s .. 24 s).
	var q1: Node = make_car(stop - 150.0, 120.0)
	var q2: Node = make_car(stop - 340.0, 120.0)
	var q3: Node = make_car(stop - 530.0, 120.0)

	# Wait until the whole queue has settled on red.
	for i in range(720):
		await get_tree().physics_frame

		if (
			float(q1.get("speed")) <= 1.0
			and float(q2.get("speed")) <= 1.0
			and float(q3.get("speed")) <= 1.0
			and float(traffic.get("sim_time")) > 11.0
		):
			break

	var p1: float = float(q1.get("progress"))
	var p2: float = float(q2.get("progress"))
	var p3: float = float(q3.get("progress"))

	check(
		float(q1.get("speed")) <= 1.0
		and float(q2.get("speed")) <= 1.0
		and float(q3.get("speed")) <= 1.0,
		"queue: all vehicles stopped on red"
	)
	check(
		p1 <= stop + 0.5,
		"queue: lead vehicle behind the stop line"
	)
	check(
		p3 < p2 and p2 < p1,
		"queue: order preserved (front to back)"
	)
	check(
		(p1 - p2) >= 140.0 and (p2 - p3) >= 140.0,
		"queue: bumper spacing kept (%.0f / %.0f)"
		% [p1 - p2, p2 - p3]
	)

	await wait_physics(40)

	check(
		absf(float(q1.get("progress")) - p1) < 1.0
		and absf(float(q2.get("progress")) - p2) < 1.0
		and absf(float(q3.get("progress")) - p3) < 1.0,
		"queue: nobody crept forward while red"
	)

	await set_clock(0.0)

	await wait_physics(90)

	check(
		float(q1.get("progress")) > p1 + 10.0
		and float(q2.get("progress")) > p2 + 5.0
		and float(q3.get("progress")) > p3 + 5.0,
		"queue: released together on green"
	)

	# --------------------------------------------------------
	# 9. Determinism
	# --------------------------------------------------------
	print("== Determinism ==")

	traffic.call("regenerate")

	await wait_physics(120)

	var state_a: String = snapshot_traffic()

	var time_a: float = float(traffic.get("sim_time"))

	traffic.call("regenerate")

	await wait_physics(120)

	var state_b: String = snapshot_traffic()

	var time_b: float = float(traffic.get("sim_time"))

	check(
		state_a == state_b,
		"same seed + same simulation time -> same state\n"
		+ "         first:  " + state_a + "\n"
		+ "         second: " + state_b
	)
	check(
		absf(time_a - time_b) < 0.0001,
		"clocks agree (%.4f vs %.4f)" % [time_a, time_b]
	)


# ============================================================
# HELPERS
# ============================================================

func find_light(line: float, dir: float) -> Node:
	var lights: Array = traffic.get("lights")

	for light in lights:
		if (
			absf(float(light.get("stop_line_progress")) - line) < 0.01
			and float(light.get("direction")) == dir
		):
			return light

	return null


# Jump the shared simulation clock and let the manager push
# the new time to every light.
func set_clock(t: float) -> void:
	traffic.set("sim_time", t)

	await wait_physics(2)


# Remove every NPC so a scenario only sees the vehicles the
# test itself creates. The ego stays (it must never react to
# lights anyway). Scans the group so untracked scenario cars
# are removed too.
func free_all_cars() -> void:
	for car in get_tree().get_nodes_in_group("traffic"):
		if is_instance_valid(car):
			if car.get_parent() != null:
				car.get_parent().remove_child(car)

			car.queue_free()

	var cars: Array = traffic.get("traffic_cars")

	cars.clear()


# One fresh NPC in lane 0 travelling with the centerline,
# wired to the manager's signal heads like a spawned car.
func make_car(progress: float, speed: float) -> Node:
	var car: Node = traffic.get("traffic_car_scene").instantiate()

	traffic.add_child(car)

	car.setup(route, LANE_ID, LANE_OFFSET, 1.0, progress, speed)
	car.lights = traffic.get("lights").duplicate()

	var cars: Array = traffic.get("traffic_cars")

	cars.append(car)

	return car


func snapshot_traffic() -> String:
	var entries: Array[String] = []

	for car in traffic.get("traffic_cars"):
		if not is_instance_valid(car):
			continue

		entries.append(
			"%.2f|%.2f"
			% [
				snappedf(float(car.get("progress")), 0.01),
				snappedf(float(car.get("speed")), 0.01)
			]
		)

	entries.sort()

	var light_states: Array[String] = []

	for light in traffic.get("lights"):
		light_states.append(str(int(light.get("state"))))

	return ";".join(entries) + " @" + ",".join(light_states)
