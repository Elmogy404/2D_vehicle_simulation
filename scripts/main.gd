extends Node2D


@onready var road_generator = $RoadGenerator
@onready var ego_vehicle = $EgoVehicle


func _ready() -> void:
	ego_vehicle.position = road_generator.get_spawn_position()

	ego_vehicle.rotation = road_generator.get_spawn_rotation()