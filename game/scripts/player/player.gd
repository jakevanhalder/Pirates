extends CharacterBody3D

@export var speed: float = 1.0
@export var send_interval: float = 0.05
@export var send_pos_threshold: float = 0.02
@export var interp_speed: float = 8.0
@export var snap_threshold: float = 5.0
@export var invert_facing: bool = false

@onready var right_cannon: Node3D = $RightCannon
@onready var left_cannon: Node3D  = $LeftCannon

const CANNON_BALL = preload("res://scenes/player/CannonBall.tscn")

var target_pos: Vector3
var moving: bool = false

var _time_since_last_send: float = 0.0
var _last_sent_pos: Vector3
var _last_sent_vel: Vector3

var _remote_transform: Transform3D
var _remote_velocity: Vector3
var _remote_moving: bool = false

# predicted (remote + velocity * lag)
var _remote_predicted_origin: Vector3

var _send_seq: int = 0

func _ready() -> void:
	target_pos = global_transform.origin
	_last_sent_pos = global_transform.origin
	_last_sent_vel = Vector3.ZERO
	_remote_transform = global_transform
	_remote_velocity = Vector3.ZERO
	_remote_predicted_origin = global_transform.origin
	
	if multiplayer.get_unique_id() != get_multiplayer_authority():
		set_process_input(false)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var cam: Camera3D = get_viewport().get_camera_3d()
		if cam == null:
			return
	
		if event.button_index == MOUSE_BUTTON_LEFT:
			var from: Vector3 = cam.project_ray_origin(event.position)
			var ray_dir: Vector3 = cam.project_ray_normal(event.position)
			if abs(ray_dir.y) < 0.0001:
				return
			var t: float = (0.0 - from.y) / ray_dir.y
			var world_pos: Vector3 = from + ray_dir * t
	
			target_pos = Vector3(world_pos.x, global_transform.origin.y, world_pos.z)
			moving = true
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			moving = false
			target_pos = global_transform.origin
			velocity.x = 0.0
			velocity.z = 0.0

func _physics_process(delta: float) -> void:
	var my_id: int = multiplayer.get_unique_id()
	var my_authority: int = get_multiplayer_authority()
	
	# Trigger left/right shooting
	if Input.is_action_just_pressed("shoot_right"):
		_shoot_from_cannon(right_cannon)
	if Input.is_action_just_pressed("shoot_left"):
		_shoot_from_cannon(left_cannon)
	
	if my_id == my_authority:
		_time_since_last_send += delta
	
		if not moving:
			velocity.x = 0.0
			velocity.z = 0.0
			move_and_slide()
			_try_send_state_if_needed()
			return
	
		var current: Vector3 = global_transform.origin
		var to_target: Vector3 = target_pos - current
		to_target.y = 0.0
	
		var dist: float = to_target.length()
		if dist < 0.1:
			moving = false
			velocity.x = 0.0
			velocity.z = 0.0
			move_and_slide()
			_try_send_state_if_needed()
			return
	
		var dir: Vector3 = Vector3.ZERO
		if dist != 0.0:
			dir = to_target / dist
	
		var look_dir: Vector3 = dir
		if invert_facing:
			look_dir = -dir
		if has_node("Pivot"):
			var pivot_node: Node = $Pivot
			if pivot_node and pivot_node.has_method("look_at"):
				pivot_node.look_at(current - look_dir, Vector3.UP)
	
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed
		velocity.y = 0.0
	
		move_and_slide()
	
		_try_send_state_if_needed()
	else:
		var predicted: Vector3 = _remote_transform.origin + _remote_velocity * send_interval
		_remote_predicted_origin = predicted
	
		var cur_pos: Vector3 = global_transform.origin
		var dist_to_pred: float = cur_pos.distance_to(_remote_predicted_origin)
	
		if dist_to_pred > snap_threshold:
			var snap_tf: Transform3D = global_transform
			snap_tf.origin = _remote_predicted_origin
			snap_tf.basis = _remote_transform.basis
			global_transform = snap_tf
			_update_pivot_rotation_from_remote(_remote_velocity, _remote_moving)
			return
	
		var alpha: float = clamp(interp_speed * delta, 0.0, 1.0)
		var new_pos: Vector3 = global_transform.origin.lerp(_remote_predicted_origin, alpha)
		var new_tf: Transform3D = global_transform
		new_tf.origin = new_pos
		global_transform = new_tf
	
		_update_pivot_rotation_from_remote(_remote_velocity, _remote_moving, delta)

func _try_send_state_if_needed() -> void:
	if send_interval <= 0.0:
		_send_state()
		return
	
	if _time_since_last_send < send_interval:
		return
	
	var pos_changed: bool = global_transform.origin.distance_to(_last_sent_pos) > send_pos_threshold
	var vel_changed: bool = velocity.distance_to(_last_sent_vel) > 0.01
	
	if pos_changed or vel_changed or moving != _remote_moving:
		_send_state()
	else:
		_time_since_last_send = 0.0

func _send_state() -> void:
	if not Network.simulation_started_flag:
		_time_since_last_send = 0.0
		return
	
	_send_seq += 1
	var ts := Time.get_ticks_msec()
	var owner_id := get_multiplayer_authority()
	var target_host := Network.host_id if Network.host_id != 0 else 1
	
	Network.rpc_id(target_host, "rpc_player_state", owner_id, global_transform, velocity, moving, ts, _send_seq)
	
	_last_sent_pos = global_transform.origin
	_last_sent_vel = velocity
	_time_since_last_send = 0.0


func set_remote_state(authoritative_transform: Transform3D, authoritative_vel: Vector3, authoritative_moving: bool) -> void:
	if multiplayer.get_unique_id() == get_multiplayer_authority():
		return
	
	_remote_transform = authoritative_transform
	_remote_velocity = authoritative_vel
	_remote_moving = authoritative_moving
	_remote_predicted_origin = _remote_transform.origin + _remote_velocity * send_interval

func _update_pivot_rotation_from_remote(remote_vel: Vector3, remote_moving: bool, delta: float = 0.0) -> void:
	if not has_node("Pivot"):
		return
	
	var pivot_node: Node = $Pivot
	if not pivot_node:
		return
	
	if remote_moving and remote_vel.length() > 0.001:
		var desired_dir: Vector3 = remote_vel.normalized()
		if invert_facing:
			desired_dir = -desired_dir
		
		var target_yaw: float = atan2(desired_dir.x, desired_dir.z)
		var cur_rot: Vector3 = pivot_node.rotation
		var t: float = 1.0
	
		if delta > 0.0:
			t = clamp(interp_speed * delta, 0.0, 1.0)
		cur_rot.y = _lerp_angle(cur_rot.y, target_yaw, t)
		pivot_node.rotation = cur_rot
	else:
		pass

func _lerp_angle(a: float, b: float, t: float) -> float:
	var diff: float = fmod(b - a + PI, TAU) - PI
	return a + diff * t

func _shoot_from_cannon(cannon: Node3D) -> void:
	var ball = CANNON_BALL.instantiate()
	var scene_root = get_tree().current_scene
	scene_root.add_child(ball)
	ball.global_transform = cannon.global_transform
	if ball.has_method("set_direction"):
		var forward = cannon.global_transform.basis * Vector3.FORWARD
		ball.set_direction(forward.normalized())
