extends Button

@onready var user_name_textbox: LineEdit = $"../UsernameInput"
@onready var user_label: Label = $"../UsernameLabel"

func _on_pressed() -> void:
	var name = user_name_textbox.text.strip_edges()
	if name == "":
		name = "New User"
	
	if self.text == "Clear":
		self.text = "Set Name"
		user_label.visible = false
		user_name_textbox.visible = true
	else:
		self.text = "Clear"
		user_name_textbox.visible = false
		user_label.visible = true
		user_label.text = "Username: " + name
