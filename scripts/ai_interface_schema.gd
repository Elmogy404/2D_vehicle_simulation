class_name AIInterfaceSchema
extends RefCounted

## Shared Godot-side reader/validator for ai/interface_schema.json.
##
## The JSON file is the single source of truth shared with Python. This helper
## only validates the existing observation/action contract; it does not change
## observation generation or vehicle control.

const SCHEMA_PATH := "res://ai/interface_schema.json"

static var _schema: Dictionary = {}
static var _load_error := ""


static func schema_error() -> String:
	get_schema()
	return _load_error


static func get_schema() -> Dictionary:
	if _schema.is_empty() and _load_error.is_empty():
		_load_schema()
	return _schema


static func _load_schema() -> void:
	if not FileAccess.file_exists(SCHEMA_PATH):
		_load_error = "Missing interface schema: %s" % SCHEMA_PATH
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SCHEMA_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		_load_error = "Interface schema is not a JSON object: %s" % SCHEMA_PATH
		return
	var structure_error := _schema_structure_error(parsed)
	if not structure_error.is_empty():
		_load_error = structure_error
		return
	_schema = parsed


static func _integer(value: Variant, fallback: int = -1) -> int:
	if typeof(value) == TYPE_INT:
		return int(value)
	if typeof(value) == TYPE_FLOAT and is_equal_approx(float(value), roundf(float(value))):
		return int(value)
	return fallback


static func _number(value: Variant, fallback: float = 0.0) -> float:
	if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
		return float(value)
	return fallback


static func _schema_structure_error(schema: Dictionary) -> String:
	var version := _integer(schema.get("schema_version"))
	if version < 1:
		return "Interface schema_version must be a positive integer"
	for section_name in ["observation", "action"]:
		var section_value: Variant = schema.get(section_name)
		if typeof(section_value) != TYPE_DICTIONARY:
			return "Interface schema is missing %s" % section_name
		var section: Dictionary = section_value
		var size := _integer(section.get("size"))
		var fields_value: Variant = section.get("fields")
		if size < 1 or typeof(fields_value) != TYPE_ARRAY:
			return "Interface %s schema has an invalid size or fields" % section_name
		var expected_index := 0
		for field_value in fields_value:
			if typeof(field_value) != TYPE_DICTIONARY:
				return "Interface %s field must be an object" % section_name
			var field: Dictionary = field_value
			var name := String(field.get("name", ""))
			var index := _integer(field.get("index"))
			var field_size := _integer(field.get("size"))
			if name.is_empty():
				return "Interface %s field is missing a name" % section_name
			if index != expected_index:
				return "Interface %s field '%s' must start at index %d" % [section_name, name, expected_index]
			if field_size < 1:
				return "Interface %s field '%s' has an invalid size" % [section_name, name]
			if typeof(field.get("min")) != TYPE_FLOAT and typeof(field.get("min")) != TYPE_INT:
				return "Interface %s field '%s' has invalid bounds" % [section_name, name]
			if typeof(field.get("max")) != TYPE_FLOAT and typeof(field.get("max")) != TYPE_INT:
				return "Interface %s field '%s' has invalid bounds" % [section_name, name]
			if _number(field.get("min")) > _number(field.get("max")):
				return "Interface %s field '%s' has reversed bounds" % [section_name, name]
			if String(field.get("layout", "")) == "xy":
				if _integer(field.get("count")) * 2 != field_size:
					return "Interface %s field '%s' xy layout must have count * 2 values" % [section_name, name]
			if bool(field.get("reserved", false)):
				var expected_value: Variant = field.get("expected")
				if typeof(expected_value) != TYPE_ARRAY or (expected_value as Array).size() != field_size:
					return "Interface %s reserved field '%s' must have one expected value per slot" % [section_name, name]
			expected_index += field_size
		if expected_index != size:
			return "Interface %s fields cover %d values, expected %d" % [section_name, expected_index, size]
	return ""


static func schema_version() -> int:
	return _integer(get_schema().get("schema_version"), -1)


static func observation_size() -> int:
	var section_value: Variant = get_schema().get("observation", {})
	if typeof(section_value) != TYPE_DICTIONARY:
		return -1
	return _integer((section_value as Dictionary).get("size"), -1)


static func action_size() -> int:
	var section_value: Variant = get_schema().get("action", {})
	if typeof(section_value) != TYPE_DICTIONARY:
		return -1
	return _integer((section_value as Dictionary).get("size"), -1)


static func observation_dtype() -> String:
	var section_value: Variant = get_schema().get("observation", {})
	if typeof(section_value) != TYPE_DICTIONARY:
		return ""
	return String((section_value as Dictionary).get("dtype", ""))


static func action_dtype() -> String:
	var section_value: Variant = get_schema().get("action", {})
	if typeof(section_value) != TYPE_DICTIONARY:
		return ""
	return String((section_value as Dictionary).get("dtype", ""))


static func metadata() -> Dictionary:
	return {
		"schema_version": schema_version(),
		"observation_size": observation_size(),
		"action_size": action_size(),
		"observation_dtype": observation_dtype(),
		"action_dtype": action_dtype(),
	}


static func compatibility_error(
	remote_version: int,
	remote_observation_size: int,
	remote_action_size: int,
	source := "remote environment",
	remote_observation_dtype := "",
	remote_action_dtype := ""
) -> String:
	if remote_version != schema_version():
		return "%s uses interface schema version %d, this process expects %d" % [
			source, remote_version, schema_version()
		]
	if remote_observation_size != observation_size():
		return "%s uses %d observation values, this process expects %d (schema v%d)" % [
			source, remote_observation_size, observation_size(), schema_version()
		]
	if remote_action_size != action_size():
		return "%s uses %d action values, this process expects %d (schema v%d)" % [
			source, remote_action_size, action_size(), schema_version()
		]
	if not remote_observation_dtype.is_empty() and remote_observation_dtype != observation_dtype():
		return "%s uses observation dtype %s, this process expects %s (schema v%d)" % [
			source, remote_observation_dtype, observation_dtype(), schema_version()
		]
	if not remote_action_dtype.is_empty() and remote_action_dtype != action_dtype():
		return "%s uses action dtype %s, this process expects %s (schema v%d)" % [
			source, remote_action_dtype, action_dtype(), schema_version()
		]
	return ""


static func validate_remote_metadata(remote: Variant, source := "remote environment") -> String:
	if typeof(remote) != TYPE_DICTIONARY:
		return "%s did not provide interface schema metadata (expected schema v%d)" % [
			source, schema_version()
		]
	var values: Dictionary = remote
	return compatibility_error(
		_integer(values.get("schema_version")),
		_integer(values.get("observation_size")),
		_integer(values.get("action_size")),
		source,
		String(values.get("observation_dtype", "")),
		String(values.get("action_dtype", ""))
	)


static func _field_for_index(index: int) -> Dictionary:
	for field_value in get_schema().get("observation", {}).get("fields", []):
		var field: Dictionary = field_value
		var start := _integer(field.get("index"))
		if index >= start and index < start + _integer(field.get("size")):
			return field
	return {}


static func _field_text(field: Dictionary, index: int) -> String:
	var field_index := index - _integer(field.get("index"))
	if _integer(field.get("size")) == 1:
		return "observation[%d] ('%s')" % [index, String(field.get("name", ""))]
	return "observation[%d] ('%s'[%d])" % [index, String(field.get("name", "")), field_index]


static func validate_observation(observation: Array, strict_reserved := true) -> Array[String]:
	var errors: Array[String] = []
	var load_error := schema_error()
	if not load_error.is_empty():
		errors.append(load_error)
		return errors
	var expected_size := observation_size()
	if observation.size() != expected_size:
		errors.append(
			"observation shape (%d,) is invalid; expected (%d,) (schema v%d)" % [
				observation.size(), expected_size, schema_version()
			]
		)
		return errors
	for index in range(observation.size()):
		var value: Variant = observation[index]
		if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
			var field := _field_for_index(index)
			var label := _field_text(field, index) if not field.is_empty() else "observation[%d]" % index
			errors.append("%s = %s must be a real number (schema v%d)" % [
				label, str(value), schema_version()
			])
			continue
		var numeric := float(value)
		if not is_finite(numeric):
			var field := _field_for_index(index)
			var label := _field_text(field, index) if not field.is_empty() else "observation[%d]" % index
			errors.append("%s = %s must be finite (schema v%d)" % [
				label, str(value), schema_version()
			])
			continue
		var field := _field_for_index(index)
		if field.is_empty():
			continue
		var minimum := _number(field.get("min"))
		var maximum := _number(field.get("max"))
		if numeric < minimum or numeric > maximum:
			errors.append("%s = %s is outside [%s, %s] (schema v%d)" % [
				_field_text(field, index), str(numeric), str(minimum), str(maximum), schema_version()
			])
	for field_value in get_schema().get("observation", {}).get("fields", []):
		var field: Dictionary = field_value
		if not strict_reserved or not bool(field.get("reserved", false)):
			continue
		var expected_value: Variant = field.get("expected")
		if typeof(expected_value) != TYPE_ARRAY:
			continue
		var expected: Array = expected_value
		var start := _integer(field.get("index"))
		for offset in range(mini(expected.size(), _integer(field.get("size")))):
			var index := start + offset
			var value := float(observation[index])
			if absf(value - float(expected[offset])) > 0.000001:
				errors.append("%s = %s does not match reserved value %s (schema v%d)" % [
					_field_text(field, index), str(value), str(float(expected[offset])), schema_version()
				])
	return errors


static func validate_action(action: Variant, clip := true) -> Dictionary:
	var result := {
		"valid": false,
		"value": Vector2.ZERO,
		"clipped": false,
		"errors": [] as Array[String],
	}
	var errors: Array[String] = result["errors"]
	var load_error := schema_error()
	if not load_error.is_empty():
		errors.append(load_error)
		return result
	if typeof(action) != TYPE_ARRAY:
		errors.append("action must be an array of %d numbers (schema v%d)" % [
			action_size(), schema_version()
		])
		return result
	var values: Array = action
	if values.size() != action_size():
		errors.append("action shape (%d,) is invalid; expected (%d,) (schema v%d)" % [
			values.size(), action_size(), schema_version()
		])
		return result
	var output: Array[float] = []
	for field_value in get_schema().get("action", {}).get("fields", []):
		var field: Dictionary = field_value
		var index := _integer(field.get("index"))
		var value: Variant = values[index]
		if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
			errors.append("action[%d] ('%s') = %s must be a real number (schema v%d)" % [
				index, String(field.get("name", "")), str(value), schema_version()
			])
			output.append(0.0)
			continue
		var numeric := float(value)
		if not is_finite(numeric):
			errors.append("action[%d] ('%s') = %s must be finite (schema v%d)" % [
				index, String(field.get("name", "")), str(value), schema_version()
			])
			output.append(0.0)
			continue
		var minimum := _number(field.get("min"))
		var maximum := _number(field.get("max"))
		if numeric < minimum or numeric > maximum:
			if not clip:
				errors.append("action[%d] ('%s') = %s is outside [%s, %s] (schema v%d)" % [
					index, String(field.get("name", "")), str(numeric), str(minimum),
					str(maximum), schema_version()
				])
			else:
				numeric = clampf(numeric, minimum, maximum)
				result["clipped"] = true
		output.append(numeric)
	if errors.is_empty():
		result["valid"] = true
		result["value"] = Vector2(output[0], output[1])
	return result
