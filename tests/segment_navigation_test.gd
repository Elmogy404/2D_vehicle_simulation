extends SceneTree

const GENERATOR = preload("res://scripts/segment_road_generator.gd")
const PIECE = preload("res://scripts/road_piece.gd")
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		printerr(message)

func _run() -> void:
	var generator := GENERATOR.new()
	for id in ["turn_left", "turn_right"]:
		var piece := PIECE.new()
		piece.piece_id = id
		var original: PackedVector2Array = piece.get_drive_paths()[0]["points"]
		var sampled: Dictionary = generator._sample_simulation_path(original, 2, 2)
		var points: PackedVector2Array = sampled["points"]
		for point in original:
			check(points.has(point), "%s lost an authored curve point" % id)
		var network := RoadNetwork.new()
		network.build([points], [sampled["half_widths"]], [sampled["lane_profile"]])
		var planned := network.find_path(points[0], points[-1])
		check(planned.size() == points.size(), "%s navigation shortcut" % id)
		check(generator._polyline_length(planned) > points[0].distance_to(points[-1]) + 200.0,
			"%s was flattened into a chord" % id)
		piece.free()
	for id in ["bulb_3_road_junction", "bulb_4_road_junction"]:
		var piece := PIECE.new()
		piece.piece_id = id
		var paths: Array[PackedVector2Array] = []
		var one_way := PackedByteArray()
		for drive_path in piece.get_drive_paths():
			var sampled: Dictionary = generator._sample_simulation_path(drive_path["points"], 2, 2)
			paths.append(sampled["points"])
			one_way.append(1 if drive_path.get("one_way", false) else 0)
		var network := RoadNetwork.new()
		network.build(paths, [], [], PackedStringArray(), one_way)
		check(network.graph_is_connected(), "%s ring is disconnected" % id)
		var ports: Array[Dictionary] = piece.get_ports()
		for from_port in ports:
			for to_port in ports:
				if from_port["id"] == to_port["id"]:
					continue
				var planned := network.find_path(from_port["position"], to_port["position"])
				check(planned.size() > 3, "%s has no circulating route" % id)
				for index in range(planned.size() - 1):
					var midpoint := (planned[index] + planned[index + 1]) * 0.5
					check(midpoint.length() >= 200.0, "%s route crosses island" % id)
					if planned[index].length() < 211.0 and planned[index + 1].length() < 211.0:
						check(planned[index].cross(planned[index + 1]) < 0.0, "ring permits wrong-way circulation")
		piece.free()
	var straight := generator._sample_simulation_path(PackedVector2Array([Vector2.ZERO, Vector2(5000, 0)]), 4, 2)
	check(straight["points"].size() == 5, "long straights retain bounded sampling")
	check(is_equal_approx(straight["half_widths"][0], 180.0) and is_equal_approx(straight["half_widths"][-1], 90.0),
		"lane-transition endpoint widths changed")
	generator.free()
	print("SEGMENT NAVIGATION: failures=", failures)
	quit(1 if failures else 0)
