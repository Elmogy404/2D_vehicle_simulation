extends CanvasLayer


# ============================================================
# GAME OVER
# ------------------------------------------------------------
# Reacts to the ego's crash signal (it does not reach into
# the sensor/ML architecture). On crash it freezes the
# simulation and shows the crash speed plus a Restart button.
#
# Built in code so main.tscn only needs one extra node.
# ============================================================

var ego: Node

var speed_text: Label


func _ready() -> void:
	layer = 10

	# Must keep processing while the tree is paused so the
	# Restart button stays clickable.
	process_mode = Node.PROCESS_MODE_ALWAYS

	_build_interface()

	visible = false

	ego = get_parent().get_node("EgoVehicle")

	ego.crashed.connect(_on_ego_crashed)


func _input(event: InputEvent) -> void:
	# Keyboard fallback for Restart.
	if visible:
		var key := event as InputEventKey

		if key and key.pressed and not key.echo:
			if key.keycode == KEY_R or key.physical_keycode == KEY_R:
				restart()


# ============================================================
# CRASH
# ============================================================

func _on_ego_crashed(crash_speed: float) -> void:
	if visible:
		return

	speed_text.text = "Speed: %d km/h" % roundi(
		crash_speed * ego.kmh_per_unit
	)

	visible = true

	# Freeze the gameplay. This node keeps running so the
	# Restart button and the R key still work.
	get_tree().paused = true


# ============================================================
# RESTART
# ============================================================

func restart() -> void:
	if not visible:
		return

	visible = false
	get_tree().paused = false

	# Reset ego state, re-place it and rebuild the traffic
	# so the simulation is back at its initial condition.
	get_parent().restart_simulation()


# ============================================================
# INTERFACE
# ============================================================

func _build_interface() -> void:
	var root := Control.new()

	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP

	add_child(root)


	var center := CenterContainer.new()

	center.name = "Center"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE

	root.add_child(center)


	var panel := PanelContainer.new()

	panel.name = "Panel"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style := StyleBoxFlat.new()

	style.bg_color = Color(0.06, 0.11, 0.15, 0.95)
	style.border_color = Color(0.95, 0.72, 0.25)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.content_margin_left = 40.0
	style.content_margin_right = 40.0
	style.content_margin_top = 28.0
	style.content_margin_bottom = 32.0

	panel.add_theme_stylebox_override("panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	center.add_child(panel)


	var box := VBoxContainer.new()

	box.name = "Box"
	box.add_theme_constant_override("separation", 14)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE

	panel.add_child(box)


	var title := Label.new()

	title.name = "Title"
	title.text = "GAME OVER"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 40)
	title.add_theme_color_override(
		"font_color",
		Color(0.95, 0.72, 0.25)
	)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE

	box.add_child(title)


	speed_text = Label.new()

	speed_text.name = "CrashSpeed"
	speed_text.text = "Speed: 0 km/h"
	speed_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	speed_text.add_theme_font_size_override("font_size", 22)
	speed_text.mouse_filter = Control.MOUSE_FILTER_IGNORE

	box.add_child(speed_text)


	var button := Button.new()

	button.name = "RestartButton"
	button.text = "Restart"
	button.custom_minimum_size = Vector2(180.0, 46.0)
	button.focus_mode = Control.FOCUS_NONE

	button.pressed.connect(restart)

	box.add_child(button)


	var hint := Label.new()

	hint.name = "Hint"
	hint.text = "or press R"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override(
		"font_color",
		Color(0.65, 0.70, 0.73)
	)
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE

	box.add_child(hint)
