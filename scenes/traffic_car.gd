class_name TrafficCar
extends CharacterBody2D


# ============================================================
# TRAFFIC SETTINGS
# ============================================================

@export_category("Traffic")

@export var acceleration: float = 100.0
@export var braking: float = 300.0

@export var max_steering_speed: float = 5.0

# How far ahead on the lane the car looks to choose its heading
# (keep it small: a long lookahead makes the body point into the
# curve and clip the walls)
# (replaces the old waypoint lookahead).
@export var lookahead_distance: float = 30.0

# How strongly the car is pulled back onto the centre of its lane
# (1/s). Higher = tighter lane keeping.
@export var lane_correction_gain: float = 8.0

# Must match the CollisionShape2D length (80 x 144 in traffic_car.tscn).
@export var car_length: float = 144.0


# ============================================================
# FOLLOWING
# ------------------------------------------------------------
# All three distances are GAPS (bumper to bumper), not
# centre to centre, so they stay valid for any car size.
# ============================================================

@export_category("Following")

@export var detection_distance: float = 300.0
@export var slow_distance: float = 160.0
@export var safe_distance: float = 60.0


# ============================================================
# CURVES
# ============================================================

@export_category("Curves")

# Heading change (radians) over curve_probe_distance that
# slows the car down to curve_speed_factor * cruise speed.
@export var curve_probe_distance: float = 180.0
@export var curve_angle_threshold: float = 0.25
@export_range(0.1, 1.0, 0.05) var curve_speed_factor: float = 0.55


# ============================================================
# ROUTE
# ============================================================

@export_category("Route")

@export var progress_search_window: float = 300.0

# Car re-enters at the start of its lane when it gets this close
# to the end of the route (Python: "re-enter when clear").
@export var route_end_margin: float = 80.0
@export var route_entry_margin: float = 250.0


# ============================================================
# INTERNAL STATE
# ============================================================

var speed: float = 120.0
var cruise_speed: float = 120.0
var target_speed: float = 120.0

var route: RoutePath

# Distance travelled along route (centreline, not the lane).
var progress: float = 0.0

# +1 = along the route, -1 = against it.
var direction: int = 1

# Lateral offset of the lane from the route centreline.
var lane_offset: float = 0.0

var lane_id: int = 0


# ============================================================
# READY
# ============================================================

func _ready() -> void:
	if not is_in_group("traffic"):
		add_to_group("traffic")


# ============================================================
# SETUP
# ============================================================

func setup(
	new_route: RoutePath,
	start_progress: float,
	new_speed: float,
	new_lane_id: int = 0,
	new_direction: int = 1,
	new_lane_offset: float = 0.0
) -> void:
	route = new_route

	direction = 1 if new_direction >= 0 else -1

	lane_id = new_lane_id
	lane_offset = new_lane_offset

	speed = new_speed
	cruise_speed = new_speed
	target_speed = new_speed

	if route == null or not route.is_valid():
		return

	place_on_route(start_progress)


func place_on_route(new_progress: float) -> void:
	progress = clampf(new_progress, 0.0, route.length)

	var lane_position: Vector2 = route.get_position_at(
		progress,
		lane_offset
	)

	if is_inside_tree():
		global_position = lane_position
	else:
		position = lane_position

	rotation = get_route_rotation(progress)

	velocity = Vector2.ZERO


func get_route_rotation(at_progress: float) -> float:
	var result: float = route.get_rotation_at(at_progress)

	if direction < 0:
		result += PI

	return result


# ============================================================
# PHYSICS
# ============================================================

func _physics_process(delta: float) -> void:
	if route == null or not route.is_valid():
		velocity = Vector2.ZERO
		return


	# --------------------------------------------------------
	# Where are we on the route?
	# --------------------------------------------------------

	update_progress()


	if is_near_route_end():
		handle_route_end()
		return


	# --------------------------------------------------------
	# Speed control
	# --------------------------------------------------------

	target_speed = calculate_target_speed()

	if speed < target_speed:
		speed = move_toward(
			speed,
			target_speed,
			acceleration * delta
		)

	else:
		speed = move_toward(
			speed,
			target_speed,
			braking * delta
		)


	# --------------------------------------------------------
	# Steering: face the way the lane is heading a bit ahead
	# --------------------------------------------------------

	var heading: Vector2 = route.get_direction_at(
		progress + direction * lookahead_distance
	) * direction

	rotation = lerp_angle(
		rotation,
		heading.angle() + PI / 2.0,
		minf(
			max_steering_speed * delta,
			1.0
		)
	)


	# --------------------------------------------------------
	# Movement: follow the lane, pulled back to its centre
	# --------------------------------------------------------

	var lane_position: Vector2 = route.get_position_at(
		progress,
		lane_offset
	)

	var lane_direction: Vector2 = route.get_direction_at(progress) * direction

	velocity = (
		lane_direction * speed
		+
		(lane_position - global_position) * lane_correction_gain
	)

	move_and_slide()


# ============================================================
# PROGRESS
# ============================================================

func update_progress() -> void:
	var hit: Dictionary = route.nearest(
		global_position,
		progress,
		progress_search_window
	)

	progress = float(hit["progress"])


func get_remaining_distance() -> float:
	if direction > 0:
		return route.length - progress

	return progress


func is_near_route_end() -> bool:
	return get_remaining_distance() < route_end_margin


# ============================================================
# ROUTE END
# ------------------------------------------------------------
# Python: the car re-enters at the entrance of the same route,
# but only when that spot is free.
# ============================================================

func handle_route_end() -> void:
	velocity = Vector2.ZERO
	speed = 0.0

	var entry_progress: float = route_entry_margin

	if direction < 0:
		entry_progress = route.length - route_entry_margin

	if is_entry_clear(entry_progress):
		place_on_route(entry_progress)


func is_entry_clear(entry_progress: float) -> bool:
	var shape_node := get_node_or_null("CollisionShape2D") as CollisionShape2D

	if shape_node == null or shape_node.shape == null:
		return true


	var query := PhysicsShapeQueryParameters2D.new()

	query.shape = shape_node.shape

	query.transform = Transform2D(
		get_route_rotation(entry_progress),
		route.get_position_at(entry_progress, lane_offset)
	)

	query.collision_mask = collision_mask
	query.exclude = [get_rid()]

	var hits: Array[Dictionary] = (
		get_world_2d().direct_space_state.intersect_shape(query, 1)
	)

	return hits.is_empty()


# ============================================================
# TARGET SPEED
# ============================================================

func calculate_target_speed() -> float:
	var free_speed: float = cruise_speed * get_curve_speed_factor()

	var leader: TrafficCar = find_vehicle_ahead()

	if leader == null:
		return free_speed


	var gap: float = get_gap_to(leader)

	if gap >= slow_distance:
		return free_speed


	if gap > safe_distance:
		var ratio: float = (
			(gap - safe_distance)
			/
			maxf(slow_distance - safe_distance, 0.001)
		)

		return minf(
			free_speed,
			lerpf(leader.speed, free_speed, ratio)
		)


	# Closer than the safe gap: never faster than the leader,
	# and down to a full stop when touching it.
	return minf(
		free_speed,
		leader.speed * gap / maxf(safe_distance, 0.001)
	)


# Slow down smoothly before tight curves (Python: 0.55 factor
# when the heading changes more than 0.25 rad within 60 units).
func get_curve_speed_factor() -> float:
	var current_direction: Vector2 = route.get_direction_at(progress)

	var ahead_direction: Vector2 = route.get_direction_at(
		progress + direction * curve_probe_distance
	)

	var angle: float = absf(
		current_direction.angle_to(ahead_direction)
	)

	return lerpf(
		1.0,
		curve_speed_factor,
		clampf(
			angle / maxf(curve_angle_threshold, 0.001),
			0.0,
			1.0
		)
	)


# ============================================================
# FIND VEHICLE AHEAD
# ------------------------------------------------------------
# Same route, same direction, same lane, further along.
# ============================================================

func find_vehicle_ahead() -> TrafficCar:
	var closest_vehicle: TrafficCar = null

	var closest_gap: float = detection_distance


	for node in get_tree().get_nodes_in_group("traffic"):
		if not is_instance_valid(node):
			continue


		var other := node as TrafficCar

		if other == null or other == self:
			continue


		if other.route != route:
			continue

		if other.direction != direction:
			continue

		if other.lane_id != lane_id:
			continue


		# Ignore cars behind us
		if (other.progress - progress) * direction <= 0.0:
			continue


		var gap: float = get_gap_to(other)

		if gap < closest_gap:
			closest_gap = gap
			closest_vehicle = other


	return closest_vehicle


func get_gap_to(other: TrafficCar) -> float:
	return maxf(
		(other.progress - progress) * direction - car_length,
		0.0
	)
