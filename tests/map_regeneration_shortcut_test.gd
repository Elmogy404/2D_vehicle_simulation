extends SceneTree

const MAIN_SCENE := preload("res://scenes/main.tscn")


func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	var main := MAIN_SCENE.instantiate() as Node2D
	root.add_child(main)
	var settings := main.get_node("SettingsPopup")
	var roads := main.get_node("RoadGenerator")
	var traffic := main.get_node("TrafficManager")
	var game_over := main.get_node("GameOver") as CanvasLayer
	var f_key := InputEventKey.new()
	f_key.keycode = KEY_F
	f_key.pressed = true

	settings.call("_input", f_key)
	if bool(main.get("environment_ready")):
		_fail("F must not bypass the initial map settings.")
		return
	settings.emit_signal("generate_requested", 123456789, false, 0)
	await main.environment_generated
	var first_seed := int(roads.get("seed_value"))
	root.push_input(f_key)
	await main.environment_generated
	await process_frame
	if not _map_is_ready(main, roads, traffic, 0, first_seed):
		_fail("F did not rebuild the original map with a fresh seed.")
		return

	var second_seed := int(roads.get("seed_value"))
	var gear := settings.get("gear_button") as Button
	var notice := settings.get("map_notice") as PanelContainer
	var seed_edit := settings.get("seed_edit") as LineEdit
	if gear == null or not gear.visible or notice == null or not notice.visible \
	or seed_edit == null or seed_edit.text != str(second_seed):
		_fail("The settings gear, map notice, or reproducible seed is missing after F.")
		return
	gear.pressed.emit()
	if not bool(settings.get("popup_open")) or not paused or notice.visible:
		_fail("The gear must reopen settings and hide the map notice.")
		return
	settings.call("_input", f_key)
	if int(roads.get("seed_value")) != second_seed:
		_fail("F should not regenerate while the settings popup is open.")
		return
	gear.pressed.emit()

	settings.emit_signal("generate_requested", 20261015, false, 1)

	await main.environment_generated
	var segmented_seed := int(roads.get("seed_value"))
	game_over.visible = true
	paused = true
	root.push_input(f_key)
	await main.environment_generated
	await process_frame
	if not _map_is_ready(main, roads, traffic, 1, segmented_seed) \
	or game_over.visible or paused:
		_fail("F did not rebuild the segmented map and clear paused Game Over.")
		return

	main.set("ai_mode_active", true)
	var old_ai_seed := int(roads.get("seed_value"))
	root.push_input(f_key)
	await main.environment_generated
	await process_frame
	var manual_spawn: Dictionary = traffic.call("get_ego_spawn_pose")
	var saved_position: Vector2 = main.get("saved_manual_position")
	if not _map_is_ready(main, roads, traffic, 1, old_ai_seed, false) \
	or not bool(main.get("ai_mode_active")) \
	or main.get("ai_route") == null \
	or saved_position.distance_to(Vector2(manual_spawn["position"])) > 1.0:
		_fail("F did not replan the AI route and update the manual return pose.")
		return
	print("MAP REGENERATION SHORTCUT TEST PASSED: F uses a new seed, preserves road type, ignores popup input, works after a crash, and replans AI mode.")
	quit(0)


func _map_is_ready(
	main: Node, roads: Node, traffic: Node, expected_type: int,
	old_seed: int, expect_traffic: bool = true
) -> bool:
	var route: RoutePath = roads.call("get_route")
	var cars: Array = traffic.get("traffic_cars")
	return bool(main.get("environment_ready")) \
		and route != null and route.is_valid() \
		and int(roads.call("get_generator_type")) == expected_type \
		and int(roads.get("seed_value")) != old_seed \
		and not bool(main.get_node("SettingsPopup").get("popup_open")) \
		and (not expect_traffic or not cars.is_empty())


func _fail(message: String) -> void:
	push_error(message)
	paused = false
	quit(1)
