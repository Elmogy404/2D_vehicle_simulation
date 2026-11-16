extends SceneTree

const REWARD_SCHEMA := preload("res://scripts/reward_config.gd")


func _initialize() -> void:
	var defaults := REWARD_SCHEMA.defaults()
	if defaults.size() != 10 or REWARD_SCHEMA.parameter_order().size() != 10:
		_fail("Reward schema must expose ten ordered parameters.")
		return
	if not is_equal_approx(float(defaults["goal_reward"]), 40.0) \
	or not is_equal_approx(float(defaults["crash_penalty"]), 35.0) \
	or not is_equal_approx(float(defaults["max_speed_reward"]), 0.0):
		_fail("Reward schema defaults changed unexpectedly.")
		return

	var partial := REWARD_SCHEMA.validate({"goal_reward": 75.0}, true)
	if not bool(partial["valid"]) or not is_equal_approx(float(partial["config"]["goal_reward"]), 75.0) \
	or not is_equal_approx(float(partial["config"]["crash_penalty"]), 35.0):
		_fail("Partial reward overrides must merge with schema defaults.")
		return
	var signed := REWARD_SCHEMA.validate({"max_speed_reward": -2.5}, true)
	if not bool(signed["valid"]) or not is_equal_approx(float(signed["config"]["max_speed_reward"]), -2.5):
		_fail("A negative top-speed reward is an intentional signed term.")
		return
	var zero := {}
	for key in REWARD_SCHEMA.parameter_order():
		zero[key] = 0.0
	if not bool(REWARD_SCHEMA.validate(zero, false)["valid"]):
		_fail("Explicit zero reward weights must remain valid.")
		return
	var nested := {
		"schema_version": REWARD_SCHEMA.schema_version(),
		"reward_config": defaults,
	}
	if not bool(REWARD_SCHEMA.validate(nested, false)["valid"]):
		_fail("Versioned nested reward configurations must be accepted.")
		return

	if bool(REWARD_SCHEMA.validate({}, false)["valid"]):
		_fail("An empty complete reward configuration must be rejected.")
		return
	if bool(REWARD_SCHEMA.validate({"unknown_term": 1.0}, true)["valid"]):
		_fail("Unknown reward fields must be rejected.")
		return
	if bool(REWARD_SCHEMA.validate({"goal_reward": -1.0}, true)["valid"]):
		_fail("Negative penalty values must be rejected.")
		return
	if bool(REWARD_SCHEMA.validate({"goal_reward": NAN}, true)["valid"]):
		_fail("NaN reward values must be rejected.")
		return
	if bool(REWARD_SCHEMA.validate({"goal_reward": 1001.0}, true)["valid"]):
		_fail("Out-of-range reward values must be rejected.")
		return
	if bool(REWARD_SCHEMA.validate({"goal_reward": "high"}, true)["valid"]):
		_fail("Non-numeric reward values must be rejected.")
		return
	if bool(REWARD_SCHEMA.validate({"reward_config": defaults, "config_version": 2}, false)["valid"]):
		_fail("Unsupported reward configuration versions must be rejected.")
		return
	if bool(REWARD_SCHEMA.validate({"reward_config": defaults, "goal_reward": 1.0}, false)["valid"]):
		_fail("Nested reward configurations must not be mixed with flat reward fields.")
		return
	if bool(REWARD_SCHEMA.validate(
		{"reward_config": defaults, "schema_version": 1, "config_version": 2}, false
	)["valid"]):
		_fail("Conflicting reward configuration versions must be rejected.")
		return

	print("AI REWARD CONFIG TEST PASSED")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
