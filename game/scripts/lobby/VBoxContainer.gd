extends VBoxContainer

func _ready() -> void:
	add_to_group("user_list")

func add_user_label(text: String) -> void:
	text = text.strip_edges()
	if text == "":
		return
	for child in get_children():
		if child is Label and child.text == text:
			return
	var label = Label.new()
	label.text = text
	add_child(label)

func remove_user_label(text: String) -> void:
	text = text.strip_edges()
	if text == "":
		return
	# find the first label with matching text and free it
	for child in get_children():
		if child is Label and child.text == text:
			child.queue_free()
			return
