extends Node2D


# ============================================================
# TRAFFIC
# ============================================================

@export_category("Traffic")

@export var traffic_car_scene: PackedScene

@export var number_of_cars: int = 8

@export var minimum_speed: float = 80.0

@export var maximum_speed: float = 160.0


# ============================================================
# LANES
# ============================================================

@export_category("Lanes")

@export var lane_count: int = 2

@export var lane_width: float = 90.0

@export var lane_spacing: int = 8

@export var first_spawn_index: int = 8


# ============================================================
# RANDOM
# ============================================================

@export_category("Random")

@export var seed_value: int = 12345

@export var randomize_seed: bool = false


# ============================================================
# INTERNAL
# ============================================================

var rng := RandomNumberGenerator.new()

var road_generator: Node

var centerline: Array[Vector2] = []

var traffic_cars: Array[Node] = []


# ============================================================
# READY
# ============================================================

func _ready() -> void:
	road_generator = get_parent().get_node(
		"RoadGenerator"
	)


	setup_rng()


	await get_tree().process_frame


	spawn_traffic()


# ============================================================
# RNG
# ============================================================

func setup_rng() -> void:
	if randomize_seed:
		rng.randomize()

	else:
		rng.seed = seed_value


# ============================================================
# SPAWN
# ============================================================

func spawn_traffic() -> void:
	clear_traffic()

	centerline = road_generator.get_center_points()

	if centerline.size() < 20:
		push_warning("Road is too short for traffic.")
		return

	if traffic_car_scene == null:
		push_error("Traffic Car Scene is not assigned.")
		return


	for i in range(number_of_cars):
		var lane_id: int = i % lane_count

		var cars_in_lane: int = int(i / lane_count)

		var spawn_index: int = (
			first_spawn_index
			+
			cars_in_lane * lane_spacing
		)


		if spawn_index >= centerline.size() - 2:
			break


		var lane_path: Array[Vector2] = build_lane_path(
			lane_id
		)


		var car: Node = traffic_car_scene.instantiate()

		add_child(car)


		var speed: float = rng.randf_range(
			minimum_speed,
			maximum_speed
		)


		if car.has_method("setup"):
			car.setup(
				lane_path,
				spawn_index,
				speed,
				lane_id
			)

			traffic_cars.append(car)

		else:
			push_error(
				"TrafficCar scene does not contain setup()."
			)

			car.queue_free()


# ============================================================
# BUILD LANE
# ============================================================

func build_lane_path(
	lane_id: int
) -> Array[Vector2]:
	var lane_path: Array[Vector2] = []


	# --------------------------------------------------------
	# Calculate lateral offset
	# --------------------------------------------------------

	var offset_from_center := (
		(
			float(lane_id)
			-
			(float(lane_count - 1) / 2.0)
		)
		*
		lane_width
	)


	for i in range(centerline.size()):
		var direction: Vector2


		if i == 0:
			direction = (
				centerline[1]
				-
				centerline[0]
			)


		elif i == centerline.size() - 1:
			direction = (
				centerline[i]
				-
				centerline[i - 1]
			)


		else:
			direction = (
				centerline[i + 1]
				-
				centerline[i - 1]
			)


		direction = direction.normalized()


		var normal := Vector2(
			- direction.y,
			direction.x
		)


		var point := (
			centerline[i]
			+
			normal * offset_from_center
		)


		lane_path.append(point)


	return lane_path


# ============================================================
# CLEAR
# ============================================================

func clear_traffic() -> void:
	for car in traffic_cars:
		if is_instance_valid(car):
			car.queue_free()


	traffic_cars.clear()


# ============================================================
# REGENERATE
# ============================================================

func regenerate() -> void:
	setup_rng()

	spawn_traffic()
