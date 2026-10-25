extends Node
## Broad phase only: callers retain their exact lane/signal safety checks.
const GROUPS := ["traffic", "traffic_lights", "crossing_pedestrians"]
const CELL_SIZE := 600.0
const MOTION_PADDING := 64.0
var buckets: Dictionary = {}
var actors_by_group: Dictionary = {}
var dirty := true
var frame := -1
var maximum_light_radius := 105.0

func _ready() -> void:
	add_to_group("simulation_spatial_index")
	process_physics_priority = -100

func invalidate() -> void:
	dirty = true

func _physics_process(_delta: float) -> void:
	refresh()

func refresh() -> void:
	buckets.clear()
	actors_by_group.clear()
	maximum_light_radius = 105.0
	for group in GROUPS:
		var cells := {}
		var actors := []
		for actor in get_tree().get_nodes_in_group(group):
			if not is_instance_valid(actor) or not actor is Node2D:
				continue
			var cell := Vector2i((actor.global_position / CELL_SIZE).floor())
			if not cells.has(cell):
				cells[cell] = []
			cells[cell].append(actor)
			actors.append(actor)
			if group == "traffic_lights":
				maximum_light_radius = maxf(maximum_light_radius, float(actor.get("intersection_width")) * 0.65)
		buckets[group] = cells
		actors_by_group[group] = actors
	frame = Engine.get_physics_frames()
	dirty = false

func ensure_current() -> void:
	if dirty or frame != Engine.get_physics_frames():
		refresh()

func nearby(group: String, position: Vector2, radius: float) -> Array:
	ensure_current()
	var cells: Dictionary = buckets.get(group, {})
	var reach := Vector2.ONE * (radius + MOTION_PADDING)
	var low := Vector2i(((position - reach) / CELL_SIZE).floor())
	var high := Vector2i(((position + reach) / CELL_SIZE).floor())
	var result := []
	var actors: Array = actors_by_group.get(group, [])
	if (high.x - low.x + 1) * (high.y - low.y + 1) > actors.size():
		for actor in actors:
			if is_instance_valid(actor) and actor.is_in_group(group) \
			and position.distance_squared_to(actor.global_position) <= radius * radius:
				result.append(actor)
		return result
	for x in range(low.x, high.x + 1):
		for y in range(low.y, high.y + 1):
			for actor in cells.get(Vector2i(x, y), []):
				if is_instance_valid(actor) and actor.is_in_group(group) \
				and position.distance_squared_to(actor.global_position) <= radius * radius:
					result.append(actor)
	return result
