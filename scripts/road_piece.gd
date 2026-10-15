@tool
extends Node2D
## Authored, reusable 2D road pieces. These scenes are deliberately separate
## from the live generator: each piece owns its exact ports and junction anchors.

const LANE_WIDTH := 90.0
const SIDEWALK_WIDTH := 28.0
const DASH_LENGTH := 28.0
const DASH_GAP := 28.0
const STRAIGHT_LENGTH := 900.0
const CENTER_CROSSWALK_DEPTH := 48.0
const CENTER_CROSSWALK_STOP_OFFSET := 75.0
const JUNCTION_REACH := 720.0
const BULB_RADIUS := 300.0
const BULB_ISLAND_RADIUS := 120.0
const BULB_SIDEWALK_RADIUS := BULB_RADIUS + SIDEWALK_WIDTH
const BULB_ARM_OVERLAP := 8.0

const ASPHALT := Color("#202122")
const SIDEWALK := Color("#56595a")
const CURB := Color("#b3b8b8")
const WHITE_MARKING := Color(0.91, 0.92, 0.89, 0.9)
const YELLOW_MARKING := Color("#f0bd32")
const CROSSWALK_MARKING := Color(0.96, 0.96, 0.93, 0.76)
const ISLAND_GREEN := Color("#315d38")

@export var piece_id: StringName = &"straight_2_lane"
@export var debug_ports := false

var generated_straight_length := 0.0


func _draw() -> void:
	match String(piece_id):
		"straight_2_lane":
			_draw_straight(_straight_length(), 2)
		"straight_2_lane_crosswalk":
			_draw_straight(_straight_length(), 2)
			_draw_center_crosswalk(2)
		"straight_4_lane":
			_draw_straight(_straight_length(), 4)
		"straight_4_lane_crosswalk":
			_draw_straight(_straight_length(), 4)
			_draw_center_crosswalk(4)
		"straight_6_lane":
			_draw_straight(_straight_length(), 6)
		"turn_right":
			_draw_turn(false)
		"turn_left":
			_draw_turn(true)
		"t_junction", "t_junction_2_lane", "four_way_intersection", "four_way_intersection_2_lane":
			_draw_orthogonal_junction(get_junction_arms())
		"u_turn_dead_end_bulb":
			_draw_dead_end_bulb()
		"bulb_4_road_junction":
			_draw_bulb_junction()
		"bulb_3_road_junction":
			_draw_bulb_junction()
		"lane_transition_6_to_4":
			_draw_lane_transition(6, 4)
		"lane_transition_4_to_2":
			_draw_lane_transition(4, 2)
	if debug_ports:
		_draw_port_debug()


func get_piece_spec() -> Dictionary:
	return {
		"id": String(piece_id),
		"lane_width": LANE_WIDTH,
		"ports": get_ports(),
		"signal_anchors": get_signal_anchors(),
		"crosswalks": get_crosswalks(),
		"drive_paths": get_drive_paths()
	}


func get_junction_arms() -> Dictionary:
	match String(piece_id):
		"t_junction":
			return {"north": 4, "south": 4, "east": 2}
		"t_junction_2_lane":
			return {"north": 2, "south": 2, "east": 2}
		"four_way_intersection":
			return {"north": 4, "south": 4, "east": 4, "west": 4}
		"four_way_intersection_2_lane":
			return {"north": 2, "south": 2, "east": 2, "west": 2}
	return {}


## A socket is at the road's exact centerline endpoint. `outward` points away
## from the piece, so two connected sockets face opposite directions.
func get_ports() -> Array[Dictionary]:
	var ports: Array[Dictionary] = []
	var straight_half_length := _straight_length() * 0.5
	match String(piece_id):
		"straight_2_lane", "straight_2_lane_crosswalk":
			ports = [_port("north", Vector2(0, -straight_half_length), Vector2.UP, 2), _port("south", Vector2(0, straight_half_length), Vector2.DOWN, 2)]
		"straight_4_lane", "straight_4_lane_crosswalk":
			ports = [_port("north", Vector2(0, -straight_half_length), Vector2.UP, 4), _port("south", Vector2(0, straight_half_length), Vector2.DOWN, 4)]
		"straight_6_lane":
			ports = [_port("north", Vector2(0, -straight_half_length), Vector2.UP, 6), _port("south", Vector2(0, straight_half_length), Vector2.DOWN, 6)]
		"turn_right":
			ports = [_port("south", Vector2(0, 720), Vector2.DOWN, 2), _port("east", Vector2(720, 0), Vector2.RIGHT, 2)]
		"turn_left":
			ports = [_port("south", Vector2(0, 720), Vector2.DOWN, 2), _port("west", Vector2(-720, 0), Vector2.LEFT, 2)]
		"t_junction":
			ports = [
				_port("north", Vector2(0, -JUNCTION_REACH), Vector2.UP, 4),
				_port("south", Vector2(0, JUNCTION_REACH), Vector2.DOWN, 4),
				_port("east", Vector2(JUNCTION_REACH, 0), Vector2.RIGHT, 2)
			]
		"t_junction_2_lane":
			ports = [
				_port("north", Vector2(0, -JUNCTION_REACH), Vector2.UP, 2),
				_port("south", Vector2(0, JUNCTION_REACH), Vector2.DOWN, 2),
				_port("east", Vector2(JUNCTION_REACH, 0), Vector2.RIGHT, 2)
			]
		"four_way_intersection":
			ports = [
				_port("north", Vector2(0, -JUNCTION_REACH), Vector2.UP, 4),
				_port("south", Vector2(0, JUNCTION_REACH), Vector2.DOWN, 4),
				_port("east", Vector2(JUNCTION_REACH, 0), Vector2.RIGHT, 4),
				_port("west", Vector2(-JUNCTION_REACH, 0), Vector2.LEFT, 4)
			]
		"four_way_intersection_2_lane":
			ports = [
				_port("north", Vector2(0, -JUNCTION_REACH), Vector2.UP, 2),
				_port("south", Vector2(0, JUNCTION_REACH), Vector2.DOWN, 2),
				_port("east", Vector2(JUNCTION_REACH, 0), Vector2.RIGHT, 2),
				_port("west", Vector2(-JUNCTION_REACH, 0), Vector2.LEFT, 2)
			]
		"u_turn_dead_end_bulb":
			ports = [_port("north", Vector2(0, -650), Vector2.UP, 2)]
		"bulb_4_road_junction":
			ports = [
				_port("north", Vector2(0, -JUNCTION_REACH), Vector2.UP, 2),
				_port("south", Vector2(0, JUNCTION_REACH), Vector2.DOWN, 2),
				_port("east", Vector2(JUNCTION_REACH, 0), Vector2.RIGHT, 2),
				_port("west", Vector2(-JUNCTION_REACH, 0), Vector2.LEFT, 2)
			]
		"bulb_3_road_junction":
			ports = [
				_port("north", Vector2(0, -JUNCTION_REACH), Vector2.UP, 2),
				_port("south", Vector2(0, JUNCTION_REACH), Vector2.DOWN, 2),
				_port("east", Vector2(JUNCTION_REACH, 0), Vector2.RIGHT, 2)
			]
		"lane_transition_6_to_4":
			ports = [_port("north", Vector2(0, -JUNCTION_REACH), Vector2.UP, 6), _port("south", Vector2(0, JUNCTION_REACH), Vector2.DOWN, 4)]
		"lane_transition_4_to_2":
			ports = [_port("north", Vector2(0, -JUNCTION_REACH), Vector2.UP, 4), _port("south", Vector2(0, JUNCTION_REACH), Vector2.DOWN, 2)]
	return ports


## Signal positions are authored relative to approach sockets, never inferred
## from a random centerline offset. A future signal manager can place a head
## using these records and use `stop_line_center` verbatim.
func get_signal_anchors() -> Array[Dictionary]:
	if ["straight_2_lane_crosswalk", "straight_4_lane_crosswalk"].has(String(piece_id)):
		var straight_anchors: Array[Dictionary] = []
		for port in get_ports():
			var incoming: Vector2 = -Vector2(port["outward"])
			var stop_center := -incoming * CENTER_CROSSWALK_STOP_OFFSET
			var perpendicular := Vector2(-incoming.y, incoming.x)
			var half_width := float(port["total_lanes"]) * LANE_WIDTH * 0.5
			straight_anchors.append({
				"port_id": String(port["id"]),
				"crosswalk_id": "center_crosswalk",
				"incoming_direction": incoming,
				"stop_line_center": stop_center,
				"stop_line_direction": perpendicular,
				"light_anchor": stop_center + perpendicular * (half_width + 42.0)
			})
		return straight_anchors
	if not ["t_junction", "t_junction_2_lane", "four_way_intersection", "four_way_intersection_2_lane"].has(String(piece_id)):
		return []
	var anchors: Array[Dictionary] = []
	for port in get_ports():
		var outward: Vector2 = port["outward"]
		var half_width := float(port["total_lanes"]) * LANE_WIDTH * 0.5
		var stop_center: Vector2 = port["position"] - outward * 390.0
		var crosswalk_center: Vector2 = port["position"] - outward * 465.0
		var perpendicular := Vector2(-outward.y, outward.x)
		anchors.append({
			"port_id": String(port["id"]),
			"incoming_direction": -outward,
			"stop_line_center": stop_center,
			"crosswalk_center": crosswalk_center,
			"stop_line_direction": perpendicular,
			"light_anchor": stop_center + perpendicular * (half_width + 42.0)
		})
	return anchors


func get_crosswalks() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if ["straight_2_lane_crosswalk", "straight_4_lane_crosswalk"].has(String(piece_id)):
		return [{
			"id": "center_crosswalk",
			"center": Vector2.ZERO,
			"width": float(get_ports()[0]["total_lanes"]) * LANE_WIDTH,
			"depth": CENTER_CROSSWALK_DEPTH
		}]
	if ["bulb_3_road_junction", "bulb_4_road_junction"].has(String(piece_id)):
		for port in get_ports():
			var outward: Vector2 = port["outward"]
			result.append({
				"port_id": port["id"],
				"center": outward * (BULB_RADIUS + 80.0),
				"width": float(port["total_lanes"]) * LANE_WIDTH,
				"depth": 48.0
			})
		return result
	for anchor in get_signal_anchors():
		result.append({
			"port_id": anchor["port_id"],
			"center": anchor["crosswalk_center"],
			"width": float(_port_by_id(String(anchor["port_id"]))["total_lanes"]) * LANE_WIDTH,
			"depth": 48.0
		})
	return result


## Paths are deliberately local to a piece. Junction paths are arm centerlines;
## the next phase can add turn-specific curves after the asset layout is signed off.
func get_drive_paths() -> Array[Dictionary]:
	var paths: Array[Dictionary] = []
	var ports := get_ports()
	if ["bulb_3_road_junction", "bulb_4_road_junction"].has(String(piece_id)):
		for port in ports:
			paths.append({"from_port": port["id"], "to_port": "bulb", "route_type": "roundabout_approach", "points": PackedVector2Array([port["position"], Vector2.ZERO])})
		return paths
	if ports.size() == 2:
		var first: Dictionary = ports[0]
		var second: Dictionary = ports[1]
		var points := PackedVector2Array()
		if String(piece_id) == "turn_right" or String(piece_id) == "turn_left":
			points = _turn_centerline(String(piece_id) == "turn_left")
		else:
			points = PackedVector2Array([first["position"], second["position"]])
		paths.append({"from_port": first["id"], "to_port": second["id"], "route_type": "through_or_turn", "points": points})
		return paths
	for port in ports:
		var path := PackedVector2Array([Vector2(port["position"]), Vector2.ZERO])
		paths.append({"from_port": port["id"], "to_port": "junction", "route_type": "approach", "points": path})
	return paths


## The exposed asphalt perimeter. Socket ends stay open so adjoining pieces
## share a drivable connection; these paths also drive the physical borders.
func get_road_edge_paths() -> Array[PackedVector2Array]:
	var edges: Array[PackedVector2Array] = []
	var id := String(piece_id)
	if id.begins_with("straight_"):
		var ports := get_ports()
		var half_width := float(ports[0]["total_lanes"]) * LANE_WIDTH * 0.5
		var half_length := _straight_length() * 0.5
		for side: float in [-1.0, 1.0]:
			var x := side * half_width
			edges.append(PackedVector2Array([Vector2(x, -half_length), Vector2(x, half_length)]))
	elif id == "turn_left" or id == "turn_right":
		var centerline := _turn_centerline(id == "turn_left")
		for side: float in [-1.0, 1.0]:
			edges.append(_offset_path(centerline, side * LANE_WIDTH))
	elif ["t_junction", "t_junction_2_lane", "four_way_intersection", "four_way_intersection_2_lane"].has(id):
		edges = _get_junction_road_curb_segments(get_junction_arms())
	elif id == "lane_transition_6_to_4" or id == "lane_transition_4_to_2":
		var start_half := (270.0 if id == "lane_transition_6_to_4" else 180.0)
		var end_half := start_half - LANE_WIDTH
		for side: float in [-1.0, 1.0]:
			edges.append(PackedVector2Array([
				Vector2(side * start_half, -JUNCTION_REACH),
				Vector2(side * end_half, JUNCTION_REACH)
			]))
	elif id == "bulb_3_road_junction" or id == "bulb_4_road_junction":
		var road_half := LANE_WIDTH
		var join_distance := sqrt(BULB_RADIUS * BULB_RADIUS - road_half * road_half)
		var arm_angles: Array[float] = []
		for port in get_ports():
			var outward: Vector2 = port["outward"]
			var across := Vector2(-outward.y, outward.x)
			var position: Vector2 = port["position"]
			arm_angles.append(outward.angle())
			for side: float in [-1.0, 1.0]:
				edges.append(PackedVector2Array([
					position + across * road_half * side,
					outward * join_distance + across * road_half * side
				]))
		edges.append_array(_get_open_circle_curb_paths(BULB_RADIUS, road_half, arm_angles))
	elif id == "u_turn_dead_end_bulb":
		var road_half := LANE_WIDTH
		var bulb_center := Vector2(0.0, 250.0)
		var join_y := bulb_center.y - sqrt(224.0 * 224.0 - road_half * road_half)
		for side: float in [-1.0, 1.0]:
			var x := side * road_half
			edges.append(PackedVector2Array([Vector2(x, -650.0), Vector2(x, join_y)]))
		var opening := asin(road_half / 224.0)
		edges.append(_arc_path(bulb_center, 224.0, -PI * 0.5 + opening, -PI * 0.5 - opening + TAU, 96))
	return edges


func configure_generated_straight(length: float) -> void:
	generated_straight_length = maxf(length, 1.0)
	queue_redraw()


func _straight_length() -> float:
	return generated_straight_length if generated_straight_length > 0.0 else STRAIGHT_LENGTH


func _port(port_id: String, position: Vector2, outward: Vector2, total_lanes: int, flow := "two_way") -> Dictionary:
	return {
		"id": port_id,
		"position": position,
		"outward": outward.normalized(),
		"total_lanes": total_lanes,
		"flow": flow,
		"lane_width": LANE_WIDTH
	}


func _port_by_id(port_id: String) -> Dictionary:
	for port in get_ports():
		if String(port["id"]) == port_id:
			return port
	return {}


func _draw_straight(length: float, total_lanes: int) -> void:
	_draw_vertical_surface(length, total_lanes * LANE_WIDTH)
	var half_length := length * 0.5
	for boundary in range(1, total_lanes):
		var x := (float(boundary) - float(total_lanes) * 0.5) * LANE_WIDTH
		var color := YELLOW_MARKING if is_zero_approx(x) else WHITE_MARKING
		_draw_dashed_line(Vector2(x, -half_length + 22.0), Vector2(x, half_length - 22.0), color, 4.0)


func _draw_center_crosswalk(total_lanes: int) -> void:
	var road_width := float(total_lanes) * LANE_WIDTH
	var half_width := road_width * 0.5
	var half_depth := CENTER_CROSSWALK_DEPTH * 0.5
	# Cover lane dashes inside the zebra so the crossing reads as one clean band.
	draw_rect(Rect2(Vector2(-half_width + 2.0, -half_depth), Vector2(road_width - 4.0, CENTER_CROSSWALK_DEPTH)), ASPHALT)
	for stripe_index in range(12):
		var offset := -half_width + 14.0 + float(stripe_index) * ((road_width - 28.0) / 11.0)
		var stripe_center := Vector2(offset, 0.0)
		draw_line(stripe_center + Vector2(0.0, -20.0), stripe_center + Vector2(0.0, 20.0), CROSSWALK_MARKING, 9.0, true)
	for stop_y in [-CENTER_CROSSWALK_STOP_OFFSET, CENTER_CROSSWALK_STOP_OFFSET]:
		draw_line(Vector2(-half_width, stop_y), Vector2(half_width, stop_y), WHITE_MARKING, 4.0, true)


func _draw_vertical_surface(length: float, road_width: float) -> void:
	var half_length := length * 0.5
	_draw_vertical_surface_between(-half_length, half_length, road_width)


func _draw_vertical_surface_between(top: float, bottom: float, road_width: float, draw_edges := true) -> void:
	var half_road := road_width * 0.5
	var length := bottom - top
	var pavement_width := road_width + SIDEWALK_WIDTH * 2.0
	draw_rect(Rect2(Vector2(-pavement_width * 0.5, top), Vector2(pavement_width, length)), SIDEWALK)
	draw_rect(Rect2(Vector2(-half_road, top), Vector2(road_width, length)), ASPHALT)
	if draw_edges:
		draw_line(Vector2(-half_road, top), Vector2(-half_road, bottom), CURB, 4.0, true)
		draw_line(Vector2(half_road, top), Vector2(half_road, bottom), CURB, 4.0, true)
		draw_line(Vector2(-pavement_width * 0.5, top), Vector2(-pavement_width * 0.5, bottom), CURB.darkened(0.18), 2.0, true)
		draw_line(Vector2(pavement_width * 0.5, top), Vector2(pavement_width * 0.5, bottom), CURB.darkened(0.18), 2.0, true)


func _draw_turn(is_left: bool) -> void:
	var path := _turn_centerline(is_left)
	_draw_road_path(path, 2)


func _turn_centerline(is_left: bool) -> PackedVector2Array:
	var radius := 360.0
	var center := Vector2(radius, radius)
	var start_angle := PI
	var end_angle := PI * 1.5
	if is_left:
		center.x = -radius
		start_angle = 0.0
		end_angle = -PI * 0.5
	# Tangent stubs make each asset a full connector, not only the curved corner.
	var points := PackedVector2Array([Vector2(0, JUNCTION_REACH)])
	for i in range(33):
		var weight := float(i) / 32.0
		var angle := lerpf(start_angle, end_angle, weight)
		points.append(center + Vector2(cos(angle), sin(angle)) * radius)
	points.append(Vector2(-JUNCTION_REACH if is_left else JUNCTION_REACH, 0))
	return points


func _draw_road_path(path: PackedVector2Array, total_lanes: int) -> void:
	var width := float(total_lanes) * LANE_WIDTH
	_draw_ribbon(path, width + SIDEWALK_WIDTH * 2.0, SIDEWALK)
	_draw_ribbon(path, width, ASPHALT)
	for side in [-1.0, 1.0]:
		var edge := _offset_path(path, float(side) * width * 0.5)
		if edge.size() >= 2:
			draw_polyline(edge, CURB, 4.0, true)
	var outer_width := width + SIDEWALK_WIDTH * 2.0
	for side in [-1.0, 1.0]:
		var outer_edge := _offset_path(path, float(side) * outer_width * 0.5)
		if outer_edge.size() >= 2:
			draw_polyline(outer_edge, CURB.darkened(0.18), 2.0, true)
	for boundary in range(1, total_lanes):
		var offset := (float(boundary) - float(total_lanes) * 0.5) * LANE_WIDTH
		var color := YELLOW_MARKING if is_zero_approx(offset) else WHITE_MARKING
		_draw_dashed_path(_offset_path(path, offset), color, 4.0)


func _draw_ribbon(path: PackedVector2Array, width: float, color: Color) -> void:
	if path.size() < 2:
		return
	var left := _offset_path(path, width * 0.5)
	var right := _offset_path(path, -width * 0.5)
	var polygon := PackedVector2Array()
	polygon.append_array(left)
	for i in range(right.size() - 1, -1, -1):
		polygon.append(right[i])
	draw_colored_polygon(polygon, color, PackedVector2Array(), null)


func _offset_path(path: PackedVector2Array, offset: float) -> PackedVector2Array:
	var result := PackedVector2Array()
	for i in range(path.size()):
		var previous_normal := Vector2.ZERO
		var next_normal := Vector2.ZERO
		if i > 0:
			var previous_direction := (path[i] - path[i - 1]).normalized()
			previous_normal = Vector2(-previous_direction.y, previous_direction.x)
		if i + 1 < path.size():
			var next_direction := (path[i + 1] - path[i]).normalized()
			next_normal = Vector2(-next_direction.y, next_direction.x)
		var normal := next_normal if previous_normal == Vector2.ZERO else previous_normal
		var scale := 1.0
		if previous_normal != Vector2.ZERO and next_normal != Vector2.ZERO:
			var miter := previous_normal + next_normal
			if miter.length_squared() > 0.001:
				normal = miter.normalized()
				scale = minf(1.0 / maxf(absf(normal.dot(next_normal)), 0.5), 2.0)
		result.append(path[i] + normal * offset * scale)
	return result


func _draw_dashed_path(path: PackedVector2Array, color: Color, width: float) -> void:
	var travelled := 0.0
	for i in range(path.size() - 1):
		var segment := path[i + 1] - path[i]
		var length := segment.length()
		if length < 0.1:
			continue
		var direction := segment / length
		var cursor := 0.0
		while cursor < length:
			var phase := fposmod(travelled + cursor, DASH_LENGTH + DASH_GAP)
			if phase < DASH_LENGTH:
				var dash_end := minf(cursor + DASH_LENGTH - phase, length)
				draw_line(path[i] + direction * cursor, path[i] + direction * dash_end, color, width, true)
				cursor = dash_end
			else:
				cursor += DASH_LENGTH + DASH_GAP - phase
		travelled += length


func _draw_dashed_line(start: Vector2, finish: Vector2, color: Color, width: float) -> void:
	var segment := finish - start
	var length := segment.length()
	if length < 0.1:
		return
	var direction := segment / length
	var cursor := 0.0
	while cursor < length:
		var dash_end := minf(cursor + DASH_LENGTH, length)
		draw_line(start + direction * cursor, start + direction * dash_end, color, width, true)
		cursor += DASH_LENGTH + DASH_GAP


func _draw_orthogonal_junction(arms: Dictionary) -> void:
	var north_lanes := int(arms.get("north", 0))
	var south_lanes := int(arms.get("south", 0))
	var east_lanes := int(arms.get("east", 0))
	var west_lanes := int(arms.get("west", 0))
	var vertical_lanes := maxi(north_lanes, south_lanes)
	var horizontal_lanes := maxi(east_lanes, west_lanes)
	var vertical_width := float(vertical_lanes) * LANE_WIDTH
	var horizontal_width := float(horizontal_lanes) * LANE_WIDTH
	var vertical_half := vertical_width * 0.5
	var horizontal_half := horizontal_width * 0.5
	var reach := JUNCTION_REACH
	var junction_clearance := maxf(vertical_half, horizontal_half) + 72.0

	# Sidewalk slabs first; asphalt is laid over the junction interior, so their
	# edges never intrude into the drivable union.
	if north_lanes > 0 or south_lanes > 0:
		var pavement_width := vertical_width + SIDEWALK_WIDTH * 2.0
		draw_rect(Rect2(Vector2(-pavement_width * 0.5, -reach), Vector2(pavement_width, reach * 2.0)), SIDEWALK)
	if east_lanes > 0:
		draw_rect(Rect2(Vector2(0, -horizontal_half - SIDEWALK_WIDTH), Vector2(reach, horizontal_width + SIDEWALK_WIDTH * 2.0)), SIDEWALK)
	if west_lanes > 0:
		draw_rect(Rect2(Vector2(-reach, -horizontal_half - SIDEWALK_WIDTH), Vector2(reach, horizontal_width + SIDEWALK_WIDTH * 2.0)), SIDEWALK)

	if north_lanes > 0 or south_lanes > 0:
		draw_rect(Rect2(Vector2(-vertical_half, -reach), Vector2(vertical_width, reach * 2.0)), ASPHALT)
	if east_lanes > 0:
		draw_rect(Rect2(Vector2(0, -horizontal_half), Vector2(reach, horizontal_width)), ASPHALT)
	if west_lanes > 0:
		draw_rect(Rect2(Vector2(-reach, -horizontal_half), Vector2(reach, horizontal_width)), ASPHALT)

	for road_curb in _get_junction_road_curb_segments(arms):
		draw_line(road_curb[0], road_curb[1], CURB, 4.0, true)
	for outer_curb in _get_junction_outer_curb_segments(arms):
		draw_line(outer_curb[0], outer_curb[1], CURB.darkened(0.18), 2.0, true)

	# Lane markings stop before the common junction box. Their termination is
	# derived from the widest arm and is therefore consistent for every socket.
	if north_lanes > 0 or south_lanes > 0:
		for boundary in range(1, vertical_lanes):
			var x := (float(boundary) - float(vertical_lanes) * 0.5) * LANE_WIDTH
			var color := YELLOW_MARKING if is_zero_approx(x) else WHITE_MARKING
			if north_lanes > 0:
				_draw_dashed_line(Vector2(x, -reach + 20.0), Vector2(x, -junction_clearance), color, 4.0)
			if south_lanes > 0:
				_draw_dashed_line(Vector2(x, junction_clearance), Vector2(x, reach - 20.0), color, 4.0)
	if east_lanes > 0 or west_lanes > 0:
		for boundary in range(1, horizontal_lanes):
			var y := (float(boundary) - float(horizontal_lanes) * 0.5) * LANE_WIDTH
			var color := YELLOW_MARKING if is_zero_approx(y) else WHITE_MARKING
			if east_lanes > 0:
				_draw_dashed_line(Vector2(junction_clearance, y), Vector2(reach - 20.0, y), color, 4.0)
			if west_lanes > 0:
				_draw_dashed_line(Vector2(-reach + 20.0, y), Vector2(-junction_clearance, y), color, 4.0)

	for port in get_ports():
		_draw_crosswalk_for_port(port)


func _get_junction_outer_curb_segments(arms: Dictionary) -> Array[PackedVector2Array]:
	return _get_junction_curb_segments(arms, SIDEWALK_WIDTH)


func _get_junction_road_curb_segments(arms: Dictionary) -> Array[PackedVector2Array]:
	return _get_junction_curb_segments(arms, 0.0)


func _get_junction_curb_segments(arms: Dictionary, margin: float) -> Array[PackedVector2Array]:
	var north_lanes := int(arms.get("north", 0))
	var south_lanes := int(arms.get("south", 0))
	var east_lanes := int(arms.get("east", 0))
	var west_lanes := int(arms.get("west", 0))
	var vertical_half := float(maxi(north_lanes, south_lanes)) * LANE_WIDTH * 0.5
	var horizontal_half := float(maxi(east_lanes, west_lanes)) * LANE_WIDTH * 0.5
	var vertical_outer := vertical_half + margin
	var horizontal_outer := horizontal_half + margin
	var result: Array[PackedVector2Array] = []
	if north_lanes > 0 or south_lanes > 0:
		for side: float in [-1.0, 1.0]:
			var x := side * vertical_outer
			var intersecting_arm_exists := west_lanes > 0 if side < 0.0 else east_lanes > 0
			if intersecting_arm_exists:
				result.append(PackedVector2Array([Vector2(x, -JUNCTION_REACH), Vector2(x, -horizontal_outer)]))
				result.append(PackedVector2Array([Vector2(x, horizontal_outer), Vector2(x, JUNCTION_REACH)]))
			else:
				result.append(PackedVector2Array([Vector2(x, -JUNCTION_REACH), Vector2(x, JUNCTION_REACH)]))
	if east_lanes > 0 or west_lanes > 0:
		for side: float in [-1.0, 1.0]:
			var y := side * horizontal_outer
			var intersecting_arm_exists := north_lanes > 0 if side < 0.0 else south_lanes > 0
			var east_start := vertical_outer if intersecting_arm_exists else 0.0
			var west_end := -vertical_outer if intersecting_arm_exists else 0.0
			if east_lanes > 0:
				result.append(PackedVector2Array([Vector2(east_start, y), Vector2(JUNCTION_REACH, y)]))
			if west_lanes > 0:
				result.append(PackedVector2Array([Vector2(-JUNCTION_REACH, y), Vector2(west_end, y)]))
	return result


func _draw_crosswalk_for_port(port: Dictionary) -> void:
	var outward: Vector2 = port["outward"]
	var width := float(port["total_lanes"]) * LANE_WIDTH
	var center: Vector2 = port["position"] - outward * 465.0
	var across := Vector2(-outward.y, outward.x)
	for stripe_index in range(12):
		var offset := -width * 0.5 + 14.0 + float(stripe_index) * ((width - 28.0) / 11.0)
		var stripe_center := center + across * offset
		var start := stripe_center - outward * 20.0
		var finish := stripe_center + outward * 20.0
		draw_line(start, finish, CROSSWALK_MARKING, 9.0, true)
	var stop_center: Vector2 = port["position"] - outward * 390.0
	draw_line(stop_center - across * width * 0.5, stop_center + across * width * 0.5, WHITE_MARKING, 4.0, true)


func _draw_dead_end_bulb() -> void:
	var road_width := 2.0 * LANE_WIDTH
	var port_y := -650.0
	var bulb_center := Vector2(0, 250)
	# Lay down the turnaround first. The entry road overlaps its top edge so the
	# asphalt and sidewalk form one continuous, clean shape at the connection.
	draw_circle(bulb_center, 252.0, SIDEWALK)
	draw_circle(bulb_center, 224.0, ASPHALT)
	_draw_vertical_surface_between(port_y, 48.0, road_width, false)
	draw_circle(bulb_center, 82.0, ISLAND_GREEN)
	for road_edge in get_road_edge_paths():
		draw_polyline(road_edge, CURB, 4.0, true)
	var sidewalk_half := road_width * 0.5 + SIDEWALK_WIDTH
	var sidewalk_join_y := bulb_center.y - sqrt(252.0 * 252.0 - sidewalk_half * sidewalk_half)
	for side: float in [-1.0, 1.0]:
		var x := side * sidewalk_half
		draw_line(Vector2(x, port_y), Vector2(x, sidewalk_join_y), CURB.darkened(0.18), 2.0, true)
	var sidewalk_opening := asin(sidewalk_half / 252.0)
	draw_polyline(_arc_path(bulb_center, 252.0, -PI * 0.5 + sidewalk_opening, -PI * 0.5 - sidewalk_opening + TAU, 96), CURB.darkened(0.18), 2.0, true)
	draw_arc(bulb_center, 82.0, 0.0, TAU, 48, Color("#8eaa72"), 3.0, true)
	# The single centerline enters the bulb and ends at its central island.
	draw_line(Vector2(0, port_y + 25.0), Vector2(0, bulb_center.y - 90.0), YELLOW_MARKING, 4.0, true)


func _draw_bulb_junction() -> void:
	# A circular, un-signalized hub with radial road arms. The arms are drawn
	# over the circles to leave matching openings in both curb rings.
	draw_circle(Vector2.ZERO, BULB_SIDEWALK_RADIUS, SIDEWALK)
	draw_circle(Vector2.ZERO, BULB_RADIUS, ASPHALT)
	var ports := get_ports()
	var road_half := 2.0 * LANE_WIDTH * 0.5
	var pavement_half := road_half + SIDEWALK_WIDTH
	for port in ports:
		_draw_bulb_arm(port, pavement_half, SIDEWALK, BULB_SIDEWALK_RADIUS)
	for port in ports:
		_draw_bulb_arm(port, road_half, ASPHALT, BULB_RADIUS)

	var road_angles: Array[float] = []
	var sidewalk_angles: Array[float] = []
	for port in ports:
		var outward: Vector2 = port["outward"]
		var angle := outward.angle()
		road_angles.append(angle)
		sidewalk_angles.append(angle)
		var across := Vector2(-outward.y, outward.x)
		var position: Vector2 = port["position"]
		# Meet the circular curb at its exact chord endpoint. Using radius itself
		# here leaves a small visible kink/gap because the road edge is offset.
		var road_join_distance := sqrt(BULB_RADIUS * BULB_RADIUS - road_half * road_half)
		var sidewalk_join_distance := sqrt(BULB_SIDEWALK_RADIUS * BULB_SIDEWALK_RADIUS - pavement_half * pavement_half)
		draw_line(position - across * road_half, outward * road_join_distance - across * road_half, CURB, 4.0, true)
		draw_line(position + across * road_half, outward * road_join_distance + across * road_half, CURB, 4.0, true)
		draw_line(position - across * pavement_half, outward * sidewalk_join_distance - across * pavement_half, CURB.darkened(0.18), 2.0, true)
		draw_line(position + across * pavement_half, outward * sidewalk_join_distance + across * pavement_half, CURB.darkened(0.18), 2.0, true)
		_draw_dashed_line(position - outward * 28.0, outward * (BULB_RADIUS + 125.0), YELLOW_MARKING, 4.0)
		_draw_bulb_crosswalk(port)

	_draw_open_circle_curb(BULB_RADIUS, road_half, road_angles, CURB, 4.0)
	_draw_open_circle_curb(BULB_SIDEWALK_RADIUS, pavement_half, sidewalk_angles, CURB.darkened(0.18), 2.0)
	draw_circle(Vector2.ZERO, BULB_ISLAND_RADIUS, ISLAND_GREEN)
	draw_arc(Vector2.ZERO, BULB_ISLAND_RADIUS, 0.0, TAU, 64, Color("#8eaa72"), 3.0, true)


func _draw_bulb_arm(port: Dictionary, half_width: float, color: Color, join_radius: float) -> void:
	var outward: Vector2 = port["outward"]
	var across := Vector2(-outward.y, outward.x)
	# Start each arm before its circle's edge chord, not near the circle's
	# centerline radius. Otherwise the wider parts of the arm leave crescent gaps.
	var join_distance := sqrt(maxf(join_radius * join_radius - half_width * half_width, 0.0))
	var near_hub := outward * maxf(0.0, join_distance - BULB_ARM_OVERLAP)
	var far_end: Vector2 = port["position"]
	var polygon := PackedVector2Array([
		near_hub - across * half_width,
		near_hub + across * half_width,
		far_end + across * half_width,
		far_end - across * half_width
	])
	draw_colored_polygon(polygon, color)


func _draw_bulb_crosswalk(port: Dictionary) -> void:
	var outward: Vector2 = port["outward"]
	var across := Vector2(-outward.y, outward.x)
	var center := outward * (BULB_RADIUS + 80.0)
	var width := float(port["total_lanes"]) * LANE_WIDTH
	for stripe_index in range(10):
		var offset := -width * 0.5 + 12.0 + float(stripe_index) * ((width - 24.0) / 9.0)
		var stripe_center := center + across * offset
		draw_line(stripe_center - outward * 21.0, stripe_center + outward * 21.0, CROSSWALK_MARKING, 8.0, true)


func _draw_open_circle_curb(radius: float, opening_half_width: float, port_angles: Array[float], color: Color, line_width: float) -> void:
	for curb_path in _get_open_circle_curb_paths(radius, opening_half_width, port_angles):
		draw_polyline(curb_path, color, line_width, true)


func _get_open_circle_curb_paths(radius: float, opening_half_width: float, port_angles: Array[float]) -> Array[PackedVector2Array]:
	var paths: Array[PackedVector2Array] = []
	if port_angles.is_empty():
		return paths
	var angles := port_angles.duplicate()
	angles.sort()
	var opening_angle := asin(clampf(opening_half_width / radius, 0.0, 0.95))
	for index in range(angles.size()):
		var start_angle: float = angles[index] + opening_angle
		var next_angle: float = angles[(index + 1) % angles.size()]
		if index == angles.size() - 1:
			next_angle += TAU
		var end_angle := next_angle - opening_angle
		if end_angle > start_angle:
			paths.append(_arc_path(Vector2.ZERO, radius, start_angle, end_angle, 40))
	return paths


func _arc_path(center: Vector2, radius: float, start_angle: float, end_angle: float, steps: int) -> PackedVector2Array:
	var points := PackedVector2Array()
	for index in range(steps + 1):
		var angle := lerpf(start_angle, end_angle, float(index) / float(steps))
		points.append(center + Vector2(cos(angle), sin(angle)) * radius)
	return points


func _draw_lane_transition(from_lanes: int, to_lanes: int) -> void:
	var start_half := float(from_lanes) * LANE_WIDTH * 0.5
	var end_half := float(to_lanes) * LANE_WIDTH * 0.5
	var top := -JUNCTION_REACH
	var bottom := JUNCTION_REACH
	var sidewalk_polygon := PackedVector2Array([
		Vector2(-start_half - SIDEWALK_WIDTH, top), Vector2(start_half + SIDEWALK_WIDTH, top),
		Vector2(end_half + SIDEWALK_WIDTH, bottom), Vector2(-end_half - SIDEWALK_WIDTH, bottom)
	])
	var road_polygon := PackedVector2Array([
		Vector2(-start_half, top), Vector2(start_half, top),
		Vector2(end_half, bottom), Vector2(-end_half, bottom)
	])
	draw_colored_polygon(sidewalk_polygon, SIDEWALK)
	draw_colored_polygon(road_polygon, ASPHALT)

	for side: float in [-1.0, 1.0]:
		draw_line(Vector2(side * start_half, top), Vector2(side * end_half, bottom), CURB, 4.0, true)
		draw_line(Vector2(side * (start_half + SIDEWALK_WIDTH), top), Vector2(side * (end_half + SIDEWALK_WIDTH), bottom), CURB.darkened(0.18), 2.0, true)
		# The dropped outside lane narrows to the curb; the striped wedge makes
		# the lane reduction unambiguous rather than looking like missing asphalt.
		draw_line(Vector2(side * end_half, top + 120.0), Vector2(side * end_half, bottom), WHITE_MARKING, 4.0, true)
		for hatch_index in range(12):
			var y := top + 300.0 + float(hatch_index) * 34.0
			var progress := (y - top) / (bottom - top)
			var half_width := lerpf(start_half, end_half, progress)
			var taper_width := half_width - end_half
			if taper_width > 22.0:
				draw_line(Vector2(side * (end_half + 5.0), y + 12.0), Vector2(side * (half_width - 5.0), y - 12.0), WHITE_MARKING, 3.0, true)

	for boundary in range(1, to_lanes):
		var x := (float(boundary) - float(to_lanes) * 0.5) * LANE_WIDTH
		var color := YELLOW_MARKING if is_zero_approx(x) else WHITE_MARKING
		_draw_dashed_line(Vector2(x, top + 20.0), Vector2(x, bottom - 20.0), color, 4.0)


func _draw_port_debug() -> void:
	for port in get_ports():
		var position: Vector2 = port["position"]
		var outward: Vector2 = port["outward"]
		draw_circle(position, 16.0, Color(0.12, 0.85, 1.0, 0.95))
		draw_line(position, position + outward * 100.0, Color(1.0, 0.25, 0.24), 5.0, true)
