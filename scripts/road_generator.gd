extends Node2D

# ============================================================
# ROAD
# ============================================================

@export_category("Road")

@export var road_width: float = 200.0
@export var road_length: float = 4000.0
@export var segment_length: float = 60.0


# ============================================================
# CURVATURE
# ============================================================

@export_category("Curvature")

## Maximum heading change per segment (degrees). Automatically limited so the
## inner edge of the road can never fold over itself.
@export_range(1.0, 45.0, 1.0) var max_turn_angle: float = 12.0

## How quickly steering follows its target (0 = never, 1 = instantly).
@export_range(0.01, 1.0, 0.01) var turn_smoothing: float = 0.25

## Maximum heading (degrees) away from the starting direction.
@export var max_total_turn: float = 90.0

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


func generate_road() -> void:
	clear_generated_content()

	setup_rng()

	generate_centerline()
	generate_boundaries()

	route.build(center_points)

	build_road_polygon()
	build_lane_markings()
	build_boundary_visuals()
	build_debug_centerline()
	build_collisions()

	road_regenerated.emit()


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


# ============================================================
# ANGLE GENERATION
# ============================================================

## Largest heading change per segment that still keeps the inner road edge
## valid (the turning radius must stay larger than the road's half width).
func get_max_turn_per_segment() -> float:
	var min_radius := maxf(road_width * 0.75, 1.0)
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

		steer_hold = rng.randi_range(4, 10)

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
	return maxf(minimum_segment_distance, road_width + boundary_thickness)


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

	var half_width := road_width * 0.5

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

	if left_points.size() < 2:
		road.polygon = PackedVector2Array()
		return

	var polygon := PackedVector2Array()

	# Left side
	for point in left_points:
		polygon.append(point)

	# Right side reversed
	for i in range(right_points.size() - 1, -1, -1):
		polygon.append(right_points[i])

	road.polygon = polygon
	road.color = Color(0.12, 0.12, 0.12)


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


func _make_dash(from: Vector2, to: Vector2) -> Line2D:
	var line := Line2D.new()

	line.width = line_width
	line.default_color = Color.WHITE
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

	for point in left_points:
		left_line.add_point(point)

	for point in right_points:
		right_line.add_point(point)

	var edge_color := Color(1.0, 0.85, 0.1)

	left_line.width = 5.0
	right_line.width = 5.0

	left_line.default_color = edge_color
	right_line.default_color = edge_color

	left_line.visible = show_debug_boundaries
	right_line.visible = show_debug_boundaries


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