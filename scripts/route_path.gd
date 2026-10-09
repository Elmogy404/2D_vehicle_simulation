class_name RoutePath
extends RefCounted


# ============================================================
# ROUTE PATH
# ------------------------------------------------------------
# A polyline that can be walked by distance ("progress").
# Port of the Python reference class `Route`.
#
#   get_position_at(progress, lateral_offset)  <- Route.pose()
#   get_rotation_at(progress)                  <- angle from Route.pose()
#   nearest(position, hint, window)            <- Route.nearest()
#
# Conventions (identical to traffic_car.gd / traffic_manager.gd):
#   * rotation 0 = sprite faces UP, rotation = direction.angle() + PI/2
#   * positive lateral offset = right-hand side of the travel
#     direction, normal = Vector2(-direction.y, direction.x)
# ============================================================

const MIN_POINT_DISTANCE: float = 0.001


var points: Array[Vector2] = []

# Distance from the start of the route to every point.
var cumulative: PackedFloat64Array = PackedFloat64Array()

# Smoothed (averaged) direction and normal at every point.
# Interpolating them keeps lane offsets continuous across the
# corners of the polyline (the Python version offsets per
# segment, which is fine for its finely rounded routes but would
# make cars jitter on a 60 unit segment road).
var tangents: PackedVector2Array = PackedVector2Array()
var normals: PackedVector2Array = PackedVector2Array()
var half_widths: PackedFloat32Array = PackedFloat32Array()

var length: float = 0.0


# ============================================================
# BUILD
# ============================================================

func _init(new_points: Array[Vector2] = []) -> void:
	build(new_points)


func build(
	new_points: Array[Vector2],
	new_half_widths: PackedFloat32Array = PackedFloat32Array()
) -> void:
	points.clear()
	cumulative.clear()
	tangents.clear()
	normals.clear()
	half_widths.clear()

	length = 0.0


	for point in new_points:
		if not points.is_empty():
			var step: float = points[points.size() - 1].distance_to(point)

			# Skip duplicate points, they would create
			# zero-length segments.
			if step < MIN_POINT_DISTANCE:
				continue

			length += step

		points.append(point)
		cumulative.append(length)
		var source_index: int = mini(half_widths.size(), new_half_widths.size() - 1)

		if new_half_widths.is_empty():
			half_widths.append(100.0)
		else:
			half_widths.append(new_half_widths[source_index])


	if points.size() < 2:
		return


	for i in range(points.size()):
		var before: Vector2 = Vector2.ZERO
		var after: Vector2 = Vector2.ZERO

		if i > 0:
			before = (points[i] - points[i - 1]).normalized()

		if i < points.size() - 1:
			after = (points[i + 1] - points[i]).normalized()


		var tangent: Vector2 = before + after

		if tangent.length_squared() < 0.0001:
			# Hairpin: both directions cancel out.
			tangent = after if after != Vector2.ZERO else before


		tangent = tangent.normalized()

		tangents.append(tangent)

		normals.append(
			Vector2(
				-tangent.y,
				tangent.x
			)
		)


func is_valid() -> bool:
	return points.size() >= 2 and length > 0.0


# ============================================================
# POSE
# ============================================================

func get_position_at(
	distance: float,
	lateral_offset: float = 0.0
) -> Vector2:
	if not is_valid():
		return Vector2.ZERO


	var clamped: float = clampf(distance, 0.0, length)

	var segment: int = _segment_for(clamped)

	var t: float = _segment_t(segment, clamped)

	var base: Vector2 = points[segment].lerp(
		points[segment + 1],
		t
	)


	if is_zero_approx(lateral_offset):
		return base


	var normal: Vector2 = normals[segment].lerp(
		normals[segment + 1],
		t
	)

	if normal.length_squared() < 0.0001:
		normal = normals[segment]

	return base + normal.normalized() * lateral_offset


func get_direction_at(distance: float) -> Vector2:
	if not is_valid():
		return Vector2.UP


	var clamped: float = clampf(distance, 0.0, length)

	var segment: int = _segment_for(clamped)

	var t: float = _segment_t(segment, clamped)

	var direction: Vector2 = tangents[segment].lerp(
		tangents[segment + 1],
		t
	)

	if direction.length_squared() < 0.0001:
		direction = tangents[segment]

	return direction.normalized()


# Rotation for a node whose sprite faces UP.
func get_rotation_at(distance: float) -> float:
	return get_direction_at(distance).angle() + PI / 2.0


# Left-hand normal of the travel direction at `distance`.
func get_normal_at(distance: float) -> Vector2:
	var direction: Vector2 = get_direction_at(distance)

	return Vector2(
		-direction.y,
		direction.x
	)


func get_half_width_at(distance: float) -> float:
	if not is_valid() or half_widths.size() != points.size():
		return 100.0

	var clamped := clampf(distance, 0.0, length)
	var segment := _segment_for(clamped)
	var t := _segment_t(segment, clamped)
	return lerpf(half_widths[segment], half_widths[segment + 1], t)


# distance → pose in one call.
func get_pose_at(
	distance: float,
	lateral_offset: float = 0.0
) -> Dictionary:
	return {
		"position": get_position_at(distance, lateral_offset),
		"direction": get_direction_at(distance),
		"rotation": get_rotation_at(distance)
	}


# ============================================================
# NEAREST
# ------------------------------------------------------------
# Returns { "distance": lateral distance to the route,
#           "progress": distance along the route }.
#
# hint + window limit the search to the part of the route
# around the vehicle (cheap), omit them to search everything.
# ============================================================

func nearest(
	position: Vector2,
	hint: float = -1.0,
	window: float = -1.0
) -> Dictionary:
	var result: Dictionary = {
		"distance": INF,
		"progress": 0.0
	}

	if not is_valid():
		return result


	var first_segment: int = 0
	var last_segment: int = points.size() - 2

	if hint >= 0.0 and window > 0.0:
		first_segment = _segment_for(hint - window)
		last_segment = _segment_for(hint + window)


	var best_squared: float = INF

	for i in range(first_segment, last_segment + 1):
		var a: Vector2 = points[i]
		var segment_vector: Vector2 = points[i + 1] - a

		var segment_length_squared: float = (
			segment_vector.length_squared()
		)

		var t: float = clampf(
			(position - a).dot(segment_vector)
			/
			segment_length_squared,
			0.0,
			1.0
		)

		var closest: Vector2 = a + segment_vector * t

		var squared: float = position.distance_squared_to(closest)

		if squared < best_squared:
			best_squared = squared

			result["progress"] = (
				cumulative[i]
				+
				t * sqrt(segment_length_squared)
			)


	result["distance"] = sqrt(best_squared)

	return result


# ============================================================
# INTERNAL
# ============================================================

# Index of the segment that contains `distance`
# (segment i runs from points[i] to points[i + 1]).
func _segment_for(distance: float) -> int:
	var index: int = cumulative.bsearch(
		clampf(distance, 0.0, length)
	)

	return clampi(
		index - 1,
		0,
		points.size() - 2
	)


func _segment_t(segment: int, distance: float) -> float:
	var segment_length: float = (
		cumulative[segment + 1]
		-
		cumulative[segment]
	)

	return clampf(
		(distance - cumulative[segment])
		/
		maxf(segment_length, 0.0001),
		0.0,
		1.0
	)
