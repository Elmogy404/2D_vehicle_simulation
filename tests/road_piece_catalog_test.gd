extends SceneTree

const EXPECTED := {
	"straight_2_lane": {"ports": [2, 2], "signals": 0, "crosswalks": 0},
	"straight_2_lane_crosswalk": {"ports": [2, 2], "signals": 2, "crosswalks": 1},
	"straight_4_lane": {"ports": [4, 4], "signals": 0, "crosswalks": 0},
	"straight_4_lane_crosswalk": {"ports": [4, 4], "signals": 2, "crosswalks": 1},
	"straight_6_lane": {"ports": [6, 6], "signals": 0, "crosswalks": 0},
	"turn_left": {"ports": [2, 2], "signals": 0, "crosswalks": 0},
	"turn_right": {"ports": [2, 2], "signals": 0, "crosswalks": 0},
	"t_junction": {"ports": [4, 4, 2], "signals": 3, "crosswalks": 3},
	"t_junction_2_lane": {"ports": [2, 2, 2], "signals": 3, "crosswalks": 3},
	"four_way_intersection": {"ports": [4, 4, 4, 4], "signals": 4, "crosswalks": 4},
	"four_way_intersection_2_lane": {"ports": [2, 2, 2, 2], "signals": 4, "crosswalks": 4},
	"u_turn_dead_end_bulb": {"ports": [2], "signals": 0, "crosswalks": 0},
	"bulb_3_road_junction": {"ports": [2, 2, 2], "signals": 0, "crosswalks": 3},
	"bulb_4_road_junction": {"ports": [2, 2, 2, 2], "signals": 0, "crosswalks": 4},
	"lane_transition_6_to_4": {"ports": [6, 4], "signals": 0, "crosswalks": 0},
	"lane_transition_4_to_2": {"ports": [4, 2], "signals": 0, "crosswalks": 0}
}

var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	for piece_id in EXPECTED:
		var path := "res://scenes/road_pieces/%s.tscn" % piece_id
		var packed := load(path) as PackedScene
		_check(packed != null, "%s scene loads" % piece_id)
		if packed == null:
			continue
		var piece := packed.instantiate() as Node2D
		_check(piece != null, "%s instantiates as Node2D" % piece_id)
		if piece == null:
			continue
		var ports: Array[Dictionary] = piece.call("get_ports")
		var signals: Array[Dictionary] = piece.call("get_signal_anchors")
		var crosswalks: Array[Dictionary] = piece.call("get_crosswalks")
		var paths: Array[Dictionary] = piece.call("get_drive_paths")
		var road_edges: Array[PackedVector2Array] = piece.call("get_road_edge_paths")
		_check(String(piece.get("piece_id")) == piece_id, "%s scene ID matches" % piece_id)
		var expected_lanes: Array = EXPECTED[piece_id]["ports"]
		_check(ports.size() == expected_lanes.size(), "%s has expected port count" % piece_id)
		_check(signals.size() == EXPECTED[piece_id]["signals"], "%s has expected signal anchors" % piece_id)
		_check(crosswalks.size() == EXPECTED[piece_id]["crosswalks"], "%s has expected crosswalks" % piece_id)
		_check(not paths.is_empty(), "%s defines at least one drive path" % piece_id)
		_check(not road_edges.is_empty(), "%s defines its physical road borders" % piece_id)
		for edge in road_edges:
			_check(edge.size() >= 2, "%s road border has at least two points" % piece_id)
		var port_ids := {}
		for port_index in range(ports.size()):
			var port: Dictionary = ports[port_index]
			var id := String(port["id"])
			_check(not port_ids.has(id), "%s port IDs are unique" % piece_id)
			port_ids[id] = true
			var outward: Vector2 = port["outward"]
			_check(is_equal_approx(outward.length(), 1.0), "%s port %s has normalized outward vector" % [piece_id, id])
			_check(float(port["lane_width"]) == 90.0, "%s port %s uses agreed lane width" % [piece_id, id])
			_check(int(port["total_lanes"]) == int(expected_lanes[port_index]), "%s port %s declares expected total lane count" % [piece_id, id])
		if ["t_junction", "t_junction_2_lane", "four_way_intersection", "four_way_intersection_2_lane"].has(piece_id):
			var drawn_arms: Dictionary = piece.call("get_junction_arms")
			var drawn_directions: Array = drawn_arms.keys()
			var socket_directions: Array[String] = []
			for port in ports:
				socket_directions.append(String(port["id"]))
			drawn_directions.sort()
			socket_directions.sort()
			_check(drawn_directions == socket_directions,
				"%s rendered arms match its road sockets exactly" % piece_id)
			for port in ports:
				_check(int(drawn_arms[String(port["id"])]) == int(port["total_lanes"]),
					"%s rendered arm lane count matches its socket" % piece_id)
		for crosswalk in crosswalks:
			var expected_crosswalk_width := float(ports[0]["total_lanes"]) * 90.0
			if crosswalk.has("port_id"):
				var port: Dictionary = piece.call("_port_by_id", String(crosswalk["port_id"]))
				expected_crosswalk_width = float(port["total_lanes"]) * 90.0
			_check(is_equal_approx(float(crosswalk["width"]), expected_crosswalk_width), "%s crosswalk width follows its road" % piece_id)
		for route in paths:
			var points: PackedVector2Array = route["points"]
			_check(points.size() >= 2, "%s drive route has at least two points" % piece_id)
		if piece_id == "turn_left" or piece_id == "turn_right":
			var turn_points: PackedVector2Array = paths[0]["points"]
			_check(turn_points[0].is_equal_approx(ports[0]["position"]), "%s turn starts exactly at its first socket" % piece_id)
			_check(turn_points[-1].is_equal_approx(ports[1]["position"]), "%s turn completes to its second socket" % piece_id)
			_check(turn_points.size() >= 30, "%s turn includes the complete curved quarter and tangent approaches" % piece_id)
			var incoming_tangent := (turn_points[1] - turn_points[0]).normalized()
			var outgoing_tangent := (turn_points[-1] - turn_points[-2]).normalized()
			_check(incoming_tangent.dot(-Vector2(ports[0]["outward"])) > 0.99, "%s enters tangent to its approach road" % piece_id)
			_check(outgoing_tangent.dot(Vector2(ports[1]["outward"])) > 0.99, "%s exits tangent to its side road" % piece_id)
			_check(absf(Vector2(ports[0]["outward"]).dot(Vector2(ports[1]["outward"]))) < 0.01, "%s connects perpendicular sockets for a full 90-degree turn" % piece_id)
		if piece_id == "straight_2_lane_crosswalk" or piece_id == "straight_4_lane_crosswalk":
			var center_crosswalk: Dictionary = crosswalks[0]
			_check(String(center_crosswalk["id"]) == "center_crosswalk", "%s names its centered crosswalk" % piece_id)
			_check(Vector2(center_crosswalk["center"]).is_zero_approx(), "%s crosswalk is fixed at the piece center" % piece_id)
			_check(is_equal_approx(float(center_crosswalk["depth"]), 48.0), "%s crosswalk has the authored depth" % piece_id)
			var anchored_ports := {}
			for anchor in signals:
				var port_id := String(anchor["port_id"])
				anchored_ports[port_id] = true
				_check(String(anchor["crosswalk_id"]) == "center_crosswalk", "%s signal anchor references its crosswalk" % piece_id)
				var incoming: Vector2 = anchor["incoming_direction"]
				var stop_line: Vector2 = anchor["stop_line_center"]
				_check(is_equal_approx(stop_line.dot(incoming), -75.0), "%s stop line is a fixed distance before the crosswalk" % piece_id)
				var light_anchor: Vector2 = anchor["light_anchor"]
				_check(absf(light_anchor.x) > float(ports[0]["total_lanes"]) * 45.0, "%s light anchor sits beside the road edge" % piece_id)
			_check(anchored_ports.size() == 2 and anchored_ports.has("north") and anchored_ports.has("south"), "%s has one stable signal anchor per approach" % piece_id)
		piece.free()
	_check_junction_outer_curbs("t_junction", 5)
	_check_junction_outer_curbs("t_junction_2_lane", 5)
	_check_junction_outer_curbs("four_way_intersection", 8)
	_check_junction_outer_curbs("four_way_intersection_2_lane", 8)
	if _failures.is_empty():
		print("ROAD PIECE CATALOG TEST PASSED: %d modular pieces validated." % EXPECTED.size())
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _check_junction_outer_curbs(piece_id: String, expected_segments: int) -> void:
	var packed := load("res://scenes/road_pieces/%s.tscn" % piece_id) as PackedScene
	if packed == null:
		_check(false, "%s outer curb clipping scene loads" % piece_id)
		return
	var piece := packed.instantiate() as Node2D
	var arms: Dictionary = piece.call("get_junction_arms")
	var curb_segments: Array[PackedVector2Array] = piece.call("_get_junction_outer_curb_segments", arms)
	var vertical_outer := float(maxi(int(arms.get("north", 0)), int(arms.get("south", 0)))) * 45.0 + 28.0
	var horizontal_outer := float(maxi(int(arms.get("east", 0)), int(arms.get("west", 0)))) * 45.0 + 28.0
	var clipped := true
	for segment in curb_segments:
		if segment.size() != 2:
			clipped = false
			continue
		var start := segment[0]
		var finish := segment[1]
		if absf(start.x - finish.x) < 0.001:
			var horizontal_side_arm := "west" if start.x < 0.0 else "east"
			if int(arms.get(horizontal_side_arm, 0)) > 0:
				clipped = clipped and minf(absf(start.y), absf(finish.y)) >= horizontal_outer - 0.01
		else:
			var vertical_side_arm := "north" if start.y < 0.0 else "south"
			if int(arms.get(vertical_side_arm, 0)) > 0:
				clipped = clipped and minf(absf(start.x), absf(finish.x)) >= vertical_outer - 0.01
	_check(curb_segments.size() == expected_segments,
		"%s outer curb is split into the expected visible perimeter pieces" % piece_id)
	_check(clipped,
		"%s outer curb stops at each perpendicular street opening" % piece_id)
	piece.free()


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
