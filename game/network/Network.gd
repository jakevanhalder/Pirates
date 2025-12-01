extends Node

signal player_connected(peer_id, player_info)
signal player_disconnected(peer_id)
signal server_disconnected
signal lobby_created(host_id, host_info, address)
signal lobby_removed(host_id)
signal simulation_started

const PORT := 7000
const DEFAULT_SERVER_IP := "127.0.0.1"
const MAX_CONNECTIONS := 8

var players: Dictionary = {}
var player_info: Dictionary = {"name": "Player"}
var players_loaded: int = 0
var player_loaded_once: Dictionary = {}

var current_port: int = PORT
const PORT_FALLBACK_TRIES := 3

var host_id: int = 0

var simulation_started_flag: bool = false

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_player_connected)
	multiplayer.peer_disconnected.connect(_on_player_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_ok)
	multiplayer.connection_failed.connect(_on_connected_fail)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func _get_best_local_ip() -> String:
	var addrs := IP.get_local_addresses()
	var ipv4_list: Array = []
	var ipv6_list: Array = []
	
	for a in addrs:
		if typeof(a) != TYPE_STRING:
			continue
		var s := str(a).strip_edges()
		# ignore loopbacks and link-local
		if s == "127.0.0.1" or s == "::1" or s.begins_with("169.254."):
			continue
		if s.find(".") != -1:
			ipv4_list.append(s)
		else:
			ipv6_list.append(s)
	
	# Preference order for IPv4 private ranges
	# 192.168.x.x
	for ip in ipv4_list:
		if ip.begins_with("192.168."):
			return ip
	# 10.x.x.x
	for ip in ipv4_list:
		if ip.begins_with("10."):
			return ip
	# 172.16.0.0 - 172.31.255.255 (check first two octets)
	for ip in ipv4_list:
		if ip.find(".") != -1:
			var parts: PackedStringArray = ip.split(".")
			if parts.size() >= 2:
				var o1 := int(parts[0])
				var o2 := int(parts[1])
				if o1 == 172 and o2 >= 16 and o2 <= 31:
					return ip
	# any remaining IPv4
	if ipv4_list.size() > 0:
		return ipv4_list[0]
	# fallback to first non-loopback IPv6
	if ipv6_list.size() > 0:
		return ipv6_list[0]
	
	return DEFAULT_SERVER_IP

func create_game(port_override: int = 0) -> int:
	var start_port := PORT
	
	if port_override and port_override > 0:
		start_port = port_override
	
	var last_err := ERR_CANT_CREATE
	
	for attempt_offset in range(0, PORT_FALLBACK_TRIES + 1):
		var try_port := start_port + attempt_offset
		var peer := ENetMultiplayerPeer.new()
		var err := peer.create_server(try_port, MAX_CONNECTIONS)
	
		if err == OK:
			# success
			multiplayer.multiplayer_peer = peer
			current_port = try_port
	
			# compute and store host id explicitly
			host_id = multiplayer.get_unique_id()
			players.clear()
			players[host_id] = player_info.duplicate(true)
			emit_signal("player_connected", host_id, players[host_id])
	
			# format host_address
			var ip := _get_best_local_ip()
			var host_address := ""
			if ip.find(".") != -1:
				host_address = "%s:%d" % [ip, try_port]
			else:
				host_address = "[%s]:%d" % [ip, try_port]
	
			push_warning("Network.create_game: server created on port %d — local address reported as %s." % [try_port, ip])
			emit_signal("lobby_created", host_id, players[host_id], host_address)
			return OK
	
		last_err = err
		if err != ERR_CANT_CREATE:
			push_error("Network.create_game: ENet create_server returned error code: %s" % str(err))
			return err
	
		push_warning("Network.create_game: port %d unavailable, trying next port." % try_port)
	
	# all attempts failed
	push_error("Network.create_game: Could not bind any port in range %d..%d (last err %s)" % [start_port, start_port + PORT_FALLBACK_TRIES, str(last_err)])
	return last_err

func join_game(address: String = "") -> int:
	if address.is_empty():
		address = DEFAULT_SERVER_IP
	
	var parsed := _parse_host_port(address)
	var ip_str: String = str(parsed.get("host", DEFAULT_SERVER_IP))
	var port_to_use: int = int(parsed.get("port", PORT))
	
	if ip_str == "" or ip_str == null:
		ip_str = DEFAULT_SERVER_IP
	
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip_str, port_to_use)
	if err != OK:
		push_error("Network.join_game: ENet create_client returned error %s when connecting to %s:%d" % [str(err), ip_str, port_to_use])
		match err:
			ERR_CANT_CONNECT:
				push_error("ERR_CANT_CONNECT: could not reach host. Check firewall and that host is running and reachable.")
			_:
				push_error("Unknown create_client error: %s" % str(err))
		return err
	
	multiplayer.multiplayer_peer = peer
	push_warning("Network.join_game: client created, attempting connection to %s:%d" % [ip_str, port_to_use])
	return OK

func _parse_host_port(address: String) -> Dictionary:
	var result := {"host":"", "port": PORT}
	
	if address == "" or address == null:
		result.host = DEFAULT_SERVER_IP
		return result
	
	address = address.strip_edges()
	
	if address.begins_with("["):
		var closing := address.find("]")
		if closing == -1:
			result.host = address
			return result
		result.host = address.substr(1, closing - 1)
		
		if closing + 1 < address.length() and address[closing + 1] == ":":
			var port_str := address.substr(closing + 2, address.length() - closing - 2)
			if port_str.is_valid_int():
				var p := int(port_str)
				if p > 0:
					result.port = p
		return result
	
	var colon_count := 0
	for ch in address:
		if ch == ":":
			colon_count += 1
	
	if colon_count == 0:
		result.host = address
		return result
	
	if colon_count == 1:
		var parts := address.split(":", false, 2)
		result.host = parts[0]
		if parts.size() > 1 and parts[1].is_valid_int():
			var p := int(parts[1])
			if p > 0:
				result.port = p
		return result
	
	result.host = address
	return result

func remove_multiplayer_peer() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	players.clear()
	players_loaded = 0
	if host_id != 0:
		emit_signal("lobby_removed", host_id)
	host_id = 0

@rpc("call_local", "any_peer", "reliable")
func rpc_load_game(game_scene_path: String) -> void:
	get_tree().change_scene_to_file(game_scene_path)

@rpc("call_local", "any_peer", "reliable")
func rpc_start_simulation() -> void:
	simulation_started_flag = true
	emit_signal("simulation_started")

@rpc("any_peer", "reliable")
func _register_player(new_player_info: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	
	var new_player_id := multiplayer.get_remote_sender_id()
	players[new_player_id] = new_player_info.duplicate(true)
	emit_signal("player_connected", new_player_id, players[new_player_id])
	
	for recipient_peer_id in players.keys():
		if typeof(recipient_peer_id) != TYPE_INT:
			continue
		rpc_id(recipient_peer_id, "rpc_set_player_info", new_player_id, new_player_info)

@rpc("any_peer", "call_local", "reliable")
func rpc_spawn_player(spawn_peer_id: int, transform: Transform3D) -> void:
	spawn_local_player(spawn_peer_id, transform)

func spawn_local_player(spawn_peer_id: int, transform: Transform3D) -> void:
	var current_scene: Node = get_tree().get_current_scene()
	if current_scene == null:
		push_error("spawn_local_player: current scene is null on peer %d" % multiplayer.get_unique_id())
		return
	
	var parent: Node = current_scene.get_node_or_null("World")
	if parent == null:
		parent = current_scene
	
	var to_remove: Array = []
	for child in parent.get_children():
		if child is Node:
			if child.name == "PlayerShip":
				if is_instance_valid(child):
					child.queue_free()
	
	for d in to_remove:
		push_warning("spawn_local_player: removing existing node with same owner %s -> %s" % [str(spawn_peer_id), d.name])
		if is_instance_valid(d):
			d.queue_free()
	
	var desired_name: String = "Player_%d" % spawn_peer_id
	var found: Array = []
	_search_nodes_by_name_recursive(parent, desired_name, found)
	
	if found.size() > 1:
		push_warning("spawn_local_player: found %d nodes named %s under %s on peer %d — removing duplicates" %
					 [found.size(), desired_name, parent.name, multiplayer.get_unique_id()])
		for i in range(1, found.size()):
			var dup: Node = found[i] as Node
			if is_instance_valid(dup):
				dup.queue_free()
	
	if found.size() >= 1:
		var existing: Node = found[0] as Node
		
		if existing.has_method("set_multiplayer_authority"):
			existing.set_multiplayer_authority(spawn_peer_id)
		elif existing.has_method("set_network_master"):
			existing.set_network_master(spawn_peer_id)
		existing.global_transform = transform
		push_warning("spawn_local_player: updated existing %s under %s on peer %d (owner=%d)" %
					 [desired_name, parent.name, multiplayer.get_unique_id(), spawn_peer_id])
		return
	
	const player_scene_path := "res://scenes/player/PlayerShip.tscn"
	var PlayerShipScene: PackedScene = preload(player_scene_path)
	var ship: Node = PlayerShipScene.instantiate() as Node
	ship.name = desired_name
	
	if ship.has_method("set_multiplayer_authority"):
		ship.set_multiplayer_authority(spawn_peer_id)
	elif ship.has_method("set_network_master"):
		ship.set_network_master(spawn_peer_id)
	
	parent.add_child(ship)
	ship.global_transform = transform

func _search_nodes_by_name_recursive(root: Node, name_to_find: String, out_array: Array) -> void:
	if root.name == name_to_find:
		out_array.append(root)
	for child in root.get_children():
		if child is Node:
			_search_nodes_by_name_recursive(child as Node, name_to_find, out_array)

@rpc("any_peer", "call_local", "unreliable")
func rpc_player_state(owner_peer_id: int, authoritative_transform: Transform3D, authoritative_vel: Vector3, authoritative_moving: bool) -> void:
	if multiplayer.is_server():
		var sender := multiplayer.get_remote_sender_id()
		if sender != 0:
			for recipient in players.keys():
				if typeof(recipient) != TYPE_INT:
					continue
				if recipient == sender:
					continue
				rpc_id(recipient, "rpc_player_state", owner_peer_id, authoritative_transform, authoritative_vel, authoritative_moving)
	
	var current_scene: Node = get_tree().get_current_scene()
	if current_scene == null:
		return
	
	var parent: Node = current_scene.get_node_or_null("World")
	if parent == null:
		parent = current_scene
	
	var node_name := "Player_%d" % owner_peer_id
	var player_node: Node = parent.get_node_or_null(node_name)
	if player_node == null:
		push_warning("rpc_player_state: Player node not found for id %d on peer %d (looking for %s)" % [owner_peer_id, multiplayer.get_unique_id(), node_name])
		return
	
	if player_node.has_method("set_remote_state"):
		player_node.call("set_remote_state", authoritative_transform, authoritative_vel, authoritative_moving)
	else:
		player_node.set("global_transform", authoritative_transform)

@rpc("call_local", "any_peer", "reliable")
func rpc_set_player_info(peer_id: int, info: Dictionary) -> void:
	players[peer_id] = info.duplicate(true)
	emit_signal("player_connected", peer_id, players[peer_id])

@rpc("call_local", "any_peer", "reliable")
func rpc_lobby_info(host_id_in: int, host_info: Dictionary, address: String) -> void:
	host_id = host_id_in
	emit_signal("lobby_created", host_id_in, host_info, address)

@rpc("any_peer", "reliable")
func player_loaded() -> void:
	if multiplayer.is_server():
		var sender := multiplayer.get_remote_sender_id()
	
		# Prevent double-counting
		if player_loaded_once.get(sender, false):
			return
		player_loaded_once[sender] = true
		
		players_loaded += 1
		
		if players_loaded == players.size():
			var current_scene := get_tree().get_current_scene()
			if current_scene and current_scene.has_method("start_game"):
				current_scene.start_game()
			players_loaded = 0
			player_loaded_once.clear()

func _on_player_connected(id: int) -> void:
	if multiplayer.is_server():
		for pid in players.keys():
			rpc_id(id, "rpc_set_player_info", pid, players[pid])
	
		var ip := _get_best_local_ip()
		var host_address := ""
		if ip.find(".") != -1:
			host_address = "%s:%d" % [ip, current_port]
		else:
			host_address = "[%s]:%d" % [ip, current_port]
	
		if host_id == 0:
			host_id = multiplayer.get_unique_id()
	
		rpc_id(id, "rpc_lobby_info", host_id, players[host_id], host_address)

func _on_player_disconnected(id: int) -> void:
	if players.has(id):
		players.erase(id)
	emit_signal("player_disconnected", id)
	
	if id == host_id:
		remove_multiplayer_peer()
		emit_signal("server_disconnected")

func _on_connected_ok() -> void:
	var peer_id := multiplayer.get_unique_id()
	players[peer_id] = player_info.duplicate(true)
	emit_signal("player_connected", peer_id, players[peer_id])
	
	var target_host := host_id if host_id != 0 else 1
	rpc_id(target_host, "_register_player", player_info)
	
	var root_scene := get_tree().get_current_scene()
	if root_scene:
		var status_node: Label = root_scene.get_node_or_null("UI").get_node_or_null("LobbiesPanel").find_child("StatusLabel") as Label
		if status_node:
			status_node.text = ""

func _on_connected_fail() -> void:
	remove_multiplayer_peer()

func _on_server_disconnected() -> void:
	remove_multiplayer_peer()
	emit_signal("server_disconnected")
