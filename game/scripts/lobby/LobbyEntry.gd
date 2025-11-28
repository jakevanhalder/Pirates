extends PanelContainer

signal start_requested()
signal disconnect_requested()

@export var host_id: int = 0
@export var host_address: String = ""
@export var is_local_host: bool = false

@onready var host_name_label := $HBoxContainer/VBoxContainer/HostNameLabel
@onready var id_label := $HBoxContainer/VBoxContainer/IdLabel
@onready var count_label := $HBoxContainer/CountLabel
@onready var start_btn := $HBoxContainer/StartButton
@onready var disconnect_btn := $HBoxContainer/DisconnectButton

func _ready() -> void:
	start_btn.pressed.connect(_on_start_pressed)
	disconnect_btn.pressed.connect(_on_disconnect_pressed)
	_update_buttons()

func setup(_host_id: int, _host_info: Dictionary, _is_local_host: bool=false, _address: String="127.0.0.1") -> void:
	host_id = _host_id
	host_address = _address
	is_local_host = _is_local_host
	
	host_name_label.text = str(_host_info.get("name", "Host"))
	id_label.text = "ID: %s • %s" % [str(host_id), host_address]
	_update_buttons()
	_update_count_display()

func update_count(count: int) -> void:
	count_label.text = "Players: %d" % count

func _update_buttons() -> void:
	start_btn.visible = is_local_host
	disconnect_btn.visible = is_local_host

func _update_count_display() -> void:
	if is_local_host and Network:
		update_count(Network.players.size())

func _on_start_pressed() -> void:
	emit_signal("start_requested")
	var scene_path := "res://scenes/game/Game.tscn"
	if Network.multiplayer.is_server():
		Network.rpc("rpc_load_game", scene_path)

func _on_disconnect_pressed() -> void:
	emit_signal("disconnect_requested")
	Network.remove_multiplayer_peer()
