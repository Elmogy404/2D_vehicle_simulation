extends CanvasLayer


var mode_label: Label
var detail_label: Label
var checkpoint_label := "150k best checkpoint [1]"


func _ready() -> void:
	layer = 4
	_build_interface()
	set_mode(false, "", 0.0)


func set_mode(ai_active: bool, status: String, remaining_distance: float) -> void:
	if mode_label == null:
		return
	if ai_active:
		mode_label.text = "AI DRIVE  •  " + checkpoint_label.to_upper()
		mode_label.add_theme_color_override("font_color", Color(0.35, 0.95, 0.60))
		var detail := status
		if remaining_distance > 0.0 and status.begins_with("AI driving"):
			detail += "  Goal ahead: %d units" % roundi(remaining_distance)
		detail_label.text = detail
	else:
		mode_label.text = "MANUAL DRIVE  •  " + checkpoint_label.to_upper()
		mode_label.add_theme_color_override("font_color", Color(0.72, 0.84, 0.94))
		detail_label.text = status


func set_checkpoint_label(label: String) -> void:
	checkpoint_label = label


func _build_interface() -> void:
	var panel := PanelContainer.new()
	panel.name = "DriveStatusPanel"
	panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	panel.offset_left = 16.0
	panel.offset_top = -100.0
	panel.offset_right = 430.0
	panel.offset_bottom = -16.0
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.065, 0.08, 0.91)
	style.border_color = Color(0.24, 0.43, 0.47, 0.95)
	style.set_border_width_all(1)
	style.set_corner_radius_all(7)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 8.0
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	var labels := VBoxContainer.new()
	labels.add_theme_constant_override("separation", 4)
	labels.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(labels)

	mode_label = Label.new()
	mode_label.add_theme_font_size_override("font_size", 13)
	mode_label.add_theme_color_override("font_color", Color(0.72, 0.84, 0.94))
	mode_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	labels.add_child(mode_label)

	detail_label = Label.new()
	detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_label.add_theme_font_size_override("font_size", 12)
	detail_label.add_theme_color_override("font_color", Color(0.82, 0.87, 0.89))
	detail_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	labels.add_child(detail_label)
