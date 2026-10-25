extends Node2D

const TrafficLightScript = preload("res://scripts/traffic_light.gd")

@export var seed_value: int = 24680
@export_range(1, 12, 1) var minimum_lights: int = 3
@export_range(1, 12, 1) var maximum_lights: int = 5

var road_generator: Node
var lights: Array[Node] = []
var light_feature_indices: PackedInt32Array = PackedInt32Array()
var rng := RandomNumberGenerator.new()
var lights_enabled: bool = false
signal lights_regenerated


func _ready() -> void:
	road_generator = get_parent().get_node("RoadGenerator")
	road_generator.road_regenerated.connect(regenerate)
	regenerate()


func regenerate() -> void:
	clear_lights()
	if not lights_enabled:
		lights_regenerated.emit()
		return
	rng.seed = seed_value
	if road_generator == null:
		lights_regenerated.emit()
		return
	var network: Object = road_generator.call("get_road_network")
	if network == null:
		lights_regenerated.emit()
		return
	if road_generator.has_method("uses_segmented_generation") \
	and bool(road_generator.call("uses_segmented_generation")):
		_regenerate_authored_lights(network)
		lights_regenerated.emit()
		return
	var intersection_nodes: Array[int] = network.call("get_intersection_nodes")
	if intersection_nodes.is_empty():
		lights_regenerated.emit()
		return
	var chosen_nodes: Array[int] = []
	var four_way_nodes: Array[int] = []
	for node_id in intersection_nodes:
		if int(network.call("get_node_degree", node_id)) >= 4:
			four_way_nodes.append(node_id)
	if not four_way_nodes.is_empty():
		chosen_nodes.append(four_way_nodes[rng.randi_range(0, four_way_nodes.size() - 1)])
	var shuffled_nodes := intersection_nodes.duplicate()
	for i in range(shuffled_nodes.size() - 1, 0, -1):
		var swap_index := rng.randi_range(0, i)
		var held: int = shuffled_nodes[i]
		shuffled_nodes[i] = shuffled_nodes[swap_index]
		shuffled_nodes[swap_index] = held
	var requested := rng.randi_range(minimum_lights, maximum_lights)
	var target_count := mini(requested, intersection_nodes.size())
	for node_id in shuffled_nodes:
		if chosen_nodes.size() >= target_count:
			break
		if not chosen_nodes.has(node_id):
			chosen_nodes.append(node_id)
	for index in range(chosen_nodes.size()):
		var node_id := chosen_nodes[index]
		var position: Vector2 = network.call("get_node_position", node_id)
		var axis: Vector2 = network.call("get_node_axis", node_id)
		var arms: Array[Dictionary] = network.call("get_node_arms", node_id)
		var intersection_width := maxf(
			float(network.call("get_node_half_width", node_id)) * 2.0,
			float(road_generator.get("cross_street_width"))
		)
		var light: Node = TrafficLightScript.new()
		light.name = "TrafficLight_%02d" % index
		add_child(light)
		light.configure_network(
			position,
			axis,
			rng.randf() * light.cycle_duration() * 2.0,
			intersection_width,
			node_id,
			arms
		)
		lights.append(light)
		light_feature_indices.append(node_id)

	lights_regenerated.emit()


func _regenerate_authored_lights(network: Object) -> void:
	var features: Array[Dictionary] = road_generator.call("get_authored_road_features")
	var feature_index := 0
	for feature in features:
		var authored_anchors: Array[Dictionary] = feature.get("signal_anchors", [])
		if authored_anchors.is_empty():
			continue
		var center: Vector2 = feature.get("center", Vector2.ZERO)
		var piece_index := int(feature.get("piece_index", -1))
		var node_id := int(network.call("nearest_node", center))
		var axis := Vector2(authored_anchors[0].get("outward", Vector2.RIGHT)).normalized()
		if node_id >= 0 and int(network.call("get_node_degree", node_id)) >= 3:
			axis = Vector2(network.call("get_node_axis", node_id)).normalized()
		if axis.length_squared() < 0.001:
			axis = Vector2.RIGHT

		var axis_rotation := axis.angle()
		var arms: Array[Dictionary] = []
		var half_width := 0.0
		var farthest_stop_line := 0.0
		for anchor in authored_anchors:
			var outward: Vector2 = anchor.get("outward", Vector2.ZERO)
			var stop_center: Vector2 = anchor.get("stop_line_center", center)
			var light_anchor: Vector2 = anchor.get("light_anchor", stop_center)
			var arm_half_width := float(anchor.get("half_width", 90.0))
			half_width = maxf(half_width, arm_half_width)
			farthest_stop_line = maxf(farthest_stop_line, center.distance_to(stop_center))
			arms.append({
				"outward": outward,
				"half_width": arm_half_width,
				"stop_center_local": (stop_center - center).rotated(-axis_rotation),
				"lamp_position_local": (light_anchor - center).rotated(-axis_rotation),
				"stop_line_is_authored": true
			})
		if arms.is_empty():
			continue

		var light := TrafficLightScript.new()
		light.name = "TrafficLight_Authored_%02d" % feature_index
		light.set("authored_piece_index", piece_index)
		add_child(light)
		var intersection_width := maxf(farthest_stop_line * 2.0, half_width * 2.0)
		light.configure_network(
			center,
			axis,
			rng.randf() * light.cycle_duration() * 2.0,
			intersection_width,
			node_id,
			arms
		)
		lights.append(light)
		light_feature_indices.append(node_id)
		feature_index += 1


func clear_lights() -> void:
	var index := get_tree().get_first_node_in_group("simulation_spatial_index")
	if index != null:
		index.call("invalidate")
	for light in lights:
		if is_instance_valid(light):
			if light.get_parent() != null:
				light.get_parent().remove_child(light)

			light.queue_free()

	lights.clear()
	light_feature_indices.clear()


func light_for_progress(target_progress: float) -> Node:
	for light in lights:
		if absf(float(light.get("progress")) - target_progress) < 1.0:
			return light
	return null


func light_for_node(node_id: int) -> Node:
	for light in lights:
		if int(light.get("graph_node_id")) == node_id:
			return light
	return null


func light_for_piece(piece_index: int) -> Node:
	for light in lights:
		if int(light.get("authored_piece_index")) == piece_index:
			return light
	return null


func progress_snapshot() -> PackedFloat32Array:
	var result := PackedFloat32Array()

	for light in lights:
		result.append(light.progress)

	return result


func set_lights_enabled(enabled: bool) -> void:
	lights_enabled = enabled
	regenerate()
