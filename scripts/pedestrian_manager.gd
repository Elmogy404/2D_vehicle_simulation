extends Node2D


const PEDESTRIAN_SCENE := preload("res://scenes/Pedestrian.tscn")
const ROUNDABOUT_TYPE := "roundabout"
const PEDESTRIAN_TINTS: Array[Color] = [
	Color(1.0, 1.0, 1.0),
	Color(0.92, 0.96, 1.0),
	Color(1.0, 0.94, 0.88)
]

@export var seed_value: int = 97531
@export_range(1, 6, 1) var pedestrians_per_intersection: int = 2
@export var minimum_speed: float = 38.0
@export var maximum_speed: float = 62.0
@export var curb_margin: float = 30.0
@export var side_road_clearance: float = 24.0
@export var group_spacing: float = 30.0
@export var crosswalk_band_length: float = 48.0
@export var crosswalk_stripe_width: float = 4.0
@export var crosswalk_stripe_spacing: float = 12.0
@export var crosswalk_edge_inset: float = 14.0

var pedestrians: Array[SimulationPedestrian] = []
var road_generator: Node
var light_manager: Node
var rng := RandomNumberGenerator.new()
var crosswalks: Node2D


func _ready() -> void:
	road_generator = get_parent().get_node("RoadGenerator")
	light_manager = get_parent().get_node("TrafficLightManager")
	light_manager.lights_regenerated.connect(regenerate)
	regenerate()


func regenerate() -> void:
	clear_pedestrians()
	_clear_crosswalks()
	crosswalks = Node2D.new()
	crosswalks.name = "Crosswalks"
	add_child(crosswalks)
	if road_generator == null or light_manager == null:
		return

	var route: RoutePath = road_generator.get_route()
	if route == null or not route.is_valid():
		return
	var indices: PackedInt32Array = road_generator.get_intersection_indices()
	var feature_types: PackedStringArray = road_generator.get_intersection_types()
	var map_seed := int(road_generator.get("seed_value"))
	rng.seed = posmod(seed_value ^ map_seed, 2147483647)
	var side_road_half_width := float(road_generator.get("cross_street_width")) * 0.5

	for intersection_number in range(indices.size()):
		if intersection_number < feature_types.size() \
		and feature_types[intersection_number] == ROUNDABOUT_TYPE:
			continue
		var index := indices[intersection_number]
		var progress := float(route.cumulative[index])
		var linked_light: Node = light_manager.light_for_progress(progress)
		# Never put pedestrians on an unsignalized crossing or roundabout entry.
		if linked_light == null:
			continue

		var crossing_side := -1.0 if intersection_number % 2 == 0 else 1.0
		var group_half_span := float(maxi(pedestrians_per_intersection - 1, 0)) \
			* group_spacing * 0.5
		var along_offset := crossing_side * (
			side_road_half_width + side_road_clearance + group_half_span
		)
		var crossing_progress := clampf(
			progress + crossing_side * along_offset,
			0.0,
			route.length
		)
		var crossing_edges: Dictionary = road_generator.get_road_edges_at(crossing_progress)
		var left_edge: Vector2 = crossing_edges["left"]
		var right_edge: Vector2 = crossing_edges["right"]
		var cross_road_axis := (left_edge - right_edge).normalized()
		var tangent := route.get_direction_at(crossing_progress)
		var endpoint_a := left_edge + cross_road_axis * curb_margin
		var endpoint_b := right_edge - cross_road_axis * curb_margin
		_build_crosswalk(route, crossing_progress)

		for pedestrian_index in range(pedestrians_per_intersection):
			var group_offset := (
				float(pedestrian_index)
				- float(pedestrians_per_intersection - 1) * 0.5
			) * group_spacing
			var pedestrian := PEDESTRIAN_SCENE.instantiate() as SimulationPedestrian
			pedestrian.name = "Pedestrian_%02d_%02d" % [intersection_number, pedestrian_index]
			pedestrian.configure(
				endpoint_a + tangent * group_offset,
				endpoint_b + tangent * group_offset,
				rng.randf_range(minimum_speed, maximum_speed),
				linked_light,
				PEDESTRIAN_TINTS[(intersection_number + pedestrian_index) % PEDESTRIAN_TINTS.size()],
				intersection_number
			)
			add_child(pedestrian)
			pedestrians.append(pedestrian)


func _build_crosswalk(route: RoutePath, center_progress: float) -> void:
	var stripe_count := maxi(
		3,
		int(floor(crosswalk_band_length / maxf(crosswalk_stripe_spacing, 1.0))) + 1
	)
	for stripe_index in range(stripe_count):
		var stripe_offset := (
			float(stripe_index) - float(stripe_count - 1) * 0.5
		) * crosswalk_stripe_spacing
		var stripe_progress := clampf(
			center_progress + stripe_offset,
			0.0,
			route.length
		)
		var road_edges: Dictionary = road_generator.get_road_edges_at(stripe_progress)
		var left_edge: Vector2 = road_edges["left"]
		var right_edge: Vector2 = road_edges["right"]
		var cross_road_axis := (right_edge - left_edge).normalized()
		var edge_inset := crosswalk_edge_inset + crosswalk_stripe_width * 0.5
		var stripe := Line2D.new()
		stripe.name = "Stripe_%02d" % stripe_index
		stripe.width = crosswalk_stripe_width
		stripe.default_color = Color(0.83, 0.86, 0.84, 0.48)
		stripe.antialiased = true
		stripe.begin_cap_mode = Line2D.LINE_CAP_NONE
		stripe.end_cap_mode = Line2D.LINE_CAP_NONE
		stripe.add_point(left_edge + cross_road_axis * edge_inset)
		stripe.add_point(right_edge - cross_road_axis * edge_inset)
		stripe.set_meta("route_progress", stripe_progress)
		crosswalks.add_child(stripe)


func _clear_crosswalks() -> void:
	var old_crosswalks := get_node_or_null("Crosswalks")
	if old_crosswalks != null:
		remove_child(old_crosswalks)
		old_crosswalks.queue_free()
	crosswalks = null


func clear_pedestrians() -> void:
	for pedestrian in pedestrians:
		if not is_instance_valid(pedestrian):
			continue
		pedestrian.remove_from_group("pedestrians")
		if pedestrian.get_parent() != null:
			pedestrian.get_parent().remove_child(pedestrian)
		pedestrian.queue_free()
	pedestrians.clear()
