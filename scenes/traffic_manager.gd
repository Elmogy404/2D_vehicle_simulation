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

# true  : lanes right of the centreline drive forward, lanes left
#         of it drive the opposite way (like the Python reference)
# false : every lane drives forward (previous behaviour)
@export var bidirectional_traffic: bool = true

# Distances along the road (they replace the old point indices
# first_spawn_index / lane_spacing).
@export var first_spawn_distance: float = 480.0

@export var spawn_spacing: float = 480.0

# No cars are spawned closer than this to the end of the road.
@export var spawn_end_margin: float = 300.0


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

var routes: Array[RoutePath] = []

var traffic_cars: Array[Node] = []


# ============================================================
# READY
# ============================================================

func _ready() -> void:
	road_generator = get_parent().get_node(
		"RoadGenerator"
	)


	# Rebuild traffic whenever the road is regenerated (R key,
	# generate_with_seed, ...).
	if road_generator.has_signal("road_generated"):
		road_generator.road_generated.connect(regenerate)


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
# ROUTES
# ------------------------------------------------------------
# For now the road is a single route. Later the road generator
# will provide several (branches), this is the only place that
# needs to know.
# ============================================================

func build_routes() -> void:
	routes.clear()

	centerline = road_generator.get_center_points()

	var route := RoutePath.new(centerline)

	if route.is_valid():
		routes.append(route)


# ============================================================
# LANES
# ============================================================

# Lateral offset of a lane from the road centreline
# (same formula as before).
func get_lane_offset(lane_id: int) -> float:
	return (
		(
			float(lane_id)
			-
			(float(lane_count - 1) / 2.0)
		)
		*
		lane_width
	)


# +1 = drives along the route, -1 = against it.
func get_lane_direction(lane_offset: float) -> int:
	if not bidirectional_traffic:
		return 1

	return 1 if lane_offset >= 0.0 else -1


# ============================================================
# SPAWN
# ============================================================

func spawn_traffic() -> void:
	clear_traffic()

	build_routes()

	if centerline.size() < 20 or routes.is_empty():
		push_warning("Road is too short for traffic.")
		return

	if traffic_car_scene == null:
		push_error("Traffic Car Scene is not assigned.")
		return


	var route: RoutePath = routes[0]


	for i in range(number_of_cars):
		var lane_id: int = i % lane_count

		var cars_in_lane: int = floori(
			float(i) / float(lane_count)
		)

		var lane_offset: float = get_lane_offset(lane_id)

		var lane_direction: int = get_lane_direction(lane_offset)


		var distance_from_entry: float = (
			first_spawn_distance
			+
			cars_in_lane * spawn_spacing
		)

		if distance_from_entry >= route.length - spawn_end_margin:
			break


		# Cars driving against the route start at its far end.
		var start_progress: float = distance_from_entry

		if lane_direction < 0:
			start_progress = route.length - distance_from_entry


		var car: Node = traffic_car_scene.instantiate()

		if not car.has_method("setup"):
			push_error(
				"TrafficCar scene does not contain setup()."
			)

			car.queue_free()

			continue


		var speed: float = rng.randf_range(
			minimum_speed,
			maximum_speed
		)


		# Place the car BEFORE adding it to the tree. Adding it first
		# registers its collision shape at (0, 0) for one physics
		# step, which shoves anything standing at the spawn point
		# (the ego vehicle) away.
		car.setup(
			route,
			start_progress,
			speed,
			lane_id,
			lane_direction,
			lane_offset
		)

		add_child(car)

		traffic_cars.append(car)


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
