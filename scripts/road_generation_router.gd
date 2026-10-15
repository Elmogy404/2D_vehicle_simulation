class_name RoadGenerationRouter
extends Node2D
## Keeps gameplay code independent from which road builder the user selects.

signal road_regenerated

const ORIGINAL_SCENE := preload("res://scenes/RoadGenerator.tscn")
const SEGMENTED_SCRIPT := preload("res://scripts/segment_road_generator.gd")
const ORIGINAL_MODE := 0
const SEGMENTED_MODE := 1
const SEGMENTED_PIECE_COUNT := 200

@export var generator_mode := ORIGINAL_MODE
@export var seed_value: int = 333333333
@export var enable_hotkeys := false:
	set(value):
		enable_hotkeys = value
		_forward_property(&"enable_hotkeys", value)

var active_generator: Node2D


func set_generator_type(mode: int) -> void:
	var requested_mode := clampi(mode, ORIGINAL_MODE, SEGMENTED_MODE)
	if requested_mode == generator_mode:
		return
	generator_mode = requested_mode
	_clear_active_generator()


func get_generator_type() -> int:
	return generator_mode


func uses_segmented_generation() -> bool:
	return generator_mode == SEGMENTED_MODE


func get_generator_label() -> String:
	return "Segmented city blocks (200 pieces)" if generator_mode == SEGMENTED_MODE \
		else "Original procedural network"


func generate_with_seed(new_seed: int) -> void:
	seed_value = new_seed
	if active_generator == null or not is_instance_valid(active_generator):
		active_generator = _create_active_generator(new_seed)
	if active_generator == null:
		push_error("RoadGenerationRouter: the selected generator could not be created.")
		return
	if active_generator.has_method("generate_with_seed"):
		active_generator.call("generate_with_seed", new_seed)
	else:
		push_error("RoadGenerationRouter: selected generator has no generate_with_seed method.")


func get_route() -> RoutePath:
	if active_generator == null or not active_generator.has_method("get_route"):
		return null
	return active_generator.call("get_route") as RoutePath


func get_road_network() -> RefCounted:
	if active_generator == null or not active_generator.has_method("get_road_network"):
		return null
	return active_generator.call("get_road_network") as RefCounted


func get_center_points() -> Array[Vector2]:
	if active_generator != null and active_generator.has_method("get_center_points"):
		return active_generator.call("get_center_points")
	return []


func get_width_profile() -> PackedFloat32Array:
	if active_generator != null and active_generator.has_method("get_width_profile"):
		return active_generator.call("get_width_profile")
	return PackedFloat32Array()


func get_lane_profile() -> PackedFloat32Array:
	if active_generator != null and active_generator.has_method("get_lane_profile"):
		return active_generator.call("get_lane_profile")
	return PackedFloat32Array()


func get_map_paths() -> Array[PackedVector2Array]:
	if active_generator != null and active_generator.has_method("get_map_paths"):
		return active_generator.call("get_map_paths")
	return []


func get_map_path_half_width_profiles() -> Array[PackedFloat32Array]:
	if active_generator != null and active_generator.has_method("get_map_path_half_width_profiles"):
		return active_generator.call("get_map_path_half_width_profiles")
	return []


func get_map_bounds() -> Rect2:
	if active_generator != null and active_generator.has_method("get_map_bounds"):
		return active_generator.call("get_map_bounds")
	return Rect2(Vector2.ZERO, Vector2.ONE)


func get_obstacle_regions() -> Array[Dictionary]:
	if active_generator != null and active_generator.has_method("get_obstacle_regions"):
		return active_generator.call("get_obstacle_regions")
	return []


func get_intersection_indices() -> PackedInt32Array:
	if active_generator != null and active_generator.has_method("get_intersection_indices"):
		return active_generator.call("get_intersection_indices")
	return PackedInt32Array()


func get_intersection_types() -> PackedStringArray:
	if active_generator != null and active_generator.has_method("get_intersection_types"):
		return active_generator.call("get_intersection_types")
	return PackedStringArray()


func get_branch_sides() -> PackedInt32Array:
	if active_generator != null and active_generator.has_method("get_branch_sides"):
		return active_generator.call("get_branch_sides")
	return PackedInt32Array()


func get_spawn_position() -> Vector2:
	if active_generator != null and active_generator.has_method("get_spawn_position"):
		return active_generator.call("get_spawn_position")
	return Vector2.ZERO


func get_spawn_rotation() -> float:
	if active_generator != null and active_generator.has_method("get_spawn_rotation"):
		return active_generator.call("get_spawn_rotation")
	return 0.0


func get_player_spawn_pose(lateral_offset: float) -> Dictionary:
	if active_generator != null and active_generator.has_method("get_player_spawn_pose"):
		return active_generator.call("get_player_spawn_pose", lateral_offset)
	return {}


func get_generation_summary() -> Dictionary:
	if active_generator != null and active_generator.has_method("get_generation_summary"):
		return active_generator.call("get_generation_summary")
	return {}


func get_layout_summary() -> Dictionary:
	if active_generator != null and active_generator.has_method("get_layout_summary"):
		return active_generator.call("get_layout_summary")
	return {}


func get_piece_count() -> int:
	if active_generator != null and active_generator.has_method("get_piece_count"):
		return int(active_generator.call("get_piece_count"))
	return 0


func get_authored_road_features() -> Array[Dictionary]:
	if active_generator != null and active_generator.has_method("get_authored_road_features"):
		return active_generator.call("get_authored_road_features")
	return []


func _get(property: StringName) -> Variant:
	if active_generator != null and _has_property(active_generator, property):
		return active_generator.get(property)
	match property:
		&"lane_width":
			return 90.0
		&"road_width":
			return 200.0
		&"maximum_road_width":
			return 280.0
		&"cross_street_width":
			return 160.0
		&"segment_length":
			return 60.0
		&"seed_value":
			return seed_value
		&"enable_hotkeys":
			return enable_hotkeys
	return null


func _create_active_generator(new_seed: int) -> Node2D:
	var instance: Node2D
	if generator_mode == SEGMENTED_MODE:
		instance = SEGMENTED_SCRIPT.new() as Node2D
		if instance == null:
			return null
		instance.name = "SegmentedRoadGenerator"
		instance.set("minimum_piece_count", SEGMENTED_PIECE_COUNT)
		instance.set("maximum_piece_count", SEGMENTED_PIECE_COUNT)
		instance.set("generate_on_ready", false)
	else:
		instance = ORIGINAL_SCENE.instantiate() as Node2D
		if instance == null:
			return null
		instance.name = "OriginalRoadGenerator"
		instance.set("generate_on_ready", false)
		instance.set("enable_hotkeys", enable_hotkeys)
	instance.set("seed_value", new_seed)
	add_child(instance)
	if instance.has_signal("road_regenerated"):
		instance.connect("road_regenerated", _on_active_generator_regenerated)
	if instance.has_signal("generation_completed"):
		instance.connect("generation_completed", _on_segment_generation_completed)
	return instance


func _on_active_generator_regenerated() -> void:
	road_regenerated.emit()


func _on_segment_generation_completed(_seed: int, _piece_count: int) -> void:
	road_regenerated.emit()


func _clear_active_generator() -> void:
	if active_generator == null or not is_instance_valid(active_generator):
		active_generator = null
		return
	active_generator.queue_free()
	active_generator = null


func _forward_property(property: StringName, value: Variant) -> void:
	if active_generator != null and _has_property(active_generator, property):
		active_generator.set(property, value)


func _has_property(target: Object, property: StringName) -> bool:
	for entry in target.get_property_list():
		if StringName(entry.get("name", "")) == property:
			return true
	return false
