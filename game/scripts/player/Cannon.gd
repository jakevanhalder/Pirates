extends Node3D

@onready var timer: Timer = $Timer

const CANNON_BALL = preload("res://scenes/player/CannonBall.tscn")

func _physics_process(delta: float) -> void:
	if timer.is_stopped():
		if Input.is_action_just_pressed("shoot_right"):
			timer.start(0.1)
			var attack = CANNON_BALL.instantiate()
			add_child(attack)
			attack.global_transform = global_transform
