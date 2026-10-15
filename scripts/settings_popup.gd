extends CanvasLayer

const TRAINING_CONTROLLER_SCRIPT := preload("res://scripts/ai_training_controller.gd")
const REWARD_FIELDS := [
	["progress_gain", "Forward progress reward", 1.0],
	["max_speed_reward", "Top-speed reward (per step)", 0.05],
	["lane_penalty", "Lane deviation penalty", 0.12],
	["edge_penalty", "Road-edge penalty", 0.6],
	["heading_penalty", "Wrong-heading penalty", 0.08],
	["step_penalty", "Per-step penalty", 0.01],
	["crash_penalty", "Crash penalty", 35.0],
	["off_road_penalty", "Off-road penalty", 35.0],
	["goal_reward", "Goal reward", 40.0],
	["timeout_penalty", "Timeout penalty", 20.0],
]


signal generate_requested(seed_value: int, randomize_seed: bool, generator_type: int)
signal quick_generate_requested
signal checkpoint_requested(checkpoint_id: int)
signal target_distance_changed(distance: float)
signal popup_visibility_changed(is_open: bool)

var map_generated := false
var popup_open := true
var seed_edit: LineEdit
var random_seed_check: CheckBox
var generator_option: OptionButton
var status_label: Label
var target_label: Label
var target_slider: HSlider
var checkpoint_status: Label
var popup_root: Control
var gear_button: Button
var close_button: Button
var map_notice: PanelContainer
var map_notice_label: Label
var map_notice_timer: Timer
var training_controller: Node
var training_inputs: Dictionary = {}
var reward_inputs: Dictionary = {}
var training_status_label: Label
var training_progress: ProgressBar
var training_start_button: Button
var training_pause_button: Button
var training_resume_button: Button
var training_stop_button: Button


func _ready() -> void:
	layer = 8
	process_mode = Node.PROCESS_MODE_ALWAYS
	training_controller = TRAINING_CONTROLLER_SCRIPT.new()
	training_controller.name = "AiTrainingController"
	add_child(training_controller)
	_build_interface()
	training_controller.status_changed.connect(_on_training_status_changed)
	_on_training_status_changed(training_controller.get("latest_status"))
	set_popup_open(true)


func _input(event: InputEvent) -> void:
	if popup_open or not map_generated:
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_F or key.physical_keycode == KEY_F:
		quick_generate_requested.emit()
		get_viewport().set_input_as_handled()


func set_popup_open(open: bool) -> void:
	popup_open = open
	if popup_root != null:
		popup_root.visible = open
	if gear_button != null:
		gear_button.text = "×" if open else "⚙"
	if open and map_notice != null:
		map_notice.hide()
		map_notice_timer.stop()
	popup_visibility_changed.emit(open)


func set_map_generated(
	generated: bool,
	seed_value: int = 0,
	generator_label: String = ""
) -> void:
	map_generated = generated
	if close_button != null:
		close_button.disabled = not generated
	if generated:
		seed_edit.text = str(seed_value)
		status_label.text = "Map seed %d generated with %s. NPCs deployed; driving is ready." % [
			seed_value, generator_label
		]
		set_popup_open(false)
		_show_map_notice(seed_value, generator_label)
	else:
		status_label.text = "Generate a district before driving. The spawn point stays at the map centre."


func set_status(message: String) -> void:
	if status_label != null:
		status_label.text = message


func _show_map_notice(seed_value: int, generator_label: String) -> void:
	if map_notice == null:
		return
	map_notice_label.text = "%s  •  SEED %d" % [generator_label.to_upper(), seed_value]
	map_notice.show()
	map_notice_timer.start(3.0)


func set_checkpoint_label(message: String) -> void:
	if checkpoint_status != null:
		checkpoint_status.text = "Selected model: " + message


func set_target_distance(distance: float) -> void:
	if target_slider == null:
		return
	target_slider.set_value_no_signal(clampf(distance, target_slider.min_value, target_slider.max_value))
	_update_target_label(target_slider.value)


func _build_interface() -> void:
	var root := Control.new()
	root.name = "SettingsRoot"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	var popup_contents := Control.new()
	popup_contents.name = "PopupContents"
	popup_contents.set_anchors_preset(Control.PRESET_FULL_RECT)
	popup_contents.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(popup_contents)

	var dimmer := ColorRect.new()
	dimmer.name = "PopupBackdrop"
	dimmer.set_anchors_preset(Control.PRESET_FULL_RECT)
	dimmer.color = Color(0.015, 0.025, 0.035, 0.58)
	dimmer.mouse_filter = Control.MOUSE_FILTER_STOP
	popup_contents.add_child(dimmer)

	var panel := PanelContainer.new()
	panel.name = "SettingsPanel"
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -300.0
	panel.offset_top = -316.0
	panel.offset_right = 300.0
	panel.offset_bottom = 316.0
	panel.custom_minimum_size = Vector2(600.0, 0.0)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.035, 0.065, 0.08, 0.98)
	panel_style.border_color = Color(0.27, 0.48, 0.53, 1.0)
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(12)
	panel_style.content_margin_left = 24.0
	panel_style.content_margin_right = 24.0
	panel_style.content_margin_top = 18.0
	panel_style.content_margin_bottom = 18.0
	panel.add_theme_stylebox_override("panel", panel_style)
	popup_contents.add_child(panel)

	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 9)
	panel.add_child(layout)

	var title := Label.new()
	title.text = "DRIVING SIMULATOR"
	title.add_theme_font_size_override("font_size", 23)
	title.add_theme_color_override("font_color", Color(0.88, 0.95, 0.97))
	layout.add_child(title)

	var intro := Label.new()
	intro.text = "Generate a seeded road network from the fixed centre, with randomized junctions, connected side streets, turnarounds, sidewalks and crossings."
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.add_theme_font_size_override("font_size", 13)
	intro.add_theme_color_override("font_color", Color(0.72, 0.81, 0.84))
	layout.add_child(intro)

	var tabs := TabContainer.new()
	tabs.name = "SettingsTabs"
	tabs.custom_minimum_size = Vector2(0.0, 475.0)
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout.add_child(tabs)
	var main_scroll := ScrollContainer.new()
	main_scroll.name = "Main"
	main_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tabs.add_child(main_scroll)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 9)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_scroll.add_child(content)

	var generator_header := Label.new()
	generator_header.text = "ROAD GENERATOR"
	generator_header.add_theme_font_size_override("font_size", 13)
	generator_header.add_theme_color_override("font_color", Color(0.65, 0.85, 0.91))
	content.add_child(generator_header)
	generator_option = OptionButton.new()
	generator_option.name = "RoadGeneratorChoice"
	generator_option.add_item("Original procedural network", 0)
	generator_option.add_item("Segmented city blocks · 200 pieces", 1)
	generator_option.select(0)
	generator_option.tooltip_text = "Choose which road system builds the next map."
	content.add_child(generator_option)

	var seed_header := Label.new()
	seed_header.text = "MAP SEED"
	seed_header.add_theme_font_size_override("font_size", 13)
	seed_header.add_theme_color_override("font_color", Color(0.65, 0.85, 0.91))
	content.add_child(seed_header)

	var seed_row := HBoxContainer.new()
	seed_row.add_theme_constant_override("separation", 10)
	content.add_child(seed_row)
	seed_edit = LineEdit.new()
	seed_edit.name = "MapSeed"
	seed_edit.placeholder_text = "Enter a seed to reproduce a map"
	seed_edit.text = "333333333"
	seed_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seed_row.add_child(seed_edit)
	random_seed_check = CheckBox.new()
	random_seed_check.text = "Random every time"
	random_seed_check.button_pressed = true
	random_seed_check.toggled.connect(_on_random_seed_toggled)
	seed_row.add_child(random_seed_check)
	seed_edit.editable = false

	var generate_button := Button.new()
	generate_button.name = "GenerateMap"
	generate_button.text = "Generate world and deploy NPCs"
	generate_button.custom_minimum_size.y = 42.0
	generate_button.pressed.connect(_on_generate_pressed)
	content.add_child(generate_button)

	status_label = Label.new()
	status_label.name = "MapStatus"
	status_label.text = "Generate a district before driving. The spawn point stays at the map centre."
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.custom_minimum_size.y = 32.0
	status_label.add_theme_font_size_override("font_size", 12)
	status_label.add_theme_color_override("font_color", Color(0.82, 0.87, 0.89))
	content.add_child(status_label)

	var separator := HSeparator.new()
	content.add_child(separator)

	var ai_title := Label.new()
	ai_title.text = "AI TEST CONTROLS"
	ai_title.add_theme_font_size_override("font_size", 14)
	ai_title.add_theme_color_override("font_color", Color(0.65, 0.85, 0.91))
	content.add_child(ai_title)

	var checkpoint_row := HBoxContainer.new()
	checkpoint_row.add_theme_constant_override("separation", 10)
	content.add_child(checkpoint_row)
	var first_model := Button.new()
	first_model.text = "Run best model  [1]"
	first_model.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	first_model.pressed.connect(_on_checkpoint_pressed.bind(1))
	checkpoint_row.add_child(first_model)
	var second_model := Button.new()
	second_model.text = "Run 276k model  [2]"
	second_model.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	second_model.pressed.connect(_on_checkpoint_pressed.bind(2))
	checkpoint_row.add_child(second_model)
	checkpoint_status = Label.new()
	checkpoint_status.text = "Selected model: 150k best checkpoint"
	checkpoint_status.add_theme_font_size_override("font_size", 11)
	checkpoint_status.add_theme_color_override("font_color", Color(0.72, 0.81, 0.84))
	content.add_child(checkpoint_status)

	target_label = Label.new()
	target_label.add_theme_font_size_override("font_size", 12)
	target_label.add_theme_color_override("font_color", Color(0.82, 0.87, 0.89))
	content.add_child(target_label)
	target_slider = HSlider.new()
	target_slider.name = "AiGoalDistanceSlider"
	target_slider.min_value = 250.0
	target_slider.max_value = 5500.0
	target_slider.step = 250.0
	target_slider.value = 4200.0
	target_slider.custom_minimum_size.y = 20.0
	target_slider.tooltip_text = "Set the PPO destination distance. Press R during an AI drive to start a new trip."
	target_slider.value_changed.connect(_on_target_slider_changed)
	content.add_child(target_slider)
	_update_target_label(target_slider.value)

	var controls := Label.new()
	controls.text = "Drive: W accelerate  •  S / Space brake  •  A/D steer\nMap: F generate a fresh map using the current road type\nCamera: C toggle free view  •  WASD/arrows move  •  mouse wheel zoom  •  Shift faster  •  R reset\nAI: I toggle manual/AI  •  1/2 choose checkpoint  •  R retry  •  M expand map"
	controls.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	controls.add_theme_font_size_override("font_size", 11)
	controls.add_theme_color_override("font_color", Color(0.66, 0.76, 0.80))
	content.add_child(controls)

	var footer := HBoxContainer.new()
	footer.alignment = BoxContainer.ALIGNMENT_END
	content.add_child(footer)
	close_button = Button.new()
	close_button.text = "Close and drive"
	close_button.disabled = true
	close_button.pressed.connect(_on_close_pressed)
	footer.add_child(close_button)
	_build_training_tab(tabs)

	gear_button = Button.new()
	gear_button.name = "SettingsCog"
	gear_button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	gear_button.offset_left = -58.0
	gear_button.offset_top = 16.0
	gear_button.offset_right = -16.0
	gear_button.offset_bottom = 58.0
	gear_button.text = "×"
	gear_button.tooltip_text = "Open or close settings"
	gear_button.add_theme_font_size_override("font_size", 27)
	gear_button.pressed.connect(_on_gear_pressed)
	root.add_child(gear_button)

	map_notice = PanelContainer.new()
	map_notice.name = "MapNotice"
	map_notice.set_anchors_preset(Control.PRESET_CENTER_TOP)
	map_notice.offset_left = -210.0
	map_notice.offset_top = 16.0
	map_notice.offset_right = 210.0
	map_notice.offset_bottom = 54.0
	map_notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_notice.visible = false
	var notice_style := StyleBoxFlat.new()
	notice_style.bg_color = Color(0.035, 0.065, 0.08, 0.93)
	notice_style.border_color = Color(0.32, 0.62, 0.66, 0.95)
	notice_style.set_border_width_all(1)
	notice_style.set_corner_radius_all(7)
	notice_style.content_margin_left = 12.0
	notice_style.content_margin_right = 12.0
	notice_style.content_margin_top = 7.0
	notice_style.content_margin_bottom = 7.0
	map_notice.add_theme_stylebox_override("panel", notice_style)
	root.add_child(map_notice)
	map_notice_label = Label.new()
	map_notice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	map_notice_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_notice_label.add_theme_font_size_override("font_size", 12)
	map_notice_label.add_theme_color_override("font_color", Color(0.85, 0.95, 0.97))
	map_notice.add_child(map_notice_label)
	map_notice_timer = Timer.new()
	map_notice_timer.one_shot = true
	map_notice_timer.timeout.connect(map_notice.hide)
	add_child(map_notice_timer)
	popup_root = popup_contents


func _build_training_tab(tabs: TabContainer) -> void:
	var training_tab := VBoxContainer.new()
	training_tab.name = "AI Training"
	training_tab.add_theme_constant_override("separation", 8)
	tabs.add_child(training_tab)

	training_status_label = Label.new()
	training_status_label.name = "TrainingStatus"
	training_status_label.text = "No training run active. Configure PPO below, then press Start."
	training_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	training_status_label.custom_minimum_size.y = 38.0
	training_tab.add_child(training_status_label)
	training_progress = ProgressBar.new()
	training_progress.name = "TrainingProgress"
	training_progress.show_percentage = false
	training_progress.custom_minimum_size.y = 17.0
	training_tab.add_child(training_progress)

	var actions := HBoxContainer.new()
	training_tab.add_child(actions)
	training_start_button = _training_action(actions, "Start training", _on_training_start_pressed)
	training_pause_button = _training_action(actions, "Pause", _on_training_pause_pressed)
	training_resume_button = _training_action(actions, "Resume", _on_training_resume_pressed)
	training_stop_button = _training_action(actions, "End and save", _on_training_stop_pressed)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	training_tab.add_child(scroll)
	var fields := VBoxContainer.new()
	fields.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fields.add_theme_constant_override("separation", 7)
	scroll.add_child(fields)
	_training_section(fields, "PROCESS AND MODEL")
	var python_relative := "res://.venv-ai/Scripts/python.exe" if OS.get_name() == "Windows" else "res://.venv-ai/bin/python"
	var python_default := ProjectSettings.globalize_path(python_relative)
	training_inputs["python_path"] = _training_text_field(fields, "Python executable", python_default)
	training_inputs["godot_path"] = _training_text_field(fields, "Godot executable", OS.get_executable_path())
	training_inputs["run_name"] = _training_text_field(fields, "Run name (blank = new timestamped run)", "")
	training_inputs["resume_path"] = _training_text_field(fields, "Resume checkpoint (.zip, optional)", "")
	training_inputs["output_root"] = _training_text_field(fields, "Output folder (blank = project ai/)", "")
	training_inputs["workers"] = _training_number_field(fields, "Parallel Godot workers", 1, 32, 1, 1)
	training_inputs["steps"] = _training_number_field(fields, "Total training timesteps", 1024, 50000000, 1, 1000000)
	training_inputs["seed"] = _training_number_field(fields, "Training seed", 1, 2147483646, 1, 7)
	_training_section(fields, "PPO AND EVALUATION")
	training_inputs["learning_rate"] = _training_number_field(fields, "Learning rate", 0.000001, 0.01, 0.000001, 0.0003)
	training_inputs["batch_size"] = _training_number_field(fields, "PPO batch size", 16, 1024, 16, 64)
	training_inputs["gamma"] = _training_number_field(fields, "Discount factor (gamma)", 0.8, 0.9999, 0.0001, 0.995)
	training_inputs["entropy_coefficient"] = _training_number_field(fields, "Entropy coefficient", 0.0, 0.2, 0.001, 0.01)
	training_inputs["checkpoint_every"] = _training_number_field(fields, "Checkpoint interval (steps)", 1, 5000000, 1, 10240)
	training_inputs["eval_every"] = _training_number_field(fields, "Evaluation interval (0 disables)", 0, 5000000, 1000, 50000)
	training_inputs["eval_episodes"] = _training_number_field(fields, "Episodes per evaluation", 8, 256, 1, 16)
	training_inputs["success_threshold"] = _training_number_field(fields, "Early-stop success threshold", 0.0, 1.0, 0.01, 0.9)
	training_inputs["early_stop_patience"] = _training_number_field(fields, "Successful evaluations to stop (0 disables)", 0, 20, 1, 3)
	_training_section(fields, "REWARD AND PENALTY WEIGHTS")
	for definition in REWARD_FIELDS:
		reward_inputs[definition[0]] = _training_number_field(
			fields, String(definition[1]), 0.0, 1000.0, 0.01, float(definition[2])
		)
	var note := Label.new()
	note.text = "Each worker runs an empty-road Godot world. Changes above apply only to a new run. Pausing waits for the current environment step; End saves the latest model. Changing rewards creates a new experiment—do not resume an older checkpoint with different weights."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 11)
	fields.add_child(note)


func _training_action(parent: HBoxContainer, title: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = title
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(handler)
	parent.add_child(button)
	return button


func _training_section(parent: VBoxContainer, title: String) -> void:
	parent.add_child(HSeparator.new())
	var label := Label.new()
	label.text = title
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.65, 0.85, 0.91))
	parent.add_child(label)


func _training_text_field(parent: VBoxContainer, title: String, default_value: String) -> LineEdit:
	var label := Label.new()
	label.text = title
	parent.add_child(label)
	var input := LineEdit.new()
	input.text = default_value
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(input)
	return input


func _training_number_field(
	parent: VBoxContainer, title: String, minimum: float, maximum: float,
	step_size: float, default_value: float
) -> SpinBox:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = title
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var input := SpinBox.new()
	input.min_value = minimum
	input.max_value = maximum
	input.step = step_size
	input.value = default_value
	input.custom_minimum_size.x = 145.0
	row.add_child(input)
	return input


func _training_config() -> Dictionary:
	var config := {}
	for key in training_inputs:
		var field: Control = training_inputs[key]
		config[key] = field.value if field is SpinBox else field.text.strip_edges()
	var rewards := {}
	for key in reward_inputs:
		rewards[key] = reward_inputs[key].value
	config["reward_config"] = rewards
	return config


func _on_training_start_pressed() -> void:
	var config := _training_config()
	if int(config["eval_every"]) == 0 and int(config["early_stop_patience"]) > 0:
		training_status_label.text = "Set early-stop patience to 0 when evaluation is disabled."
		return
	var error: String = training_controller.call("start_training", config)
	if not error.is_empty():
		training_status_label.text = error


func _on_training_pause_pressed() -> void:
	if training_controller.call("pause_training"):
		training_status_label.text = "Pause requested; waiting for the current PPO step."


func _on_training_resume_pressed() -> void:
	if training_controller.call("resume_training"):
		training_status_label.text = "Resume requested."


func _on_training_stop_pressed() -> void:
	if training_controller.call("stop_training"):
		training_status_label.text = "Stop requested. The trainer will save the latest model."


func _on_training_status_changed(status: Dictionary) -> void:
	if training_status_label == null:
		return
	var active: bool = training_controller.call("is_training_active")
	var state := String(status.get("state", "idle"))
	var steps := int(status.get("timesteps", 0))
	var total := maxi(int(status.get("total_steps", 1)), 1)
	var message := String(status.get("message", "Configure PPO, then press Start training."))
	training_status_label.text = "%s · %d / %d steps · %s" % [state.capitalize(), steps, total, message]
	if state == "failed" and status.has("log_path"):
		training_status_label.text += "\nLog: " + String(status["log_path"])
	var evaluation: Dictionary = status.get("last_evaluation", {})
	if not evaluation.is_empty():
		training_status_label.text += "\nLast evaluation: %.0f%% success, %.0f%% crash." % [
			float(evaluation.get("success_rate", 0.0)) * 100.0,
			float(evaluation.get("crash_rate", 0.0)) * 100.0
		]
	training_progress.max_value = total
	training_progress.value = mini(steps, total)
	training_start_button.disabled = active
	training_pause_button.disabled = not active or state != "running"
	training_resume_button.disabled = not active or state != "paused"
	training_stop_button.disabled = not active or state in ["stopping", "saving"]
	for field in training_inputs.values():
		field.editable = not active
	for field in reward_inputs.values():
		field.editable = not active


func _on_random_seed_toggled(enabled: bool) -> void:
	seed_edit.editable = not enabled


func _on_generate_pressed() -> void:
	var seed_value := 0
	if not random_seed_check.button_pressed:
		if not seed_edit.text.is_valid_int():
			set_status("Enter a whole-number seed, or choose Random every time.")
			return
		seed_value = int(seed_edit.text)
	generate_requested.emit(
		seed_value,
		random_seed_check.button_pressed,
		generator_option.get_selected_id()
	)


func _on_checkpoint_pressed(checkpoint_id: int) -> void:
	if not map_generated:
		set_status("Generate a map first; the AI needs connected roads to plan a trip.")
		return
	checkpoint_requested.emit(checkpoint_id)
	set_popup_open(false)


func _on_target_slider_changed(value: float) -> void:
	_update_target_label(value)
	target_distance_changed.emit(value)


func _update_target_label(value: float) -> void:
	if target_label != null:
		target_label.text = "AI goal length: %d units" % roundi(value)


func _on_close_pressed() -> void:
	if map_generated:
		set_popup_open(false)


func _on_gear_pressed() -> void:
	if popup_open:
		if map_generated:
			set_popup_open(false)
	else:
		set_popup_open(true)
