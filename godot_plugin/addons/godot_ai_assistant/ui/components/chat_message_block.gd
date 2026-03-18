@tool
extends VBoxContainer
class_name GodotAIChatMessageBlock

## View component: renders a single chat message block (role + message + optional reasoning).

@onready var role_label: Label = $RoleLabel
@onready var reasoning_panel: PanelContainer = $ReasoningPanel
@onready var reasoning_text: RichTextLabel = $ReasoningPanel/ReasoningScroll/ReasoningText
@onready var message_text: RichTextLabel = $MessageText
@onready var divider: HSeparator = $Divider

var message_index: int = -1
var role: String = ""


func configure(
	p_index: int,
	p_role: String,
	p_message_bbcode: String,
	p_reasoning_bbcode: String,
	p_font_size: int,
	p_show_divider: bool
) -> void:
	message_index = p_index
	role = p_role
	set_meta("_ai_message_index", p_index)
	set_meta("_ai_chat_role", p_role)

	role_label.text = "You" if p_role == "user" else "Assistant"
	role_label.add_theme_font_size_override("font_size", p_font_size)
	var role_color := Color(0.69, 0.69, 0.69, 1.0)
	if p_role == "user":
		role_color = Color(0.75, 0.85, 0.95, 1.0)
	role_label.add_theme_color_override("font_color", role_color)

	reasoning_text.add_theme_font_size_override("normal_font_size", maxi(10, p_font_size - 2))
	reasoning_text.add_theme_font_size_override("mono_font_size", maxi(10, p_font_size - 2))
	reasoning_text.text = p_reasoning_bbcode
	reasoning_panel.visible = not p_reasoning_bbcode.is_empty()

	message_text.add_theme_font_size_override("normal_font_size", p_font_size)
	message_text.add_theme_font_size_override("mono_font_size", p_font_size)
	message_text.text = p_message_bbcode

	divider.visible = p_show_divider

