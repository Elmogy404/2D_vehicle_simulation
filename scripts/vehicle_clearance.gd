extends RefCounted
## Full oriented-body clearance used by both training and NPC deployment.
var query := PhysicsShapeQueryParameters2D.new()

func _init(size: Vector2, margin: float = 2.0) -> void:
	var shape := RectangleShape2D.new()
	shape.size = size + Vector2.ONE * margin * 2.0
	query.shape = shape
	query.collision_mask = 1
	query.collide_with_areas = false

func is_clear(space: PhysicsDirectSpaceState2D, position: Vector2, rotation: float) -> bool:
	query.transform = Transform2D(rotation, position)
	return space.intersect_shape(query, 1).is_empty()

static func bodies_overlap(position: Vector2, rotation: float, size: Vector2,
		other_position: Vector2, other_rotation: float, other_size: Vector2,
		margin: Vector2 = Vector2(8, 28)) -> bool:
	# Separating-axis test, also valid before newly spawned bodies have been
	# registered by physics. Longitudinal spacing must not block adjacent lanes.
	var own_x := Vector2.RIGHT.rotated(rotation)
	var own_y := Vector2.DOWN.rotated(rotation)
	var other_x := Vector2.RIGHT.rotated(other_rotation)
	var other_y := Vector2.DOWN.rotated(other_rotation)
	var half := size * 0.5 + margin
	var other_half := other_size * 0.5
	var separation := other_position - position
	for axis in [own_x, own_y, other_x, other_y]:
		var own_extent := absf(axis.dot(own_x)) * half.x + absf(axis.dot(own_y)) * half.y
		var other_extent := absf(axis.dot(other_x)) * other_half.x + absf(axis.dot(other_y)) * other_half.y
		if absf(separation.dot(axis)) >= own_extent + other_extent:
			return false
	return true
