extends Node2D
## Standalone review sheet for the reusable modular road pieces.

const COLUMN_GAP := 1800.0
const ROW_GAP := 1800.0
const COLUMN_COUNT := 5
const PIECE_IDS := [
	"straight_2_lane", "straight_4_lane", "straight_6_lane", "turn_left", "turn_right",
	"t_junction", "four_way_intersection", "u_turn_dead_end_bulb", "bulb_3_road_junction", "bulb_4_road_junction",
	"lane_transition_6_to_4", "lane_transition_4_to_2",
	"straight_2_lane_crosswalk", "straight_4_lane_crosswalk",
	"t_junction_2_lane", "four_way_intersection_2_lane"
]
const TITLES := {
	"straight_2_lane": "STRAIGHT · 2 LANES",
	"straight_4_lane": "STRAIGHT · 4 LANES",
	"straight_6_lane": "STRAIGHT · 6 LANES",
	"turn_left": "LEFT TURN",
	"turn_right": "RIGHT TURN",
	"t_junction": "T-JUNCTION",
	"four_way_intersection": "4-WAY INTERSECTION",
	"u_turn_dead_end_bulb": "BULB DEAD END · U-TURN",
	"bulb_3_road_junction": "3-ROAD BULB",
	"bulb_4_road_junction": "4-ROAD BULB",
	"lane_transition_6_to_4": "FUNNEL · 6 → 4 LANES",
	"lane_transition_4_to_2": "FUNNEL · 4 → 2 LANES",
	"straight_2_lane_crosswalk": "2 LANES · ZEBRA",
	"straight_4_lane_crosswalk": "4 LANES · ZEBRA",
	"t_junction_2_lane": "T-JUNCTION · 2 LANES",
	"four_way_intersection_2_lane": "4-WAY · 2 LANES"
}

var _camera: Camera2D


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color("#444648"))
	_camera = get_node_or_null("Camera2D") as Camera2D
	if _camera != null:
		var viewport_size := get_viewport_rect().size
		var fit_zoom := minf(viewport_size.x / 9000.0, viewport_size.y / 6200.0)
		_camera.zoom = Vector2.ONE * fit_zoom
		_camera.make_current()
	var title := Label.new()
	title.text = "ROAD PIECE CATALOG  ·  90-UNIT LANES  ·  LANE COUNTS ARE TOTAL"
	title.position = Vector2(18.0, 12.0)
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color("#f2f1e9"))
	var overlay := CanvasLayer.new()
	add_child(overlay)
	overlay.add_child(title)
	for index in range(PIECE_IDS.size()):
		var piece_id: String = PIECE_IDS[index]
		var packed := load("res://scenes/road_pieces/%s.tscn" % piece_id) as PackedScene
		if packed == null:
			push_error("Missing road piece scene: %s" % piece_id)
			continue
		var piece := packed.instantiate() as Node2D
		piece.position = _piece_position(index)
		piece.set("debug_ports", true)
		add_child(piece)
	queue_redraw()


func _draw() -> void:
	var font := ThemeDB.fallback_font
	if font == null:
		return
	var zoom := _camera.zoom.x if _camera != null else 0.15
	var label_size := maxi(14, int(round(15.0 / zoom)))
	for index in range(PIECE_IDS.size()):
		var piece_id: String = PIECE_IDS[index]
		var center := _piece_position(index)
		draw_string(font, center + Vector2(-800, -850), TITLES[piece_id], HORIZONTAL_ALIGNMENT_CENTER, 1600.0, label_size, Color("#dce4e5"))


func _piece_position(index: int) -> Vector2:
	var row_count := ceili(float(PIECE_IDS.size()) / float(COLUMN_COUNT))
	var row := floori(float(index) / float(COLUMN_COUNT))
	var items_in_row := mini(COLUMN_COUNT, PIECE_IDS.size() - row * COLUMN_COUNT)
	var row_start_column := (COLUMN_COUNT - items_in_row) * 0.5
	var column := float(index % COLUMN_COUNT) + row_start_column
	return Vector2((column - float(COLUMN_COUNT - 1) * 0.5) * COLUMN_GAP, (float(row) - float(row_count - 1) * 0.5) * ROW_GAP)
