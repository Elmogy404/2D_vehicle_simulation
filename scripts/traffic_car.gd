extends CharacterBody2D


# ============================================================
# TRAFFIC SETTINGS
# ============================================================

@export_category("Traffic")

@export var acceleration: float = 100.0
@export var braking: float = 300.0

@export var max_steering_speed: float = 5.0


# ============================================================
# FOLLOWING
# ------------------------------------------------------------
# Distances are measured ALONG THE ROUTE between vehicle
# centers, so following stays correct through curves.
# ============================================================

@export_category("Following")

@export var detection_distance: float = 320.0
@export var safe_distance: float = 28.0
@export var slow_distance: float = 220.0

## Desired seconds of separation from the rear bumper ahead.
@export var time_headway: float = 1.25

## Extra braking multiplier when the available stopping distance is small.
@export var emergency_brake_multiplier: float = 1.8

@export_category("Lane Merging")
@export var merge_lookahead: float = 480.0
@export var merge_duration: float = 2.2
@export var merge_ahead_clearance: float = 175.0
@export var merge_behind_clearance: float = 155.0
@export var merge_stop_buffer: float = 35.0

## How close another vehicle may be to this lane's re-entry
## point before this vehicle is allowed to loop back.
@export var reentry_clearance: float = 150.0


# ============================================================
# LOOKAHEAD / CURVES
# ============================================================

@export_category("Lane Keeping")

@export var lookahead_time: float = 0.35
@export var minimum_lookahead: float = 60.0
@export var maximum_lookahead: float = 220.0

## Heading change over the probe distance that triggers the
## strongest curve slowdown.
@export var max_curve_angle: float = 0.6

## Speed ratio kept on the sharpest allowed curve.
@export var curve_speed_factor: float = 0.45

@export var curve_probe_distance: float = 150.0


# ============================================================
# VEHICLE GEOMETRY
# ============================================================

@export_category("Geometry")

@export var vehicle_length: float = 122.0
@export var vehicle_width: float = 62.0

## A foreign vehicle counts as sharing this lane when its
## center is within this distance of the lane centerline.
@export var lane_match_distance: float = 75.0


# ============================================================
# INTERNAL STATE
# ============================================================

var speed: float = 120.0
var cruise_speed: float = 120.0
var target_speed: float = 120.0

# Shared, distance-based view of the road centerline.
var route: RoutePath

# Distance along the centerline. Direction of travel is
# independent of this value (see travel_direction).
var progress: float = 0.0

# +1 travels with the centerline, -1 against it.
var travel_direction: float = 1.0

var lane_id: int = 0
var lane_index: int = 0
var lane_offset: float = 0.0
var lane_change_active: bool = false
var lane_change_from: int = 0
var lane_change_to: int = 0
var lane_change_elapsed: float = 0.0
var merge_signal_active: bool = false
var signal_lights: Array[Line2D] = []


# ============================================================
# READY
# ============================================================

func _ready() -> void:
	if not is_in_group("traffic"):
		add_to_group("traffic")
	_build_turn_signals()


# ============================================================
# SETUP
# ============================================================

func setup(
	new_route: RoutePath,
	new_lane_id: int,
	new_lane_index: int,
	new_lane_offset: float,
	new_travel_direction: float,
	start_progress: float,
	new_speed: float
) -> void:
	route = new_route
	lane_id = new_lane_id
	lane_index = new_lane_index
	lane_offset = new_lane_offset

	travel_direction = 1.0 if new_travel_direction >= 0.0 else -1.0

	speed = new_speed
	cruise_speed = new_speed
	target_speed = new_speed

	progress = clampf(
		start_progress,
		0.0,
		route.length if route != null else 0.0
	)

	snap_to_route()


func configure_visual(texture: Texture2D, body_size: Vector2) -> void:
	vehicle_width = body_size.x
	vehicle_length = body_size.y

	var sprite := get_node_or_null("Sprite2D") as Sprite2D
	var collider := get_node_or_null("CollisionShape2D") as CollisionShape2D

	if sprite != null:
		sprite.texture = texture

	if collider != null:
		var rectangle := collider.shape as RectangleShape2D

		if rectangle != null:
			# Shapes loaded from a PackedScene can share resources. Duplicate before
			# applying per-vehicle dimensions.
			rectangle = rectangle.duplicate() as RectangleShape2D
			rectangle.size = body_size
			collider.shape = rectangle

	_position_turn_signals()


# Place the car exactly on its lane and face it forward.
func snap_to_route() -> void:
	if route == null or not route.is_valid():
		velocity = Vector2.ZERO
		return

	lane_offset = _lane_offset_at(progress)
	global_position = route.get_position_at(progress, lane_offset)

	rotation = (
		route.get_direction_at(progress)
		* travel_direction
	).angle() + PI / 2.0


# ============================================================
# PHYSICS
# ============================================================

func _physics_process(delta: float) -> void:
	if route == null or not route.is_valid():
		velocity = Vector2.ZERO
		return

	_update_lane_merge(delta)

	# --------------------------------------------------------
	# Speed targets: cruise limited by curves, leaders and
	# the route end.
	# --------------------------------------------------------

	target_speed = curve_speed_limit()

	var leader: Dictionary = leader_state()
	var leader_gap: float = float(leader["gap"])

	if leader_gap < detection_distance:
		target_speed = minf(
			target_speed,
			follow_speed(
				leader_gap,
				float(leader["speed"])
			)
		)

	if not reentry_clear():
		target_speed = minf(
			target_speed,
			stop_before_route_end_speed()
		)

	target_speed = minf(target_speed, traffic_light_speed_limit())
	target_speed = minf(target_speed, merge_speed_limit())

	# --------------------------------------------------------
	# Acceleration / braking
	# --------------------------------------------------------

	if speed < target_speed:
		speed = move_toward(
			speed,
			target_speed,
			acceleration * delta
		)

	else:
		var applied_braking: float = braking

		if leader_gap < safe_distance:
			applied_braking *= emergency_brake_multiplier

		speed = move_toward(
			speed,
			target_speed,
			applied_braking * delta
		)

	# --------------------------------------------------------
	# Advance progress along the route
	# --------------------------------------------------------

	progress += travel_direction * speed * delta

	handle_route_end()

	# --------------------------------------------------------
	# Lane keeping: steer toward a point ahead on the lane
	# --------------------------------------------------------

	var look: float = clampf(
		speed * lookahead_time,
		minimum_lookahead,
		maximum_lookahead
	)

	var target_distance: float = progress + travel_direction * look

	# Never aim beyond the exit while waiting for re-entry.
	if not reentry_clear():
		var exit: float = exit_progress()

		if travel_direction > 0.0:
			target_distance = minf(target_distance, exit)

		else:
			target_distance = maxf(target_distance, exit)

	var target_lane_offset := _lane_offset_at(target_distance)
	var target_point: Vector2 = route.get_position_at(
		target_distance,
		target_lane_offset
	)

	var to_target: Vector2 = target_point - global_position

	if to_target.length_squared() < 0.01:
		velocity = Vector2.ZERO
		return


	var direction: Vector2 = to_target.normalized()

	var desired_rotation: float = (
		direction.angle()
		+
		PI / 2.0
	)

	rotation = lerp_angle(
		rotation,
		desired_rotation,
		minf(max_steering_speed * delta, 1.0)
	)

	velocity = direction * speed

	move_and_slide()

	# A physical contact must remove forward drive immediately. This prevents
	# NPCs from continuously pushing another car or vibrating against a wall.
	if get_slide_collision_count() > 0:
		speed = 0.0

	sync_progress()
	lane_offset = _lane_offset_at(progress)
	_update_turn_signal_visuals()


func _lane_offset_at(distance: float) -> float:
	var side := 1.0 if travel_direction >= 0.0 else -1.0
	var width: float = route.lane_width

	if not lane_change_active:
		return side * (float(lane_index) + 0.5) * width

	var t := clampf(lane_change_elapsed / maxf(merge_duration, 0.1), 0.0, 1.0)
	var smooth_t := t * t * (3.0 - 2.0 * t)
	var from_offset := side * (float(lane_change_from) + 0.5) * width
	var to_offset := side * (float(lane_change_to) + 0.5) * width
	return lerpf(from_offset, to_offset, smooth_t)


func _update_lane_merge(delta: float) -> void:
	if lane_change_active:
		lane_change_elapsed += delta

		if lane_change_elapsed >= merge_duration:
			lane_index = lane_change_to
			lane_change_active = false
			merge_signal_active = false
			lane_change_elapsed = 0.0

		return

	if lane_index <= 0:
		merge_signal_active = false
		return

	var end_gap := lane_end_gap()
	merge_signal_active = end_gap < merge_lookahead

	if merge_signal_active and can_merge_into(lane_index - 1):
		lane_change_from = lane_index
		lane_change_to = lane_index - 1
		lane_change_elapsed = 0.0
		lane_change_active = true


func lane_end_gap() -> float:
	if lane_index <= 0:
		return INF

	var step := 25.0
	var distance := 0.0

	while distance <= merge_lookahead:
		var probe := progress + travel_direction * distance

		if probe < 0.0 or probe > route.length:
			return INF

		if route.get_lane_count_at(probe) <= lane_index:
			return distance

		distance += step

	return INF


func can_merge_into(target_lane: int) -> bool:
	for other in get_tree().get_nodes_in_group("traffic"):
		if not is_instance_valid(other) or other == self:
			continue

		if other.get("route") != route:
			continue

		if float(other.get("travel_direction")) != travel_direction:
			continue

		var other_lane: int = int(other.get("lane_index"))

		if bool(other.get("lane_change_active")):
			other_lane = int(other.get("lane_change_to"))

		if other_lane != target_lane:
			continue

		var gap := (float(other.get("progress")) - progress) * travel_direction

		if gap >= 0.0 and gap < merge_ahead_clearance:
			return false

		if gap < 0.0 and absf(gap) < merge_behind_clearance:
			return false

	# The ego is not part of the traffic group, but it has exactly the same
	# right-of-way in the continuing lane. Include its actual lateral position
	# so an NPC cannot start a merge through the player's car.
	var ego: Node2D = get_tree().get_first_node_in_group("vehicle_obstacle") as Node2D
	if ego != null and is_instance_valid(ego):
		var near: Dictionary = route.nearest(ego.global_position, progress, merge_lookahead)
		var ego_progress: float = float(near["progress"])
		var center := route.get_position_at(ego_progress)
		var ego_offset := (ego.global_position - center).dot(route.get_normal_at(ego_progress))
		var target_offset := route.get_lane_offset_at(ego_progress, target_lane, travel_direction)

		if absf(ego_offset - target_offset) <= lane_match_distance:
			var ego_gap := (ego_progress - progress) * travel_direction
			if ego_gap >= 0.0 and ego_gap < merge_ahead_clearance:
				return false
			if ego_gap < 0.0 and absf(ego_gap) < merge_behind_clearance:
				return false

	return true


func merge_speed_limit() -> float:
	if lane_change_active or lane_index <= 0:
		return cruise_speed

	var end_gap := lane_end_gap()

	if end_gap == INF:
		return cruise_speed

	if can_merge_into(lane_index - 1):
		return cruise_speed

	if end_gap <= merge_stop_buffer:
		return 0.0

	return sqrt(
		2.0 * braking * maxf(end_gap - merge_stop_buffer, 0.0)
	)


func _build_turn_signals() -> void:
	for y in [-vehicle_length * 0.36, vehicle_length * 0.36]:
		var light := Line2D.new()
		light.width = 7.0
		light.default_color = Color(1.0, 0.58, 0.05)
		light.z_index = 3
		light.add_point(Vector2(-vehicle_width * 0.42 - 3.0, float(y)))
		light.add_point(Vector2(-vehicle_width * 0.42 + 3.0, float(y)))
		light.visible = false
		add_child(light)
		signal_lights.append(light)


func _position_turn_signals() -> void:
	for i in range(signal_lights.size()):
		var y := -vehicle_length * 0.36 if i == 0 else vehicle_length * 0.36
		signal_lights[i].clear_points()
		signal_lights[i].add_point(Vector2(-vehicle_width * 0.42 - 3.0, y))
		signal_lights[i].add_point(Vector2(-vehicle_width * 0.42 + 3.0, y))


func _update_turn_signal_visuals() -> void:
	var blink_on := merge_signal_active and fmod(Time.get_ticks_msec() / 1000.0, 0.8) < 0.4

	for light in signal_lights:
		light.visible = blink_on


# ============================================================
# PROGRESS
# ------------------------------------------------------------
# Physics may push the car around (walls, other cars), so the
# route progress is re-derived from the real position every
# frame instead of being trusted blindly.
# ============================================================

func sync_progress() -> void:
	if route == null or not route.is_valid():
		return

	var window: float = 200.0

	var result: Dictionary = route.nearest(
		global_position,
		progress,
		window
	)

	# Ignore results that would mean the car left the road
	# entirely (keep last known progress instead).
	if float(result["distance"]) > 300.0:
		return

	progress = clampf(
		float(result["progress"]),
		0.0,
		route.length
	)


# ============================================================
# ROUTE END / RE-ENTRY
# ============================================================

func exit_progress() -> float:
	# Stop/wrap with the whole vehicle still on the road.
	var margin: float = vehicle_length * 0.5

	return (
		route.length - margin
		if travel_direction > 0.0
		else margin
	)


func entry_progress() -> float:
	var margin: float = vehicle_length * 0.5

	return (
		margin
		if travel_direction > 0.0
		else route.length - margin
	)


func handle_route_end() -> void:
	var exit: float = exit_progress()

	if travel_direction > 0.0 and progress >= exit:
		if reentry_clear():
			progress = entry_progress()
			snap_to_route()

		else:
			progress = exit

	elif travel_direction < 0.0 and progress <= exit:
		if reentry_clear():
			progress = entry_progress()
			snap_to_route()

		else:
			progress = exit


# True when no same-lane vehicle (including the ego) occupies
# the stretch of lane this vehicle would re-enter onto.
func reentry_clear() -> bool:
	var entry: float = entry_progress()

	# Also block on vehicles sitting slightly BEFORE the entry
	# point (right at the road start / end).
	var behind: float = vehicle_length * 0.5

	for other_progress in same_lane_progresses():
		var ahead: float = (
			(other_progress - entry) * travel_direction
		)

		if ahead >= -behind and ahead < reentry_clearance:
			return false

	return true


# Speed limit while waiting for the route end to clear:
# the speed from which the car can still stop exactly at the
# exit with full braking (sqrt(2 * a * d)).
func stop_before_route_end_speed() -> float:
	var remaining: float = (
		(exit_progress() - progress) * travel_direction
	)

	if remaining <= 0.0:
		return 0.0

	return sqrt(2.0 * braking * remaining)


# ============================================================
# SPEED LIMITS
# ============================================================

func curve_speed_limit() -> float:
	if route == null or not route.is_valid():
		return 0.0

	var probe: float = clampf(
		progress + travel_direction * curve_probe_distance,
		0.0,
		route.length
	)

	var angle: float = absf(
		route.get_direction_at(progress).angle_to(
			route.get_direction_at(probe)
		)
	)

	var t: float = clampf(
		angle / maxf(max_curve_angle, 0.001),
		0.0,
		1.0
	)

	return cruise_speed * lerpf(1.0, curve_speed_factor, t)


func follow_speed(gap: float, leader_speed: float = 0.0) -> float:
	if gap <= safe_distance:
		return 0.0

	var desired_gap: float = safe_distance + speed * time_headway

	if gap >= maxf(slow_distance, desired_gap):
		return cruise_speed

	# Match the leader, then use remaining gap error to close smoothly. The
	# stopping-distance cap prevents a fast follower from arriving too quickly.
	var proportional_speed: float = (
		leader_speed
		+ (gap - desired_gap) / maxf(time_headway, 0.1)
	)
	var stopping_speed: float = sqrt(
		2.0 * braking * maxf(gap - safe_distance, 0.0)
	)

	return clampf(
		minf(proportional_speed, stopping_speed),
		0.0,
		cruise_speed
	)


func traffic_light_speed_limit() -> float:
	var nearest_gap: float = INF
	var nearest_light: Node

	for candidate in get_tree().get_nodes_in_group("traffic_lights"):
		var light := candidate as Node

		if light == null or light.route != route:
			continue

		var stop_progress: float = light.stop_progress_for(travel_direction)
		var center_gap: float = (
			(stop_progress - progress) * travel_direction
		)
		var bumper_gap: float = center_gap - vehicle_length * 0.5

		if bumper_gap >= 0.0 and bumper_gap < nearest_gap:
			nearest_gap = bumper_gap
			nearest_light = light

	if nearest_light == null:
		return cruise_speed

	if not nearest_light.requires_stop(speed, nearest_gap, braking):
		return cruise_speed

	if nearest_gap <= safe_distance:
		return 0.0

	return sqrt(
		2.0 * braking * maxf(nearest_gap - safe_distance, 0.0)
	)


# ============================================================
# LEADER DETECTION
# ------------------------------------------------------------
# Gap is the along-route distance from this car's center to
# the nearest same-lane obstacle's center. Negative / huge
# results mean "nothing ahead".
# ============================================================

func gap_to_leader() -> float:
	return float(leader_state()["gap"])


## Returns bumper-to-bumper gap and leader speed. Using physical lengths fixes
## the previous mismatch where following decisions used center distances.
func leader_state() -> Dictionary:
	var best_gap: float = INF
	var best_speed: float = 0.0

	for other in get_tree().get_nodes_in_group("traffic"):
		if not is_instance_valid(other) or other == self:
			continue

		if other.get("route") != route:
			continue

		if float(other.get("travel_direction")) != travel_direction:
			continue

		var other_offset: float = float(other.call(
			"_lane_offset_at",
			float(other.get("progress"))
		))
		var own_offset: float = _lane_offset_at(float(other.get("progress")))

		if absf(other_offset - own_offset) > lane_match_distance:
			continue

		var center_gap: float = (
			(float(other.get("progress")) - progress)
			*
			travel_direction
		)
		var other_length: float = float(other.get("vehicle_length"))
		var gap: float = center_gap - (vehicle_length + other_length) * 0.5

		if center_gap <= 0.0 or gap >= best_gap:
			continue

		best_gap = gap
		best_speed = float(other.get("speed"))

	# The ego vehicle is not part of the traffic system but
	# still occupies a lane.
	var ego: Node = get_tree().get_first_node_in_group(
		"vehicle_obstacle"
	)

	if ego != null and is_instance_valid(ego):
		var ego_gap: float = gap_to_position(
			ego.global_position
		)

		if ego_gap < best_gap:
			best_gap = ego_gap
			best_speed = float(ego.get("current_speed"))

	for pedestrian in get_tree().get_nodes_in_group("pedestrians"):
		if not is_instance_valid(pedestrian):
			continue
		# Pedestrians waiting at the curb are deliberately outside the roadway.
		# Only an active crossing should act as a longitudinal lane obstacle.
		if not bool(pedestrian.get("is_crossing")):
			continue

		var pedestrian_gap: float = gap_to_position(pedestrian.global_position)

		if pedestrian_gap < best_gap:
			best_gap = pedestrian_gap
			best_speed = 0.0

	return {"gap": best_gap, "speed": best_speed}


func gap_to_position(position: Vector2) -> float:
	if route == null or not route.is_valid():
		return INF

	var near: Dictionary = route.nearest(position)

	var other_progress: float = float(near["progress"])

	# Only when the other vehicle really shares this lane.
	var lane_center: Vector2 = route.get_position_at(
		other_progress,
		lane_offset
	)

	if lane_center.distance_to(position) > lane_match_distance:
		return INF

	var center_gap: float = (
		(other_progress - progress)
		*
		travel_direction
	)

	if center_gap <= 0.0:
		return INF

	var other_length: float = 122.0
	var ego: Node = get_tree().get_first_node_in_group("vehicle_obstacle")

	if ego != null and ego.has_method("get_speed_kmh"):
		other_length = float(ego.get("vehicle_length"))

	return center_gap - (vehicle_length + other_length) * 0.5


# All route progress values of vehicles sharing this lane
# (other traffic cars only).
func same_lane_progresses() -> Array[float]:
	var values: Array[float] = []

	for other in get_tree().get_nodes_in_group("traffic"):
		if not is_instance_valid(other) or other == self:
			continue

		if other.get("route") != route:
			continue

		if float(other.get("travel_direction")) != travel_direction:
			continue

		var other_offset: float = float(other.call(
			"_lane_offset_at",
			float(other.get("progress"))
		))
		var own_offset: float = _lane_offset_at(float(other.get("progress")))

		if absf(other_offset - own_offset) > lane_match_distance:
			continue

		values.append(float(other.get("progress")))

	var ego: Node = get_tree().get_first_node_in_group(
		"vehicle_obstacle"
	)

	if ego != null and is_instance_valid(ego):
		# Membership here must ignore direction: an ego behind
		# this car still blocks re-entry when this car wraps.
		var near: Dictionary = route.nearest(
			ego.global_position
		)

		var lane_center: Vector2 = route.get_position_at(
			float(near["progress"]),
			lane_offset
		)

		if lane_center.distance_to(ego.global_position) <= lane_match_distance:
			values.append(float(near["progress"]))

	return values
