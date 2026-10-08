extends CharacterBody2D


# ============================================================
# TRAFFIC SETTINGS
# ============================================================

@export_category("Traffic")

@export var acceleration: float = 100.0
@export var braking: float = 300.0

@export var max_steering_speed: float = 5.0
@export var waypoint_reach_distance: float = 30.0


# ============================================================
# FOLLOWING
# ============================================================

@export_category("Following")

@export var detection_distance: float = 180.0
@export var safe_distance: float = 70.0
@export var slow_distance: float = 130.0


# ============================================================
# INTERNAL STATE
# ============================================================

var speed: float = 120.0
var cruise_speed: float = 120.0
var target_speed: float = 120.0

var path_points: Array[Vector2] = []

var current_index: int = 0

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
	new_path: Array[Vector2],
	start_index: int,
	new_speed: float,
	new_lane_id: int = 0
) -> void:
	path_points = new_path

	current_index = clampi(
		start_index,
		0,
		maxi(path_points.size() - 1, 0)
	)

	speed = new_speed
	cruise_speed = new_speed
	target_speed = new_speed

	lane_id = new_lane_id

	if path_points.is_empty():
		return

	if is_inside_tree():
		global_position = path_points[current_index]
	else:
		position = path_points[current_index]

	update_rotation()


# ============================================================
# PHYSICS
# ============================================================

func _physics_process(delta: float) -> void:
	if path_points.size() < 2:
		velocity = Vector2.ZERO
		return


	# --------------------------------------------------------
	# Update waypoint
	# --------------------------------------------------------

	update_waypoint()


	# --------------------------------------------------------
	# Calculate direction
	# --------------------------------------------------------

	var target_point: Vector2 = get_lookahead_point()

	var to_target: Vector2 = (
		target_point - global_position
	)


	if to_target.length_squared() < 0.001:
		velocity = Vector2.ZERO
		return


	var direction: Vector2 = to_target.normalized()


	# --------------------------------------------------------
	# Detect vehicle in same lane
	# --------------------------------------------------------

	var vehicle_ahead: Node2D = find_vehicle_ahead()


	if vehicle_ahead != null:
		var distance: float = (
			global_position.distance_to(
				vehicle_ahead.global_position
			)
		)

		if distance <= safe_distance:
			target_speed = cruise_speed * 0.25

		elif distance < slow_distance:
			var ratio: float = clampf(
				(distance - safe_distance)
				/
				maxf(
					slow_distance - safe_distance,
					0.001
				),
				0.0,
				1.0
			)

			target_speed = lerpf(
				cruise_speed * 0.25,
				cruise_speed,
				ratio)

		else:
			target_speed = cruise_speed

	else:
		target_speed = cruise_speed


	# --------------------------------------------------------
	# Speed control
	# --------------------------------------------------------

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
	# Steering
	# --------------------------------------------------------

	var desired_rotation: float = (
		direction.angle()
		+
		PI / 2.0
	)


	rotation = lerp_angle(
		rotation,
		desired_rotation,
		minf(
			max_steering_speed * delta,
			1.0
		)
	)


	# --------------------------------------------------------
	# Movement
	# --------------------------------------------------------

	velocity = direction * speed

	move_and_slide()


# ============================================================
# WAYPOINT
# ============================================================

func update_waypoint() -> void:
	if path_points.is_empty():
		return


	while current_index < path_points.size() - 1:
		var target: Vector2 = path_points[current_index]

		var distance: float = (
			global_position.distance_to(target)
		)

		if distance > waypoint_reach_distance:
			break

		current_index += 1


	# Loop back to beginning
	if current_index >= path_points.size() - 1:
		current_index = 0

		global_position = path_points[0]


# ============================================================
# LOOKAHEAD
# ============================================================

func get_lookahead_point() -> Vector2:
	var lookahead_index: int = min(
		current_index + 2,
		path_points.size() - 1
	)

	return path_points[lookahead_index]


# ============================================================
# FIND VEHICLE AHEAD
# ============================================================

func find_vehicle_ahead() -> Node2D:
	var closest_vehicle: Node2D = null

	var closest_distance: float = detection_distance


	for node in get_tree().get_nodes_in_group("traffic"):
		if not is_instance_valid(node):
			continue


		var other: Node2D = node as Node2D

		if other == null:
			continue


		if other == self:
			continue


		# ----------------------------------------------------
		# SAME LANE ONLY
		# ----------------------------------------------------

		var other_lane = other.get("lane_id")

		if other_lane != lane_id:
			continue


		# ----------------------------------------------------
		# GET OTHER CAR PATH POSITION
		# ----------------------------------------------------

		var other_index_value = other.get("current_index")

		if other_index_value == null:
			continue


		var other_index: int = int(other_index_value)


		# ----------------------------------------------------
		# ONLY LOOK FOR CARS AHEAD
		# ----------------------------------------------------

		var index_difference: int = (
			other_index - current_index
		)


		# Ignore cars behind us
		if index_difference <= 0:
			continue


		# Don't detect cars on the other side of the loop
		if index_difference > 20:
			continue


		# ----------------------------------------------------
		# ACTUAL DISTANCE
		# ----------------------------------------------------

		var distance: float = global_position.distance_to(
			other.global_position
		)


		if distance > detection_distance:
			continue


		# ----------------------------------------------------
		# CLOSEST VEHICLE
		# ----------------------------------------------------

		if distance < closest_distance:
			closest_distance = distance

			closest_vehicle = other


	return closest_vehicle

# ============================================================
# ROTATION
# ============================================================

func update_rotation() -> void:
	if path_points.size() < 2:
		return


	var next_index: int = min(
		current_index + 1,
		path_points.size() - 1
	)


	var direction: Vector2 = (
		path_points[next_index]
		-
		path_points[current_index]
	).normalized()


	if direction.length_squared() < 0.001:
		return


	rotation = (
		direction.angle()
		+
		PI / 2.0
	)