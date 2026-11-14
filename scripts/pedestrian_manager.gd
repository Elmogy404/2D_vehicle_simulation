extends Node2D


const PEDESTRIAN_SCENE := preload("res://scenes/Pedestrian.tscn")
const PEDESTRIAN_TINTS: Array[Color] = [
	Color(1.0, 1.0, 1.0),
	Color(0.92, 0.96, 1.0),
	Color(1.0, 0.94, 0.88)
]

@export var seed_value: int = 97531
@export_range(1, 4, 1) var pedestrians_per_crossing: int = 2
@export_range(1, 4, 1) var authored_pedestrians_per_crossing: int = 1
@export var player_pedestrian_simulation_radius: float = 1800.0
@export var traffic_pedestrian_simulation_radius: float = 700.0
@export var activity_update_interval: float = 0.25
@export var minimum_speed: float = 38.0
@export var maximum_speed: float = 62.0
@export var curb_margin: float = 28.0
@export var group_spacing: float = 22.0
@export var crosswalk_band_length: float = 32.0
@export var crosswalk_stripe_width: float = 3.0
@export var crosswalk_stripe_spacing: float = 8.0
@export var crosswalk_edge_inset: float = 5.0

var pedestrians: Array[SimulationPedestrian] = []
var road_generator: Node
var light_manager: Node
var rng := RandomNumberGenerator.new()
var crosswalks: Node2D
var pedestrians_enabled: bool = false
var authored_pedestrian_lod_active: bool = false
var activity_update_remaining: float = 0.0


func _ready() -> void:
	road_generator = get_parent().get_node("RoadGenerator")
	light_manager = get_parent().get_node("TrafficLightManager")
	light_manager.lights_regenerated.connect(regenerate)
	regenerate()


func _process(delta: float) -> void:
	if not pedestrians_enabled or not authored_pedestrian_lod_active:
		return
	activity_update_remaining -= delta
	if activity_update_remaining > 0.0:
		return
	activity_update_remaining = maxf(activity_update_interval, 0.05)
	_refresh_authored_pedestrian_activity()


func regenerate() -> void:
	clear_pedestrians()
	_clear_crosswalks()
	if not pedestrians_enabled or road_generator == null or light_manager == null:
		return
	var network: Object = road_generator.call("get_road_network")
	if network == null:
		return
	var map_seed := int(road_generator.get("seed_value"))
	rng.seed = posmod(seed_value ^ map_seed, 2147483647)
	if road_generator.has_method("uses_segmented_generation") \
	and bool(road_generator.call("uses_segmented_generation")):
		_spawn_authored_crosswalk_pedestrians()
		return
	crosswalks = Node2D.new()
	crosswalks.name = "Crosswalks"
	crosswalks.z_index = 2
	add_child(crosswalks)
	var lights: Array = light_manager.get("lights")
	for crossing_index in range(lights.size()):
		var light: Node = lights[crossing_index]
		if not is_instance_valid(light):
			continue
		var node_id := int(light.get("graph_node_id"))
		if int(network.call("get_node_degree", node_id)) < 3:
			continue
		var crossing_center: Vector2 = network.call("get_node_position", node_id)
		var road_axis: Vector2 = network.call("get_node_axis", node_id).normalized()
		if road_axis.length_squared() < 0.5:
			continue
		var half_width := float(network.call("get_node_half_width", node_id))
		if half_width < 50.0:
			continue
		# On a T junction, move the crossing along the through-road so the zebra
		# marks and waiting pedestrians never sit in the mouth of the side street.
		var branch_direction: Vector2 = network.call("get_node_branch_direction", node_id)
		if branch_direction.length_squared() > 0.5:
			var shift := minf(float(road_generator.get("cross_street_width")) * 0.5 + 45.0,
				half_width * 0.72)
			var side := -1.0 if rng.randi_range(0, 1) == 0 else 1.0
			crossing_center += road_axis * shift * side

		var road_normal := road_axis.rotated(PI * 0.5)
		var endpoint_a := crossing_center + road_normal * (half_width + curb_margin)
		var endpoint_b := crossing_center - road_normal * (half_width + curb_margin)
		_build_crosswalk(crossing_center, road_axis, half_width, node_id)
		var group_half_span := float(maxi(pedestrians_per_crossing - 1, 0)) \
			* group_spacing * 0.5
		for pedestrian_index in range(pedestrians_per_crossing):
			var group_offset := (
				float(pedestrian_index)
				- float(pedestrians_per_crossing - 1) * 0.5
			) * group_spacing
			var pedestrian := PEDESTRIAN_SCENE.instantiate() as SimulationPedestrian
			pedestrian.name = "Pedestrian_%02d_%02d" % [node_id, pedestrian_index]
			pedestrian.configure(
				endpoint_a + road_axis * group_offset,
				endpoint_b + road_axis * group_offset,
				rng.randf_range(minimum_speed, maximum_speed),
				light,
				PEDESTRIAN_TINTS[(crossing_index + pedestrian_index) % PEDESTRIAN_TINTS.size()],
				node_id,
				road_axis
			)
			add_child(pedestrian)
			pedestrians.append(pedestrian)


func _spawn_authored_crosswalk_pedestrians() -> void:
	var features: Array[Dictionary] = road_generator.call("get_authored_road_features")
	var crossing_index := 0
	var per_crossing := clampi(authored_pedestrians_per_crossing, 1, 4)
	for feature in features:
		var piece_index := int(feature.get("piece_index", -1))
		var authored_crosswalks: Array[Dictionary] = feature.get("crosswalks", [])
		if authored_crosswalks.is_empty():
			continue
		var linked_light: Node = null
		if light_manager.has_method("light_for_piece"):
			linked_light = light_manager.call("light_for_piece", piece_index)
		for crossing in authored_crosswalks:
			var crossing_center: Vector2 = crossing.get("center", Vector2.ZERO)
			var road_axis: Vector2 = Vector2(crossing.get("axis", Vector2.ZERO)).normalized()
			var crossing_half_width := float(crossing.get("width", 0.0)) * 0.5
			if road_axis.length_squared() < 0.5 or crossing_half_width < 40.0:
				continue
			var road_normal := road_axis.rotated(PI * 0.5)
			var endpoint_a := crossing_center + road_normal * (crossing_half_width + curb_margin)
			var endpoint_b := crossing_center - road_normal * (crossing_half_width + curb_margin)
			for pedestrian_index in range(per_crossing):
				var group_offset := (
					float(pedestrian_index)
					- float(per_crossing - 1) * 0.5
				) * group_spacing
				var pedestrian := PEDESTRIAN_SCENE.instantiate() as SimulationPedestrian
				pedestrian.name = "Pedestrian_Authored_%03d_%02d" % [crossing_index, pedestrian_index]
				pedestrian.configure(
					endpoint_a + road_axis * group_offset,
					endpoint_b + road_axis * group_offset,
					rng.randf_range(minimum_speed, maximum_speed),
					linked_light,
					PEDESTRIAN_TINTS[(crossing_index + pedestrian_index) % PEDESTRIAN_TINTS.size()],
					piece_index,
					road_axis
				)
				add_child(pedestrian)
				pedestrians.append(pedestrian)
			crossing_index += 1
	authored_pedestrian_lod_active = true
	activity_update_remaining = 0.0
	_refresh_authored_pedestrian_activity()


func _refresh_authored_pedestrian_activity() -> void:
	var player := get_parent().get_node_or_null("EgoVehicle") as Node2D
	var traffic_cars: Array = get_tree().get_nodes_in_group("traffic")
	var has_activity_focus := player != null or not traffic_cars.is_empty()
	var player_radius_squared := player_pedestrian_simulation_radius * player_pedestrian_simulation_radius
	var traffic_radius_squared := traffic_pedestrian_simulation_radius * traffic_pedestrian_simulation_radius
	for pedestrian in pedestrians:
		if not is_instance_valid(pedestrian):
			continue
		var should_simulate := bool(pedestrian.get("is_crossing")) or not has_activity_focus
		if not should_simulate and player != null:
			should_simulate = pedestrian.global_position.distance_squared_to(player.global_position) \
				<= player_radius_squared
		if not should_simulate:
			for car in traffic_cars:
				if not is_instance_valid(car):
					continue
				if pedestrian.global_position.distance_squared_to(car.global_position) <= traffic_radius_squared:
					should_simulate = true
					break
		if pedestrian.is_physics_processing() != should_simulate:
			pedestrian.set_physics_process(should_simulate)


func _build_crosswalk(
	center: Vector2,
	road_axis: Vector2,
	half_width: float,
	graph_node_id: int
) -> void:
	var stripe_count := maxi(
		3,
		int(floor(crosswalk_band_length / maxf(crosswalk_stripe_spacing, 1.0))) + 1
	)
	var road_normal := road_axis.rotated(PI * 0.5)
	var safe_half_width := maxf(half_width - crosswalk_edge_inset, 8.0)
	for stripe_index in range(stripe_count):
		var stripe_offset := (
			float(stripe_index) - float(stripe_count - 1) * 0.5
		) * crosswalk_stripe_spacing
		var stripe_center := center + road_axis * stripe_offset
		var stripe := Line2D.new()
		stripe.name = "Stripe_%02d" % stripe_index
		stripe.width = crosswalk_stripe_width
		stripe.default_color = Color(0.83, 0.86, 0.84, 0.48)
		stripe.antialiased = true
		stripe.begin_cap_mode = Line2D.LINE_CAP_NONE
		stripe.end_cap_mode = Line2D.LINE_CAP_NONE
		stripe.add_point(stripe_center - road_normal * safe_half_width)
		stripe.add_point(stripe_center + road_normal * safe_half_width)
		stripe.set_meta("graph_node_center", center)
		stripe.set_meta("road_half_width", half_width)
		stripe.set_meta("graph_node_id", graph_node_id)
		crosswalks.add_child(stripe)


func _clear_crosswalks() -> void:
	var old_crosswalks := get_node_or_null("Crosswalks")
	if old_crosswalks != null:
		remove_child(old_crosswalks)
		old_crosswalks.queue_free()
	crosswalks = null


func clear_pedestrians() -> void:
	authored_pedestrian_lod_active = false
	for pedestrian in pedestrians:
		if not is_instance_valid(pedestrian):
			continue
		pedestrian.remove_from_group("pedestrians")
		pedestrian.remove_from_group("crossing_pedestrians")
		if pedestrian.get_parent() != null:
			pedestrian.get_parent().remove_child(pedestrian)
		pedestrian.queue_free()
	pedestrians.clear()


func set_pedestrians_enabled(enabled: bool) -> void:
	pedestrians_enabled = enabled
	if enabled:
		regenerate()
	else:
		clear_pedestrians()
		_clear_crosswalks()
