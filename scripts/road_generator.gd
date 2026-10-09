extends Node2D

const ROAD_NETWORK := preload("res://scripts/road_network.gd")

# ============================================================
# ROAD
# ============================================================

@export_category("Road")

@export var road_width: float = 200.0
@export var road_length: float = 7600.0
@export var segment_length: float = 60.0

@export_category("Road Complexity")
@export var minimum_road_width: float = 190.0
@export var maximum_road_width: float = 280.0
@export var width_change_smoothing: float = 0.16
@export_range(5, 8, 1) var intersection_count: int = 6
## Distance across the whole district between the two collector roads. This
## leaves real block space between a six-lane arterial and local streets.
@export var cross_street_length: float = 1700.0
@export var cross_street_width: float = 160.0
## Parallel streets beyond the first collector turn the district into a road
## network instead of a main road with decorative branches.
@export_range(2, 3, 1) var corridors_per_side: int = 2
@export var corridor_spacing: float = 620.0
@export var local_spur_length: float = 460.0
@export var roundabout_radius: float = 125.0
@export_range(1, 5, 1) var turnaround_count: int = 2
@export var turnaround_width: float = 360.0
@export_range(1, 3, 1) var minimum_lanes_per_direction: int = 1
@export_range(1, 3, 1) var maximum_lanes_per_direction: int = 3
@export var lane_width: float = 90.0
@export var shoulder_width: float = 10.0


# ============================================================
# CURVATURE
# ============================================================

@export_category("Curvature")

## Maximum heading change per segment (degrees). Automatically limited so the
## inner edge of the road can never fold over itself.
@export_range(1.0, 45.0, 1.0) var max_turn_angle: float = 16.0

## How quickly steering follows its target (0 = never, 1 = instantly).
@export_range(0.01, 1.0, 0.01) var turn_smoothing: float = 0.25

## Maximum heading (degrees) away from the starting direction.
## Arterials on real maps bend gradually but rarely fold back through their own
## parallel collectors inside one district. Local roads provide the tighter
## turns, so the arterial stays directionally coherent.
@export var max_total_turn: float = 55.0

## Number of segments at the start that stay perfectly straight.
@export var min_straight_segments: int = 3


# ============================================================
# SELF INTERSECTION
# ============================================================

@export_category("Safety")

## Clearance to other parts of the road. Automatically raised to at least
## road_width + boundary_thickness so different parts never overlap.
@export var minimum_point_distance: float = 200.0
@export var minimum_segment_distance: float = 200.0


# ============================================================
# GENERATION
# ============================================================

@export_category("Generation")

@export var seed_value: int = 333333333
@export var randomize_seed: bool = false
@export var minimum_map_length: float = 5600.0
@export var maximum_map_length: float = 11000.0
@export_range(4, 7, 1) var minimum_intersections: int = 4
@export_range(7, 11, 1) var maximum_intersections: int = 10
@export_range(1, 2, 1) var minimum_corridors_per_side: int = 1
@export_range(2, 4, 1) var maximum_corridors_per_side: int = 3
@export_range(1, 8, 1) var minimum_obstacles: int = 2
@export_range(2, 12, 1) var maximum_obstacles: int = 7

## Press R while the game is running to generate a new random road.
@export var enable_hotkeys: bool = true


# ============================================================
# LANE MARKINGS
# ============================================================

@export_category("Lane Markings")

@export var dash_length: float = 25.0
@export var gap_length: float = 25.0
@export var line_width: float = 5.0


# ============================================================
# COLLISION
# ============================================================

@export_category("Collision")

@export var boundary_thickness: float = 12.0


# ============================================================
# DEBUG
# ============================================================

@export_category("Debug")

@export var show_debug_centerline: bool = false
@export var show_debug_boundaries: bool = true


# ============================================================
# INTERNAL
# ============================================================

# Extra angle tried (in degrees) when the preferred direction is blocked.
const STEER_CANDIDATES := [0.0, -4.0, 4.0, -8.0, 8.0, -14.0, 14.0, -22.0, 22.0]

var rng := RandomNumberGenerator.new()

var center_points: Array[Vector2] = []
var left_points: Array[Vector2] = []
var right_points: Array[Vector2] = []
var road_widths: PackedFloat32Array = PackedFloat32Array()
var lane_profile: PackedFloat32Array = PackedFloat32Array()
var intersection_indices: PackedInt32Array = PackedInt32Array()
var turnaround_indices: PackedInt32Array = PackedInt32Array()
var intersection_types: PackedStringArray = PackedStringArray()
var branch_sides: PackedInt32Array = PackedInt32Array()
var road_network: RefCounted = ROAD_NETWORK.new()
var secondary_paths: Array[PackedVector2Array] = []
var secondary_path_widths: PackedFloat32Array = PackedFloat32Array()
var secondary_path_classes: PackedStringArray = PackedStringArray()
var corridor_paths: Array[PackedVector2Array] = []
var dead_end_centers: Array[Vector2] = []
var dead_end_directions: Array[Vector2] = []
var corridor_ranges: Dictionary = {}
var obstacle_regions: Array[Dictionary] = []
var generated_road_length: float = 7600.0
var generated_intersection_count: int = 6
var generated_left_corridors: int = 2
var generated_right_corridors: int = 2
var generated_density: float = 0.5
var generated_irregularity: float = 0.5

# Distance-based view of the centerline. Rebuilt on every generation so
# traffic always follows the current road.
var route: RoutePath = RoutePath.new()

# Emitted after a road (and its route) has been fully rebuilt.
signal road_regenerated

var current_angle: float = 0.0
var current_steer: float = 0.0
var steer_target: float = 0.0
var steer_hold: int = 0


# ============================================================
# READY / INPUT
# ============================================================

func _ready() -> void:
	generate_road()


func _unhandled_input(event: InputEvent) -> void:
	if not enable_hotkeys:
		return

	var key_event := event as InputEventKey

	if key_event and key_event.pressed and not key_event.echo:
		if key_event.keycode == KEY_R:
			generate_random_road()


# ============================================================
# PUBLIC GENERATION API
# ============================================================
func get_center_points() -> Array[Vector2]:
	return center_points.duplicate()


func get_route() -> RoutePath:
	return route


func get_road_network() -> RefCounted:
	return road_network


func generate_road() -> void:
	clear_generated_content()

	setup_rng()
	generate_layout_profile()

	generate_centerline()
	generate_road_features()
	generate_boundaries()
	generate_secondary_network()
	generate_obstacles()

	var route_half_widths := PackedFloat32Array()

	for width in road_widths:
		route_half_widths.append(width * 0.5)

	route.build(center_points, route_half_widths, lane_profile, lane_width)
	road_network.build(get_map_paths())

	build_road_polygon()
	build_cross_streets()
	build_obstacles()
	build_lane_markings()
	build_boundary_visuals()
	build_debug_centerline()
	build_collisions()

	road_regenerated.emit()


func get_intersection_indices() -> PackedInt32Array:
	return intersection_indices.duplicate()


func get_intersection_types() -> PackedStringArray:
	return intersection_types.duplicate()


func get_branch_sides() -> PackedInt32Array:
	return branch_sides.duplicate()


## Centerlines used by the minimap and route graph. The first path remains the
## route used by current NPC traffic; all later paths are fully rendered and
## physically traversable streets in the generated district.
func get_map_paths() -> Array[PackedVector2Array]:
	var paths: Array[PackedVector2Array] = [PackedVector2Array(center_points)]
	for path in secondary_paths:
		paths.append(path)

	return paths


func _collector_offset_for(feature: int, side: float) -> float:
	return _corridor_offset_for(feature, side, 1)


func _corridor_offset_for(feature: int, side: float, level: int) -> float:
	var base := cross_street_length * 0.5 + float(level - 1) * corridor_spacing
	# Stable hash-like variation creates irregular block depth without consuming
	# generator RNG state. Outer streets vary less so blocks do not pinch closed.
	var phase := (
		float(posmod(seed_value, 100000)) * 0.017
		+ float(feature) * 2.173
		+ side * 0.731
		+ float(level) * 1.117
	)
	return base + sin(phase) * (80.0 if level == 1 else 45.0)


## Builds the complete secondary street graph before rendering it. Four long
## corridors, frequent transverse streets, perimeter links, roundabouts, and
## selected dead ends make the result read as a district instead of one route.
func generate_secondary_network() -> void:
	secondary_paths.clear()
	secondary_path_widths.clear()
	secondary_path_classes.clear()
	corridor_paths.clear()
	dead_end_centers.clear()
	dead_end_directions.clear()
	corridor_ranges.clear()
	if center_points.size() < 2 or intersection_indices.is_empty():
		return

	for side_value in [-1.0, 1.0]:
		var side: float = side_value
		var corridor_count := _corridor_count_for_side(side)
		for level in range(1, corridor_count + 1):
			var feature_range := _choose_corridor_range(level)
			corridor_ranges[_corridor_key(side, level)] = feature_range
			var corridor := PackedVector2Array()
			for marker in range(feature_range.x, feature_range.y + 1):
				var index := _index_for_feature_marker(marker)
				var roundabout_here := (
					level == 1
					and marker >= 0
					and marker < intersection_indices.size()
					and intersection_types[marker] == "roundabout"
					and is_equal_approx(float(branch_sides[marker]), side)
				)
				if roundabout_here:
					_append_roundabout_bypass(corridor, marker, side)
				else:
					corridor.append(_corridor_point_at(index, marker, side, level))
			var width := (
				cross_street_width * rng.randf_range(1.02, 1.22)
				if level == 1
				else cross_street_width * rng.randf_range(0.72, 0.96)
			)
			_register_secondary_path(corridor, width, "collector" if level == 1 else "local", true)

	# Every primary junction connects to all corridor levels on its active side.
	# A four-way junction connects both halves of the district.
	for feature in range(intersection_indices.size()):
		var index := intersection_indices[feature]
		for side_value in _branch_directions(feature):
			var side: float = side_value
			var tangent := _tangent_at(index)
			var outward := Vector2(-tangent.y, tangent.x) * side
			var center := center_points[index]
			var inner := _corridor_point_at(index, feature, side, 1)
			if not _corridor_exists_at(feature, side, 1):
				continue

			if intersection_types[feature] == "roundabout":
				var approach := PackedVector2Array([center, inner - outward * roundabout_radius])
				_register_secondary_path(approach, cross_street_width, "connector")
				_register_secondary_path(_roundabout_path(inner, outward), cross_street_width, "roundabout")
				if _corridor_count_for_side(side) > 1:
					var outward_link := PackedVector2Array([inner + outward * roundabout_radius])
					for level in range(2, _corridor_count_for_side(side) + 1):
						if _corridor_exists_at(feature, side, level):
							outward_link.append(_corridor_point_at(index, feature, side, level))
					_register_secondary_path(outward_link, cross_street_width, "connector")
			else:
				var connector := PackedVector2Array([center])
				for level in range(1, _corridor_count_for_side(side) + 1):
					if _corridor_exists_at(feature, side, level):
						connector.append(_corridor_point_at(index, feature, side, level))
				_add_optional_dead_end(connector, feature, outward, tangent)
				var connector_width := cross_street_width * (
					1.32 if rng.randf() < generated_density * 0.28 else 1.0
				)
				_register_secondary_path(
					connector,
					connector_width,
					"boulevard" if connector_width > cross_street_width else "connector"
				)

	# Close the street graph around both ends of the arterial. These are normal
	# cross streets, so the map has no visually privileged start or finish.
	_register_secondary_path(_perimeter_cross_street(0, -1), cross_street_width * 1.08, "perimeter")
	_register_secondary_path(
		_perimeter_cross_street(center_points.size() - 1, intersection_indices.size()),
		cross_street_width * 1.08,
		"perimeter"
	)
	_add_random_local_loops()
	_add_random_diagonal_links()


func _register_secondary_path(
	path: PackedVector2Array,
	width: float,
	road_class: String,
	is_corridor: bool = false
) -> void:
	if path.size() < 2:
		return
	secondary_paths.append(path)
	secondary_path_widths.append(width)
	secondary_path_classes.append(road_class)
	if is_corridor:
		corridor_paths.append(path)


func _corridor_count_for_side(side: float) -> int:
	return generated_left_corridors if side < 0.0 else generated_right_corridors


func _corridor_key(side: float, level: int) -> String:
	return "%d:%d" % [-1 if side < 0.0 else 1, level]


func _choose_corridor_range(level: int) -> Vector2i:
	var last_marker := intersection_indices.size()
	if level == 1 or rng.randf() < 0.38 + generated_density * 0.34:
		return Vector2i(-1, last_marker)
	var latest_start := maxi(-1, last_marker - 3)
	var start := rng.randi_range(-1, latest_start)
	var end := rng.randi_range(start + 2, last_marker)
	return Vector2i(start, end)


func _corridor_exists_at(feature_marker: int, side: float, level: int) -> bool:
	var key := _corridor_key(side, level)
	if not corridor_ranges.has(key):
		return false
	var feature_range: Vector2i = corridor_ranges[key]
	return feature_marker >= feature_range.x and feature_marker <= feature_range.y


func _index_for_feature_marker(marker: int) -> int:
	if marker < 0:
		return 0
	if marker >= intersection_indices.size():
		return center_points.size() - 1
	return intersection_indices[marker]


func _add_random_local_loops() -> void:
	if intersection_indices.size() < 2:
		return
	var loop_count := clampi(
		roundi(lerpf(1.0, 5.0, generated_density)) + rng.randi_range(-1, 1),
		1,
		5
	)
	var used: Dictionary = {}
	for loop_number in range(loop_count):
		var feature := rng.randi_range(0, intersection_indices.size() - 2)
		var side := -1.0 if rng.randi_range(0, 1) == 0 else 1.0
		var key := "%d:%d" % [feature, int(side)]
		if used.has(key) or not _corridor_exists_at(feature, side, 1) \
		or not _corridor_exists_at(feature + 1, side, 1):
			continue
		used[key] = true
		var start := _corridor_point_at(intersection_indices[feature], feature, side, 1)
		var finish := _corridor_point_at(intersection_indices[feature + 1], feature + 1, side, 1)
		var across := finish - start
		var direction := across.normalized()
		var outward := Vector2(-direction.y, direction.x) * side
		var inset := lerpf(230.0, 430.0, generated_irregularity)
		var loop := PackedVector2Array([
			start,
			start - outward * inset + direction * 100.0,
			(start + finish) * 0.5 - outward * inset * 1.18,
			finish - outward * inset - direction * 100.0,
			finish
		])
		var loop_width := cross_street_width * rng.randf_range(0.68, 0.84)
		if _candidate_path_is_clear(loop, loop_width):
			_register_secondary_path(loop, loop_width, "local_loop")


func _add_random_diagonal_links() -> void:
	if intersection_indices.size() < 3:
		return
	var link_count := rng.randi_range(0, 1 + roundi(generated_density * 2.0))
	for link_number in range(link_count):
		var feature := rng.randi_range(0, intersection_indices.size() - 2)
		var target_feature := feature + 1
		var side := -1.0 if rng.randi_range(0, 1) == 0 else 1.0
		if not _corridor_exists_at(target_feature, side, 1):
			continue
		if intersection_types[target_feature] == "roundabout" \
		and is_equal_approx(float(branch_sides[target_feature]), side):
			continue
		var start := center_points[intersection_indices[feature]]
		var finish := _corridor_point_at(
			intersection_indices[target_feature], target_feature, side, 1
		)
		var middle := start.lerp(finish, 0.52)
		middle += _tangent_at(intersection_indices[feature]) * rng.randf_range(-150.0, 150.0)
		var diagonal := PackedVector2Array([start, middle, finish])
		var diagonal_width := cross_street_width * rng.randf_range(0.82, 1.08)
		if _candidate_path_is_clear(diagonal, diagonal_width):
			_register_secondary_path(diagonal, diagonal_width, "diagonal")


func _candidate_path_is_clear(path: PackedVector2Array, width: float) -> bool:
	var comparison_paths := get_map_paths()
	for candidate_index in range(path.size() - 1):
		var a := path[candidate_index]
		var b := path[candidate_index + 1]
		for comparison_index in range(comparison_paths.size()):
			var other := comparison_paths[comparison_index]
			var other_width := (
				maximum_road_width
				if comparison_index == 0
				else secondary_path_widths[comparison_index - 1]
			)
			for other_index in range(other.size() - 1):
				var c := other[other_index]
				var d := other[other_index + 1]
				var shares_endpoint := (
					a.distance_squared_to(c) < 1.0
					or a.distance_squared_to(d) < 1.0
					or b.distance_squared_to(c) < 1.0
					or b.distance_squared_to(d) < 1.0
				)
				if shares_endpoint:
					continue
				if segment_to_segment_distance(a, b, c, d) < (width + other_width) * 0.5 + 35.0:
					return false
	return true


func _corridor_point_at(index: int, feature: int, side: float, level: int) -> Vector2:
	var tangent := _tangent_at(index)
	var normal := Vector2(-tangent.y, tangent.x)
	return (
		center_points[index]
		+ normal * side * _corridor_offset_for(feature, side, level)
		+ tangent * _corridor_longitudinal_shift(feature, side, level)
	)


func _corridor_longitudinal_shift(feature: int, side: float, level: int) -> float:
	if feature < 0 or feature >= intersection_indices.size():
		return 0.0
	var phase := (
		float(posmod(seed_value, 1000003)) * 0.0031
		+ float(feature) * 1.417
		+ side * 2.219
		+ float(level) * 0.871
	)
	return sin(phase) * lerpf(45.0, 220.0, generated_irregularity)


func _tangent_at(index: int) -> Vector2:
	if index <= 0:
		return (center_points[1] - center_points[0]).normalized()
	if index >= center_points.size() - 1:
		return (center_points[-1] - center_points[-2]).normalized()
	return (center_points[index + 1] - center_points[index - 1]).normalized()


func _append_roundabout_bypass(path: PackedVector2Array, feature: int, side: float) -> void:
	var index := intersection_indices[feature]
	var tangent := _tangent_at(index)
	var center := _corridor_point_at(index, feature, side, 1)
	var start_direction := -tangent
	var sweep := -side * PI
	for step in range(7):
		path.append(
			center
			+ start_direction.rotated(sweep * float(step) / 6.0) * roundabout_radius
		)


func _roundabout_path(center: Vector2, outward: Vector2) -> PackedVector2Array:
	var ring := PackedVector2Array()
	for step in range(33):
		ring.append(
			center
			+ (-outward).rotated(TAU * float(step) / 32.0) * roundabout_radius
		)
	return ring


func _add_optional_dead_end(
	connector: PackedVector2Array,
	feature: int,
	outward: Vector2,
	tangent: Vector2
) -> void:
	if intersection_types[feature] != "t_junction":
		return
	var start := connector[connector.size() - 1]
	var bend_sign := -1.0 if (feature + posmod(seed_value, 2)) % 2 == 0 else 1.0
	var middle := start + outward * local_spur_length * 0.52 + tangent * bend_sign * 70.0
	var finish := start + outward * local_spur_length + tangent * bend_sign * 115.0
	connector.append(middle)
	connector.append(finish)
	dead_end_centers.append(finish)
	dead_end_directions.append((finish - middle).normalized())


func _perimeter_cross_street(index: int, feature_marker: int) -> PackedVector2Array:
	var result := PackedVector2Array()
	for level in range(generated_left_corridors, 0, -1):
		if _corridor_exists_at(feature_marker, -1.0, level):
			result.append(_corridor_point_at(index, feature_marker, -1.0, level))
	result.append(center_points[index])
	for level in range(1, generated_right_corridors + 1):
		if _corridor_exists_at(feature_marker, 1.0, level):
			result.append(_corridor_point_at(index, feature_marker, 1.0, level))
	return result


func generate_obstacles() -> void:
	obstacle_regions.clear()
	if intersection_indices.is_empty():
		return
	var labels: Array[String] = [
		"PARK", "LAKE", "FIELD", "CONSTRUCTION",
		"RESTRICTED AREA", "INDUSTRIAL SITE"
	]
	var requested := clampi(
		roundi(lerpf(float(minimum_obstacles), float(maximum_obstacles), generated_density))
		+ rng.randi_range(-1, 1),
		minimum_obstacles,
		maximum_obstacles
	)
	var anchor_indices: Array[int] = [0]
	for index in intersection_indices:
		anchor_indices.append(index)
	anchor_indices.append(center_points.size() - 1)

	var attempts := requested * 12
	for attempt in range(attempts):
		if obstacle_regions.size() >= requested:
			break
		var interval := rng.randi_range(0, anchor_indices.size() - 2)
		var start_index := anchor_indices[interval]
		var finish_index := anchor_indices[interval + 1]
		if finish_index - start_index < 4:
			continue
		var middle_index := int((start_index + finish_index) * 0.5)
		var side := -1.0 if rng.randi_range(0, 1) == 0 else 1.0
		var tangent := _tangent_at(middle_index)
		var normal := Vector2(-tangent.y, tangent.x) * side
		var marker := clampi(interval - 1, 0, intersection_indices.size() - 1)
		var inner_offset := _corridor_offset_for(marker, side, 1)
		var main_half := road_widths[middle_index] * 0.5
		var collector_half := cross_street_width * 0.62
		var available_normal := inner_offset - main_half - collector_half - 150.0
		if available_normal < 190.0:
			continue
		var normal_size := rng.randf_range(180.0, minf(available_normal, 440.0))
		var block_length := center_points[start_index].distance_to(center_points[finish_index])
		var available_length := block_length - cross_street_width * 2.4
		if available_length < 260.0:
			continue
		var tangent_size := rng.randf_range(240.0, minf(available_length, 920.0))
		var normal_distance := main_half + 70.0 + normal_size * 0.5
		var longitudinal_jitter := rng.randf_range(-1.0, 1.0) * maxf(
			0.0, (available_length - tangent_size) * 0.22
		)
		var center := (
			center_points[middle_index]
			+ normal * normal_distance
			+ tangent * longitudinal_jitter
		)
		var region := {
			"center": center,
			"size": Vector2(tangent_size, normal_size),
			"rotation": tangent.angle(),
			"label": labels[rng.randi_range(0, labels.size() - 1)]
		}
		if _obstacle_is_clear(region):
			obstacle_regions.append(region)


func _obstacle_is_clear(region: Dictionary) -> bool:
	var center: Vector2 = region["center"]
	var size: Vector2 = region["size"]
	var rotation: float = region["rotation"]
	var tangent := Vector2.from_angle(rotation)
	var normal := Vector2(-tangent.y, tangent.x)
	var map_paths: Array[PackedVector2Array] = get_map_paths()
	for path_index in range(map_paths.size()):
		var path := map_paths[path_index]
		var half_width := (
			maximum_road_width * 0.5
			if path_index == 0
			else secondary_path_widths[path_index - 1] * 0.5
		)
		for segment_index in range(path.size() - 1):
			for sample in [
				path[segment_index],
				path[segment_index].lerp(path[segment_index + 1], 0.5),
				path[segment_index + 1]
			]:
				var delta: Vector2 = sample - center
				if absf(delta.dot(tangent)) < size.x * 0.5 + half_width + 38.0 \
				and absf(delta.dot(normal)) < size.y * 0.5 + half_width + 38.0:
					return false
	for existing in obstacle_regions:
		var other_center: Vector2 = existing["center"]
		var other_size: Vector2 = existing["size"]
		if center.distance_to(other_center) < size.length() * 0.5 + other_size.length() * 0.5 + 90.0:
			return false
	return true


func _rectangle_points(center: Vector2, size: Vector2, rotation: float) -> PackedVector2Array:
	var tangent := Vector2.from_angle(rotation)
	var normal := Vector2(-tangent.y, tangent.x)
	var half_x := tangent * size.x * 0.5
	var half_y := normal * size.y * 0.5
	return PackedVector2Array([
		center - half_x - half_y,
		center + half_x - half_y,
		center + half_x + half_y,
		center - half_x + half_y
	])


func get_map_bounds() -> Rect2:
	var has_point := false
	var minimum := Vector2.ZERO
	var maximum := Vector2.ZERO

	for path in get_map_paths():
		for point in path:
			if not has_point:
				minimum = point
				maximum = point
				has_point = true
			else:
				minimum = minimum.min(point)
				maximum = maximum.max(point)

	return Rect2(minimum - Vector2(160.0, 160.0), maximum - minimum + Vector2(320.0, 320.0))


func get_turnaround_indices() -> PackedInt32Array:
	return turnaround_indices.duplicate()


func get_width_profile() -> PackedFloat32Array:
	return road_widths.duplicate()


func get_lane_profile() -> PackedFloat32Array:
	return lane_profile.duplicate()


func regenerate() -> void:
	generate_road()


func generate_with_seed(new_seed: int) -> void:
	seed_value = new_seed
	randomize_seed = false

	generate_road()


func generate_random_road() -> void:
	generate_with_seed(randi())


# ============================================================
# RNG
# ============================================================

func setup_rng() -> void:
	if randomize_seed:
		seed_value = randi()

	# Same seed -> same road. The seed stays visible in seed_value so a
	# road you like can be reproduced later.
	rng.seed = seed_value


func generate_layout_profile() -> void:
	generated_density = rng.randf()
	generated_irregularity = rng.randf()
	generated_road_length = rng.randf_range(
		minf(minimum_map_length, maximum_map_length),
		maxf(minimum_map_length, maximum_map_length)
	)
	var density_count := roundi(lerpf(
		float(minimum_intersections),
		float(maximum_intersections),
		generated_density
	))
	generated_intersection_count = clampi(
		density_count + rng.randi_range(-1, 1),
		minimum_intersections,
		maximum_intersections
	)
	generated_left_corridors = rng.randi_range(
		minimum_corridors_per_side,
		maximum_corridors_per_side
	)
	generated_right_corridors = rng.randi_range(
		minimum_corridors_per_side,
		maximum_corridors_per_side
	)
	# Preserve the legacy public values as the currently generated profile so
	# inspectors and external tooling see the actual map rather than defaults.
	road_length = generated_road_length
	intersection_count = generated_intersection_count
	corridors_per_side = maxi(generated_left_corridors, generated_right_corridors)


func get_layout_summary() -> Dictionary:
	return {
		"length": generated_road_length,
		"density": generated_density,
		"irregularity": generated_irregularity,
		"intersections": generated_intersection_count,
		"left_corridors": generated_left_corridors,
		"right_corridors": generated_right_corridors,
		"obstacles": obstacle_regions.size(),
		"road_classes": secondary_path_classes.duplicate()
	}


func get_obstacle_regions() -> Array[Dictionary]:
	return obstacle_regions.duplicate(true)


# ============================================================
# CENTERLINE
# ============================================================

func generate_centerline() -> void:
	center_points.clear()

	current_angle = 0.0
	current_steer = 0.0
	steer_target = 0.0
	steer_hold = 0

	var current_pos := Vector2.ZERO

	center_points.append(current_pos)

	var number_of_segments: int = int(generated_road_length / maxf(segment_length, 1.0))
	var turn_limit := get_max_turn_per_segment()

	for i in range(number_of_segments):
		var previous_angle := current_angle
		var desired_angle := calculate_next_angle(i)
		var placed := false

		# Try the preferred direction first, then nearby alternatives.
		for offset in STEER_CANDIDATES:
			var offset_deg: float = offset

			var candidate := clampf(
				desired_angle + offset_deg,
				previous_angle - turn_limit,
				previous_angle + turn_limit
			)

			candidate = clampf(candidate, -max_total_turn, max_total_turn)

			var next_pos := current_pos + Vector2.from_angle(deg_to_rad(candidate)) * segment_length

			if is_position_safe(next_pos):
				current_angle = candidate
				current_pos = next_pos
				placed = true
				break

		if not placed:
			push_warning("RoadGenerator: no safe direction found, road ends early at segment %d." % i)
			break

		center_points.append(current_pos)


func generate_road_features() -> void:
	road_widths.clear()
	lane_profile.clear()
	intersection_indices.clear()
	turnaround_indices.clear()
	intersection_types.clear()
	branch_sides.clear()

	if center_points.is_empty():
		return

	# Real roads keep a lane count for a while, then add or remove one lane at a
	# time over a finite merge taper. The schedule guarantees useful 1/2/3-lane
	# sections without making the entire road continuously expand and contract.
	var last_point := maxi(center_points.size() - 1, 1)
	for i in range(center_points.size()):
		var ratio := float(i) / float(last_point)
		var lanes := _lane_profile_for_ratio(ratio)
		lane_profile.append(lanes)
		road_widths.append(lanes * lane_width * 2.0 + shoulder_width * 2.0)

	var usable_start: int = maxi(8, int(600.0 / maxf(segment_length, 1.0)))
	var usable_end: int = center_points.size() - usable_start - 1

	if usable_end <= usable_start:
		return

	var type_schedule: Array[String] = ["t_junction", "four_way", "roundabout"]
	var optional_types: Array[String] = ["t_junction", "t_junction", "four_way", "roundabout"]
	while type_schedule.size() < generated_intersection_count:
		type_schedule.append(optional_types[rng.randi_range(0, optional_types.size() - 1)])
	for schedule_index in range(type_schedule.size() - 1, 0, -1):
		var swap_index := rng.randi_range(0, schedule_index)
		var held := type_schedule[schedule_index]
		type_schedule[schedule_index] = type_schedule[swap_index]
		type_schedule[swap_index] = held

	# Seeded wide jitter changes block lengths substantially while a minimum
	# spacing keeps adjacent junction conflict zones from overlapping.
	var slot_span := float(usable_end - usable_start) / float(generated_intersection_count + 1)
	for feature in range(generated_intersection_count):
		var ratio := (float(feature) + 1.0) / (float(generated_intersection_count) + 1.0)
		var base := int(round(lerpf(float(usable_start), float(usable_end), ratio)))
		var jitter_limit := maxi(2, roundi(slot_span * lerpf(0.16, 0.38, generated_irregularity)))
		var jitter := rng.randi_range(-jitter_limit, jitter_limit)
		var chosen_intersection := _straightest_intersection_near(
			clampi(base + jitter, usable_start, usable_end),
			usable_start,
			usable_end
		)
		var minimum_feature_gap := maxi(5, floori(slot_span * 0.55))
		for previous_intersection in intersection_indices:
			if absi(chosen_intersection - previous_intersection) < minimum_feature_gap:
				chosen_intersection = clampi(
					previous_intersection + minimum_feature_gap,
					usable_start,
					usable_end
				)
		intersection_indices.append(chosen_intersection)

		var junction_type := type_schedule[feature]
		intersection_types.append(junction_type)
		branch_sides.append(
			0 if junction_type == "four_way" else _safest_branch_side(chosen_intersection)
		)

	for feature in range(turnaround_count):
		var ratio := (float(feature) + 0.5) / float(maxi(turnaround_count, 1))
		var base := int(round(lerpf(float(usable_start), float(usable_end), ratio)))
		var chosen := clampi(base + rng.randi_range(-2, 2), usable_start, usable_end)

		# Keep turnaround bulbs away from intersection openings.
		for intersection_index in intersection_indices:
			if absi(chosen - intersection_index) < 5:
				chosen = clampi(chosen + 6, usable_start, usable_end)

		turnaround_indices.append(chosen)

		for offset in range(-3, 4):
			var index := chosen + offset

			if index >= 0 and index < road_widths.size():
				var influence := 1.0 - absf(float(offset)) / 4.0
				road_widths[index] = maxf(
					road_widths[index],
					lerpf(road_widths[index], turnaround_width, influence)
				)


func _lane_profile_for_ratio(ratio: float) -> float:
	var stages: Array[Vector2] = [
		Vector2(0.00, 1.0), Vector2(0.12, 1.0),
		Vector2(0.20, 2.0), Vector2(0.32, 2.0),
		Vector2(0.40, 3.0), Vector2(0.58, 3.0),
		Vector2(0.66, 2.0), Vector2(0.76, 2.0),
		Vector2(0.84, 1.0), Vector2(1.00, 1.0)
	]

	for i in range(stages.size() - 1):
		if ratio <= stages[i + 1].x:
			var span := maxf(stages[i + 1].x - stages[i].x, 0.001)
			var t := clampf((ratio - stages[i].x) / span, 0.0, 1.0)
			var smooth_t := t * t * (3.0 - 2.0 * t)
			return lerpf(stages[i].y, stages[i + 1].y, smooth_t)

	return 1.0


func _safest_branch_side(intersection_index: int) -> int:
	var tangent := (
		center_points[intersection_index + 1]
		- center_points[intersection_index - 1]
	).normalized()
	var across := Vector2(-tangent.y, tangent.x)
	var preferred := -1 if rng.randi_range(0, 1) == 0 else 1
	var best_side := preferred
	var best_clearance := -INF

	for candidate_side in [-1, 1]:
		var endpoint := (
			center_points[intersection_index]
			+ across * float(candidate_side) * _collector_offset_for(intersection_indices.size() - 1, float(candidate_side))
		)
		var clearance := INF
		# Ignore the arterial immediately around the junction; it is the intended
		# connection. Everything else must remain away from the terminal bulb.
		for point_index in range(center_points.size()):
			if absi(point_index - intersection_index) <= 7:
				continue
			clearance = minf(clearance, endpoint.distance_to(center_points[point_index]))

		# Also avoid endpoints already assigned to earlier map pieces.
		for previous_feature in range(branch_sides.size()):
			var previous_index := intersection_indices[previous_feature]
			var previous_tangent := (
				center_points[previous_index + 1]
				- center_points[previous_index - 1]
			).normalized()
			var previous_across := Vector2(-previous_tangent.y, previous_tangent.x)
			for previous_side in _branch_directions(previous_feature):
				var previous_endpoint := (
					center_points[previous_index]
					+ previous_across * previous_side * _collector_offset_for(previous_feature, previous_side)
				)
				clearance = minf(clearance, endpoint.distance_to(previous_endpoint))

		if clearance > best_clearance + 0.01 \
		or (is_equal_approx(clearance, best_clearance) and candidate_side == preferred):
			best_clearance = clearance
			best_side = candidate_side

	return best_side


func _straightest_intersection_near(base: int, lower: int, upper: int) -> int:
	var best := base
	var best_score := INF

	for candidate in range(maxi(lower, base - 7), mini(upper, base + 7) + 1):
		if candidate <= 0 or candidate >= center_points.size() - 1:
			continue

		var before := (center_points[candidate] - center_points[candidate - 1]).normalized()
		var after := (center_points[candidate + 1] - center_points[candidate]).normalized()
		var curvature := absf(before.angle_to(after))
		var lane_penalty := maxf(lane_profile[candidate] - 2.0, 0.0) * 0.5
		var score := curvature + lane_penalty

		if score < best_score:
			best_score = score
			best = candidate

	return best


# ============================================================
# ANGLE GENERATION
# ============================================================

## Largest heading change per segment that still keeps the inner road edge
## valid (the turning radius must stay larger than the road's half width).
func get_max_turn_per_segment() -> float:
	var widest_road := (
		float(maximum_lanes_per_direction) * lane_width * 2.0
		+ shoulder_width * 2.0
	)
	# Keep the inner edge well outside the center of curvature. This is stricter
	# than merely avoiding a mathematical fold and produces believable bends.
	# Parallel collector roads are offset from the arterial. The arterial's
	# radius must remain larger than that offset or an inside collector folds
	# back into the next block even when the arterial surface itself is valid.
	var collector_offset := (
		cross_street_length * 0.5
		+ float(corridors_per_side - 1) * corridor_spacing
		+ 90.0
	)
	var min_radius := maxf(widest_road * 0.9, collector_offset + 420.0)
	var geometric_limit := rad_to_deg(segment_length / min_radius)

	return minf(max_turn_angle, geometric_limit)


## Returns the preferred heading (degrees) for the next segment.
func calculate_next_angle(index: int) -> float:
	# Keep the beginning straight
	if index < min_straight_segments:
		return current_angle

	var turn_limit := get_max_turn_per_segment()

	# Pick a new steering target every few segments
	steer_hold -= 1

	if steer_hold <= 0:
		# Gentle pull back towards the start direction so the road
		# doesn't hug the heading limit.
		var bias := -clampf(current_angle / maxf(max_total_turn, 1.0), -1.0, 1.0) * turn_limit * 0.5

		steer_target = clampf(
			rng.randf_range(-turn_limit, turn_limit) + bias,
			- turn_limit,
			turn_limit
		)

		steer_hold = rng.randi_range(3, 8)

	# Smooth steering -> no abrupt direction changes
	current_steer = lerpf(current_steer, steer_target, turn_smoothing)

	return clampf(
		current_angle + current_steer,
		- max_total_turn,
		max_total_turn
	)


# ============================================================
# POSITION SAFETY
# ============================================================

func get_required_clearance() -> float:
	var widest_road := (
		float(maximum_lanes_per_direction) * lane_width * 2.0
		+ shoulder_width * 2.0
	)
	return maxf(minimum_segment_distance, widest_road + boundary_thickness)


func is_position_safe(new_position: Vector2) -> bool:
	var count := center_points.size()

	if count < 2:
		return true

	var clearance := get_required_clearance()
	var point_clearance := maxf(minimum_point_distance, clearance)

	# Recent road is always close by definition, so skip it.
	var ignore_recent := ceili(point_clearance / maxf(segment_length, 1.0)) + 1

	var new_start := center_points[count - 1]

	# --------------------------------------------------------
	# Don't get too close to old points
	# --------------------------------------------------------

	for i in range(count - ignore_recent):
		if new_position.distance_to(center_points[i]) < point_clearance:
			return false

	# --------------------------------------------------------
	# Don't cross or approach previous road segments
	# --------------------------------------------------------

	for i in range(count - 1 - ignore_recent):
		var old_start := center_points[i]
		var old_end := center_points[i + 1]

		if segments_intersect(new_start, new_position, old_start, old_end):
			return false

		if segment_to_segment_distance(new_start, new_position, old_start, old_end) < clearance:
			return false

	return true


# ============================================================
# SEGMENT INTERSECTION
# ============================================================

func segments_intersect(
	a: Vector2,
	b: Vector2,
	c: Vector2,
	d: Vector2
) -> bool:
	var denominator := (
		(b.x - a.x) * (d.y - c.y)
		-
		(b.y - a.y) * (d.x - c.x)
	)

	if absf(denominator) < 0.0001:
		return false

	var ua := (
		(c.x - a.x) * (d.y - c.y)
		-
		(c.y - a.y) * (d.x - c.x)
	) / denominator

	var ub := (
		(c.x - a.x) * (b.y - a.y)
		-
		(c.y - a.y) * (b.x - a.x)
	) / denominator

	return ua >= 0.0 and ua <= 1.0 and ub >= 0.0 and ub <= 1.0


# ============================================================
# SEGMENT DISTANCE
# ============================================================

func segment_to_segment_distance(
	a: Vector2,
	b: Vector2,
	c: Vector2,
	d: Vector2
) -> float:
	var d1 := point_to_segment_distance(a, c, d)
	var d2 := point_to_segment_distance(b, c, d)
	var d3 := point_to_segment_distance(c, a, b)
	var d4 := point_to_segment_distance(d, a, b)

	return minf(minf(d1, d2), minf(d3, d4))


func point_to_segment_distance(
	point: Vector2,
	a: Vector2,
	b: Vector2
) -> float:
	var ab := b - a
	var length_squared := ab.length_squared()

	if length_squared == 0.0:
		return point.distance_to(a)

	var t := clampf((point - a).dot(ab) / length_squared, 0.0, 1.0)
	var closest := a + ab * t

	return point.distance_to(closest)


# ============================================================
# ROAD BOUNDARIES
# ============================================================

func segment_normal(a: Vector2, b: Vector2) -> Vector2:
	var direction := (b - a).normalized()

	return Vector2(-direction.y, direction.x)


func generate_boundaries() -> void:
	left_points.clear()
	right_points.clear()

	var count := center_points.size()

	if count < 2:
		return

	for i in range(count):
		var normal: Vector2
		var miter_scale := 1.0

		if i == 0:
			normal = segment_normal(center_points[0], center_points[1])

		elif i == count - 1:
			normal = segment_normal(center_points[i - 1], center_points[i])

		else:
			var n1 := segment_normal(center_points[i - 1], center_points[i])
			var n2 := segment_normal(center_points[i], center_points[i + 1])

			normal = n1 + n2

			if normal.length_squared() < 0.0001:
				normal = n1
			else:
				normal = normal.normalized()

			# Mitering keeps the road width constant through curves
			miter_scale = 1.0 / maxf(normal.dot(n1), 0.5)

		var half_width: float = (
			road_widths[i] * 0.5
			if i < road_widths.size()
			else road_width * 0.5
		)
		var offset := normal * half_width * miter_scale

		left_points.append(center_points[i] + offset)
		right_points.append(center_points[i] - offset)


# ============================================================
# NODE HELPERS
# ============================================================

func _get_or_create(node_name: String, type_name: String) -> Node:
	var node := get_node_or_null(node_name)

	if node == null:
		node = ClassDB.instantiate(type_name)
		node.name = node_name
		add_child(node)

	return node


func _clear_children(node: Node) -> void:
	for child in node.get_children():
		# Remove immediately so names are free again for the new content
		node.remove_child(child)
		child.queue_free()


# ============================================================
# ROAD POLYGON
# ============================================================

func build_road_polygon() -> void:
	var road := _get_or_create("Road", "Polygon2D") as Polygon2D
	road.polygon = PackedVector2Array()

	var surface := _get_or_create("RoadSurface", "Node2D")
	_clear_children(surface)

	if left_points.size() < 2:
		return

	# One convex quad per segment avoids the triangulation artifacts produced by
	# a single concave polygon when the road widens through a sharp curve.
	for i in range(left_points.size() - 1):
		var strip := Polygon2D.new()
		strip.color = Color(0.12, 0.12, 0.12)
		strip.polygon = PackedVector2Array([
			left_points[i],
			left_points[i + 1],
			right_points[i + 1],
			right_points[i]
		])
		surface.add_child(strip)


func build_obstacles() -> void:
	var container := _get_or_create("ObstacleAreas", "Node2D") as Node2D
	_clear_children(container)
	container.z_index = -1
	for region_index in range(obstacle_regions.size()):
		var region := obstacle_regions[region_index]
		var center: Vector2 = region["center"]
		var size: Vector2 = region["size"]
		var rotation: float = region["rotation"]
		var points := _rectangle_points(center, size, rotation)

		var area := Polygon2D.new()
		area.name = "Obstacle_%02d" % region_index
		area.color = Color(0.15, 0.36, 0.18)
		area.polygon = points
		container.add_child(area)

		var outline := Line2D.new()
		outline.width = 5.0
		outline.default_color = Color(0.30, 0.55, 0.31)
		outline.antialiased = true
		outline.closed = true
		for point in points:
			outline.add_point(point)
		container.add_child(outline)

		var label := Label.new()
		label.name = "ObstacleLabel_%02d" % region_index
		label.text = String(region["label"])
		label.position = center - size * 0.5
		label.size = size
		label.pivot_offset = size * 0.5
		label.rotation = rotation
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", 34)
		label.add_theme_color_override("font_color", Color(0.88, 0.96, 0.86))
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		container.add_child(label)

		var body := StaticBody2D.new()
		body.name = "ObstacleBody_%02d" % region_index
		body.collision_layer = 1
		body.collision_mask = 2
		var shape_node := CollisionShape2D.new()
		var shape := RectangleShape2D.new()
		shape.size = size
		shape_node.shape = shape
		shape_node.position = center
		shape_node.rotation = rotation
		body.add_child(shape_node)
		container.add_child(body)


func build_cross_streets() -> void:
	var container := _get_or_create("CrossStreets", "Node2D")
	_clear_children(container)
	_build_secondary_network(container)

	for feature in range(intersection_indices.size()):
		if intersection_types[feature] != "roundabout":
			continue
		var index := intersection_indices[feature]
		var tangent := _tangent_at(index)
		var side := float(branch_sides[feature])
		var outward := Vector2(-tangent.y, tangent.x) * side
		var center := _corridor_point_at(index, feature, side, 1)
		_build_roundabout(container, center, outward, tangent)

	for dead_end_index in range(dead_end_centers.size()):
		var outward := dead_end_directions[dead_end_index]
		_build_cul_de_sac(
			container,
			dead_end_centers[dead_end_index],
			outward,
			Vector2(-outward.y, outward.x)
		)


func _branch_directions(feature: int) -> Array[float]:
	if feature < 0 or feature >= branch_sides.size() or branch_sides[feature] == 0:
		return [-1.0, 1.0]
	return [float(branch_sides[feature])]


func _build_secondary_network(container: Node) -> void:
	var body := StaticBody2D.new()
	body.name = "SecondaryRoadWalls"
	body.collision_layer = 1
	body.collision_mask = 2
	container.add_child(body)

	for path_index in range(secondary_paths.size()):
		var path := secondary_paths[path_index]
		if path.size() < 2:
			continue
		var half_width := secondary_path_widths[path_index] * 0.5
		var is_ring := path.size() > 12 and path[0].distance_squared_to(path[-1]) < 1.0

		for segment_index in range(path.size() - 1):
			var start := path[segment_index]
			var finish := path[segment_index + 1]
			var segment := finish - start
			if segment.length_squared() < 1.0:
				continue
			var direction := segment.normalized()
			var normal := Vector2(-direction.y, direction.x)
			var strip := Polygon2D.new()
			strip.color = Color(0.115, 0.115, 0.115)
			strip.polygon = PackedVector2Array([
				start + normal * half_width,
				finish + normal * half_width,
				finish - normal * half_width,
				start - normal * half_width
			])
			container.add_child(strip)

			if not is_ring and not _segment_inside_roundabout(start, finish):
				var start_trim := _junction_clearance(start, half_width)
				var finish_trim := _junction_clearance(finish, half_width)
				var wall_start := start + direction * start_trim
				var wall_finish := finish - direction * finish_trim
				if wall_start.distance_to(wall_finish) > 12.0:
					for wall_side in [-1.0, 1.0]:
						var edge_start: Vector2 = wall_start + normal * half_width * wall_side
						var edge_finish: Vector2 = wall_finish + normal * half_width * wall_side
						_add_wall_segment(body, edge_start, edge_finish)
						_add_edge_visual(container, edge_start, edge_finish)

		# Circular asphalt joints remove cracks and pointed triangles where two
		# independently angled street strips meet.
		for point_index in range(1, path.size() - 1):
			var joint := Polygon2D.new()
			joint.color = Color(0.115, 0.115, 0.115)
			joint.polygon = _circle_points(path[point_index], half_width, 16)
			container.add_child(joint)

		_add_dashed_centerline(container, path, is_ring, half_width)


func _junction_clearance(point: Vector2, default_half_width: float) -> float:
	for index in range(center_points.size()):
		if point.distance_squared_to(center_points[index]) < 1.0:
			return maxf(
				road_widths[index] * 0.5,
				_network_half_width_at(point, default_half_width)
			) + 18.0
	if _network_point_occurrences(point) > 1:
		return _network_half_width_at(point, default_half_width) + 18.0
	return 0.0


func _network_half_width_at(point: Vector2, fallback: float) -> float:
	var result := fallback
	for path_index in range(secondary_paths.size()):
		for candidate in secondary_paths[path_index]:
			if point.distance_squared_to(candidate) < 1.0:
				result = maxf(result, secondary_path_widths[path_index] * 0.5)
				break
	return result


func _network_point_occurrences(point: Vector2) -> int:
	var occurrences := 0
	for path in secondary_paths:
		for candidate in path:
			if point.distance_squared_to(candidate) < 1.0:
				occurrences += 1
				break
	for candidate in center_points:
		if point.distance_squared_to(candidate) < 1.0:
			occurrences += 1
			break
	return occurrences


func _segment_inside_roundabout(start: Vector2, finish: Vector2) -> bool:
	var midpoint := (start + finish) * 0.5
	for feature in range(intersection_types.size()):
		if intersection_types[feature] != "roundabout":
			continue
		var side := float(branch_sides[feature])
		var center := _corridor_point_at(intersection_indices[feature], feature, side, 1)
		if midpoint.distance_to(center) < roundabout_radius + cross_street_width:
			return true
	return false


func _add_dashed_centerline(
	container: Node,
	path: PackedVector2Array,
	is_ring: bool,
	half_width: float
) -> void:
	if is_ring:
		return
	var pattern := dash_length + gap_length
	if pattern <= 0.0:
		return
	var travelled := 0.0
	for segment_index in range(path.size() - 1):
		var start := path[segment_index]
		var segment := path[segment_index + 1] - start
		var length := segment.length()
		if length < 1.0:
			continue
		if _segment_inside_roundabout(start, path[segment_index + 1]):
			travelled += length
			continue
		var direction := segment / length
		var trim_start := 0.0 if is_ring else _junction_clearance(start, half_width)
		var trim_finish := 0.0 if is_ring else _junction_clearance(path[segment_index + 1], half_width)
		var distance := trim_start
		var usable_end := length - trim_finish
		while distance < usable_end:
			var phase := fmod(travelled + distance, pattern)
			if phase < dash_length:
				var dash_end := minf(distance + dash_length - phase, usable_end)
				var dash := Line2D.new()
				dash.width = line_width
				dash.default_color = Color(0.95, 0.72, 0.12)
				dash.antialiased = true
				dash.add_point(start + direction * distance)
				dash.add_point(start + direction * dash_end)
				container.add_child(dash)
				distance = dash_end
			else:
				distance += pattern - phase
		travelled += length


func _add_edge_visual(container: Node, start: Vector2, finish: Vector2) -> void:
	var edge := Line2D.new()
	edge.width = 4.0
	edge.default_color = Color(0.68, 0.70, 0.70)
	edge.antialiased = true
	edge.begin_cap_mode = Line2D.LINE_CAP_ROUND
	edge.end_cap_mode = Line2D.LINE_CAP_ROUND
	edge.add_point(start)
	edge.add_point(finish)
	container.add_child(edge)


func _build_cul_de_sac(
	container: Node,
	center: Vector2,
	outward: Vector2,
	tangent: Vector2
) -> void:
	var radius := cross_street_width * 0.68
	var bulb := Polygon2D.new()
	bulb.color = Color(0.115, 0.115, 0.115)
	bulb.polygon = _circle_points(center, radius, 24)
	container.add_child(bulb)

	var body := StaticBody2D.new()
	body.name = "CulDeSacWalls_%d_%d" % [roundi(center.x), roundi(center.y)]
	body.collision_layer = 1
	body.collision_mask = 2
	container.add_child(body)
	_add_round_boundary(body, center, radius, outward, tangent, true)
	_add_round_outline_openings(container, center, radius, [-outward])


func _build_roundabout(
	container: Node,
	center: Vector2,
	outward: Vector2,
	tangent: Vector2
) -> void:
	var outer_radius := roundabout_radius + cross_street_width * 0.5
	var island_radius := maxf(roundabout_radius - cross_street_width * 0.5, 34.0)
	var apron := Polygon2D.new()
	apron.color = Color(0.115, 0.115, 0.115)
	apron.polygon = _circle_points(center, outer_radius, 32)
	container.add_child(apron)

	var island := Polygon2D.new()
	island.color = Color(0.16, 0.34, 0.16)
	island.polygon = _circle_points(center, island_radius, 24)
	container.add_child(island)

	var body := StaticBody2D.new()
	body.name = "RoundaboutWalls_%d_%d" % [roundi(center.x), roundi(center.y)]
	body.collision_layer = 1
	body.collision_mask = 2
	container.add_child(body)
	_add_round_boundary_openings(
		body,
		center,
		outer_radius,
		[-outward, outward, tangent, -tangent]
	)
	_add_round_outline_openings(
		container,
		center,
		outer_radius,
		[-outward, outward, tangent, -tangent]
	)

	var island_shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = island_radius
	island_shape.shape = circle
	island_shape.position = center
	body.add_child(island_shape)

	var island_edge := Line2D.new()
	island_edge.width = 4.0
	island_edge.default_color = Color(0.92, 0.92, 0.92)
	island_edge.closed = true
	for point in _circle_points(center, island_radius, 24):
		island_edge.add_point(point)
	container.add_child(island_edge)


func _add_round_outline_openings(
	container: Node,
	center: Vector2,
	radius: float,
	openings: Array
) -> void:
	var steps := 40
	for step in range(steps):
		var a_direction := Vector2.from_angle(TAU * float(step) / float(steps))
		var b_direction := Vector2.from_angle(TAU * float(step + 1) / float(steps))
		var middle := (a_direction + b_direction).normalized()
		var at_opening := false
		for opening_value in openings:
			var opening: Vector2 = opening_value
			if middle.dot(opening) > 0.62:
				at_opening = true
				break
		if not at_opening:
			_add_edge_visual(
				container,
				center + a_direction * radius,
				center + b_direction * radius
			)


func _circle_points(center: Vector2, radius: float, steps: int) -> PackedVector2Array:
	var result := PackedVector2Array()
	for step in range(steps):
		result.append(center + Vector2.from_angle(TAU * float(step) / float(steps)) * radius)
	return result


func _add_round_boundary(
	body: StaticBody2D,
	center: Vector2,
	radius: float,
	outward: Vector2,
	_tangent: Vector2,
	leave_entrance: bool
) -> void:
	_add_round_boundary_openings(body, center, radius, [-outward] if leave_entrance else [])


func _add_round_boundary_openings(
	body: StaticBody2D,
	center: Vector2,
	radius: float,
	openings: Array
) -> void:
	var steps := 24
	for step in range(steps):
		var a_direction := Vector2.from_angle(TAU * float(step) / float(steps))
		var b_direction := Vector2.from_angle(TAU * float(step + 1) / float(steps))
		var middle := (a_direction + b_direction).normalized()
		var at_opening := false
		for opening_value in openings:
			var opening: Vector2 = opening_value
			if middle.dot(opening) > 0.56:
				at_opening = true
				break
		if at_opening:
			continue
		_add_wall_segment(body, center + a_direction * radius, center + b_direction * radius)


func _add_wall_segment(body: StaticBody2D, start: Vector2, end: Vector2) -> void:
	var segment := end - start

	if segment.length_squared() < 1.0:
		return

	var rectangle := RectangleShape2D.new()
	rectangle.size = Vector2(segment.length(), boundary_thickness)
	var shape := CollisionShape2D.new()
	shape.shape = rectangle
	shape.position = (start + end) * 0.5
	shape.rotation = segment.angle()
	body.add_child(shape)


# ============================================================
# LANE MARKINGS
# ============================================================

func build_lane_markings() -> void:
	var container := Node2D.new()
	container.name = "LaneMarkings"
	add_child(container)

	var pattern := dash_length + gap_length

	if dash_length <= 0.0 or pattern <= 0.0:
		return

	# The dash pattern continues across segments, so dashes keep an even
	# rhythm instead of restarting every segment.
	var travelled := 0.0

	for i in range(center_points.size() - 1):
		var start := center_points[i]
		var segment := center_points[i + 1] - start
		var length := segment.length()

		if length < 0.001:
			continue

		var direction := segment / length
		var d := 0.0

		while d < length:
			var phase := fmod(travelled + d, pattern)

			if phase < dash_length:
				var dash_end := minf(d + maxf(dash_length - phase, 0.01), length)

				container.add_child(
					_make_dash(start + direction * d, start + direction * dash_end)
				)

				d = dash_end

			else:
				# Skip the gap
				d += maxf(pattern - phase, 0.01)

		travelled += length

	# White dividers taper in from the shoulder as a lane is added and taper
	# back out when it merges. Each short segment is convex/render-safe and
	# follows the same lane profile used by traffic.
	for direction in [-1.0, 1.0]:
		for divider_index in range(1, maximum_lanes_per_direction):
			for i in range(center_points.size() - 1):
				var profile_a: float = lane_profile[i]
				var profile_b: float = lane_profile[i + 1]

				if maxf(profile_a, profile_b) <= float(divider_index) + 0.02:
					continue

				if (i + divider_index) % 2 != 0:
					continue

				var offset_a := _lane_divider_offset(profile_a, divider_index, float(direction))
				var offset_b := _lane_divider_offset(profile_b, divider_index, float(direction))
				var line := Line2D.new()
				line.width = 3.0
				line.default_color = Color(0.92, 0.92, 0.92)
				var from := center_points[i] + route.get_normal_at(float(route.cumulative[i])) * offset_a
				var full_to := center_points[i + 1] + route.get_normal_at(float(route.cumulative[i + 1])) * offset_b
				line.add_point(from)
				line.add_point(from.lerp(full_to, 0.62))
				container.add_child(line)


func _lane_divider_offset(profile: float, divider_index: int, direction: float) -> float:
	var transition := clampf(float(divider_index + 1) - profile, 0.0, 1.0)
	return direction * (
		float(divider_index) * lane_width
		+ shoulder_width * transition
	)


func _make_dash(from: Vector2, to: Vector2) -> Line2D:
	var line := Line2D.new()

	line.width = line_width
	line.default_color = Color(0.95, 0.72, 0.12)
	line.begin_cap_mode = Line2D.LINE_CAP_NONE
	line.end_cap_mode = Line2D.LINE_CAP_NONE

	line.add_point(from)
	line.add_point(to)

	return line


# ============================================================
# BOUNDARY VISUALS
# ============================================================

func build_boundary_visuals() -> void:
	var left_line := _get_or_create("LeftBoundary", "Line2D") as Line2D
	var right_line := _get_or_create("RightBoundary", "Line2D") as Line2D
	left_line.clear_points()
	right_line.clear_points()
	left_line.visible = false
	right_line.visible = false

	var container := _get_or_create("EdgeMarkings", "Node2D")
	_clear_children(container)
	var edge_color := Color(0.68, 0.70, 0.70)
	if not show_debug_boundaries:
		return

	# Separate pieces leave a clean opening at every junction. A single Line2D
	# used to draw a white stroke straight across side roads.
	for i in range(left_points.size() - 1):
		if _segment_is_intersection_opening(i):
			continue
		for points in [left_points, right_points]:
			var edge := Line2D.new()
			edge.width = 4.0
			edge.default_color = edge_color
			edge.antialiased = true
			edge.begin_cap_mode = Line2D.LINE_CAP_ROUND
			edge.end_cap_mode = Line2D.LINE_CAP_ROUND
			edge.add_point(points[i])
			edge.add_point(points[i + 1])
			container.add_child(edge)


func build_debug_centerline() -> void:
	var line := _get_or_create("DebugCenterline", "Line2D") as Line2D

	line.clear_points()

	for point in center_points:
		line.add_point(point)

	line.width = 2.0
	line.default_color = Color(1.0, 0.2, 0.2)
	line.visible = show_debug_centerline


# ============================================================
# COLLISIONS
# ============================================================

func build_collisions() -> void:
	var container := _get_or_create("Collisions", "Node2D")

	_clear_children(container)

	var walls := StaticBody2D.new()
	walls.name = "Walls"
	# Layer 1: world geometry. It only needs to collide with vehicles.
	walls.collision_layer = 1
	walls.collision_mask = 2
	container.add_child(walls)

	# Walls sit just outside the road edge so the drivable width stays
	# exactly road_width.
	create_collision_chain(left_points, walls, 1.0)
	create_collision_chain(right_points, walls, -1.0)


func create_collision_chain(
	points: Array[Vector2],
	body: StaticBody2D,
	outward_sign: float
) -> void:
	if points.size() < 2:
		return

	for i in range(points.size() - 1):
		if _segment_is_intersection_opening(i):
			continue

		var start := points[i]
		var end := points[i + 1]

		var segment := end - start
		var length := segment.length()

		if length < 0.001:
			continue

		var direction := segment / length
		var outward := Vector2(-direction.y, direction.x) * outward_sign

		var rectangle := RectangleShape2D.new()

		# Slightly longer than the segment so neighbouring walls overlap
		# and leave no gaps in curves.
		rectangle.size = Vector2(length + boundary_thickness, boundary_thickness)

		var shape := CollisionShape2D.new()

		shape.shape = rectangle
		shape.position = (start + end) * 0.5 + outward * boundary_thickness * 0.5
		shape.rotation = segment.angle()

		body.add_child(shape)


func _segment_is_intersection_opening(segment_index: int) -> bool:
	for intersection_index in intersection_indices:
		if absi(segment_index - intersection_index) <= 1:
			return true

	return false


# ============================================================
# CLEAR
# ============================================================

func clear_generated_content() -> void:
	var old_markings := get_node_or_null("LaneMarkings")

	if old_markings:
		remove_child(old_markings)
		old_markings.queue_free()

	var collisions := get_node_or_null("Collisions")

	if collisions:
		_clear_children(collisions)

	var cross_streets := get_node_or_null("CrossStreets")

	if cross_streets:
		_clear_children(cross_streets)

	var road_surface := get_node_or_null("RoadSurface")

	if road_surface:
		_clear_children(road_surface)

	var edge_markings := get_node_or_null("EdgeMarkings")

	if edge_markings:
		_clear_children(edge_markings)

	var obstacle_areas := get_node_or_null("ObstacleAreas")

	if obstacle_areas:
		_clear_children(obstacle_areas)

# ============================================================
# SPAWN POSE
# ============================================================

func get_spawn_position() -> Vector2:
	if center_points.is_empty():
		return Vector2.ZERO

	return center_points[0]


func get_spawn_rotation() -> float:
	if center_points.size() < 2:
		return 0.0

	var direction := (
		center_points[1]
		-
		center_points[0]
	)

	return direction.angle() + PI / 2.0
