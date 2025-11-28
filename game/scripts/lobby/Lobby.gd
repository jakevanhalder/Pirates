extends Node

const LOBBIES_PANEL_PATH := "UI/LobbiesPanel/MarginContainer/VBoxContainer"

@onready var lobbies_vbox := get_node_or_null(LOBBIES_PANEL_PATH)
@onready var create_btn := lobbies_vbox.get_node_or_null("CreateLobbyButton") if lobbies_vbox else null

var LobbyEntryScene: PackedScene = preload("res://ui/lobby/LobbyEntry.tscn")

var lobby_entries: Dictionary = {}

func _ready() -> void:
	for k in lobby_entries.keys():
		var e: Node = lobby_entries[k]
		if is_instance_valid(e):
			e.queue_free()
	lobby_entries.clear()
	
	if not lobbies_vbox:
		push_error("LobbyUI: couldn't find LobbiesPanel VBoxContainer at path: %s" % LOBBIES_PANEL_PATH)
		return
	
	if create_btn:
		if create_btn.has_signal("lobby_created_ok"):
			create_btn.lobby_created_ok.connect(func() -> void:
				_show_status("Lobby created. You are host.")
			)
		if create_btn.has_signal("lobby_created_failed"):
			create_btn.lobby_created_failed.connect(func(err) -> void:
				_show_status("Create failed: %s" % str(err))
			)
	else:
		push_warning("LobbyUI: no CreateLobbyButton found under the LobbiesPanel VBoxContainer.")
	
	Network.lobby_created.connect(_on_lobby_created)
	Network.lobby_removed.connect(_on_lobby_removed)
	Network.player_connected.connect(_on_player_connected)
	Network.player_disconnected.connect(_on_player_disconnected)
	Network.server_disconnected.connect(_on_server_disconnected)

func _on_create_lobby_pressed() -> void:
	var err := Network.create_game()
	if err != OK:
		_show_status("Create failed: %s" % str(err))
		return
	_show_status("Lobby created. You are host.")

func _on_lobby_created(host_id: int, host_info: Dictionary, address: String) -> void:
	_add_lobby_entry(host_id, host_info, true, address)

func _on_lobby_removed(host_id: int) -> void:
	_remove_lobby_entry(host_id)

func _on_player_connected(peer_id: int, player_info: Dictionary) -> void:
	if Network.multiplayer.is_server():
		_update_local_entry_count(1)

func _on_player_disconnected(peer_id: int) -> void:
	if Network.multiplayer.is_server():
		_update_local_entry_count(1)

func _on_server_disconnected() -> void:
	_remove_lobby_entry(1)
	_show_status("Server disconnected.")

func _add_lobby_entry(host_id: int, host_info: Dictionary, is_local_host: bool=false, address: String="127.0.0.1") -> void:
	if lobby_entries.has(host_id):
		var existing: Node = lobby_entries[host_id]
		if existing.has_method("setup"):
			existing.setup(host_id, host_info, is_local_host, address)
		_update_local_entry_count(host_id)
		return
	
	var entry: Node = LobbyEntryScene.instantiate()
	lobbies_vbox.add_child(entry)
	lobby_entries[host_id] = entry
	
	if entry.has_method("setup"):
		entry.setup(host_id, host_info, is_local_host, address)
	
	if entry.has_signal("disconnect_requested"):
		var disconnect_callable := Callable(self, "_on_entry_disconnect_requested")
		if not entry.is_connected("disconnect_requested", disconnect_callable):
			entry.disconnect_requested.connect(_on_entry_disconnect_requested)
	
	if entry.has_signal("start_requested"):
		var start_callable := Callable(self, "_on_entry_start_requested")
		if not entry.is_connected("start_requested", start_callable):
			entry.start_requested.connect(_on_entry_start_requested)
	_update_local_entry_count(host_id)

func _remove_lobby_entry(host_id: int) -> void:
	if not lobby_entries.has(host_id):
		return
	
	var entry: Node = lobby_entries[host_id]
	entry.queue_free()
	lobby_entries.erase(host_id)

func _update_local_entry_count(host_id: int) -> void:
	if not lobby_entries.has(host_id):
		return
	
	var entry: Node = lobby_entries[host_id]
	if host_id == 1 and Network.players:
		if entry.has_method("update_count"):
			entry.update_count(Network.players.size())

func _on_entry_disconnect_requested() -> void:
	Network.remove_multiplayer_peer()
	_show_status("Disconnected.")

func _on_entry_start_requested() -> void:
	_show_status("Starting game...")

func _show_status(text: String) -> void:
	var ui_root := get_node_or_null("UI")
	var output_panel: PanelContainer = null
	
	if ui_root:
		output_panel = ui_root.get_node_or_null("OutputPanel")
	
	if output_panel:
		var status_label: Label = output_panel.find_child("StatusLabel")
	
		if status_label and status_label is Label:
			status_label.text = text
			return
	
	print(text)

