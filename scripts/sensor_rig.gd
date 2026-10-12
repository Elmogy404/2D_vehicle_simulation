extends Node2D

# Layer 1 → Road boundaries
# Layer 2 → Traffic
# Layer 3 → Pedestrians
# Layer 4 → Obstacles

# GREEN  → far away
# YELLOW → medium distance
# RED    → close

# ============================================================
# SENSOR SETTINGS
# ============================================================

@export_category("Sensors")

@export var sensor_range: float = 300.0

@export var sensor_angles: Array[float] = [
	-60.0,
	-45.0,
	-30.0,
	-15.0,
	0.0,
	15.0,
	30.0,
	45.0,
	60.0
]


# ============================================================
# DEBUG
# ============================================================

@export_category("Debug")

@export var show_rays: bool = false
@export var ray_width: float = 2.0


# ============================================================
# SENSOR DATA
# ============================================================

var distances: Array[float] = []

var hit_points: Array[Vector2] = []


# ============================================================
# READY
# ============================================================

func _ready() -> void:
	distances.resize(sensor_angles.size())
	hit_points.resize(sensor_angles.size())

	for i in range(sensor_angles.size()):
		distances[i] = 1.0
		hit_points[i] = Vector2.ZERO


# ============================================================
# SENSOR UPDATE
# ============================================================

func _physics_process(_delta: float) -> void:
	update_sensors()

	queue_redraw()


# ============================================================
# CAST ALL RAYS
# ============================================================

func update_sensors() -> void:
	var space_state := get_world_2d().direct_space_state

	var forward := Vector2.UP.rotated(
		global_rotation
	)


	for i in range(sensor_angles.size()):
		var angle := deg_to_rad(
			sensor_angles[i]
		)


		var direction := forward.rotated(
			angle
		)


		var start := global_position

		var end := (
			start
			+
			direction * sensor_range
		)


		var query := PhysicsRayQueryParameters2D.create(
			start,
			end
		)


		# Detect collision objects
		# World boundaries, vehicles, and pedestrians.
		query.collision_mask = 7

		# Don't detect the ego vehicle
		query.exclude = [
			get_parent()
		]


		var result := space_state.intersect_ray(
			query
		)


		if result.is_empty():
			distances[i] = 1.0

			hit_points[i] = end

		else:
			var hit_position: Vector2 = result.position

			var distance := (
				start.distance_to(hit_position)
			)


			distances[i] = clamp(
				distance / sensor_range,
				0.0,
				1.0
			)

			hit_points[i] = hit_position


# ============================================================
# DEBUG DRAWING
# ============================================================

func _draw() -> void:
	if not show_rays:
		return


	for i in range(sensor_angles.size()):
		var local_hit := to_local(
			hit_points[i]
		)


		var color := Color.GREEN


		if distances[i] < 0.33:
			color = Color.RED

		elif distances[i] < 0.66:
			color = Color.YELLOW


		draw_line(
			Vector2.ZERO,
			local_hit,
			color,
			ray_width
		)


		draw_circle(
			local_hit,
			4.0,
			color
		)


# ============================================================
# PUBLIC OBSERVATION
# ============================================================

func get_observation() -> Array[float]:
	return distances.duplicate()
