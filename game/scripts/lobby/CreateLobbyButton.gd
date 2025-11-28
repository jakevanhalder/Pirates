extends Button
signal lobby_created_ok
signal lobby_created_failed(err_code)

func _on_pressed() -> void:
	var err := Network.create_game()
	if err != OK:
		emit_signal("lobby_created_failed", err)
	else:
		emit_signal("lobby_created_ok")
