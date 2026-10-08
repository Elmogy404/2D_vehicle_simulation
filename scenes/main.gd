extends Node2D


# true : the ego vehicle starts in the right-most traffic lane
#        (needed once traffic drives in both directions, the
#        centreline is the border between the two directions)
# false: old behaviour, start on the centreline
@export var start_in_lane: bool = true


@onready var road_generator = $RoadGenerator
@onready var ego_vehicle = $EgoVehicle
@onready var traffic_manager = $TrafficManager


func _ready() -> void:
	ego_vehicle.rotation = road_generator.get_spawn_rotation()

	var lane_offset: float = 0.0

	if start_in_lane:
		lane_offset = traffic_manager.get_lane_offset(
			traffic_manager.lane_count - 1
		)

	# Right-hand side of the heading (same convention as the lanes)
	ego_vehicle.position = (
		road_generator.get_spawn_position()
		+
		Vector2.RIGHT.rotated(ego_vehicle.rotation) * lane_offset
	)
