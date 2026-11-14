extends SceneTree

const GENERATOR_SCRIPT := preload("res://scripts/segment_road_generator.gd")
const TEST_SEEDS: Array[int] = [20261014, 20261015, 20261016, 20261017, 20261018, 20261019, 20261020, 20261021]
const EXPECTED_PIECE_COUNT := 500


func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	var success := true
	var observed_grid_sizes: Dictionary = {}
	for test_seed in TEST_SEEDS:
		var generator := GENERATOR_SCRIPT.new() as Node
		if generator == null:
			push_error("Could not instantiate the segment road generator.")
			success = false
			continue

		generator.set("generate_on_ready", false)
		generator.set("randomize_seed_on_ready", false)
		generator.set("minimum_piece_count", EXPECTED_PIECE_COUNT)
		generator.set("maximum_piece_count", EXPECTED_PIECE_COUNT)
		root.add_child(generator)
		generator.call("generate_with_seed", test_seed)

		var summary: Dictionary = generator.call("get_generation_summary")
		var piece_count := int(summary["piece_count"])
		var open_socket_count := int(summary["open_socket_count"])
		var generation_error := String(summary["error"])
		var grid_size := int(summary["grid_size"])
		var road_network: RoadNetwork = generator.get("road_network")
		observed_grid_sizes[grid_size] = true
		print("500-PIECE PREVIEW CHECK: seed=%d, grid=%dx%d, pieces=%d, connections=%d, open_sockets=%d" % [
			test_seed, grid_size, grid_size, piece_count, int(summary["connection_count"]), open_socket_count
		])
		var seed_success := piece_count == EXPECTED_PIECE_COUNT \
			and open_socket_count == 0 \
			and road_network.graph_is_connected() \
			and generation_error.is_empty()
		if not seed_success:
			push_error("500-piece generation failed for seed %d: count=%d, open_sockets=%d, error='%s'." % [
				test_seed, piece_count, open_socket_count, generation_error
			])
			success = false
		generator.free()
	if observed_grid_sizes.size() < 2:
		push_error("500-piece seeds did not exercise both supported district footprints.")
		success = false
	if success:
		print("500-PIECE PREVIEW TEST PASSED: all seeds completed and different block counts were exercised.")
	quit(0 if success else 1)
