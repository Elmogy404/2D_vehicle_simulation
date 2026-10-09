extends Node2D


@onready var road_generator = $RoadGenerator
@onready var ego_vehicle = $EgoVehicle
@onready var traffic_manager = $TrafficManager
@onready var traffic_light_manager = $TrafficLightManager
@onready var pedestrian_manager = $PedestrianManager


func _ready() -> void:
	place_ego()

	# Rebuilds the ego spawn pose whenever the road changes
	# (traffic follows automatically via its own connection).
	road_generator.road_regenerated.connect(place_ego)


func place_ego() -> void:
	var pose: Dictionary = traffic_manager.get_ego_spawn_pose()

	ego_vehicle.position = pose["position"]
	ego_vehicle.rotation = pose["rotation"]


# Restart: clear the crash, put the ego back on its spawn
# pose and rebuild the traffic from the same seeds, so the
# simulation returns to its exact initial condition.
func restart_simulation() -> void:
	ego_vehicle.reset_vehicle()

	place_ego()

	traffic_manager.regenerate()
	traffic_light_manager.regenerate()
	pedestrian_manager.regenerate()
