class_name SimulationPedestrian
extends CharacterBody2D


@export var radius: float = 12.0
@export var walking_speed: float = 48.0
@export var wait_duration: float = 1.0

var endpoint_a: Vector2
var endpoint_b: Vector2
var target: Vector2
var traffic_light: Node
var wait_remaining: float = 0.0
var body_color: Color = Color(0.95, 0.55, 0.2)


func configure(
	start: Vector2,
	finish: Vector2,
	speed: float,
	linked_light: Node,
	color: Color
) -> void:
	endpoint_a = start
	endpoint_b = finish
	global_position = start
	target = finish
	walking_speed = speed
	traffic_light = linked_light
	body_color = color
	add_to_group("pedestrians")
	_build_collider()
	queue_redraw()


func _physics_process(delta: float) -> void:
	if wait_remaining > 0.0:
		wait_remaining -= delta
		velocity = Vector2.ZERO
		return

	# Pedestrians cross while vehicle traffic is red. Once already in the road,
	# they finish the crossing instead of stopping in a live lane.
	var at_endpoint := global_position.distance_to(endpoint_a) < 2.0 or global_position.distance_to(endpoint_b) < 2.0

	if at_endpoint and traffic_light != null and int(traffic_light.get("state")) != 2:
		velocity = Vector2.ZERO
		return

	var to_target := target - global_position

	if to_target.length() <= 3.0:
		global_position = target
		target = endpoint_a if target == endpoint_b else endpoint_b
		wait_remaining = wait_duration
		velocity = Vector2.ZERO
		return

	velocity = to_target.normalized() * walking_speed
	move_and_slide()


func _build_collider() -> void:
	if get_node_or_null("CollisionShape2D") != null:
		return

	var shape := CapsuleShape2D.new()
	shape.radius = radius
	shape.height = radius * 2.6
	var collider := CollisionShape2D.new()
	collider.name = "CollisionShape2D"
	collider.shape = shape
	add_child(collider)


func _draw() -> void:
	draw_circle(Vector2.ZERO, radius, body_color)
	draw_circle(Vector2(0.0, -radius * 1.15), radius * 0.55, body_color.lightened(0.18))
