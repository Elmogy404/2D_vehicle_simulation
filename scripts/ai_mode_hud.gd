extends CanvasLayer

signal target_distance_changed(distance: float)

var mode_label: Label
var detail_label: Label
var target_label: Label
var target_slider: HSlider
var input_hint_label: Label
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
		input_hint_label.text = "1: 150k best   •   2: 276,480   •   I: manual   •   R: retry"
	else:
		mode_label.text = "MANUAL DRIVE  •  " + checkpoint_label.to_upper()
		mode_label.add_theme_color_override("font_color", Color(0.72, 0.84, 0.94))
		detail_label.text = status if not status.is_empty() else "Press 1 or 2 to run a model, or I to run the selected one."
		input_hint_label.text = "1: 150k default   •   2: 276,480   •   I: run selected model"


func set_checkpoint_label(label: String) -> void:
	checkpoint_label = label


func set_target_distance(distance: float) -> void:
	if target_slider == null:
		return
	target_slider.set_value_no_signal(clampf(distance, target_slider.min_value, target_slider.max_value))
	_update_target_label(target_slider.value)


func _build_interface() -> void:
	var panel := PanelContainer.new()
	panel.name = "AiModePanel"
	panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	panel.offset_left = 16.0
	panel.offset_top = -176.0
	panel.offset_right = 440.0
	panel.offset_bottom = -16.0
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.065, 0.08, 0.91)
	style.border_color = Color(0.24, 0.43, 0.47, 0.95)
	style.set_border_width_all(1)
	style.set_corner_radius_all(7)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 7.0
	style.content_margin_bottom = 7.0
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	var labels := VBoxContainer.new()
	labels.add_theme_constant_override("separation", 4)
	labels.mouse_filter = Control.MOUSE_FILTER_PASS
	panel.add_child(labels)

	mode_label = Label.new()
	mode_label.add_theme_font_size_override("font_size", 13)
	mode_label.add_theme_color_override("font_color", Color(0.72, 0.84, 0.94))
	mode_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	labels.add_child(mode_label)

	target_label = Label.new()
	target_label.add_theme_font_size_override("font_size", 12)
	target_label.add_theme_color_override("font_color", Color(0.82, 0.87, 0.89))
	target_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	labels.add_child(target_label)

	target_slider = HSlider.new()
	target_slider.name = "AiGoalDistanceSlider"
	target_slider.min_value = 250.0
	target_slider.max_value = 5500.0
	target_slider.step = 250.0
	target_slider.value = 4200.0
	target_slider.focus_mode = Control.FOCUS_ALL
	target_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	target_slider.custom_minimum_size.y = 20.0
	target_slider.tooltip_text = "Choose a goal distance from 250 to 5,500 world units. R starts a new AI trip."
	target_slider.value_changed.connect(_on_target_slider_changed)
	labels.add_child(target_slider)

	detail_label = Label.new()
	detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_label.add_theme_font_size_override("font_size", 12)
	detail_label.add_theme_color_override("font_color", Color(0.82, 0.87, 0.89))
	detail_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	labels.add_child(detail_label)

	input_hint_label = Label.new()
	input_hint_label.add_theme_font_size_override("font_size", 11)
	input_hint_label.add_theme_color_override("font_color", Color(0.67, 0.77, 0.81))
	input_hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	labels.add_child(input_hint_label)
	_update_target_label(target_slider.value)


func _on_target_slider_changed(value: float) -> void:
	_update_target_label(value)
	target_distance_changed.emit(value)


func _update_target_label(value: float) -> void:
	if target_label != null:
		target_label.text = "AI destination length: %d units" % roundi(value)
