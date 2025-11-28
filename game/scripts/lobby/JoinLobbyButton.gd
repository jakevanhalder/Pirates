extends Button

@onready var ip_input: Node = $"../JoinIPInput"
@onready var status_label: Label = $"../StatusLabel"

func _on_pressed() -> void:
	var ip_text: String = ""
	if ip_input != null:
		if ip_input is LineEdit:
			ip_text = ip_input.text.strip_edges()

	if ip_text == "":
		__set_status("Please enter a server IP in JoinIPInput.")
		return

	# Try to join
	var err: int = Network.join_game(ip_text)
	if err != OK:
		__set_status("Join failed: %s" % str(err))
	else:
		__set_status("Joining %s ..." % ip_text)

func __set_status(text: String) -> void:
	if status_label != null:
		status_label.text = text
	else:
		print(text)
