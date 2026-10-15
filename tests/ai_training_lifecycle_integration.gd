extends SceneTree
## Optional slow integration test: starts one real PPO worker, pauses, resumes,
## then requests a clean stop and checks that a model was saved.

const CONTROLLER_SCRIPT := preload("res://scripts/ai_training_controller.gd")
const RUN_NAME := "codex_gui_lifecycle_test"


func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	var controller := CONTROLLER_SCRIPT.new() as Node
	root.add_child(controller)
	var output_root := ProjectSettings.globalize_path("res://ai/runs/gui_lifecycle_test_output")
	var config := {
		"python_path": ProjectSettings.globalize_path("res://.venv-ai/Scripts/python.exe"),
		"godot_path": OS.get_executable_path(),
		"run_name": RUN_NAME,
		"output_root": output_root,
		"workers": 2,
		"steps": 1024,
		"seed": 73,
		"checkpoint_every": 2048,
		"eval_every": 0,
		"eval_episodes": 8,
		"early_stop_patience": 0,
		"success_threshold": 0.9,
		"reward_config": {"progress_gain": 0.75},
	}
	var error: String = controller.call("start_training", config)
	if not error.is_empty():
		push_error("Could not launch PPO from Godot: " + error)
		quit(1)
		return
	if not await _wait_for_state(controller, "running", 60000):
		controller.call("stop_training")
		push_error("PPO did not enter running state: " + str(controller.get("latest_status")))
		quit(1)
		return
	if not controller.call("pause_training") or not await _wait_for_state(controller, "paused", 30000):
		controller.call("stop_training")
		push_error("PPO did not pause: " + str(controller.get("latest_status")))
		quit(1)
		return
	if not controller.call("resume_training") or not await _wait_for_state(controller, "running", 30000):
		controller.call("stop_training")
		push_error("PPO did not resume: " + str(controller.get("latest_status")))
		quit(1)
		return
	if not controller.call("stop_training") or not await _wait_for_state(controller, "stopped", 120000):
		push_error("PPO did not stop cleanly: " + str(controller.get("latest_status")))
		quit(1)
		return
	var model_path := output_root.path_join("models").path_join(RUN_NAME + ".zip")
	if not FileAccess.file_exists(model_path):
		push_error("Stopped PPO did not save its current model: " + model_path)
		quit(1)
		return
	print("AI TRAINING LIFECYCLE PASSED: start, pause, resume, clean stop, saved model.")
	quit(0)


func _wait_for_state(controller: Node, wanted: String, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		await process_frame
		var status: Dictionary = controller.get("latest_status")
		var state := String(status.get("state", ""))
		if state == wanted:
			return true
		if state in ["failed", "completed", "stopped"] and state != wanted:
			return false
	return false
