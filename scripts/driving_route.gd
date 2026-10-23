extends RoutePath
## A car-sized, rounded reference path derived from the street graph. The
## original street polyline remains available for pavement/width queries.

var street := RoutePath.new()
var turn_starts := PackedFloat64Array()
var turn_ends := PackedFloat64Array()
var turn_ranges: Array[Vector2] = []
var curve_ranges: Array[Vector2] = []
var curve_offsets := PackedFloat32Array()
var failure_reason := ""
var usable_start := 0.0
var usable_end := 0.0
var offset_samples := PackedFloat32Array()


func build_from_graph(graph_points: PackedVector2Array, widths: PackedFloat32Array, nominal_lane_width: float, minimum_radius: float) -> bool:
	turn_starts.clear()
	turn_ends.clear()
	turn_ranges.clear()
	curve_ranges.clear()
	curve_offsets.clear()
	failure_reason = ""
	offset_samples.clear()
	var original: Array[Vector2] = []
	for point in graph_points:
		original.append(point)
	if original.size() < 2:
		return false
	# Route endpoints are sampled graph nodes, often only 60 units from a
	# junction. They are not physical road ends. Extend the construction
	# tangents so an unused endpoint stub cannot force an artificial tiny
	# turning radius. Spawn/goal selection stays inside the original interval.
	original[0] -= (original[1] - original[0]).normalized() * 400.0
	original[-1] += (original[-1] - original[-2]).normalized() * 400.0
	street.build(original, widths, PackedFloat32Array(), nominal_lane_width)
	street.direction_blend_distance = 0.0
	if not street.is_valid():
		return false
	# Remove straight intermediate graph nodes before choosing turn setbacks.
	var vertices: Array[int] = [0]
	for i in range(1, original.size() - 1):
		var before := original[i] - original[i - 1]
		var after := original[i + 1] - original[i]
		if absf(before.angle_to(after)) > deg_to_rad(0.5):
			vertices.append(i)
	vertices.append(original.size() - 1)
	# Dense arterial samples immediately beside a junction must not act as
	# another hard corner and limit the junction's turning setback to 30 units.
	var changed := true
	while changed:
		changed = false
		for j in range(1, vertices.size() - 1):
			var pivot := original[vertices[j]]
			var angle := (pivot - original[vertices[j - 1]]).angle_to(original[vertices[j + 1]] - pivot)
			if absf(angle) < deg_to_rad(32.0):
				continue
			for neighbor in [j - 1, j + 1]:
				if neighbor <= 0 or neighbor >= vertices.size() - 1:
					continue
				var point := original[vertices[neighbor]]
				var small_angle := (point - original[vertices[neighbor - 1]]).angle_to(original[vertices[neighbor + 1]] - point)
				if absf(small_angle) < deg_to_rad(15.0) and point.distance_to(pivot) < minimum_radius * 2.0:
					vertices.remove_at(neighbor)
					changed = true
					break
			if changed:
				break
	var rounded: Array[Vector2] = [original[0]]
	var rounded_widths := PackedFloat32Array([widths[0]])
	var sharp_intervals: Array[Vector2i] = []
	var curve_intervals: Array[Vector2i] = []
	var curve_targets := PackedFloat32Array()
	for j in range(1, vertices.size() - 1):
		var i := vertices[j]
		var corner := original[i]
		var incoming := corner - original[vertices[j - 1]]
		var outgoing := original[vertices[j + 1]] - corner
		var before := incoming.normalized()
		var after := outgoing.normalized()
		var angle := before.angle_to(after)
		if absf(angle) >= deg_to_rad(150.0):
			return false
		var radius := maxf(160.0, minimum_radius * 1.15)
		var tangent_factor := tan(absf(angle) * 0.5)
		var setback := radius * tangent_factor
		var previous_setback := 0.0
		var next_setback := 0.0
		if j > 1:
			var prior_direction := original[vertices[j - 1]] - original[vertices[j - 2]]
			previous_setback = radius * tan(absf(prior_direction.angle_to(incoming)) * 0.5)
		if j < vertices.size() - 2:
			var following_direction := original[vertices[j + 2]] - original[vertices[j + 1]]
			next_setback = radius * tan(absf(outgoing.angle_to(following_direction)) * 0.5)
		setback *= minf(1.0, minf(incoming.length() * 0.95 / maxf(setback + previous_setback, 0.001), outgoing.length() * 0.95 / maxf(setback + next_setback, 0.001)))
		radius = setback / maxf(tangent_factor, 0.00001)
		# A visually connected edge is not necessarily steerable by this car.
		if radius < minimum_radius * 1.02:
			failure_reason = "radius %.1f angle %.1f edges %.1f/%.1f" % [radius, rad_to_deg(angle), incoming.length(), outgoing.length()]
			return false
		var entry := corner - before * setback
		_append_line(rounded, rounded_widths, entry, street.get_half_width_at(street.cumulative[i] - setback))
		var entry_index := rounded.size() - 1
		var side := signf(angle)
		var center := entry + Vector2(-before.y, before.x) * side * radius
		var radial := entry - center
		var samples := maxi(2, ceili(radius * absf(angle) / 8.0))
		for sample in range(1, samples + 1):
			var weight := float(sample) / float(samples)
			rounded.append(center + radial.rotated(angle * weight))
			rounded_widths.append(street.get_half_width_at(street.cumulative[i] + lerpf(-setback, setback, weight)))
		if absf(angle) >= deg_to_rad(32.0):
			sharp_intervals.append(Vector2i(entry_index, rounded.size() - 1))
		curve_intervals.append(Vector2i(entry_index, rounded.size() - 1))
		curve_targets.append(-signf(angle) * 15.0 if absf(angle) >= deg_to_rad(32.0) else 0.0)
	_append_line(rounded, rounded_widths, original[-1], widths[-1])
	build(rounded, rounded_widths, PackedFloat32Array(), nominal_lane_width)
	usable_start = 400.0
	usable_end = length - 400.0
	for interval in curve_intervals:
		curve_ranges.append(Vector2(cumulative[interval.x], cumulative[interval.y]))
	curve_offsets = curve_targets
	for interval in sharp_intervals:
		turn_starts.append(cumulative[interval.x])
		turn_ends.append(cumulative[interval.y])
		turn_ranges.append(Vector2(cumulative[interval.x], cumulative[interval.y]))
	for progress in cumulative:
		offset_samples.append(_compute_driving_offset(progress))
	return is_valid()


func _append_line(output: Array[Vector2], output_widths: PackedFloat32Array, endpoint: Vector2, endpoint_width: float) -> void:
	var origin := output[-1]
	var origin_width := output_widths[-1]
	var samples := maxi(1, ceili(origin.distance_to(endpoint) / 15.0))
	for sample in range(1, samples + 1):
		var weight := float(sample) / float(samples)
		output.append(origin.lerp(endpoint, weight))
		output_widths.append(lerpf(origin_width, endpoint_width, weight))


func get_driving_offset(progress: float) -> float:
	if offset_samples.size() == points.size() and is_valid():
		var segment := _segment_for(progress)
		return lerpf(offset_samples[segment], offset_samples[segment + 1], _segment_t(segment, clampf(progress, 0.0, length)))
	return _compute_driving_offset(progress)


func _compute_driving_offset(progress: float) -> float:
	# A nominal half-lane offset leaves only 40 units on an 80-unit half
	# street, less than the 31-unit half body plus the 10-unit spawn margin.
	var nominal := minf(35.0, minf(lane_width * 0.5, maxf(0.0, get_half_width_at(progress) - 45.0)))
	var weight_product := 1.0
	var target_sum := 0.0
	var target_weight := 0.0
	for i in range(curve_ranges.size()):
		var interval := curve_ranges[i]
		var separation := maxf(interval.x - progress, progress - interval.y)
		var weight := clampf(separation / 240.0, 0.0, 1.0)
		weight = weight * weight * (3.0 - 2.0 * weight)
		weight_product *= weight
		target_sum += curve_offsets[i] * (1.0 - weight)
		target_weight += 1.0 - weight
	if target_weight <= 0.00001:
		return nominal
	return lerpf(target_sum / target_weight, nominal, weight_product)


func get_driving_direction(progress: float) -> Vector2:
	var first := clampf(progress - 2.0, 0.0, length)
	var last := clampf(progress + 2.0, 0.0, length)
	return (get_position_at(last, get_driving_offset(last)) - get_position_at(first, get_driving_offset(first))).normalized()


func get_rotation_at(distance: float) -> float:
	return get_driving_direction(distance).angle() + PI * 0.5


func count_completed_turns(first: float, last: float) -> int:
	var count := 0
	for i in range(turn_starts.size()):
		if turn_starts[i] >= first and turn_ends[i] <= last:
			count += 1
	return count
