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
	or float(config.get("reward_config", {}).get("max_speed_reward", 0.0)) != 0.05:
		push_error("Training tab defaults do not match the existing PPO trainer.")
		quit(1)
		return
	var controller := settings.get_node("AiTrainingController")
	if controller == null or not controller.has_method("pause_training") \
	or not controller.has_method("resume_training") or not controller.has_method("stop_training"):
		push_error("The Training tab is not connected to process controls.")
		quit(1)
		return
	print("AI TRAINING UI TEST PASSED: two tabs, PPO defaults, rewards, and process controls are present.")
	quit(0)
