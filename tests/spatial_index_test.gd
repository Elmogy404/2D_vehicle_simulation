extends SceneTree
const INDEX = preload("res://scripts/simulation_spatial_index.gd")
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		printerr(message)

func _run() -> void:
	var index := INDEX.new()
	root.add_child(index)
	var actors := []
	for i in range(2000):
		var actor := Node2D.new()
		actor.position = Vector2((i % 50) * 420 - 10000, (i / 50) * 420 - 8000)
		root.add_child(actor)
		actor.add_to_group("traffic")
		actors.append(actor)
	index.refresh()
	for origin in [Vector2.ZERO, Vector2(-9999, -8001), Vector2(599, 599)]:
		for radius in [0.0, 600.0, 4000.0]:
			var expected := []
			for actor in actors:
				if origin.distance_squared_to(actor.position) <= radius * radius:
					expected.append(actor.get_instance_id())
			var actual := []
			for actor in index.nearby("traffic", origin, radius):
				actual.append(actor.get_instance_id())
			expected.sort()
			actual.sort()
			check(actual == expected, "spatial query differs from full scan")
	# Normal movement between the index tick and a later NPC tick may cross
	# a cell boundary. The padded lookup must still include that body.
	actors[0].position = Vector2(599, 0)
	index.invalidate()
	index.refresh()
	actors[0].position = Vector2(605, 0)
	check(index.nearby("traffic", Vector2(605, 0), 1.0).has(actors[0]), "moving body disappeared across a cell seam")
	actors[0].free()
	check(index.nearby("traffic", Vector2(605, 0), 1.0).is_empty(), "freed body remained indexed")
	var started := Time.get_ticks_usec()
	for i in range(1000):
		index.nearby("traffic", Vector2(i % 20 * 300, i % 13 * 300), 500.0)
	var indexed_ms := float(Time.get_ticks_usec() - started) / 1000.0
	started = Time.get_ticks_usec()
	for i in range(1000):
		var origin := Vector2(i % 20 * 300, i % 13 * 300)
		for actor in actors:
			if is_instance_valid(actor):
				var _near := origin.distance_squared_to(actor.position) <= 250000.0
	var scan_ms := float(Time.get_ticks_usec() - started) / 1000.0
	print("SPATIAL INDEX: failures=%d; 2,000 actors, 1,000 queries indexed=%.1fms full_scan=%.1fms" % [failures, indexed_ms, scan_ms])
	quit(1 if failures else 0)
