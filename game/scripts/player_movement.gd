extends CharacterBody3D

@export var speed: float = 1.0
var target_pos: Vector3
var moving: bool = false

func _ready() -> void:
	target_pos = global_transform.origin

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var cam: Camera3D = get_viewport().get_camera_3d()
		if cam == null:
			return # no camera available

		if event.button_index == MOUSE_BUTTON_LEFT:
			# Ray from camera through the mouse point
			var from: Vector3 = cam.project_ray_origin(event.position)
			var ray_dir: Vector3 = cam.project_ray_normal(event.position)

			# Intersect ray with plane y = 0
			if abs(ray_dir.y) < 0.0001:
				return
			var t: float = (0.0 - from.y) / ray_dir.y
			var world_pos: Vector3 = from + ray_dir * t

			# Keep the ship's current Y (height) for now and use clicked X/Z
			target_pos = Vector3(world_pos.x, global_transform.origin.y, world_pos.z)
			moving = true

		elif event.button_index == MOUSE_BUTTON_RIGHT:
			moving = false
			target_pos = global_transform.origin
			velocity.x = 0
			velocity.z = 0

func _physics_process(delta: float) -> void:
	if not moving:
		velocity.x = 0
		velocity.z = 0
		move_and_slide()
		return

	var current: Vector3 = global_transform.origin
	var to_target: Vector3 = target_pos - current
	to_target.y = 0 # ignore for now

	var dist: float = to_target.length()
	if dist < 0.1:
		moving = false
		velocity.x = 0
		velocity.z = 0
		move_and_slide()
		return

	var dir: Vector3 = to_target / dist # normalized
	$Pivot.look_at(current - dir, Vector3.UP)

	# Set horizontal velocity
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	# keep vertical velocity at 0 for now
	velocity.y = 0

	move_and_slide()
