extends Node2D

const ROAD_NETWORK := preload("res://scripts/road_network.gd")

# ============================================================
# ROAD
# ============================================================

@export_category("Road")

@export var road_width: float = 200.0
@export var road_length: float = 4000.0
@export var segment_length: float = 60.0

@export_category("Road Complexity")
@export var minimum_road_width: float = 190.0
@export var maximum_road_width: float = 280.0
@export var width_change_smoothing: float = 0.16
@export_range(3, 6, 1) var intersection_count: int = 4
@export var cross_street_length: float = 700.0
@export var cross_street_width: float = 190.0
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
@export var max_total_turn: float = 160.0

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

	generate_centerline()
	generate_road_features()
	generate_boundaries()

	var route_half_widths := PackedFloat32Array()

	for width in road_widths:
		route_half_widths.append(width * 0.5)

	route.build(center_points, route_half_widths, lane_profile, lane_width)
	road_network.build(get_map_paths())

	build_road_polygon()
	build_cross_streets()
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


## Centerlines used by the minimap and future route graph. The first path is
## always the arterial; later paths are its one-lane branches and roundabouts.
func get_map_paths() -> Array[PackedVector2Array]:
	var paths: Array[PackedVector2Array] = [PackedVector2Array(center_points)]

	for feature in range(intersection_indices.size()):
		var index := intersection_indices[feature]
		if index <= 0 or index >= center_points.size() - 1:
			continue

		var center := center_points[index]
		var tangent := (center_points[index + 1] - center_points[index - 1]).normalized()
		var across := Vector2(-tangent.y, tangent.x)
		for side in _branch_directions(feature):
			var outward := across * side
			var endpoint: Vector2 = center + outward * cross_street_length * 0.5
			var branch_endpoint := endpoint
			if intersection_types[feature] == "roundabout":
				branch_endpoint = endpoint - outward * 105.0
			var branch := PackedVector2Array()
			for step in range(7):
				branch.append(center.lerp(branch_endpoint, float(step) / 6.0))
			paths.append(branch)

			if intersection_types[feature] == "roundabout":
				var ring := PackedVector2Array()
				for step in range(25):
					var angle := (-outward).angle() + TAU * float(step) / 24.0
					ring.append(endpoint + Vector2.from_angle(angle) * 105.0)
				paths.append(ring)
				for exit_side in [-1.0, 1.0]:
					var exit_direction: Vector2 = tangent * exit_side
					var exit_path := PackedVector2Array()
					var exit_start := endpoint + exit_direction * 105.0
					var exit_end := endpoint + exit_direction * 300.0
					for exit_step in range(5):
						exit_path.append(exit_start.lerp(exit_end, float(exit_step) / 4.0))
					paths.append(exit_path)

	return paths


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

	var number_of_segments: int = int(road_length / maxf(segment_length, 1.0))
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

	# Place features in evenly divided seeded slots, preventing overlaps while
	# still producing different layouts for different seeds.
	for feature in range(intersection_count):
		var ratio := (float(feature) + 1.0) / (float(intersection_count) + 1.0)
		var base := int(round(lerpf(float(usable_start), float(usable_end), ratio)))
		var jitter := rng.randi_range(-2, 2)
		var chosen_intersection := _straightest_intersection_near(
			clampi(base + jitter, usable_start, usable_end),
			usable_start,
			usable_end
		)
		for previous_intersection in intersection_indices:
			if absi(chosen_intersection - previous_intersection) < 6:
				chosen_intersection = clampi(previous_intersection + 6, usable_start, usable_end)
		intersection_indices.append(chosen_intersection)

		# A compact training map always contains the important junction classes.
		# Their exact locations and T/roundabout side stay seeded.
		if feature == 0:
			intersection_types.append("t_junction")
			branch_sides.append(_safest_branch_side(chosen_intersection))
		elif feature == 1:
			intersection_types.append("four_way")
			branch_sides.append(0)
		elif feature == 2:
			intersection_types.append("roundabout")
			branch_sides.append(_safest_branch_side(chosen_intersection))
		else:
			intersection_types.append("t_junction")
			branch_sides.append(_safest_branch_side(chosen_intersection))

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
			+ across * float(candidate_side) * cross_street_length * 0.5
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
					+ previous_across * previous_side * cross_street_length * 0.5
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
	var min_radius := maxf(widest_road * 0.9, 420.0)
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


func build_cross_streets() -> void:
	var container := _get_or_create("CrossStreets", "Node2D")
	_clear_children(container)

	for feature in range(intersection_indices.size()):
		var intersection_index := intersection_indices[feature]
		if intersection_index <= 0 or intersection_index >= center_points.size() - 1:
			continue

		var center := center_points[intersection_index]
		var tangent := (
			center_points[intersection_index + 1]
			- center_points[intersection_index - 1]
		).normalized()
		var across := Vector2(-tangent.y, tangent.x)
		var half_length := cross_street_length * 0.5
		var half_width := cross_street_width * 0.5
		var main_half_width: float = road_widths[intersection_index] * 0.5

		for direction in _branch_directions(feature):
			var endpoint: Vector2 = center + across * half_length * direction
			var polygon := Polygon2D.new()
			polygon.color = Color(0.115, 0.115, 0.115)
			polygon.polygon = PackedVector2Array([
				center - tangent * half_width,
				endpoint - tangent * half_width,
				endpoint + tangent * half_width,
				center + tangent * half_width
			])
			container.add_child(polygon)

			# Cross-street centerlines stop at the junction instead of cutting through
			# the intersection conflict area.
			var markings := Line2D.new()
			markings.width = line_width
			markings.default_color = Color(0.95, 0.72, 0.12)
			markings.add_point(endpoint)
			markings.add_point(center + across * (main_half_width + 18.0) * direction)
			container.add_child(markings)

			var outward := across * direction
			var wall_endpoint := endpoint
			if intersection_types[feature] == "roundabout":
				wall_endpoint -= outward * cross_street_width * 0.92 * 0.72
			_build_branch_walls(
				container, center, wall_endpoint, tangent, outward,
				half_width, main_half_width
			)

			if intersection_types[feature] == "roundabout":
				_build_roundabout(container, endpoint, outward, tangent)
			else:
				_build_cul_de_sac(container, endpoint, outward, tangent)


func _branch_directions(feature: int) -> Array[float]:
	if feature < 0 or feature >= branch_sides.size() or branch_sides[feature] == 0:
		return [-1.0, 1.0]
	return [float(branch_sides[feature])]


func _build_branch_walls(
	container: Node,
	center: Vector2,
	endpoint: Vector2,
	tangent: Vector2,
	outward: Vector2,
	half_width: float,
	main_half_width: float
) -> void:
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 2
	container.add_child(body)
	var opening := main_half_width + 20.0

	for side in [-1.0, 1.0]:
		var start: Vector2 = center + outward * opening + tangent * half_width * side
		var end: Vector2 = endpoint + tangent * half_width * side
		_add_wall_segment(body, start, end)


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
	body.collision_layer = 1
	body.collision_mask = 2
	container.add_child(body)
	_add_round_boundary(body, center, radius, outward, tangent, true)


func _build_roundabout(
	container: Node,
	center: Vector2,
	outward: Vector2,
	tangent: Vector2
) -> void:
	var outer_radius := cross_street_width * 0.92
	var island_radius := cross_street_width * 0.34
	var apron := Polygon2D.new()
	apron.color = Color(0.115, 0.115, 0.115)
	apron.polygon = _circle_points(center, outer_radius, 32)
	container.add_child(apron)

	# Two compact one-lane exits turn the terminal circle into a true
	# three-arm roundabout instead of a decorative turning bulb.
	for exit_side in [-1.0, 1.0]:
		var exit_direction: Vector2 = tangent * exit_side
		var exit_end := center + exit_direction * 300.0
		var half_width := cross_street_width * 0.5
		var spur := Polygon2D.new()
		spur.color = Color(0.115, 0.115, 0.115)
		spur.polygon = PackedVector2Array([
			center - outward * half_width,
			exit_end - outward * half_width,
			exit_end + outward * half_width,
			center + outward * half_width
		])
		container.add_child(spur)
		var center_line := Line2D.new()
		center_line.width = line_width
		center_line.default_color = Color(0.95, 0.72, 0.12)
		center_line.add_point(center + exit_direction * island_radius)
		center_line.add_point(exit_end)
		container.add_child(center_line)
		var spur_body := StaticBody2D.new()
		spur_body.collision_layer = 1
		spur_body.collision_mask = 2
		container.add_child(spur_body)
		for wall_side in [-1.0, 1.0]:
			_add_wall_segment(
				spur_body,
				center + exit_direction * outer_radius * 0.72 + outward * half_width * wall_side,
				exit_end + outward * half_width * wall_side
			)
		_build_cul_de_sac(container, exit_end, exit_direction, outward)

	var island := Polygon2D.new()
	island.color = Color(0.16, 0.34, 0.16)
	island.polygon = _circle_points(center, island_radius, 24)
	container.add_child(island)

	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 2
	container.add_child(body)
	_add_round_boundary_openings(
		body,
		center,
		outer_radius,
		[-outward, tangent, -tangent]
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
			if middle.dot(opening) > 0.72:
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
	var edge_color := Color(0.92, 0.92, 0.92)
	if not show_debug_boundaries:
		return

	# Separate pieces leave a clean opening at every junction. A single Line2D
	# used to draw a white stroke straight across side roads.
	for i in range(left_points.size() - 1):
		if _segment_is_intersection_opening(i):
			continue
		for points in [left_points, right_points]:
			var edge := Line2D.new()
			edge.width = 5.0
			edge.default_color = edge_color
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
