extends CanvasLayer


const MINIMAP_VIEW := preload("res://scripts/minimap_view.gd")

var view: Control
var expanded: bool = false


func _ready() -> void:
	layer = 2
	view = MINIMAP_VIEW.new()
	view.name = "View"
	add_child(view)
	_apply_size()

	var main := get_parent()
	var road := main.get_node("RoadGenerator")
	view.call("set_sources", road, main.get_node("EgoVehicle"))
	road.road_regenerated.connect(view.call.bind("reset_map"))


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_M:
		expanded = not expanded
		_apply_size()


func _apply_size() -> void:
	if view == null:
		return
	view.position = Vector2(16.0, 16.0)
	view.size = Vector2(620.0, 450.0) if expanded else Vector2(250.0, 180.0)
	view.queue_redraw()
