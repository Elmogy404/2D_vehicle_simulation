extends Node
## Launches and monitors the separate Python PPO process. No training runs in
## Godot's render/physics loop, and a clean stop is handled by train.py.

signal status_changed(status: Dictionary)

const STATUS_PATH := "res://ai/runs/gui_training_status.json"
const CONTROL_PATH := "res://ai/runs/gui_training_control.json"

var process_id := -1
var run_id := ""
var latest_status: Dictionary = {}
var poll_remaining := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var previous := _read_status()
	if not previous.is_empty():
		latest_status = previous
		run_id = String(previous.get("run_id", ""))
		var previous_pid := int(previous.get("pid", -1))
		if previous_pid > 0 and OS.is_process_running(previous_pid) \
		and String(previous.get("state", "")) in ["starting", "running", "paused", "stopping", "saving"]:
			process_id = previous_pid
		elif String(previous.get("state", "")) in ["starting", "running", "paused", "stopping", "saving"]:
			latest_status["state"] = "failed"
			latest_status["message"] = "The previous training process is no longer running."
			_write_json(STATUS_PATH, latest_status)
		status_changed.emit(latest_status)


func _process(delta: float) -> void:
	poll_remaining -= delta
	if poll_remaining > 0.0:
		return
	poll_remaining = 0.5
	var status := _read_status()
	if not status.is_empty() and String(status.get("run_id", "")) == run_id:
		latest_status = status
	if process_id > 0 and not OS.is_process_running(process_id):
		process_id = -1
		if String(latest_status.get("state", "")) not in ["completed", "stopped", "failed"]:
			latest_status["state"] = "failed"
			latest_status["message"] = "Trainer exited unexpectedly. Check %s" % String(latest_status.get("log_path", "ai/runs"))
			_write_json(STATUS_PATH, latest_status)
	status_changed.emit(latest_status)


func is_training_active() -> bool:
	return process_id > 0 and OS.is_process_running(process_id)


func start_training(config: Dictionary) -> String:
	if is_training_active():
		return "A training process is already running. Stop it before starting another."
	var runs_path := ProjectSettings.globalize_path("res://ai/runs")
	if DirAccess.make_dir_recursive_absolute(runs_path) != OK:
		return "Could not create the project ai/runs folder for training status."
	var python_path := String(config.get("python_path", "")).strip_edges()
	var godot_path := String(config.get("godot_path", "")).strip_edges()
	if python_path.is_empty() or not FileAccess.file_exists(python_path):
		return "Select an existing Python executable with the AI dependencies installed."
	if godot_path.is_empty() or not FileAccess.file_exists(godot_path):
		return "Select an existing Godot executable."
	var script_path := ProjectSettings.globalize_path("res://ai/gui_train_launcher.py")
	if not FileAccess.file_exists(script_path):
		return "The Python training launcher is missing."
	var run_name := String(config.get("run_name", "")).strip_edges()
	if run_name.is_empty():
		run_name = "setup2_gui_%d_%d" % [
			int(Time.get_unix_time_from_system()), Time.get_ticks_usec() % 100000
		]
	for character in run_name:
		if not String(character) in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-":
			return "Run name may use only letters, numbers, _ and -."
	var resume_path := String(config.get("resume_path", "")).strip_edges()
	if not resume_path.is_empty():
		if not FileAccess.file_exists(resume_path):
			return "The resume checkpoint file does not exist."
		if not resume_path.get_file().contains(run_name):
			return "Run name must match the checkpoint being resumed."
	var output_root := String(config.get("output_root", "")).strip_edges()
	if output_root.is_empty():
		output_root = ProjectSettings.globalize_path("res://ai")
	if resume_path.is_empty() and FileAccess.file_exists(output_root.path_join("models").path_join(run_name + ".zip")):
		return "A model already uses this run name. Choose a new name or resume its checkpoint."
	run_id = "%d_%d" % [int(Time.get_unix_time_from_system()), Time.get_ticks_usec()]
	var control_path := ProjectSettings.globalize_path(CONTROL_PATH)
	var status_path := ProjectSettings.globalize_path(STATUS_PATH)
	var log_path := ProjectSettings.globalize_path("res://ai/runs/gui_training_%s.log" % run_id)
	var reward_resource_path := "res://ai/runs/gui_rewards_%s.json" % run_id
	var reward_path := ProjectSettings.globalize_path(reward_resource_path)
	var initial_status := {
		"run_id": run_id,
		"state": "starting",
		"timesteps": 0,
		"total_steps": int(config.get("steps", 1000000)),
		"workers": int(config.get("workers", 1)),
		"run_name": run_name,
		"message": "Launching Python PPO trainer",
		"log_path": log_path,
	}
	if not _write_json(reward_resource_path, config.get("reward_config", {})):
		return "Could not save the reward settings for this training run."
	if not _write_json(CONTROL_PATH, {"run_id": run_id, "command": "run"}) \
	or not _write_json(STATUS_PATH, initial_status):
		return "Could not write training control files in the project ai/runs folder."
	var arguments := PackedStringArray([
		script_path,
		"--log-file", log_path,
		"--godot", godot_path,
		"--steps", str(int(config.get("steps", 1000000))),
		"--n-envs", str(int(config.get("workers", 1))),
		"--seed", str(int(config.get("seed", 7))),
		"--learning-rate", str(config.get("learning_rate", 0.0003)),
		"--batch-size", str(int(config.get("batch_size", 64))),
		"--gamma", str(config.get("gamma", 0.995)),
		"--entropy-coefficient", str(config.get("entropy_coefficient", 0.01)),
		"--checkpoint-every", str(int(config.get("checkpoint_every", 10240))),
		"--eval-every", str(int(config.get("eval_every", 50000))),
		"--eval-episodes", str(int(config.get("eval_episodes", 16))),
		"--success-threshold", str(config.get("success_threshold", 0.9)),
		"--early-stop-patience", str(int(config.get("early_stop_patience", 3))),
		"--run-name", run_name,
		"--reward-config-file", reward_path,
		"--control-file", control_path,
		"--status-file", status_path,
		"--gui-log-path", log_path,
		"--run-id", run_id,
	])
	if not String(config.get("output_root", "")).strip_edges().is_empty():
		arguments.append_array(PackedStringArray(["--output-root", output_root]))
	if not resume_path.is_empty():
		arguments.append_array(PackedStringArray(["--resume", resume_path]))
	process_id = OS.create_process(python_path, arguments)
	if process_id <= 0:
		latest_status = initial_status
		latest_status["state"] = "failed"
		latest_status["message"] = "Godot could not launch the Python executable."
		_write_json(STATUS_PATH, latest_status)
		return String(latest_status["message"])
	latest_status = initial_status
	latest_status["pid"] = process_id
	var current_status := _read_status()
	if String(current_status.get("run_id", "")) == run_id \
	and String(current_status.get("state", "")) == "starting":
		_write_json(STATUS_PATH, latest_status)
	status_changed.emit(latest_status)
	return ""


func pause_training() -> bool:
	return is_training_active() and _write_json(CONTROL_PATH, {"run_id": run_id, "command": "pause"})


func resume_training() -> bool:
	return is_training_active() and _write_json(CONTROL_PATH, {"run_id": run_id, "command": "run"})


func stop_training() -> bool:
	return is_training_active() and _write_json(CONTROL_PATH, {"run_id": run_id, "command": "stop"})


func _read_status() -> Dictionary:
	if not FileAccess.file_exists(STATUS_PATH):
		return {}
	var file := FileAccess.open(STATUS_PATH, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	return parsed if parsed is Dictionary else {}


func _write_json(path: String, value: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(value))
	return true
