extends Node2D
const CLEARANCE = preload("res://scripts/vehicle_clearance.gd")
const TRAFFIC_ROUTE = preload("res://scripts/traffic_route.gd")


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
var active_seed: int = 12345

var road_generator: Node

# Lane descriptors: { id, offset, direction }
var lanes: Array[Dictionary] = []

# Shared distance-based view of the road, owned by the
# road generator so regeneration replaces it in one place.
var route: RoutePath

var traffic_cars: Array[Node] = []
var traffic_enabled: bool = false
var route_clearance_cache: Dictionary = {}
var last_rejected_pose: Dictionary = {}

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


	# Regenerating the road must rebuild traffic too.
	road_generator.road_regenerated.connect(regenerate)


	spawn_traffic()


# ============================================================
# RNG
# ============================================================

func setup_rng() -> void:
	if randomize_seed:
		rng.randomize()
		active_seed = rng.seed

	else:
		rng.seed = seed_value
		active_seed = seed_value


func _cruise_speed_for_vehicle(variant_index: int) -> float:
	# Keep each vehicle's cruise speed stable even if route-selection retries use
	# a different number of RNG draws during a later traffic deployment.
	var speed_rng := RandomNumberGenerator.new()
	speed_rng.seed = maxi(
		1,
		posmod(active_seed + (variant_index + 1) * 104729, 2147483647)
	)
	return speed_rng.randf_range(minimum_speed, maximum_speed)


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
	if not traffic_enabled or road_generator == null:
		return
	if traffic_car_scene == null:
		push_error("Traffic Car Scene is not assigned.")
		return
	var network: Object = road_generator.call("get_road_network")
	if network == null or int(network.get("positions").size()) < 2:
		return
	var lane_width := float(road_generator.get("lane_width"))
	for i in range(number_of_cars):
		var spawned := false
		for attempt in range(64):
			var trip: Dictionary = network.call(
				# NPC routes use shortest graph trips; the curriculum walk fallback
				# is reserved for AI planning and can intentionally revisit blocks.
				"choose_random_route", 850.0 if attempt < 32 else 450.0, 3400.0 if attempt < 32 else 1700.0, 0, rng,
				PackedStringArray(["u_turn_bay"]), 4
			)
			if trip.is_empty():
				break
			var car_route := _route_from_trip_data(network, trip, lane_width)
			if car_route == null or not car_route.is_valid():
				continue
			var start_progress := minf(55.0, car_route.length * 0.04)
			var available_spawn_lanes := car_route.get_lane_count_at(0.0)
			for sample_index in range(1, 6):
				var sample_progress := start_progress * float(sample_index) / 5.0
				available_spawn_lanes = mini(
					available_spawn_lanes,
					car_route.get_lane_count_at(sample_progress)
				)
			var lane_index := rng.randi_range(
				0, available_spawn_lanes - 1
			)
			var spawn_offset := car_route.get_lane_offset_at(
				start_progress, lane_index, 1.0
			)
			var spawn_position := car_route.get_position_at(start_progress, spawn_offset)
			var spawn_rotation := car_route.get_rotation_at(start_progress)
			var body_size := TRAFFIC_BODY_SIZES[i % TRAFFIC_BODY_SIZES.size()]
			if not _network_spawn_is_clear(spawn_position, spawn_rotation, body_size):
				continue
			if not _route_is_clear(car_route, lane_index, body_size, start_progress):
				continue
			var node_path: Array = trip.get("nodes", [])
			if node_path.size() < 2:
				continue
			var car := _instantiate_network_car(i, car_route, lane_index, start_progress)
			if car == null:
				continue
			car.set("trip_end_node", int(trip.get("end_node", -1)))
			car.set("trip_previous_node", int(node_path[-2]))
			spawned = true
			break
		if not spawned:
			push_warning("TrafficManager: could not find a clear network trip for NPC %d." % i)


func _route_from_trip_data(network: Object, trip: Dictionary, lane_width: float) -> RoutePath:
	var rounded: Dictionary = network.call("smooth_route_data", trip, 120.0)
	var car_route := TRAFFIC_ROUTE.new()
	car_route.build_traffic(rounded, trip["points"], lane_width)
	return car_route if car_route.is_valid() else null


func _instantiate_network_car(
	variant_index: int,
	car_route: RoutePath,
	lane_index: int,
	start_progress: float
) -> Node:
	var car: Node = traffic_car_scene.instantiate()
	var variant := variant_index % TRAFFIC_TEXTURES.size()
	if car.has_method("configure_visual"):
		car.configure_visual(TRAFFIC_TEXTURES[variant], TRAFFIC_BODY_SIZES[variant])
	if not car.has_method("setup"):
		push_error("TrafficCar scene does not contain setup().")
		car.queue_free()
		return null
	var speed := _cruise_speed_for_vehicle(variant_index)
	car.call(
		"setup", car_route, variant_index, lane_index,
		car_route.get_lane_offset_at(start_progress, lane_index, 1.0),
		1.0, start_progress, speed
	)
	# Place the body before it enters the physics world. Adding a scene at the
	# origin and teleporting it in the same frame can leave a one-frame collider
	# behind at (0, 0), which may falsely crash the player at the map spawn.
	add_child(car)
	traffic_cars.append(car)
	return car


func _network_spawn_is_clear(position: Vector2, car_rotation: float,
		body_size: Vector2 = Vector2(62, 122), ignore: Node = null) -> bool:
	var clearance := CLEARANCE.new(body_size, 4.0)
	if not clearance.is_clear(get_world_2d().direct_space_state, position, car_rotation):
		return false
	var forward := Vector2.UP.rotated(car_rotation)
	for other in get_tree().get_nodes_in_group("traffic"):
		if not is_instance_valid(other) or other == ignore:
			continue
		var other_size := Vector2(float(other.get("vehicle_width")), float(other.get("vehicle_length")))
		if CLEARANCE.bodies_overlap(position, car_rotation, body_size, other.global_position, other.global_rotation, other_size):
			return false
	var ego := get_tree().get_first_node_in_group("vehicle_obstacle")
	if ego != null and is_instance_valid(ego):
		var ego_size := Vector2(float(ego.get("vehicle_width")), float(ego.get("vehicle_length")))
		if CLEARANCE.bodies_overlap(position, car_rotation, body_size, ego.global_position, ego.global_rotation, ego_size, Vector2(12, 60)):
			return false
	for candidate in get_tree().get_nodes_in_group("pedestrians"):
		if is_instance_valid(candidate) and CLEARANCE.bodies_overlap(position, car_rotation, body_size,
			candidate.global_position, candidate.global_rotation, Vector2(16, 25), Vector2(6, 6)):
			return false
	return forward.length_squared() > 0.5


func _route_is_clear(candidate: RoutePath, lane: int, body_size: Vector2, first: float) -> bool:
	var cache_key := "%d:%d:%d:%d:%s:%.3f" % [hash(candidate.points), hash(candidate.half_widths), hash(candidate.lane_profile), lane, str(body_size), first]
	if route_clearance_cache.has(cache_key):
		return route_clearance_cache[cache_key]
	if route_clearance_cache.size() >= 2048:
		route_clearance_cache.clear()
	var clearance := CLEARANCE.new(body_size, 2.0)
	var space := get_world_2d().direct_space_state
	var last := candidate.length - body_size.y * 0.5
	var progress := first
	while progress <= last:
		var offset := candidate.get_lane_offset_at(progress, lane, 1.0)
		if not clearance.is_clear(space, candidate.get_position_at(progress, offset), candidate.get_rotation_at(progress)):
			last_rejected_pose = {"progress": progress, "first": first, "length": candidate.length, "position": candidate.get_position_at(progress, offset), "offset": offset, "half_width": candidate.get_half_width_at(progress)}
			route_clearance_cache[cache_key] = false
			return false
		if is_equal_approx(progress, last):
			break
		progress = minf(progress + 5.0, last)
	route_clearance_cache[cache_key] = last >= first
	return last >= first


func assign_next_trip(car: Node, start_node: int, previous_node: int) -> bool:
	if not traffic_enabled or not is_instance_valid(car):
		return false
	# A graph-connected long trip can contain an unsafe turn farther ahead.
	# Try straight/short alternatives on validation failure, not only when the
	# graph has no route. Otherwise every retry can demand the same bad turn.
	for attempt in range(8):
		var minimum := 650.0 if attempt < 3 else 120.0
		var maximum := 3000.0 if attempt < 3 else 1200.0
		var turns := 1 if attempt < 3 else 0
		var previous := previous_node if attempt < 6 else -1
		if _assign_next_trip_candidate(car, start_node, previous, minimum, maximum, turns):
			return true
	return false


func _assign_next_trip_candidate(car: Node, start_node: int, previous_node: int,
		minimum: float, maximum: float, turns: int) -> bool:
	var network: Object = road_generator.call("get_road_network")
	if network == null:
		return false
	var trip: Dictionary = network.call(
		"choose_random_route_from_node",
		start_node, previous_node, minimum, maximum, rng, turns,
		PackedStringArray(["u_turn_bay"])
	)
	if trip.is_empty():
		return false
	var car_route := _route_from_trip_data(
		network, trip, float(road_generator.get("lane_width"))
	)
	if car_route == null:
		return false
	var node_path: Array = trip.get("nodes", [])
	if node_path.size() < 2:
		return false
	var next_lane := rng.randi_range(0, car_route.get_lane_count_at(0.0) - 1)
	var body_size := Vector2(float(car.get("vehicle_width")), float(car.get("vehicle_length")))
	var entry := minf(body_size.y * 0.5, car_route.length * 0.02)
	var entry_position := car_route.get_position_at(entry, car_route.get_lane_offset_at(entry, next_lane, 1.0))
	if not _route_is_clear(car_route, next_lane, body_size, entry):
		car.set_meta("trip_block_reason", "route intersects wall")
		car.set_meta("trip_block_pose", last_rejected_pose.duplicate())
		return false
	if not _network_spawn_is_clear(entry_position, car_route.get_rotation_at(entry), body_size, car):
		car.set_meta("trip_block_reason", "entry occupied")
		return false
	car.set_meta("trip_block_reason", "")
	car.call(
		"assign_trip", car_route, next_lane,
		int(trip.get("end_node", -1)), int(node_path[-2])
	)
	return true


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
	if road_generator.has_method("get_player_spawn_pose"):
		var preferred_pose: Dictionary = road_generator.call(
			"get_player_spawn_pose", float(lane["offset"])
		)
		if not preferred_pose.is_empty():
			return preferred_pose

	# Spawn inside the district rather than at a route endpoint. The arterial's
	# ends are ordinary perimeter junctions, not a level start or finish.
	var distance: float = route.length * 0.5

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
	route_clearance_cache.clear()
	var index := get_tree().get_first_node_in_group("simulation_spatial_index")
	if index != null:
		index.call("invalidate")
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


func set_traffic_enabled(enabled: bool) -> void:
	traffic_enabled = enabled
	if enabled:
		regenerate()
	else:
		clear_traffic()
