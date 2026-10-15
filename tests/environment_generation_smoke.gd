extends Node


var checks := 0
var failures := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	main_scene.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(main_scene)
	await get_tree().process_frame
	await get_tree().process_frame
	main_scene.call("_on_environment_generate_requested", 123456789, false, 0)
	_check(not get_tree().paused, "successful generation immediately resumes simulation")
	await get_tree().process_frame
	await get_tree().physics_frame

	var road: Node = main_scene.get_node("RoadGenerator")
	var lights: Node = main_scene.get_node("TrafficLightManager")
	var pedestrians: Node = main_scene.get_node("PedestrianManager")
	var traffic: Node = main_scene.get_node("TrafficManager")
	var settings: Node = main_scene.get_node("SettingsPopup")
	var route: RoutePath = road.get_route()
	var network: Object = road.call("get_road_network")
	var layout_summary: Dictionary = road.call("get_layout_summary")
	var ego: Node = main_scene.get_node("EgoVehicle")
	_check(route != null and route.is_valid(), "main scene generated the arterial route")
	_check(network.call("graph_is_connected"), "live map generated as one connected graph")
	_check(
		float(layout_summary["length"]) >= float(road.get("minimum_map_length")) - 1.0
		and float(layout_summary["length"]) <= float(road.get("maximum_map_length")) + 1.0,
		"live arterial length stays within the original map-length range"
	)
	_check(int(road.get("seed_value")) == 123456789, "chosen seed reproduces the requested map")
	_check(not get_tree().paused, "successful generation resumes simulation")
	_check(
		not bool(ego.get("has_crashed")) and not main_scene.get_node("GameOver").visible,
		"player spawn stays collision-free as NPCs enter the physics world"
	)
	_check(not bool(settings.get("popup_open")), "successful generation closes settings popup")
	settings.call("set_popup_open", true)
	_check(get_tree().paused, "opening settings pauses the simulation")
	_check(
		main_scene.get_node("Minimap/View").visible and main_scene.get_node("SpeedHud").visible,
		"settings leave minimap and speed HUD visible"
	)
	settings.call("set_popup_open", false)
	_check(not get_tree().paused, "closing settings resumes a generated simulation")

	var light_list: Array = lights.get("lights")
	var pedestrian_list: Array = pedestrians.get("pedestrians")
	var traffic_list: Array = traffic.get("traffic_cars")
	_check(light_list.size() >= 1, "network intersections received traffic signals")
	_check(pedestrian_list.size() >= 1, "signalized intersections received pedestrians")
	_check(traffic_list.size() >= 1, "NPC traffic deployed after the map")
	_check(pedestrians.get_node_or_null("Crosswalks") != null, "graph-based zebra crossings were generated")
	var signals_are_at_junctions := true
	for light in light_list:
		var node_id := int(light.get("graph_node_id"))
		if int(network.call("get_node_degree", node_id)) < 3:
			signals_are_at_junctions = false
			break
	_check(signals_are_at_junctions, "traffic signals attach to actual graph junctions")

	print("ENVIRONMENT GENERATION SMOKE: %d checks, %d failures" % [checks, failures])
	get_tree().quit(0 if failures == 0 else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		print("  PASS  " + message)
	else:
		failures += 1
		printerr("  FAIL  " + message)
