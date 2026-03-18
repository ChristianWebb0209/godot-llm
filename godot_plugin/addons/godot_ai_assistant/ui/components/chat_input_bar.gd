@tool
extends HBoxContainer
class_name GodotAIChatInputBar

## View component: chat input bar (prompt + model selector + send button) emitting signals.

signal send_pressed(text: String)
signal model_selected(index: int)

@onready var prompt_text_edit: TextEdit = $PromptTextEdit
@onready var model_option: OptionButton = $ModelOption
@onready var ask_button: Button = $AskButton


func _ready() -> void:
	if ask_button:
		ask_button.pressed.connect(_on_send_pressed)
	if prompt_text_edit:
		prompt_text_edit.gui_input.connect(_on_prompt_gui_input)
	if model_option:
		model_option.item_selected.connect(func(i: int) -> void:
			model_selected.emit(i)
		)


func _on_send_pressed() -> void:
	if not prompt_text_edit:
		return
	send_pressed.emit(prompt_text_edit.text)


func _on_prompt_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		if key.keycode in [KEY_ENTER, KEY_KP_ENTER] and not key.shift_pressed:
			prompt_text_edit.accept_event()
			_on_send_pressed()

