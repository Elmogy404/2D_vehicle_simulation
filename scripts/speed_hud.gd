extends CanvasLayer


# ============================================================
# SPEED HUD
# ------------------------------------------------------------
# Read-only display of the ego vehicle's actual velocity.
# Built in code so main.tscn only needs one extra node.
#
#   SPEED
#   72 km/h
# ============================================================

var ego: Node

var speed_label: Label


func _ready() -> void:
	layer = 1

	_build_interface()

	ego = get_parent().get_node("EgoVehicle")


func _process(_delta: float) -> void:
	if ego == null or speed_label == null:
		return

	speed_label.text = "%d km/h" % roundi(
		ego.get_speed_kmh()
	)


# ============================================================
# INTERFACE
# ============================================================

func _build_interface() -> void:
	var root := Control.new()

	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE

	add_child(root)


	# Top-right corner, mirroring the Python reference HUD.
	var box := VBoxContainer.new()

	box.name = "SpeedBox"
	box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	box.offset_left = -220.0
	box.offset_right = -16.0
	box.offset_top = 16.0
	box.offset_bottom = -1.0
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.alignment = BoxContainer.ALIGNMENT_CENTER

	root.add_child(box)


	var panel := PanelContainer.new()

	panel.name = "Panel"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style := StyleBoxFlat.new()

	style.bg_color = Color(0.06, 0.10, 0.14, 0.85)
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	style.content_margin_left = 18.0
	style.content_margin_right = 18.0
	style.content_margin_top = 10.0
	style.content_margin_bottom = 12.0

	panel.add_theme_stylebox_override("panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	box.add_child(panel)


	var labels := VBoxContainer.new()

	labels.name = "Labels"
	labels.mouse_filter = Control.MOUSE_FILTER_IGNORE

	panel.add_child(labels)


	var title := Label.new()

	title.name = "Title"
	title.text = "SPEED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override(
		"font_color",
		Color(0.75, 0.80, 0.83)
	)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE

	labels.add_child(title)


	speed_label = Label.new()

	speed_label.name = "Value"
	speed_label.text = "0 km/h"
	speed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	speed_label.add_theme_font_size_override("font_size", 34)
	speed_label.add_theme_color_override(
		"font_color",
		Color(0.95, 0.72, 0.25)
	)
	speed_label.mouse_filter = Control.MOUSE_FILTER_IGNORE

	labels.add_child(speed_label)
