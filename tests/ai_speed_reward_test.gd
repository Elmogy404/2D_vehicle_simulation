extends SceneTree

const EGO_SCENE := preload("res://scenes/EgoVehicle.tscn")
const WORLD_SCRIPT := preload("res://ai/rl_training_world.gd")


func _initialize() -> void:
	var vehicle := EGO_SCENE.instantiate()
	var world := WORLD_SCRIPT.new()
	world.set("ego", vehicle)
	world.set("reward_config", {"max_speed_reward": 0.05})
	var limit := float(vehicle.get("max_speed"))
	var display_speed := limit * float(vehicle.get("kmh_per_unit"))
	if not is_equal_approx(limit, 500.0) or not is_equal_approx(display_speed, 150.0):
		_fail("Ego vehicle must top out at 150 km/h.", world, vehicle)
		return
	vehicle.set("current_speed", limit * 0.97)
	if float(world.call("_max_speed_bonus", 20.0, false)) != 0.0:
		_fail("Below-threshold speed should not earn the bonus.", world, vehicle)
		return
	vehicle.set("current_speed", limit)
	if not is_equal_approx(float(world.call("_max_speed_bonus", 20.0, false)), 0.05):
		_fail("Forward driving at top speed should earn the bonus.", world, vehicle)
		return
	if float(world.call("_max_speed_bonus", 20.0, true)) != 0.0 \
	or float(world.call("_max_speed_bonus", -20.0, false)) != 0.0:
		_fail("Off-road or backward progress must not earn the bonus.", world, vehicle)
		return
	vehicle.set("has_crashed", true)
	if float(world.call("_max_speed_bonus", 20.0, false)) != 0.0:
		_fail("A crashed car must not earn the bonus.", world, vehicle)
		return
	world.free()
	vehicle.free()
	print("AI SPEED REWARD TEST PASSED")
	quit(0)


func _fail(message: String, world: Node, vehicle: Node) -> void:
	push_error(message)
	world.free()
	vehicle.free()
	quit(1)
