extends Node2D

const PedestrianScript = preload("res://scripts/pedestrian.gd")

@export var seed_value: int = 97531
@export_range(1, 6, 1) var pedestrians_per_intersection: int = 2
@export var minimum_speed: float = 38.0
@export var maximum_speed: float = 62.0
@export var curb_margin: float = 30.0

var pedestrians: Array[Node] = []
var road_generator: Node
var light_manager: Node
var rng := RandomNumberGenerator.new()


func _ready() -> void:
	road_generator = get_parent().get_node("RoadGenerator")
	light_manager = get_parent().get_node("TrafficLightManager")
	road_generator.road_regenerated.connect(regenerate)
	regenerate()


func regenerate() -> void:
	clear_pedestrians()
	rng.seed = seed_value
	var route: RoutePath = road_generator.get_route()
	var indices: PackedInt32Array = road_generator.get_intersection_indices()
	var lights: Array = light_manager.get("lights")

	for intersection_number in range(indices.size()):
		var index: int = indices[intersection_number]
		var progress: float = float(route.cumulative[index])
		var center := route.get_position_at(progress)
		var normal := route.get_normal_at(progress)
		var tangent := route.get_direction_at(progress)
		var half_width := route.get_half_width_at(progress)
		var linked_light: Node = lights[intersection_number] if intersection_number < lights.size() else null

		for pedestrian_index in range(pedestrians_per_intersection):
			var along_offset := (float(pedestrian_index) - float(pedestrians_per_intersection - 1) * 0.5) * 28.0
			var start := center - normal * (half_width + curb_margin) + tangent * along_offset
			var finish := center + normal * (half_width + curb_margin) + tangent * along_offset
			var pedestrian := PedestrianScript.new() as CharacterBody2D
			pedestrian.name = "Pedestrian_%02d_%02d" % [intersection_number, pedestrian_index]
			pedestrian.collision_layer = 4
			pedestrian.collision_mask = 3
			add_child(pedestrian)
			pedestrian.configure(
				start, finish,
				rng.randf_range(minimum_speed, maximum_speed),
				linked_light,
				Color.from_hsv(rng.randf(), 0.62, 0.95)
			)
			pedestrians.append(pedestrian)


func clear_pedestrians() -> void:
	for pedestrian in pedestrians:
		if is_instance_valid(pedestrian):
			if pedestrian.get_parent() != null:
				pedestrian.get_parent().remove_child(pedestrian)
			pedestrian.queue_free()

	pedestrians.clear()
