extends RayCast3D

@export var speed: float = 1.0

func _physics_process(delta: float) -> void:
	target_position = Vector3.FORWARD * speed * delta
	force_raycast_update()
	
	position += global_basis * Vector3.FORWARD * speed * delta
	
	var collider = get_collider()
	if is_colliding():
		global_position = get_collision_point()
		set_physics_process(false)

func cleanup() -> void:
	queue_free()
