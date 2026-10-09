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
# ------------------------------------------------------------
# Lane geometry is derived from the road so that the lanes
# always fit inside the drivable area:
#
#   lane_width = road_width / (2 * lanes_per_direction)
#
# With right-hand traffic, lanes on the right half of the
# road travel WITH the centerline and lanes on the left half
# travel AGAINST it.
# ============================================================

@export_category("Lanes")

## Lanes in each direction (1 = one lane each way).
@export var lanes_per_direction: int = 3

## Vehicle dimensions used to keep spawn points and lane
## offsets physically valid.
@export var vehicle_width: float = 62.0
@export var vehicle_length: float = 122.0

## Distance along the route where the first cars spawn.
@export var first_spawn_distance: float = 400.0

## Distance between spawn points of cars in the same lane.
@export var spawn_spacing: float = 500.0


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

# Lane descriptors: { id, offset, direction }
var lanes: Array[Dictionary] = []

# Shared distance-based view of the road, owned by the
# road generator so regeneration replaces it in one place.
var route: RoutePath

var traffic_cars: Array[Node] = []

const TRAFFIC_TEXTURES: Array[Texture2D] = [
	preload("res://assets/random cars/car_blue_1.png"),
	preload("res://assets/random cars/car_blue_2.png"),
	preload("res://assets/random cars/car_blue_3.png")
]

const TRAFFIC_BODY_SIZES: Array[Vector2] = [
	Vector2(62.0, 122.0),
	Vector2(62.0, 108.0),
	Vector2(62.0, 122.0)
]


# ============================================================
# READY
# ============================================================

func _ready() -> void:
	road_generator = get_parent().get_node(
		"RoadGenerator"
	)


	setup_rng()


	await get_tree().process_frame


	# Regenerating the road must rebuild traffic too.
	road_generator.connect(
		&"road_regenerated",
		regenerate
	)


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
# LANES
# ============================================================

func lane_count() -> int:
	return maxi(lanes_per_direction, 1) * 2


func build_lanes() -> void:
	lanes.clear()

	var width_per_lane: float = float(road_generator.get("lane_width"))

	if vehicle_width > width_per_lane:
		push_warning(
			"TrafficManager: vehicle width %.0f exceeds lane width %.0f."
			% [vehicle_width, width_per_lane]
		)

	var id: int = 0

	for direction in [1.0, -1.0]:
		for i in range(maxi(lanes_per_direction, 1)):
			# Distance from the centerline to this lane's
			# center. Direction +1 drives on the right half.
			var offset: float = (
				direction
				*
				(i + 0.5)
				*
				width_per_lane
			)

			lanes.append({
				"id": id,
				"offset": offset,
				"direction": direction,
				"index": i
			})

			id += 1


# ============================================================
# SPAWN
# ============================================================

func spawn_traffic() -> void:
	clear_traffic()

	route = road_generator.get_route()

	if route == null or not route.is_valid():
		push_warning("Road is too short for traffic.")
		return

	if traffic_car_scene == null:
		push_error("Traffic Car Scene is not assigned.")
		return


	build_lanes()


	for i in range(number_of_cars):
		var lane: Dictionary = lanes[i % lanes.size()]

		var cars_in_lane: int = int(i / lanes.size())

		var spawn_distance: float = (
			first_spawn_distance
			+
			cars_in_lane * spawn_spacing
		)

		spawn_distance = fmod(spawn_distance, route.length)
		var spawn_pose := find_clear_spawn_pose(spawn_distance, lane)

		if spawn_pose.is_empty():
			continue

		spawn_distance = float(spawn_pose["progress"])
		var spawn_offset: float = float(spawn_pose["offset"])


		var car: Node = traffic_car_scene.instantiate()

		add_child(car)

		# Visual variety is deterministic and collider geometry follows the
		# selected sprite. It consumes no RNG, so seeded speed assignments stay
		# backward-compatible.
		var variant: int = i % TRAFFIC_TEXTURES.size()

		if car.has_method("configure_visual"):
			car.configure_visual(
				TRAFFIC_TEXTURES[variant],
				TRAFFIC_BODY_SIZES[variant]
			)


		var speed: float = rng.randf_range(
			minimum_speed,
			maximum_speed
		)


		if car.has_method("setup"):
			car.setup(
				route,
				int(lane["id"]),
				int(lane["index"]),
				spawn_offset,
				float(lane["direction"]),
				spawn_distance,
				speed
			)

			traffic_cars.append(car)

		else:
			push_error(
				"TrafficCar scene does not contain setup()."
			)

			car.queue_free()


func find_clear_spawn_pose(start_distance: float, lane: Dictionary) -> Dictionary:
	var candidate := start_distance
	var step := maxf(float(road_generator.get("segment_length")), 30.0)
	var attempts := ceili(route.length / step)
	var lane_index: int = int(lane["index"])
	var lane_direction: float = float(lane["direction"])
	var lane_id: int = int(lane["id"])

	for attempt in range(attempts):
		if route.get_lane_count_at(candidate) > lane_index:
			var offset := route.get_lane_offset_at(candidate, lane_index, lane_direction)

			if not is_near_intersection(candidate) and is_spawn_clear(
				candidate,
				offset,
				lane_id
			):
				return {"progress": candidate, "offset": offset}

		candidate = fposmod(candidate + step, route.length)

	return {}


func is_near_intersection(candidate: float) -> bool:
	for index in road_generator.get_intersection_indices():
		var feature_progress: float = float(route.cumulative[index])

		if absf(feature_progress - candidate) < vehicle_length * 1.5:
			return true

	return false


# Never drop a car on top of another one. Vehicles in OTHER
# lanes are already separated sideways, so they only matter
# when the bodies would actually touch.
func is_spawn_clear(
	spawn_distance: float,
	spawn_offset: float,
	spawn_lane_id: int
) -> bool:
	var spawn_point: Vector2 = route.get_position_at(
		spawn_distance,
		spawn_offset
	)

	var same_lane_gap: float = vehicle_length + 20.0

	for other in get_tree().get_nodes_in_group("traffic"):
		if not is_instance_valid(other):
			continue

		if other.get("route") != route:
			continue

		if int(other.get("lane_id")) == spawn_lane_id:
			if along_route_gap(
				spawn_distance,
				float(other.get("progress"))
			) < same_lane_gap:
				return false

		elif spawn_point.distance_to(
			other.global_position
		) < vehicle_width:
			return false

	# The ego vehicle must not be overwritten either. It is
	# matched to a lane by its actual lateral position.
	var ego: Node = get_tree().get_first_node_in_group(
		"vehicle_obstacle"
	)

	if ego != null and is_instance_valid(ego):
		var near: Dictionary = route.nearest(
			ego.global_position
		)

		var lane_center: Vector2 = route.get_position_at(
			float(near["progress"]),
			spawn_offset
		)

		var shares_lane: bool = (
			lane_center.distance_to(ego.global_position)
			<= 75.0
		)

		if shares_lane:
			if along_route_gap(
				spawn_distance,
				float(near["progress"])
			) < same_lane_gap:
				return false

		elif spawn_point.distance_to(ego.global_position) < vehicle_width:
			return false

	return true


# Shortest distance along the route between two progress
# values (the route loops, so both ways are considered).
func along_route_gap(a: float, b: float) -> float:
	var gap: float = absf(a - b)
	return minf(gap, route.length - gap)


# ============================================================
# EGO SPAWN
# ------------------------------------------------------------
# The ego starts inside the first lane travelling with the
# centerline, ahead of the NPC spawn area.
# ============================================================

func get_ego_spawn_pose() -> Dictionary:
	route = road_generator.get_route()

	if route == null or not route.is_valid():
		return {
			"position": road_generator.get_spawn_position(),
			"rotation": road_generator.get_spawn_rotation()
		}

	build_lanes()

	var lane: Dictionary = lanes[0]

	var distance: float = minf(
		first_spawn_distance * 0.5,
		route.length * 0.5
	)

	return {
		"position": route.get_position_at(
			distance,
			float(lane["offset"])
		),
		"rotation": route.get_rotation_at(distance)
	}


# ============================================================
# CLEAR
# ============================================================

func clear_traffic() -> void:
	for car in traffic_cars:
		if is_instance_valid(car):
			# Remove from the tree immediately so spawn
			# clearance checks cannot see dying cars.
			if car.get_parent() != null:
				car.get_parent().remove_child(car)

			car.queue_free()


	traffic_cars.clear()


# ============================================================
# REGENERATE
# ============================================================

func regenerate() -> void:
	setup_rng()

	spawn_traffic()
