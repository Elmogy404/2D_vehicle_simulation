extends SceneTree
## Visual review only: example telemetry is confined to this preview script.

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var settings: Node = main.get_node("SettingsPopup")
	settings.get_node("AiTrainingController").set_process(false)
	var tabs: TabContainer = settings.find_child("SettingsTabs", true, false)
	tabs.current_tab = 1
	var workers := []
	for i in range(4):
		workers.append({"worker": i+1, "stage": 3, "episode_stage": 3, "turn_level": 1,
			"progress": 0.35 + float(i) * 0.12, "speed_kmh": 48 + i*4, "recent_success_rate": 0.65 + float(i)*0.05, "recent_episodes": 20})
	var history := []
	for i in range(60):
		history.append({"steps": i*1000, "success": 0.25 + float(i)*0.007 + sin(float(i)*0.4)*0.035, "return": 12.5})
	var stages := []
	for i in range(8):
		stages.append({"stage": i, "episodes": 8, "successes": maxi(0,8-i), "success_rate": float(maxi(0,8-i))/8.0,
			"mean_progress": 0.95-float(i)*0.08, "crash_rate": float(i)/16.0, "stall_rate": 0.0,
			"success_interval": [maxf(0.0,0.65-float(i)*0.1),minf(1.0,1.05-float(i)*0.07)]})
	settings.call("_on_training_status_changed", {"state": "running", "phase": "collecting", "run_name": "PREVIEW / EXAMPLE TELEMETRY", "workers": 4,
		"timesteps": 59400, "total_steps": 300000, "message": "Collecting experience · first-turn practice at 75 km/h",
		"performance": {"steps_per_second": 680, "elapsed_seconds": 94, "eta_seconds": 354}, "next_eval_step": 100000,
		"training_metrics": {"episodes": 200, "success_rate": 0.68, "crash_rate": 0.21, "stall_rate": 0.08, "timeout_rate": 0.03, "mean_return": 24.76, "mean_progress": 0.73},
		"worker_metrics": workers, "history": history, "optimizer": {"explained_variance": 0.72, "approx_kl": 0.008, "entropy_loss": -1.62},
		"last_evaluation": {"timesteps": 50000, "success_rate": 0.5625, "crash_rate": 0.31, "episodes": 64, "duration_seconds": 7.5,
			"longest_stage_success_rate": 0.125, "early_stop_streak": 0, "early_stop_patience": 3, "stages": stages}})
	settings.get("training_start_button").disabled = true
	settings.get("training_pause_button").disabled = false
	settings.get("training_stop_button").disabled = false
	for _frame in range(5):
		await process_frame
	var suffix := ""
	if OS.get_cmdline_user_args().has("--details"):
		var dashboard: Node = settings.get("training_dashboard")
		var scroll: ScrollContainer = dashboard.get("worker_table").get_parent().get_parent()
		scroll.scroll_vertical = 520
		await process_frame
		suffix = "_details"
	await RenderingServer.frame_post_draw
	var output := ProjectSettings.globalize_path("res://ai/runs/training_dashboard_preview%s.png" % suffix)
	root.get_texture().get_image().save_png(output)
	print("GUI PREVIEW SAVED: ",output)
	quit()
