extends Node

signal player_connected(peer_id, player_info)
signal player_disconnected(peer_id)
signal server_disconnected
signal lobby_created(host_id, host_info, address)
signal lobby_removed(host_id)
signal simulation_started

const PORT: int = 7000
const DEFAULT_SERVER_IP: String = "127.0.0.1"
const MAX_CONNECTIONS: int = 8

var players: Dictionary = {}
var player_info: Dictionary = {"name": "Player"}
var players_loaded: int = 0
var player_loaded_once: Dictionary = {}

var current_port: int = PORT
const PORT_FALLBACK_TRIES: int = 3

var host_id: int = 0

var simulation_started_flag: bool = false

# Metrics
var metrics_rtt: Dictionary = {}
var metrics_rtt_samples: Dictionary = {}
var metrics_bytes_sent: int = 0
var metrics_bytes_recv: int = 0
var metrics_sent_packets: int = 0
var metrics_recv_packets: int = 0
var _metrics_samples: Array = []

@export var metrics_sample_interval: float = 0.5 
@export var metrics_collection_duration: float = 30.0

@export var ping_interval_ms: int = 500

# config for local experiment/simulation (zero = off)
@export var simulate_latency_ms_min: int = 0
@export var simulate_latency_ms_max: int = 0
@export var simulate_packet_loss_pct: float = 0.0

@export var exp_latencies: Array = [0, 50, 100, 200]
@export var exp_losses: Array = [0, 1, 5]
@export var exp_repeats: int = 1
@export var exp_duration_per_setting: float = 30.0
@export var exp_pause_between_runs: float = 1.0
@export var exp_wait_for_total_players: int = 1
@export var auto_start_experiments: bool = false

var _experiment_running: bool = false

# Estimation constants
const _BYTES_PER_INT: int = 8
const _BYTES_PER_FLOAT: int = 8
const _TRANSFORM3D_FLOATS: int = 12
const _VECTOR3_FLOATS: int = 3
const _BOOL_BYTES: int = 1
const _RPC_HEADER_OVERHEAD: int = 16

var _ping_loop_running: bool = false

func _estimate_packet_size(owner_peer_id: int, authoritative_transform: Transform3D, authoritative_vel: Vector3, authoritative_moving: bool) -> int:
	var size: int = 0
	size += _BYTES_PER_INT
	size += _TRANSFORM3D_FLOATS * _BYTES_PER_FLOAT
	size += _VECTOR3_FLOATS * _BYTES_PER_FLOAT
	size += _BOOL_BYTES
	size += _RPC_HEADER_OVERHEAD
	return size

# Ping / RTT helpers
func send_ping(target_peer: int) -> void:
	var now_ms: int = Time.get_ticks_msec()
	rpc_id(target_peer, "rpc_ping", multiplayer.get_unique_id(), now_ms)

@rpc("any_peer", "reliable")
func rpc_ping(client_id: int, sent_ts: int) -> void:
	rpc_id(client_id, "rpc_pong", sent_ts, Time.get_ticks_msec())

@rpc("any_peer", "reliable")
func rpc_pong(sent_ts: int, server_ts: int) -> void:
	var now_ms: int = Time.get_ticks_msec()
	var rtt: int = now_ms - sent_ts
	var my_id: int = multiplayer.get_unique_id()
	metrics_rtt[my_id] = rtt
	if not metrics_rtt_samples.has(my_id):
		metrics_rtt_samples[my_id] = []
	var arr: Array = metrics_rtt_samples[my_id] as Array
	arr.append(rtt)
	if arr.size() > 200:
		arr.remove_at(0)
	metrics_rtt_samples[my_id] = arr

func start_ping_loop() -> void:
	if _ping_loop_running:
		return
	_ping_loop_run()

func _ping_loop_run() -> void:
	_ping_loop_running = true
	while simulation_started_flag and multiplayer.is_server():
		for pid in players.keys():
			if typeof(pid) != TYPE_INT:
				continue
			if int(pid) == multiplayer.get_unique_id():
				continue
			send_ping(int(pid))
		await get_tree().create_timer(float(ping_interval_ms) / 1000.0).timeout
	_ping_loop_running = false

func start_data_collection(duration_seconds: float = 30.0, sample_interval: float = 0.5, out_path: String = "user://metrics.csv") -> void:
	_metrics_samples.clear()
	metrics_bytes_sent = 0
	metrics_bytes_recv = 0
	metrics_sent_packets = 0
	metrics_recv_packets = 0
	metrics_sample_interval = max(0.05, sample_interval)
	metrics_collection_duration = max(1.0, duration_seconds)
	
	var iterations: int = int(ceil(metrics_collection_duration / metrics_sample_interval))
	if iterations < 1:
		iterations = 1
	
	print("[Network] Starting data collection: duration=", metrics_collection_duration, "s interval=", metrics_sample_interval, "s, iterations=", iterations, " -> file=", out_path)
	for i in range(iterations):
		_sample_metrics()
		await get_tree().create_timer(metrics_sample_interval).timeout
	
	_sample_metrics()
	dump_metrics_to_csv(out_path)

func start_auto_run(duration_seconds: float = 30.0, sample_interval: float = 0.5, latency_ms: int = 0, loss_pct: float = 0.0, run_index: int = 1) -> void:
	simulate_latency_ms_min = latency_ms
	simulate_latency_ms_max = latency_ms
	simulate_packet_loss_pct = float(loss_pct)
	
	var ts_id := int(Time.get_ticks_msec())
	var filename: String = "user://metrics_lat%d_loss%d_run%d_%d.csv" % [latency_ms, int(loss_pct), run_index, ts_id]
	start_data_collection(duration_seconds, sample_interval, filename)

func _sample_metrics() -> void:
	var now_ms: int = Time.get_ticks_msec()
	if players.size() == 0:
		var row_global: Dictionary = {
			"time_ms": now_ms,
			"peer_id": -1,
			"last_rtt_ms": -1,
			"bytes_sent": metrics_bytes_sent,
			"bytes_recv": metrics_bytes_recv,
			"sent_pkts": metrics_sent_packets,
			"recv_pkts": metrics_recv_packets
		}
		_metrics_samples.append(row_global)
		return
	
	for peer_id_obj in players.keys():
		if typeof(peer_id_obj) != TYPE_INT:
			continue
		var peer_id: int = int(peer_id_obj)
		var last_rtt: int = -1
		if metrics_rtt.has(peer_id):
			last_rtt = int(metrics_rtt[peer_id])
		var row: Dictionary = {
			"time_ms": now_ms,
			"peer_id": peer_id,
			"last_rtt_ms": last_rtt,
			"bytes_sent": metrics_bytes_sent,
			"bytes_recv": metrics_recv_packets,
			"sent_pkts": metrics_sent_packets,
			"recv_pkts": metrics_recv_packets
		}
		_metrics_samples.append(row)

func dump_metrics_to_csv(path: String = "user://metrics.csv") -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.ModeFlags.WRITE)
	if file == null:
		push_error("Could not open metrics file for writing: %s" % path)
		return
	
	file.store_line("sample_index,time_ms,peer_id,last_rtt_ms,bytes_sent,bytes_recv,sent_pkts,recv_pkts")
	var sample_count: int = _metrics_samples.size()
	for i in range(sample_count):
		var r: Dictionary = _metrics_samples[i] as Dictionary
		var time_ms: int = int(r.get("time_ms", 0))
		var peer_id: int = int(r.get("peer_id", -1))
		var last_rtt: int = int(r.get("last_rtt_ms", -1))
		var b_sent: int = int(r.get("bytes_sent", 0))
		var b_recv: int = int(r.get("bytes_recv", 0))
		var s_pkts: int = int(r.get("sent_pkts", 0))
		var r_pkts: int = int(r.get("recv_pkts", 0))
		file.store_line("%d,%d,%d,%d,%d,%d,%d,%d" % [i, time_ms, peer_id, last_rtt, b_sent, b_recv, s_pkts, r_pkts])
	
	file.close()
	print("[Network] Metrics written to: %s (samples=%d)" % [path, sample_count])
	print("[Network] OS user data dir: %s" % OS.get_user_data_dir())

func run_experiments() -> void:
	if _experiment_running:
		push_warning("run_experiments: already running")
		return
	call_deferred("_run_experiments")

func _run_experiments() -> void:
	_experiment_running = true
	
	if not multiplayer.is_server():
		push_warning("run_experiments: not server — experiments will still run but metrics may be meaningless. Run on the host for correct results.")
	
	var run_counter: int = 0
	for rep in range(exp_repeats):
		for lat in exp_latencies:
			for loss in exp_losses:
				run_counter += 1
				print("[Network][Exp] Preparing run %d: latency=%d ms, loss=%d%% (repeat %d/%d)" % [run_counter, int(lat), int(loss), rep+1, exp_repeats])
	
				# wait for sufficient players if requested
				if exp_wait_for_total_players > 1:
					print("[Network][Exp] Waiting for at least %d players..." % exp_wait_for_total_players)
					var pc: int = 0
					while true:
						pc = players.size()
						if pc >= exp_wait_for_total_players:
							break
						await get_tree().create_timer(1.0).timeout
					print("[Network][Exp] Required players present (count=%d). Starting run..." % pc)
	
				simulate_latency_ms_min = int(lat)
				simulate_latency_ms_max = int(lat)
				simulate_packet_loss_pct = float(loss)
	
				simulation_started_flag = true
				if is_instance_valid(self) and multiplayer.is_server():
					start_ping_loop()
	
				var ts_id := int(Time.get_ticks_msec())
				var filename := "user://metrics_lat%d_loss%d_run%d_%d.csv" % [int(lat), int(loss), run_counter, ts_id]
				print("[Network][Exp] Starting collection (%.1fs) -> %s" % [exp_duration_per_setting, filename])
	
				await start_data_collection(exp_duration_per_setting, metrics_sample_interval, filename)
	
				simulation_started_flag = false
				print("[Network][Exp] Completed run %d -> %s" % [run_counter, filename])
	
				await get_tree().create_timer(exp_pause_between_runs).timeout
	
	_experiment_running = false
	print("[Network][Exp] All experiments complete. Files written to user:// (see OS.get_user_data_dir()).")

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_player_connected)
	multiplayer.peer_disconnected.connect(_on_player_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_ok)
	multiplayer.connection_failed.connect(_on_connected_fail)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	
	if auto_start_experiments and multiplayer.is_server():
		call_deferred("run_experiments")

func _get_best_local_ip() -> String:
	var addrs: Array = IP.get_local_addresses()
	var ipv4_list: Array = []
	var ipv6_list: Array = []
	
	for a in addrs:
		if typeof(a) != TYPE_STRING:
			continue
		var s: String = str(a).strip_edges()
		if s == "127.0.0.1" or s == "::1" or s.begins_with("169.254."):
			continue
		if s.find(".") != -1:
			ipv4_list.append(s)
		else:
			ipv6_list.append(s)

	# Preference order for IPv4 private ranges
	for ip in ipv4_list:
		if ip.begins_with("192.168."):
			return ip
	for ip in ipv4_list:
		if ip.begins_with("10."):
			return ip
	for ip in ipv4_list:
		if ip.find(".") != -1:
			var parts: PackedStringArray = ip.split(".")
			if parts.size() >= 2:
				var o1: int = int(parts[0])
				var o2: int = int(parts[1])
				if o1 == 172 and o2 >= 16 and o2 <= 31:
					return ip
	
	if ipv4_list.size() > 0:
		return ipv4_list[0]
	if ipv6_list.size() > 0:
		return ipv6_list[0]
	
	return DEFAULT_SERVER_IP

func create_game(port_override: int = 0) -> int:
	var start_port: int = PORT
	if port_override and port_override > 0:
		start_port = port_override
	
	var last_err: int = ERR_CANT_CREATE
	for attempt_offset in range(0, PORT_FALLBACK_TRIES + 1):
		var try_port: int = start_port + attempt_offset
		var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
		var err: int = peer.create_server(try_port, MAX_CONNECTIONS)
	
		if err == OK:
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
	
	var parsed: Dictionary = _parse_host_port(address)
	var ip_str: String = str(parsed.get("host", DEFAULT_SERVER_IP))
	var port_to_use: int = int(parsed.get("port", PORT))
	
	if ip_str == "" or ip_str == null:
		ip_str = DEFAULT_SERVER_IP
	
	var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	var err: int = peer.create_client(ip_str, port_to_use)
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
	var result: Dictionary = {"host":"", "port": PORT}
	if address == "" or address == null:
		result.host = DEFAULT_SERVER_IP
		return result
	
	address = address.strip_edges()
	if address.begins_with("["):
		var closing: int = address.find("]")
		if closing == -1:
			result.host = address
			return result
		result.host = address.substr(1, closing - 1)
	
		if closing + 1 < address.length() and address[closing + 1] == ":":
			var port_str: String = address.substr(closing + 2, address.length() - closing - 2)
			if port_str.is_valid_int():
				var p: int = int(port_str)
				if p > 0:
					result.port = p
		return result
	
	var colon_count: int = 0
	for ch in address:
		if ch == ":":
			colon_count += 1
	
	if colon_count == 0:
		result.host = address
		return result
	
	if colon_count == 1:
		var parts: PackedStringArray = address.split(":", false, 2)
		result.host = parts[0]
		if parts.size() > 1 and parts[1].is_valid_int():
			var p2: int = int(parts[1])
			if p2 > 0:
				result.port = p2
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
	
	if multiplayer.is_server():
		metrics_bytes_sent = 0
		metrics_bytes_recv = 0
		metrics_sent_packets = 0
		metrics_recv_packets = 0
		_metrics_samples.clear()
	
		start_ping_loop()
		run_experiments()
		print("[Network] Server started simulation + experiments.")

@rpc("any_peer", "reliable")
func _register_player(new_player_info: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	
	var new_player_id: int = multiplayer.get_remote_sender_id()
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
	
	# remove any previous PlayerShip nodes
	for child in parent.get_children():
		if child is Node:
			if child.name == "PlayerShip" and is_instance_valid(child):
				child.queue_free()
	
	var desired_name: String = "Player_%d" % spawn_peer_id
	var found: Array = []
	_search_nodes_by_name_recursive(parent, desired_name, found)
	
	if found.size() > 1:
		push_warning("spawn_local_player: found %d nodes named %s under %s on peer %d — removing duplicates" % [found.size(), desired_name, parent.name, multiplayer.get_unique_id()])
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
		push_warning("spawn_local_player: updated existing %s under %s on peer %d (owner=%d)" % [desired_name, parent.name, multiplayer.get_unique_id(), spawn_peer_id])
		return
	
	const player_scene_path: String = "res://scenes/player/PlayerShip.tscn"
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

func _delayed_relay(recipient: int, owner_peer_id: int, authoritative_transform: Transform3D, authoritative_vel: Vector3, authoritative_moving: bool, delay_s: float) -> void:
	await get_tree().create_timer(delay_s).timeout
	rpc_id(recipient, "rpc_player_state", owner_peer_id, authoritative_transform, authoritative_vel, authoritative_moving)
	var b: int = _estimate_packet_size(owner_peer_id, authoritative_transform, authoritative_vel, authoritative_moving)
	metrics_bytes_sent += b
	metrics_sent_packets += 1

@rpc("any_peer", "call_local", "unreliable")
func rpc_player_state(owner_peer_id: int, authoritative_transform: Transform3D, authoritative_vel: Vector3, authoritative_moving: bool, ts: int = 0, seq: int = 0) -> void:
	if multiplayer.is_server():
		var sender: int = multiplayer.get_remote_sender_id()
		if sender != 0:
			for recipient in players.keys():
				if typeof(recipient) != TYPE_INT:
					continue
				var recipient_id: int = int(recipient)
				if recipient_id == sender:
					continue
	
				if simulate_packet_loss_pct > 0.0:
					if randf() < (simulate_packet_loss_pct * 0.01):
						continue
	
				var delay_ms: int = 0
				if simulate_latency_ms_max > 0:
					var span: int = simulate_latency_ms_max - simulate_latency_ms_min
					if span < 0:
						span = 0
					delay_ms = simulate_latency_ms_min
					if span > 0:
						delay_ms += int(randi() % (span + 1))
	
				if delay_ms > 0:
					call_deferred("_delayed_relay", recipient_id, owner_peer_id, authoritative_transform, authoritative_vel, authoritative_moving, delay_ms / 1000.0)
				else:
					rpc_id(recipient_id, "rpc_player_state", owner_peer_id, authoritative_transform, authoritative_vel, authoritative_moving, ts, seq)
					var b_now: int = _estimate_packet_size(owner_peer_id, authoritative_transform, authoritative_vel, authoritative_moving)
					metrics_bytes_sent += b_now
					metrics_sent_packets += 1
	
	var recv_b: int = _estimate_packet_size(owner_peer_id, authoritative_transform, authoritative_vel, authoritative_moving)
	metrics_bytes_recv += recv_b
	metrics_recv_packets += 1
	
	var current_scene: Node = get_tree().get_current_scene()
	if current_scene == null:
		return
	
	var parent: Node = current_scene.get_node_or_null("World")
	if parent == null:
		parent = current_scene
	
	var node_name: String = "Player_%d" % owner_peer_id
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
		var sender: int = multiplayer.get_remote_sender_id()
	
		if player_loaded_once.get(sender, false):
			return
		player_loaded_once[sender] = true
	
		players_loaded += 1
	
		if players_loaded == players.size():
			var current_scene: Node = get_tree().get_current_scene()
			if current_scene and current_scene.has_method("start_game"):
				current_scene.start_game()
			players_loaded = 0
			player_loaded_once.clear()

func _on_player_connected(id: int) -> void:
	if multiplayer.is_server():
		for pid in players.keys():
			rpc_id(id, "rpc_set_player_info", pid, players[pid])
	
		var ip: String = _get_best_local_ip()
		var host_address: String = ""
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
	var peer_id: int = multiplayer.get_unique_id()
	players[peer_id] = player_info.duplicate(true)
	emit_signal("player_connected", peer_id, players[peer_id])
	
	var target_host: int = host_id if host_id != 0 else 1
	rpc_id(target_host, "_register_player", player_info)
	
	var root_scene: Node = get_tree().get_current_scene()
	if root_scene:
		var status_node: Node = root_scene.get_node_or_null("UI")
		if status_node:
			# safe navigation to StatusLabel if present
			var lp: Node = status_node.get_node_or_null("LobbiesPanel")
			if lp:
				var status_label: Label = lp.find_child("StatusLabel")
				if status_label and status_label is Label:
					status_label.text = ""

func _on_connected_fail() -> void:
	remove_multiplayer_peer()

func _on_server_disconnected() -> void:
	remove_multiplayer_peer()
	emit_signal("server_disconnected")
