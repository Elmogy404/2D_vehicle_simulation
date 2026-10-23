extends VBoxContainer

const CHART := preload("res://scripts/training_chart.gd")
const INK := Color("e6eef7")
const MUTED := Color("91a7bb")
const TEAL := Color("55d8c5")
const BLUE := Color("7caaff")
var status_label: Label
var state_label: Label
var run_label: Label
var progress: ProgressBar
var actions: HBoxContainer
var setup_fields: VBoxContainer
var metric_labels: Dictionary = {}
var worker_table: Tree
var evaluation_table: Tree
var chart: Control
var diagnostic_label: Label
var context_label: Label
var model_label: Label
var runtime_label: Label
var latest: Dictionary = {}

func _ready() -> void:
	add_theme_constant_override("separation", 10)
	var heading := HBoxContainer.new()
	add_child(heading)
	var title := _label("TRAINING CONTROL", 18, INK)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(title)
	state_label = _label("IDLE", 12, TEAL)
	heading.add_child(state_label)
	run_label = _label("Configure a new experiment in Run setup", 11, MUTED)
	run_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	add_child(run_label)
	progress = ProgressBar.new()
	progress.name = "TrainingProgress"
	progress.custom_minimum_size.y = 8
	progress.show_percentage = false
	var fill := _style(Color("55d8c5"), 4)
	progress.add_theme_stylebox_override("fill", fill)
	progress.add_theme_stylebox_override("background", _style(Color("172b3c"), 4))
	add_child(progress)
	var run_metrics := GridContainer.new()
	run_metrics.columns = 4
	run_metrics.add_theme_constant_override("h_separation", 8)
	add_child(run_metrics)
	for definition in [["steps", "TRAINING STEPS"], ["fps", "STEPS / SECOND"], ["elapsed", "ELAPSED"], ["eta", "TRAINING ETA"]]:
		_card(run_metrics, definition[0], definition[1], BLUE)
	metric_labels["fps"].tooltip_text = "Recent experience collection and policy updates; checkpoint evaluation and pauses are excluded."
	metric_labels["eta"].tooltip_text = "Estimate from recent training throughput. Future evaluation time is additional."
	actions = HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	add_child(actions)
	status_label = _label("Ready for a new training run", 12, MUTED)
	status_label.name = "TrainingStatus"
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(status_label)
	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(tabs)
	var overview := _scroll_page(tabs, "Overview")
	_section(overview, "LIVE TRAINING", "Recent completed episodes across all workers. Separate from checkpoint evaluation.")
	var outcomes := GridContainer.new()
	outcomes.columns = 3
	outcomes.add_theme_constant_override("h_separation", 8)
	outcomes.add_theme_constant_override("v_separation", 8)
	overview.add_child(outcomes)
	for definition in [["train_success", "SUCCESS", TEAL], ["train_crash", "CRASH", Color("ff9a9a")], ["train_stall", "STALL / TIMEOUT", Color("efc475")], ["return", "MEAN RETURN", BLUE], ["progress", "TRIP PROGRESS", BLUE], ["episodes", "EPISODES IN WINDOW", MUTED]]:
		_card(outcomes, definition[0], definition[1], definition[2])
	chart = CHART.new()
	overview.add_child(chart)
	_section(overview, "WORKER CURRICULUM", "First-turn practice progresses through 45, 75, then 150 km/h. Advancement requires 80% over 20 frontier episodes.")
	worker_table = _table(overview, ["Worker", "Frontier / trip", "Turn practice", "Speed / progress", "Recent success"], 148)
	runtime_label = _label("Reset timings appear when workers begin collecting experience.", 11, MUTED)
	runtime_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	overview.add_child(runtime_label)
	_section(overview, "CHECKPOINT EVALUATION", "Held-out, deterministic episodes at full vehicle speed. Counts and intervals show how much evidence is available.")
	context_label = _label("Waiting for the first evaluation", 12, MUTED)
	context_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	overview.add_child(context_label)
	evaluation_table = _table(overview, ["Stage", "Success", "Episodes", "Progress", "Crash / stall", "95% interval"], 250)
	_section(overview, "LEARNING DIAGNOSTICS", "Value fit, policy change, and exploration from the latest PPO update.")
	diagnostic_label = _label("Optimizer statistics appear after the first update.", 12, MUTED)
	diagnostic_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	overview.add_child(diagnostic_label)
	model_label = _label("No checkpoint saved yet", 11, MUTED)
	model_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	overview.add_child(model_label)
	var links := HBoxContainer.new()
	overview.add_child(links)
	for definition in [["Open training log", "log_path"], ["Open checkpoint folder", "last_checkpoint"]]:
		var button := Button.new()
		button.text = definition[0]
		button.pressed.connect(_open_artifact.bind(definition[1]))
		links.add_child(button)
	setup_fields = _scroll_page(tabs, "Run setup")
	_section(setup_fields, "NEW EXPERIMENT", "Version 3 improves rewards and the turn curriculum. Start fresh; earlier environments cannot be resumed into this version.")

func _style(color: Color, radius: int = 8) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 9
	style.content_margin_bottom = 9
	return style

func _label(text_value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text_value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label

func _card(parent: Node, key: String, title: String, accent: Color) -> void:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _style(Color("112536")))
	parent.add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)
	box.add_child(_label(title, 10, MUTED))
	var value := _label("—", 21, accent)
	value.name = "Metric_" + key
	box.add_child(value)
	metric_labels[key] = value

func _scroll_page(tabs: TabContainer, title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 10)
	scroll.add_child(box)
	return box

func _section(parent: Node, title: String, detail: String) -> void:
	parent.add_child(_label(title, 12, TEAL))
	var label := _label(detail, 11, MUTED)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)

func _table(parent: Node, titles: Array, height: float) -> Tree:
	var tree := Tree.new()
	tree.hide_root = true
	tree.columns = titles.size()
	tree.column_titles_visible = true
	tree.custom_minimum_size.y = height
	tree.add_theme_font_size_override("font_size", 11)
	for i in range(titles.size()):
		tree.set_column_title(i, titles[i])
	parent.add_child(tree)
	return tree

func _percent(value: Variant) -> String:
	return "%.1f%%" % (float(value) * 100.0) if value != null else "—"

func _duration(value: Variant) -> String:
	if value == null:
		return "—"
	var seconds := maxi(0, int(value))
	return "%dh %02dm" % [seconds / 3600, seconds % 3600 / 60] if seconds >= 3600 else "%dm %02ds" % [seconds / 60, seconds % 60]

func _metric(key: String, value: String) -> void:
	metric_labels[key].text = value

func update_status(status: Dictionary) -> void:
	latest = status
	var state := String(status.get("state", "idle"))
	state_label.text = String(status.get("phase", state)).to_upper() if state == "running" else state.to_upper()
	state_label.add_theme_color_override("font_color", Color("ff9a9a") if state == "failed" else TEAL)
	run_label.text = String(status.get("run_name", "New experiment")) + "  /  %d workers" % int(status.get("workers", 0))
	var steps := int(status.get("timesteps", 0))
	var total := maxi(1, int(status.get("total_steps", 1)))
	progress.max_value = total
	progress.value = mini(steps, total)
	_metric("steps", "%s / %s" % [_compact(steps), _compact(total)])
	var performance: Dictionary = status.get("performance", {})
	_metric("fps", "%.0f" % float(performance["steps_per_second"]) if performance.has("steps_per_second") else "—")
	_metric("elapsed", _duration(performance.get("elapsed_seconds")))
	_metric("eta", _duration(performance.get("eta_seconds")) if state == "running" else "—")
	var training: Dictionary = status.get("training_metrics", {})
	_metric("train_success", _percent(training.get("success_rate")))
	_metric("train_crash", _percent(training.get("crash_rate")))
	_metric("train_stall", _percent(float(training.get("stall_rate", 0)) + float(training.get("timeout_rate", 0))) if training.get("episodes", 0) > 0 else "—")
	_metric("return", "%.2f" % float(training["mean_return"]) if training.has("mean_return") else "—")
	_metric("progress", _percent(training.get("mean_progress")))
	_metric("episodes", str(training.get("episodes", 0)))
	chart.call("set_history", status.get("history", []))
	worker_table.clear()
	var worker_root := worker_table.create_item()
	var reset_ms := 0.0
	var worker_count := 0
	var reused := 0
	for worker in status.get("worker_metrics", []):
		if worker.is_empty():
			continue
		worker_count += 1
		reset_ms += float(worker.get("reset_ms", 0))
		reused += int(worker.get("map_reused", false))
		var row := worker_table.create_item(worker_root)
		row.set_text(0, "Worker %d" % int(worker.get("worker", 0)))
		row.set_text(1, "%d / %d" % [int(worker.get("stage", 0)), int(worker.get("episode_stage", 0))])
		var stage := int(worker.get("stage", 0))
		row.set_text(2, ["45 km/h", "75 km/h", "Full speed"][clampi(int(worker.get("turn_level", 0)), 0, 2)] if stage == 3 else ("Upcoming" if stage < 3 else "Complete"))
		row.set_text(3, "%.0f km/h / %s" % [float(worker.get("speed_kmh", 0)), _percent(worker.get("progress"))])
		row.set_text(4, "%s (%d/20)" % [_percent(worker.get("recent_success_rate")), int(worker.get("recent_episodes", 0))])
	if worker_count > 0:
		runtime_label.text = "Latest resets: %.1f ms average | Cached maps: %d / %d workers | Evaluation time: %s" % [reset_ms / worker_count, reused, worker_count, _duration(performance.get("evaluation_seconds"))]
	else:
		runtime_label.text = "Reset timings appear when workers begin collecting experience."
	var evaluation: Dictionary = status.get("last_evaluation", {})
	context_label.text = "Next evaluation: %s steps" % str(status.get("next_eval_step", "not scheduled"))
	if not evaluation.is_empty():
		context_label.text = "At %d steps  •  %s success  •  %s crash  •  %d episodes  •  %.1fs\nLongest routes: %s  •  Early-stop streak %d / %d" % [int(evaluation.get("timesteps", 0)), _percent(evaluation.get("success_rate")), _percent(evaluation.get("crash_rate")), int(evaluation.get("episodes", 0)), float(evaluation.get("duration_seconds", 0)), _percent(evaluation.get("longest_stage_success_rate")), int(evaluation.get("early_stop_streak", 0)), int(evaluation.get("early_stop_patience", 0))]
	var evaluation_progress: Dictionary = status.get("evaluation_progress", {})
	if status.get("phase") == "evaluating":
		context_label.text = "Evaluating %d / %d episodes across %d worlds" % [int(evaluation_progress.get("completed", 0)), int(evaluation_progress.get("total", 0)), int(evaluation_progress.get("workers", 0))]
	evaluation_table.clear()
	var evaluation_root := evaluation_table.create_item()
	for stage in evaluation.get("stages", []):
		var row := evaluation_table.create_item(evaluation_root)
		row.set_text(0, "Stage %d" % int(stage.get("stage", 0)))
		row.set_text(1, _percent(stage.get("success_rate")))
		row.set_text(2, "%d / %d" % [int(stage.get("successes", 0)), int(stage.get("episodes", 0))])
		row.set_text(3, _percent(stage.get("mean_progress")))
		row.set_text(4, "%s / %s" % [_percent(stage.get("crash_rate")), _percent(stage.get("stall_rate"))])
		var interval: Array = stage.get("success_interval", [0.0, 1.0])
		row.set_text(5, "%s–%s" % [_percent(interval[0]), _percent(interval[1])])
	var optimizer: Dictionary = status.get("optimizer", {})
	var pieces: Array[String] = []
	for key in ["explained_variance", "approx_kl", "entropy_loss", "value_loss", "clip_fraction"]:
		if optimizer.has(key):
			pieces.append("%s: %.4f" % [key.replace("_", " "), float(optimizer[key])])
	diagnostic_label.text = "  |  ".join(pieces) if not pieces.is_empty() else "Optimizer statistics appear after the first update."
	model_label.text = "Latest checkpoint: " + String(status.get("last_model_path", status.get("last_checkpoint", "not saved yet")))
	if status.has("best_model_path"):
		model_label.text += "\nBest checkpoint: " + String(status["best_model_path"])

func _compact(value: int) -> String:
	return "%.1fM" % (float(value) / 1000000) if value >= 1000000 else ("%.1fk" % (float(value) / 1000) if value >= 1000 else str(value))

func _open_artifact(key: String) -> void:
	var path := String(latest.get(key, ""))
	if key == "last_checkpoint":
		path = String(latest.get("last_model_path", path))
		path = path.get_base_dir() if not path.is_empty() else ProjectSettings.globalize_path("res://ai/models")
	if not path.is_empty() and (FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path)):
		OS.shell_open(path)
