extends Node2D

const TrafficLightScript = preload("res://scripts/traffic_light.gd")

@export var seed_value: int = 24680
@export_range(1, 12, 1) var minimum_lights: int = 3
@export_range(1, 12, 1) var maximum_lights: int = 5
@export var end_margin: float = 600.0
@export var minimum_spacing: float = 550.0

var road_generator: Node
var lights: Array[Node] = []
var rng := RandomNumberGenerator.new()
signal lights_regenerated


func _ready() -> void:
	road_generator = get_parent().get_node("RoadGenerator")
	road_generator.road_regenerated.connect(regenerate)
	regenerate()


func regenerate() -> void:
	clear_lights()
	rng.seed = seed_value
	var route: RoutePath = road_generator.get_route()

	if route == null or not route.is_valid():
		return

	var available: float = route.length - end_margin * 2.0

	if available <= 0.0:
		return

	var feature_indices: PackedInt32Array = road_generator.get_intersection_indices()
	var positions := PackedFloat32Array()

	if not feature_indices.is_empty():
		for feature_index in feature_indices:
			positions.append(float(route.cumulative[feature_index]))
	else:
		var requested := rng.randi_range(minimum_lights, maximum_lights)
		var maximum_fit := maxi(1, int(floor(available / minimum_spacing)) + 1)
		var count := mini(requested, maximum_fit)
		var slot_size := available / float(count)

		for index in range(count):
			var slot_start := end_margin + slot_size * float(index)
			var jitter_limit := maxf(0.0, (slot_size - minimum_spacing) * 0.4)
			positions.append(slot_start + slot_size * 0.5 + rng.randf_range(-jitter_limit, jitter_limit))

	for index in range(positions.size()):
		var light_progress: float = positions[index]
		var light: Node = TrafficLightScript.new()
		light.name = "TrafficLight_%02d" % index
		add_child(light)
		light.configure(
			route,
			light_progress,
			rng.randf() * light.cycle_duration(),
			float(road_generator.get("cross_street_width"))
		)
		lights.append(light)

	lights_regenerated.emit()


func clear_lights() -> void:
	for light in lights:
		if is_instance_valid(light):
			if light.get_parent() != null:
				light.get_parent().remove_child(light)

			light.queue_free()

	lights.clear()


func progress_snapshot() -> PackedFloat32Array:
	var result := PackedFloat32Array()

	for light in lights:
		result.append(light.progress)

	return result
