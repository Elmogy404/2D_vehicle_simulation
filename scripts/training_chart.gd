extends Control

var samples: Array = []
const ACCENT := Color("55d8c5")

func _ready() -> void:
	custom_minimum_size.y = 126.0
	mouse_filter = Control.MOUSE_FILTER_STOP

func set_history(value: Array) -> void:
	samples = value
	queue_redraw()

func _draw() -> void:
	var font := ThemeDB.fallback_font
	var plot := Rect2(38, 12, maxf(size.x - 52, 1), maxf(size.y - 36, 1))
	for i in range(3):
		var y := plot.position.y + plot.size.y * float(i) / 2.0
		draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y), Color(0.35, 0.48, 0.57, 0.25))
		draw_string(font, Vector2(0, y + 4), "%d%%" % (100 - i * 50), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("8398ac"))
	var valid: Array = samples.filter(func(sample: Dictionary) -> bool: return sample.get("success") != null)
	if valid.size() < 2:
		draw_string(font, Vector2(50, 62), "Episode results will appear here", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("8398ac"))
		return
	var first := float(valid[0]["steps"])
	var span := maxf(1.0, float(valid[-1]["steps"]) - first)
	var line := PackedVector2Array()
	for sample in valid:
		line.append(Vector2(plot.position.x + plot.size.x * (float(sample["steps"]) - first) / span, plot.end.y - plot.size.y * float(sample["success"])))
	draw_polyline(line, ACCENT, 2.0, true)
	draw_circle(line[-1], 3.5, ACCENT)
	draw_string(font, Vector2(plot.position.x, size.y - 3), "%d steps" % int(first), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("8398ac"))
	draw_string(font, Vector2(plot.end.x - 95, size.y - 3), "%d steps" % int(valid[-1]["steps"]), HORIZONTAL_ALIGNMENT_RIGHT, 95, 11, Color("8398ac"))

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and not samples.is_empty():
		var valid: Array = samples.filter(func(sample: Dictionary) -> bool: return sample.get("success") != null)
		if valid.is_empty():
			return
		var target_step := lerpf(float(valid[0]["steps"]), float(valid[-1]["steps"]), clampf((event.position.x - 38.0) / maxf(size.x - 52.0, 1.0), 0.0, 1.0))
		var sample: Dictionary = valid[0]
		for candidate in valid:
			if absf(float(candidate["steps"]) - target_step) < absf(float(sample["steps"]) - target_step):
				sample = candidate
		tooltip_text = "%d steps | success %s | mean return %s" % [int(sample.get("steps", 0)), "%.1f%%" % (float(sample["success"]) * 100) if sample.get("success") != null else "pending", "%.2f" % float(sample["return"]) if sample.get("return") != null else "pending"]
