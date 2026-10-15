extends SceneTree

const GENERATOR_SCRIPT := preload("res://scripts/segment_road_generator.gd")
const EGO_SCENE := preload("res://scenes/EgoVehicle.tscn")
const TEST_SEED := 17


func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	var generator := GENERATOR_SCRIPT.new() as Node2D
	generator.set("generate_on_ready", false)
	generator.set("minimum_piece_count", 100)
	generator.set("maximum_piece_count", 150)
	root.add_child(generator)
	generator.call("generate_with_seed", TEST_SEED)
	var walls := generator.get_node_or_null("GeneratedRoadPieces/RoadEdgeCollisions") as StaticBody2D
	var pieces: Array[Dictionary] = generator.get("placed_pieces")
	var junction := _find_piece(pieces, "t_junction")
	var funnel := _find_piece(pieces, "lane_transition_4_to_2")
	var turn := _find_piece(pieces, "turn_left")
	var dead_end := _find_piece(pieces, "u_turn_dead_end_bulb")
	if walls == null or junction == null or funnel == null or turn == null or dead_end == null:
		push_error("The border test seed did not generate all required road-piece types and walls.")
		quit(1)
		return

	await physics_frame
	var space := root.get_world_2d().direct_space_state
	var checked_edges := 0
	var checked_ports := 0
	for piece_data in pieces:
		var piece := piece_data["node"] as Node2D
		var edge_paths: Array[PackedVector2Array] = piece.call("get_road_edge_paths")
		for edge_path in edge_paths:
			for segment_index in range(edge_path.size() - 1):
				var midpoint := piece.to_global((edge_path[segment_index] + edge_path[segment_index + 1]) * 0.5)
				if not _hits_wall(space, midpoint, walls):
					push_error("Missing road wall at %s edge %d." % [piece_data["piece_id"], segment_index])
					quit(1)
					return
				checked_edges += 1
		for port in piece.call("get_ports"):
			var mouth := piece.to_global(port["position"])
			if _hits_wall(space, mouth, walls):
				push_error("Road wall blocks %s port %s." % [piece_data["piece_id"], port["id"]])
				quit(1)
				return
			checked_ports += 1
	var junction_half := 180.0
	var junction_center := junction.to_global(Vector2.ZERO)
	var closed_t_side := junction.to_global(Vector2(-junction_half, 0.0))
	var open_t_port := junction.to_global(Vector2(720.0, 0.0))
	var funnel_side := funnel.to_global(Vector2(135.0, 0.0))
	var turn_edges: Array[PackedVector2Array] = turn.call("get_road_edge_paths")
	var curved_edge: PackedVector2Array = turn_edges[0]
	var turn_side := turn.to_global(curved_edge[curved_edge.size() / 2])
	var bulb_tip := dead_end.to_global(Vector2(0.0, 474.0))
	var borders_collide := _hits_wall(space, closed_t_side, walls) \
		and _hits_wall(space, funnel_side, walls) \
		and _hits_wall(space, turn_side, walls) \
		and _hits_wall(space, bulb_tip, walls)
	var road_mouths_clear := not _hits_wall(space, junction_center, walls) \
		and not _hits_wall(space, open_t_port, walls)
	if not borders_collide or not road_mouths_clear:
		push_error("A junction, funnel, turn, or dead-end border is missing, or an open road mouth is blocked.")
		quit(1)
		return

	var ego := EGO_SCENE.instantiate() as CharacterBody2D
	root.add_child(ego)
	ego.global_position = junction.to_global(Vector2(-junction_half + 80.0, 0.0))
	var outward_direction := Vector2.LEFT.rotated(junction.global_rotation)
	ego.global_rotation = outward_direction.angle() + PI * 0.5
	ego.call("set_control", 1.0, 0.0, 0.0)
	for _frame in range(120):
		await physics_frame
		if bool(ego.get("has_crashed")):
			break
	if not bool(ego.get("has_crashed")) or float(ego.get("crash_speed")) <= 0.0:
		push_error("The player drove into a T-junction border without crashing.")
		quit(1)
		return
	print("SEGMENT ROAD BOUNDARY TEST PASSED: %d edge segments collide, %d road mouths stay clear, and the player crashes on exit." % [checked_edges, checked_ports])
	quit(0)


func _find_piece(pieces: Array[Dictionary], id: String) -> Node2D:
	for piece in pieces:
		if String(piece["piece_id"]) == id:
			return piece["node"] as Node2D
	return null


func _hits_wall(space: PhysicsDirectSpaceState2D, position: Vector2, walls: StaticBody2D) -> bool:
	var circle := CircleShape2D.new()
	circle.radius = 4.0
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = circle
	query.transform = Transform2D(0.0, position)
	query.collision_mask = 1
	query.collide_with_areas = false
	for hit in space.intersect_shape(query, 8):
		if hit.get("collider") == walls:
			return true
	return false
