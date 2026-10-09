class_name SimulationPedestrian
extends CharacterBody2D


enum MotionState { WAITING_AT_CURB, CROSSING }

const WALK_FRAMES := 8
const IDLE_FRAMES := 7
const WALK_TEXTURES := {
	"front": preload("res://assets/Modern_City/Characters/PNG/Detective/not outlined/walk/detective_walk_front_NO_OUTLINE-Sheet.png"),
	"back": preload("res://assets/Modern_City/Characters/PNG/Detective/not outlined/walk/detective_walk_back_NO_OUTLINE-Sheet.png"),
	"left": preload("res://assets/Modern_City/Characters/PNG/Detective/not outlined/walk/detective_walk_left_NO_OUTLINE-Sheet.png"),
	"right": preload("res://assets/Modern_City/Characters/PNG/Detective/not outlined/walk/detective_walk_right_NO_OUTLINE-Sheet.png")
}
const IDLE_TEXTURES := {
	"front": preload("res://assets/Modern_City/Characters/PNG/Detective/not outlined/idle/detective_idle_front_NO_OUTLINE-Sheet.png"),
	"back": preload("res://assets/Modern_City/Characters/PNG/Detective/not outlined/idle/detective_idle_back_NO_OUTLINE-Sheet.png"),
	"left": preload("res://assets/Modern_City/Characters/PNG/Detective/not outlined/idle/detective_idle_left_NO_OUTLINE-Sheet.png"),
	"right": preload("res://assets/Modern_City/Characters/PNG/Detective/not outlined/idle/detective_idle_right_NO_OUTLINE-Sheet.png")
}

@export var walking_speed: float = 48.0
@export var wait_duration: float = 0.8

@onready var sprite: Sprite2D = $Sprite2D

var endpoint_a: Vector2
var endpoint_b: Vector2
var target: Vector2
var traffic_light: Node
var intersection_index: int = -1
var motion_state: MotionState = MotionState.WAITING_AT_CURB
var wait_remaining: float = 0.0
var body_tint: Color = Color.WHITE
var facing: Vector2 = Vector2.DOWN
var is_crossing: bool = false

var _crossed_this_red_phase: bool = false
var _using_walk_animation: bool = false
var _animation_direction: String = ""
var _animation_time: float = 0.0


func _ready() -> void:
	collision_layer = 4
	# Boundary walls are vehicle-only barriers. Pedestrians start just beyond
	# the curb and must be able to cross that boundary without physics blocking.
	collision_mask = 0
	z_index = 1
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.scale = Vector2(1.4, 1.4)
	sprite.modulate = body_tint
	_update_sprite(false, facing, 0.0)
	queue_redraw()


func configure(
	start: Vector2,
	finish: Vector2,
	speed: float,
	linked_light: Node,
	color_tint: Color,
	feature_index: int
) -> void:
	endpoint_a = start
	endpoint_b = finish
	global_position = start
	target = finish
	facing = (finish - start).normalized()
	walking_speed = speed
	traffic_light = linked_light
	body_tint = color_tint
	intersection_index = feature_index
	motion_state = MotionState.WAITING_AT_CURB
	wait_remaining = 0.0
	_crossed_this_red_phase = false
	is_crossing = false
	add_to_group("pedestrians")
	if is_node_ready():
		sprite.modulate = body_tint
		_update_sprite(false, facing, 0.0)


func _physics_process(delta: float) -> void:
	if traffic_light == null or not is_instance_valid(traffic_light):
		motion_state = MotionState.WAITING_AT_CURB
		is_crossing = false
		velocity = Vector2.ZERO
		return

	var signal_state := int(traffic_light.get("state"))
	var vehicles_stopped := signal_state == TrafficLight.SignalState.RED
	if not vehicles_stopped:
		_crossed_this_red_phase = false

	if motion_state == MotionState.WAITING_AT_CURB:
		velocity = Vector2.ZERO
		is_crossing = false
		if wait_remaining > 0.0:
			wait_remaining = maxf(wait_remaining - delta, 0.0)
			_update_sprite(false, target - global_position, delta)
			return
		if not vehicles_stopped or _crossed_this_red_phase:
			_update_sprite(false, target - global_position, delta)
			return
		motion_state = MotionState.CROSSING
		is_crossing = true
		_crossed_this_red_phase = true

	var to_target := target - global_position
	if to_target.length() <= walking_speed * delta + 1.0:
		global_position = target
		velocity = Vector2.ZERO
		motion_state = MotionState.WAITING_AT_CURB
		is_crossing = false
		wait_remaining = wait_duration
		target = endpoint_a if target.distance_squared_to(endpoint_b) < 0.01 else endpoint_b
		_update_sprite(false, target - global_position, delta)
		return

	facing = to_target.normalized()
	velocity = facing * walking_speed
	move_and_slide()
	_update_sprite(true, facing, delta)


func _update_sprite(walking: bool, direction: Vector2, delta: float) -> void:
	if direction.length_squared() > 0.001:
		facing = direction.normalized()
	var direction_name := _direction_name(facing)
	if walking != _using_walk_animation or direction_name != _animation_direction:
		_animation_time = 0.0
		_using_walk_animation = walking
		_animation_direction = direction_name
		sprite.texture = WALK_TEXTURES[direction_name] if walking else IDLE_TEXTURES[direction_name]
		sprite.region_enabled = true
	_animation_time += delta
	var frame_count := WALK_FRAMES if walking else IDLE_FRAMES
	var frames_per_second := 8.0 if walking else 3.5
	var frame_index := int(_animation_time * frames_per_second) % frame_count
	sprite.region_rect = Rect2(float(frame_index * 32), 0.0, 32.0, 32.0)
	sprite.modulate = body_tint


func _direction_name(direction: Vector2) -> String:
	if absf(direction.x) > absf(direction.y):
		return "right" if direction.x > 0.0 else "left"
	return "front" if direction.y > 0.0 else "back"


func _draw() -> void:
	# A small soft ground cue keeps the tiny pixel-art character readable on roads.
	draw_circle(Vector2(0.0, 10.0), 8.0, Color(0.0, 0.0, 0.0, 0.22))
