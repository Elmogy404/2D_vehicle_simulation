extends RefCounted

## Shared reward-configuration rules.  The definitions are loaded from
## res://ai/reward_config.json so Python and Godot cannot drift apart.

const SCHEMA_PATH := "res://ai/reward_config.json"
const METADATA_KEYS := ["schema_version", "config_version", "reward_config"]
static var _schema: Dictionary = {}


static func schema() -> Dictionary:
	if _schema.is_empty():
		var text := FileAccess.get_file_as_string(SCHEMA_PATH)
		if text.is_empty():
			push_error("Could not read reward configuration schema: %s" % SCHEMA_PATH)
			return {}
		var parsed: Variant = JSON.parse_string(text)
		if typeof(parsed) != TYPE_DICTIONARY:
			push_error("Reward configuration schema must be a JSON object: %s" % SCHEMA_PATH)
			return {}
		_schema = parsed
	return _schema


static func schema_version() -> int:
	return int(schema().get("schema_version", 0))


static func parameter_order() -> Array:
	return schema().get("order", [])


static func parameters() -> Dictionary:
	return schema().get("parameters", {})


static func defaults() -> Dictionary:
	var defaults_value: Variant = schema().get("defaults", {})
	if typeof(defaults_value) != TYPE_DICTIONARY:
		return {}
	var result := {}
	for key in defaults_value:
		result[key] = float(defaults_value[key])
	return result


static func _format_number(value: float) -> String:
	return str(value)


static func _version_error(field: String, value: Variant) -> String:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return "reward_config.%s: must be an integer version number" % field
	var number := float(value)
	if is_nan(number) or is_inf(number) or number != floorf(number):
		return "reward_config.%s: must be an integer version number" % field
	if int(number) != schema_version():
		return "reward_config.%s: unsupported configuration version %d (this project supports version %d)" % [
			field, int(number), schema_version()
		]
	return ""


static func _metadata_version(value: Dictionary) -> Array:
	## Validate both optional version keys, including legacy aliases.
	var errors: Array = []
	var schema_value: Variant = value.get("schema_version", null)
	var config_value: Variant = value.get("config_version", null)
	var schema_error := ""
	var config_error := ""
	if schema_value != null:
		schema_error = _version_error("schema_version", schema_value)
		if not schema_error.is_empty():
			errors.append(schema_error)
	if config_value != null:
		config_error = _version_error("config_version", config_value)
		if not config_error.is_empty():
			errors.append(config_error)
	if schema_value != null and config_value != null and schema_error.is_empty() and config_error.is_empty() \
	and int(schema_value) != int(config_value):
		errors.append("reward_config: schema_version and config_version disagree; remove one or make them equal")
	return errors


static func validate(value: Variant, allow_partial: bool = true) -> Dictionary:
	## Returns {"valid": bool, "errors": Array[String], "config": Dictionary}.
	## Partial validation is for explicit overrides; complete configurations
	## should pass allow_partial=false.
	var errors: Array = []
	if typeof(value) != TYPE_DICTIONARY:
		return {"valid": false, "errors": ["reward_config: must be a JSON object"], "config": {}}
	var supplied: Dictionary = value
	var body_value: Variant = supplied
	if supplied.has("reward_config"):
		for key in supplied:
			if not String(key) in METADATA_KEYS:
				errors.append(
					"reward_config: field '%s' cannot be combined with a nested 'reward_config' object" % String(key)
				)
		body_value = supplied["reward_config"]
		if typeof(body_value) != TYPE_DICTIONARY:
			errors.append("reward_config.reward_config: must be a JSON object")
			return {"valid": false, "errors": errors, "config": {}}
	else:
		body_value = supplied.duplicate(true)
		body_value.erase("schema_version")
		body_value.erase("config_version")
	errors.append_array(_metadata_version(supplied))
	var body: Dictionary = body_value
	var rules := parameters()
	var all_defaults := defaults()
	var body_keys := body.keys()
	for key in body_keys:
		if not rules.has(String(key)):
			errors.append("reward_config.%s: unknown reward field" % String(key))
	if body_keys.is_empty() and not allow_partial and errors.is_empty():
		errors.append("reward_config: reward configuration is empty; required fields: %s" % ", ".join(PackedStringArray(parameter_order())))
	var result := {}
	for key in parameter_order():
		var key_string := String(key)
		if not body.has(key_string):
			if not allow_partial:
				errors.append("reward_config.%s: required field is missing" % key_string)
			else:
				result[key_string] = float(all_defaults[key_string])
			continue
		var rule: Dictionary = rules[key_string]
		var item: Variant = body[key_string]
		if typeof(item) != TYPE_INT and typeof(item) != TYPE_FLOAT:
			errors.append("reward_config.%s: must be a number (got a non-numeric value)" % key_string)
			continue
		var number := float(item)
		if is_nan(number) or is_inf(number):
			errors.append("reward_config.%s: must be finite; NaN and Infinity are not allowed" % key_string)
			continue
		var minimum := float(rule["min"])
		var maximum := float(rule["max"])
		if number < 0.0 and not bool(rule["allow_negative"]):
			errors.append(
				"reward_config.%s: must be non-negative because it is subtracted as a positive penalty or is a non-negative reward term (got %s)" % [
					key_string, _format_number(number)
				]
			)
			continue
		if number < minimum or number > maximum:
			errors.append(
				"reward_config.%s: %s is outside the allowed range [%s, %s]" % [
					key_string, _format_number(number), _format_number(minimum), _format_number(maximum)
				]
			)
			continue
		if number == 0.0 and not bool(rule["allow_zero"]):
			errors.append("reward_config.%s: zero is not allowed for this component" % key_string)
			continue
		result[key_string] = number
	if not errors.is_empty():
		return {"valid": false, "errors": errors, "config": {}}
	return {"valid": true, "errors": [], "config": result}
