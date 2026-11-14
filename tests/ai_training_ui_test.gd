extends SceneTree

const MAIN_SCENE := preload("res://scenes/main.tscn")


func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	var main := MAIN_SCENE.instantiate() as Node2D
	root.add_child(main)
	var settings := main.get_node("SettingsPopup")
	var tabs := settings.find_child("SettingsTabs", true, false) as TabContainer
	if tabs == null or tabs.get_tab_count() != 2 \
	or tabs.get_tab_title(0) != "Main" or tabs.get_tab_title(1) != "AI Training":
		push_error("Settings must provide Main and AI Training tabs.")
		quit(1)
		return
	tabs.current_tab = 1
	await process_frame
	var training_tab := tabs.get_child(1) as Control
	if tabs.size.x < 300.0 or tabs.size.y < 300.0 \
	or training_tab == null or training_tab.size.x < 300.0:
		push_error("The AI Training tab has no usable layout area.")
		quit(1)
		return
	var config: Dictionary = settings.call("_training_config")
	if int(config.get("workers", 0)) != 1 or int(config.get("steps", 0)) != 1000000 \
	or float(config.get("reward_config", {}).get("crash_penalty", 0.0)) != 35.0 \
	or float(config.get("reward_config", {}).get("max_speed_reward", -1.0)) != 0.0 \
	or not is_equal_approx(float(config.get("gamma", 0)), 0.999) \
	or int(config.get("eval_episodes", 0)) != 128:
		push_error("Training tab defaults do not match the existing PPO trainer.")
		quit(1)
		return
	var dashboard: Node = settings.get("training_dashboard")
	var workers: SpinBox = settings.get("training_inputs")["workers"]
	var warning: Label = settings.get("training_worker_warning")
	var start_button: Button = settings.get("training_start_button")
	var was_disabled := start_button.disabled
	workers.value = 32
	if warning.visible:
		push_error("Worker warning must be hidden at 32 workers.")
		quit(1)
		return
	for count in [33, 128]:
		workers.value = count
		var large_config: Dictionary = settings.call("_training_config")
		if int(large_config["workers"]) != count or not warning.visible \
		or not warning.text.contains("32") or start_button.disabled != was_disabled:
			push_error("Counts above 32 must remain usable with a non-blocking warning.")
			quit(1)
			return
	workers.value = 0
	if int(workers.value) != 1 or warning.visible:
		push_error("Worker count must retain its minimum of 1 and clear the warning.")
		quit(1)
		return
	settings.call("_on_training_status_changed", {"state": "running", "timesteps": 1000, "total_steps": 10000,
		"phase": "evaluating", "performance": {"steps_per_second": 400.0, "elapsed_seconds": 30.0, "eta_seconds": 20.0},
		"training_metrics": {"episodes": 20, "success_rate": 0.65, "crash_rate": 0.2, "mean_return": 12.0},
		"worker_metrics": [{"worker": 1, "stage": 3, "episode_stage": 3, "turn_level": 1}],
		"evaluation_progress": {"completed": 8, "total": 64, "workers": 4},
		"last_evaluation": {"stages": [{"stage": 3, "episodes": 8, "successes": 5, "success_rate": 0.625, "success_interval": [0.3, 0.9]}]}})
	if dashboard == null or dashboard.get("metric_labels")["train_success"].text != "65.0%" \
	or not dashboard.get("context_label").text.contains("8 / 64"):
		push_error("Dashboard does not display live and evaluation information separately.")
		quit(1)
		return
	var controller := settings.get_node("AiTrainingController")
	if controller == null or not controller.has_method("pause_training") \
	or not controller.has_method("resume_training") or not controller.has_method("stop_training"):
		push_error("The Training tab is not connected to process controls.")
		quit(1)
		return
	print("AI TRAINING UI TEST PASSED: defaults, telemetry, uncapped workers, warning threshold, and process controls.")
	quit(0)
