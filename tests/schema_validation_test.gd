extends SceneTree
## Validate the shared interface schema, both boundaries, and a real generated observation.

const INTERFACE_SCHEMA = preload("res://scripts/ai_interface_schema.gd")

class TestWorld extends "res://ai/rl_training_world.gd":
	var response: Dictionary = {}

	func _ready() -> void:
		_setup_training_world()
		set_process(false)

	func _send_message(message: Dictionary) -> void:
		response = message


var failures := 0
var checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr("FAIL: ", message)


func _valid_observation() -> Array:
	var observation := []
	observation.resize(INTERFACE_SCHEMA.observation_size())
	observation.fill(0.0)
	observation[observation.size() - 1] = 1.0
	return observation


func _errors_text(errors: Array) -> String:
	var parts := PackedStringArray()
	for error in errors:
		parts.append(String(error))
	return "; ".join(parts)


func _run() -> void:
	_check(INTERFACE_SCHEMA.schema_error().is_empty(), "schema loads: %s" % INTERFACE_SCHEMA.schema_error())
	_check(INTERFACE_SCHEMA.schema_version() == 1, "schema version")
	_check(INTERFACE_SCHEMA.observation_size() == 31, "observation size comes from schema")
	_check(INTERFACE_SCHEMA.action_size() == 2, "action size comes from schema")
	_check(INTERFACE_SCHEMA.observation_dtype() == "float32", "observation dtype comes from schema")

	var metadata := INTERFACE_SCHEMA.metadata()
	_check(metadata.get("schema_version") == 1, "metadata version")
	_check(metadata.get("observation_size") == 31, "metadata observation size")
	_check(metadata.get("action_size") == 2, "metadata action size")

	var observation := _valid_observation()
	_check(INTERFACE_SCHEMA.validate_observation(observation).is_empty(), "valid observation passes")

	var wrong_shape := observation.duplicate()
	wrong_shape.pop_back()
	_check(not INTERFACE_SCHEMA.validate_observation(wrong_shape).is_empty(), "wrong observation shape fails")

	var non_finite := observation.duplicate()
	non_finite[2] = NAN
	_check(_errors_text(INTERFACE_SCHEMA.validate_observation(non_finite)).contains("finite"), "NaN observation fails")
	non_finite = observation.duplicate()
	non_finite[2] = INF
	_check(not INTERFACE_SCHEMA.validate_observation(non_finite).is_empty(), "Inf observation fails")

	var non_numeric := observation.duplicate()
	non_numeric[2] = "not-a-number"
	_check(not INTERFACE_SCHEMA.validate_observation(non_numeric).is_empty(), "non-numeric observation fails")

	var out_of_bounds := observation.duplicate()
	out_of_bounds[22] = -0.1
	_check(_errors_text(INTERFACE_SCHEMA.validate_observation(out_of_bounds)).contains("outside"), "observation bound fails")

	var reserved := observation.duplicate()
	reserved[30] = 0.0
	_check(_errors_text(INTERFACE_SCHEMA.validate_observation(reserved)).contains("reserved"), "reserved signal fails")

	var action_result := INTERFACE_SCHEMA.validate_action([0.25, -0.5], true)
	_check(bool(action_result.get("valid", false)), "valid action passes")
	_check(not bool(action_result.get("clipped", false)), "valid action is not clipped")
	_check(action_result.get("value") == Vector2(0.25, -0.5), "action field order")

	var clipped := INTERFACE_SCHEMA.validate_action([-2.0, 3.0], true)
	_check(bool(clipped.get("valid", false)), "out-of-range action remains accepted")
	_check(bool(clipped.get("clipped", false)), "out-of-range action is explicitly clipped")
	_check(clipped.get("value") == Vector2(-1.0, 1.0), "clipped action bounds")

	var rejected := INTERFACE_SCHEMA.validate_action([-2.0, 3.0], false)
	_check(not bool(rejected.get("valid", false)), "strict mode rejects out-of-range action")

	for malformed in [[0.0], [0.0, 0.0, 0.0], ["bad", 0.0], [NAN, 0.0], [INF, 0.0], null]:
		_check(not bool(INTERFACE_SCHEMA.validate_action(malformed, true).get("valid", false)), "malformed action fails: %s" % str(malformed))

	_check(INTERFACE_SCHEMA.compatibility_error(1, 31, 2).is_empty(), "compatible protocol metadata")
	_check(INTERFACE_SCHEMA.compatibility_error(2, 31, 2).contains("schema version"), "schema version mismatch")
	_check(INTERFACE_SCHEMA.compatibility_error(1, 30, 2).contains("observation"), "observation size mismatch")
	_check(INTERFACE_SCHEMA.compatibility_error(1, 31, 3).contains("action"), "action size mismatch")
	_check(INTERFACE_SCHEMA.compatibility_error(1, 31, 2, "remote", "float64", "float32").contains("observation dtype"), "observation dtype mismatch")
	_check(not INTERFACE_SCHEMA.validate_remote_metadata({}).is_empty(), "missing protocol metadata fails")
	_check(INTERFACE_SCHEMA.validate_remote_metadata(metadata).is_empty(), "protocol metadata passes")

	var world := TestWorld.new()
	root.add_child(world)
	var reset_error: String = await world._reset_episode(4101, false, 0)
	_check(reset_error.is_empty(), "real environment reset")
	var real_observation: Array = world._get_observation()
	_check(INTERFACE_SCHEMA.validate_observation(real_observation).is_empty(),
		"real generated observation passes: %s" % _errors_text(INTERFACE_SCHEMA.validate_observation(real_observation)))
	await world._step_episode([0.0, 0.35])
	_check(not world.response.has("error"), "real valid action step passes: %s" % str(world.response.get("error", "")))
	_check(INTERFACE_SCHEMA.validate_observation(world.response.get("observation", [])).is_empty(),
		"real step observation passes")
	_check(world.response.get("schema_version") == 1, "real step response carries schema version")
	_check(world.response.get("info", {}).get("interface_schema", {}).get("schema_version") == 1,
		"real step info carries interface metadata")
	await world._step_episode(["bad", 0.0])
	_check(world.response.has("error"), "real malformed action is rejected")
	_check(String(world.response.get("error", "")).contains("action schema error"), "real malformed action error is actionable")
	world.queue_free()
	await process_frame

	print("SCHEMA VALIDATION: %d checks, failures=%d" % [checks, failures])
	quit(1 if failures else 0)
