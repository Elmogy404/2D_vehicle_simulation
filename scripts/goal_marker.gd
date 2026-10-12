extends Node2D

var world_position := Vector2.ZERO
var active := false


func set_goal(position: Vector2, enabled: bool) -> void:
	world_position = position
	active = enabled
	queue_redraw()


func _draw() -> void:
	if not active:
		return
	var marker_position := to_local(world_position)
	draw_circle(marker_position, 85.0, Color(0.12, 0.9, 0.35, 0.14))
	draw_arc(marker_position, 85.0, 0.0, TAU, 48, Color(0.2, 1.0, 0.48, 0.95), 4.0)
	draw_line(marker_position + Vector2(-13.0, 0.0), marker_position + Vector2(13.0, 0.0), Color(0.72, 1.0, 0.82), 3.0)
	draw_line(marker_position + Vector2(0.0, -13.0), marker_position + Vector2(0.0, 13.0), Color(0.72, 1.0, 0.82), 3.0)
