class_name EnvironmentState
extends Node


## Read-only simulation telemetry. It owns no driving policy and does not
## mutate the vehicle, road, traffic, or sensors.
@onready var ego: CharacterBody2D = get_parent().get_node("EgoVehicle")
@onready var road_generator: Node = get_parent().get_node("RoadGenerator")
@onready var traffic_manager: Node = get_parent().get_node("TrafficManager")


func get_state() -> Dictionary:
	var route: RoutePath = road_generator.get_route()

	if route == null or not route.is_valid():
		return {}

	var nearest: Dictionary = route.nearest(ego.global_position)
	var progress: float = float(nearest["progress"])
	var route_direction: Vector2 = route.get_direction_at(progress)
	var vehicle_direction := Vector2.UP.rotated(ego.global_rotation)
	var heading_error: float = route_direction.angle_to(vehicle_direction)
	var center: Vector2 = route.get_position_at(progress)
	var right := Vector2(-route_direction.y, route_direction.x)
	var lateral_offset: float = (ego.global_position - center).dot(right)
	var lane_offset: float = _nearest_lane_offset(lateral_offset)
	var road_width: float = float(road_generator.get("road_width"))
	var probe_distance: float = 150.0
	var future_direction: Vector2 = route.get_direction_at(
		minf(progress + probe_distance, route.length)
	)
	var sensors: Node = ego.get_node_or_null("SensorRig")
	var sensor_distances: Array[float] = []

	if sensors != null and sensors.has_method("get_observation"):
		sensor_distances = sensors.get_observation()

	return {
		"speed": float(ego.get("current_speed")),
		"speed_kmh": ego.get_speed_kmh(),
		"normalized_speed": float(ego.get("current_speed")) / maxf(float(ego.get("max_speed")), 0.001),
		"steering": float(ego.get("steering_input")),
		"heading_error": heading_error,
		"lateral_offset": lateral_offset,
		"normalized_lateral_offset": lateral_offset / maxf(road_width * 0.5, 0.001),
		"lane_center_error": lateral_offset - lane_offset,
		"road_curvature": route_direction.angle_to(future_direction),
		"route_progress": progress,
		"normalized_route_progress": progress / maxf(route.length, 0.001),
		"has_crashed": bool(ego.get("has_crashed")),
		"sensor_distances": sensor_distances
	}


func _nearest_lane_offset(lateral_offset: float) -> float:
	var lanes: Array = traffic_manager.get("lanes")
	var best_offset: float = 0.0
	var best_distance: float = INF

	for lane in lanes:
		var offset: float = float(lane["offset"])
		var distance: float = absf(lateral_offset - offset)

		if distance < best_distance:
			best_distance = distance
			best_offset = offset

	return best_offset
