extends Node3D

@export var PlayerShipScene: PackedScene = preload("res://scenes/game/PlayerShip.tscn")
const SPAWN_OFFSET := 4.0

func _ready() -> void:
	if Network.multiplayer.is_server():
		Network.player_loaded()
	else:
		var target_host := Network.host_id if Network.host_id != 0 else 1
		await get_tree().create_timer(0.02).timeout
		Network.rpc_id(target_host, "player_loaded")
	
	push_warning("Game._ready() on peer %d" % Network.multiplayer.get_unique_id())

func start_game() -> void:
	if not Network.multiplayer.is_server():
		return
	
	push_warning("Game.start_game: players to spawn: %s" % str(Network.players.keys()))
	
	var i := 0
	for pid in Network.players.keys():
		var x := float(i) * SPAWN_OFFSET
		var t := Transform3D(Basis(), Vector3(x, 0, 0))
	
		Network.rpc("rpc_spawn_player", pid, t)
		i += 1
	
	await get_tree().create_timer(0.08).timeout
	
	Network.rpc("rpc_start_simulation")
