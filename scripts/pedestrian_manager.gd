extends Node2D

const PedestrianScript = preload("res://scripts/pedestrian.gd")

@export var seed_value: int = 97531
@export_range(1, 6, 1) var pedestrians_per_intersection: int = 2
@export var minimum_speed: float = 38.0
@export var maximum_speed: float = 62.0
@export var curb_margin: float = 30.0
@export var side_road_clearance: float = 24.0

var pedestrians: Array[Node] = []
var road_generator: Node
var light_manager: Node
var rng := RandomNumberGenerator.new()


func _ready() -> void:
	road_generator = get_parent().get_node("RoadGenerator")
	light_manager = get_parent().get_node("TrafficLightManager")
	light_manager.lights_regenerated.connect(regenerate)
	regenerate()


func regenerate() -> void:
	clear_pedestrians()
	rng.seed = seed_value
	var route: RoutePath = road_generator.get_route()
	var indices: PackedInt32Array = road_generator.get_intersection_indices()

	for intersection_number in range(indices.size()):
		var index: int = indices[intersection_number]
		var progress: float = float(route.cumulative[index])
		var center := route.get_position_at(progress)
		var normal := route.get_normal_at(progress)
		var tangent := route.get_direction_at(progress)
		var half_width := route.get_half_width_at(progress)
		var linked_light: Node = light_manager.light_for_progress(progress)
		var side_road_half_width: float = float(road_generator.get("cross_street_width")) * 0.5

		for pedestrian_index in range(pedestrians_per_intersection):
			# Cross beside the junction instead of waiting in the side-road mouth.
			# Alternating sides spreads groups over the two marked crosswalks while
			# keeping every curb endpoint clear of local traffic lanes.
			var crossing_side := -1.0 if pedestrian_index % 2 == 0 else 1.0
			var row := int(pedestrian_index / 2)
			var along_offset := crossing_side * (
				side_road_half_width
				+ side_road_clearance
				+ float(row) * 26.0
			)
			var start := center - normal * (half_width + curb_margin) + tangent * along_offset
			var finish := center + normal * (half_width + curb_margin) + tangent * along_offset
			var pedestrian := PedestrianScript.new() as CharacterBody2D
			pedestrian.name = "Pedestrian_%02d_%02d" % [intersection_number, pedestrian_index]
			pedestrian.collision_layer = 4
			# Pedestrians collide with static world geometry but keep walking through
			# a vehicle after accidental contact. Vehicles still detect their layer,
			# preventing the mutual CharacterBody deadlock that froze the road.
			pedestrian.collision_mask = 1
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
