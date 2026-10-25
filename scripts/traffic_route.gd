extends RoutePath
## Lane-aware NPC routes: prepare a single safe turning lane before a corner,
## and move its target away from the inside curb through the curved junction.
var corners: Array[Dictionary] = []

func build_traffic(rounded: Dictionary, original: PackedVector2Array, nominal_lane_width: float) -> void:
	build(rounded["points"], rounded["half_widths"], rounded["lane_profile"], nominal_lane_width)
	corners.clear()
	for index in range(1, original.size() - 1):
		var angle := (original[index] - original[index - 1]).angle_to(original[index + 1] - original[index])
		if absf(angle) >= deg_to_rad(32.0) and absf(angle) < deg_to_rad(150.0):
			corners.append({"progress": float(nearest(original[index])["progress"]), "offset": -signf(angle) * 15.0})

func get_lane_profile_at(distance: float) -> float:
	var profile := super.get_lane_profile_at(distance)
	for corner in corners:
		var separation := absf(distance - float(corner["progress"]))
		var weight := smoothstep(160.0, 500.0, separation)
		profile = minf(profile, lerpf(1.0, profile, weight))
	return profile

func get_npc_lane_offset(distance: float, lane: int, direction: float) -> float:
	var offset := super.get_lane_offset_at(distance, lane, direction)
	var safe_offset := maxf(0.0, get_half_width_at(distance) - 45.0)
	offset = clampf(offset, -safe_offset, safe_offset)
	for corner in corners:
		var separation := absf(distance - float(corner["progress"]))
		var weight := 1.0 - smoothstep(120.0, 400.0, separation)
		offset = lerpf(offset, float(corner["offset"]) * direction, weight)
	return offset

func get_lane_offset_at(distance: float, lane: int, direction: float) -> float:
	return get_npc_lane_offset(distance, lane, direction)
