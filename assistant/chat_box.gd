# chat_box.gd
# This file is part of I, Voyager
# https://ivoyager.dev
# *****************************************************************************
# Copyright 2019-2026 Charlie Whitfield
# I, Voyager is a registered trademark of Charlie Whitfield in the US
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# *****************************************************************************
class_name IVAssistantChatBox
extends VBoxContainer

## A chat box where the user talks with the assistant.
##
## A project places it in its GUI, usually in a panel of its own, and styles it
## with its theme; the colors below are those a theme has no entry for. It shows
## [code]IVAssistant.conversation[/code]: the user's words, the assistant's
## replies and, with [member show_tool_calls], the tools it calls. Each reply is
## an accessibility live region, so a screen reader reads it as it arrives.
## With no connection, it offers the setup wizard if the project has one. The
## text field takes focus when the chat box is shown, and lets it go on
## [code]ui_cancel[/code]. The user's assistant can't see or operate it
## ([constant IVAssistantWidgets.PRIVATE_GROUP]). Empty unless the assistant is
## enabled. See SPECIFICATION.md §12.5.

## The chat's width, in multiples of the theme's font size.
@export var width_in_font_sizes := 26.0
## The most lines of conversation shown before it scrolls.
@export var transcript_lines := 10.0
## Whether to show each tool the assistant calls.
@export var show_tool_calls := true
## Whether to speak each reply with the system's text-to-speech, which needs the
## project setting [code]audio/general/text_to_speech[/code].
@export var speak_replies := false
## The color of the user's words.
@export var user_color := Color(0.62, 0.78, 1.0)
## The color of notes: the connection, and the tools called.
@export var note_color := Color(0.62, 0.62, 0.62)
## The color of errors.
@export var error_color := Color(1.0, 0.56, 0.46)

var _assistant: Node # IVAssistant
var _conversation: IVAssistantConversation

var _scroll: ScrollContainer
var _entries: VBoxContainer
var _status: Label
var _setup_button: Button
var _input_row: HBoxContainer
var _message_edit: LineEdit
var _send_button: Button
var _new_button: Button


func _init() -> void:
	add_to_group(IVAssistantWidgets.PRIVATE_GROUP)
	_build()


func _ready() -> void:
	_assistant = get_node_or_null(^"/root/IVAssistant")
	if _assistant:
		_conversation = _assistant.get(&"conversation")
	if !_conversation:
		hide()
		return
	_status.add_theme_color_override(&"font_color", note_color)
	_conversation.turn_started.connect(_on_turn_started)
	_conversation.reply_received.connect(_on_reply_received)
	_conversation.tool_called.connect(_on_tool_called)
	_conversation.turn_finished.connect(_on_turn_finished)
	_conversation.cleared.connect(_on_cleared)
	_show_connection()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_THEME_CHANGED:
			_resize()
		NOTIFICATION_VISIBILITY_CHANGED:
			if is_visible_in_tree():
				_scroll_to_end()
				if _message_edit.is_visible_in_tree():
					_message_edit.grab_focus.call_deferred()


func _build() -> void:
	_scroll = ScrollContainer.new()
	add_child(_scroll)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_MAXIMIZE_FIRST
	_scroll.size_flags_vertical = SIZE_EXPAND_FILL
	_entries = VBoxContainer.new()
	_scroll.add_child(_entries)
	_entries.size_flags_horizontal = SIZE_EXPAND_FILL
	_status = Label.new()
	add_child(_status)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.accessibility_live = AccessibilityServer.LIVE_POLITE
	_setup_button = Button.new()
	add_child(_setup_button)
	_setup_button.size_flags_horizontal = SIZE_SHRINK_CENTER
	_setup_button.pressed.connect(_on_setup_pressed)
	_input_row = HBoxContainer.new()
	add_child(_input_row)
	_message_edit = LineEdit.new()
	_input_row.add_child(_message_edit)
	_message_edit.size_flags_horizontal = SIZE_EXPAND_FILL
	_message_edit.text_submitted.connect(_on_text_submitted)
	_message_edit.gui_input.connect(_on_message_edit_gui_input)
	_send_button = Button.new()
	_input_row.add_child(_send_button)
	_send_button.text = tr("Send")
	_send_button.pressed.connect(_on_send_pressed)
	_new_button = Button.new()
	_input_row.add_child(_new_button)
	_new_button.text = tr("New")
	_new_button.tooltip_text = tr("Start a new conversation")
	_new_button.pressed.connect(_on_new_pressed)


func _resize() -> void:
	var font_size := get_theme_font_size(&"font_size", &"Label")
	var font := get_theme_font(&"font", &"Label")
	custom_minimum_size.x = width_in_font_sizes * font_size
	var transcript_height := transcript_lines * font.get_height(font_size)
	_scroll.custom_maximum_size = Vector2(-1.0, transcript_height)


func _show_connection() -> void:
	var assistant_name := _conversation.assistant_name
	var connection := _conversation.connections.connection
	_input_row.visible = connection != null
	var has_setup_wizard: bool = _assistant.call(&"has_setup_wizard")
	_setup_button.visible = !connection and has_setup_wizard
	_setup_button.text = tr("Set up %s...") % assistant_name
	_message_edit.placeholder_text = tr("Ask %s") % assistant_name
	_message_edit.accessibility_name = _message_edit.placeholder_text
	_show_running(false)
	if !connection:
		_status.text = tr("%s isn't connected to an AI model.") % assistant_name
		_status.show()
		return
	_add_entry(tr("%s is using %s, from %s.") % [assistant_name, connection.model,
			tr(connection.provider_name)], note_color)


func _show_running(is_running: bool) -> void:
	_status.text = tr("%s is thinking...") % _conversation.assistant_name if is_running else ""
	_status.visible = _status.text != ""
	_send_button.text = tr("Stop") if is_running else tr("Send")


func _add_entry(text: String, color := Color.TRANSPARENT, is_live := false) -> void:
	var entry := Label.new()
	_entries.add_child(entry)
	entry.auto_translate_mode = AUTO_TRANSLATE_MODE_DISABLED
	entry.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if color.a > 0.0:
		entry.add_theme_color_override(&"font_color", color)
	if is_live:
		# A screen reader announces a live region when its text changes, not
		# necessarily when it appears.
		entry.accessibility_live = AccessibilityServer.LIVE_POLITE
		await get_tree().process_frame
		if !is_instance_valid(entry):
			return
	entry.text = text
	_scroll_to_end()


func _scroll_to_end() -> void:
	await get_tree().process_frame # the transcript's new size
	_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)


func _send_message() -> void:
	var text := _message_edit.text.strip_edges()
	if !text or _conversation.is_running():
		return
	_message_edit.clear()
	_conversation.send(text)


func _speak(text: String) -> void:
	if !ProjectSettings.get_setting("audio/general/text_to_speech", false):
		return
	var language := TranslationServer.get_locale().get_slice("_", 0)
	var voices := DisplayServer.tts_get_voices_for_language(language)
	if voices:
		DisplayServer.tts_speak(text, voices[0])


# Models write Markdown, which a Label and a screen reader show as typed.
func _to_plain_text(text: String) -> String:
	var lines := text.split("\n")
	for i in lines.size():
		var line := lines[i]
		var stripped := line.strip_edges(true, false)
		var indent := line.left(line.length() - stripped.length())
		if stripped.begins_with("#"):
			line = indent + stripped.lstrip("#").strip_edges(true, false)
		elif stripped.begins_with("- ") or stripped.begins_with("* "):
			line = indent + "• " + stripped.substr(2)
		lines[i] = line
	return "\n".join(lines).replace("**", "").replace("`", "")


func _format_tool_call(tool_name: String, arguments: Dictionary) -> String:
	var values: Array[String] = []
	for argument: String in arguments:
		var value: Variant = arguments[argument]
		var value_text: String = value if value is String else JSON.stringify(value)
		values.append(value_text.left(60))
	return "%s(%s)" % [tool_name, ", ".join(values)]


func _on_turn_started(text: String) -> void:
	_add_entry(text, user_color)
	_show_running(true)


func _on_reply_received(text: String) -> void:
	var plain_text := _to_plain_text(text)
	_add_entry(plain_text, Color.TRANSPARENT, true)
	if speak_replies:
		_speak(plain_text)


func _on_tool_called(tool_name: String, arguments: Dictionary) -> void:
	if show_tool_calls:
		_add_entry(_format_tool_call(tool_name, arguments), note_color)


func _on_turn_finished(error: String, unsent_text: String) -> void:
	_show_running(false)
	if error:
		_add_entry(error, error_color)
	if unsent_text and !_message_edit.text:
		_message_edit.text = unsent_text
		_message_edit.caret_column = unsent_text.length()


func _on_cleared() -> void:
	for entry in _entries.get_children():
		entry.queue_free()
	if speak_replies and DisplayServer.tts_is_speaking():
		DisplayServer.tts_stop()
	_show_connection()


func _on_text_submitted(_text: String) -> void:
	_send_message()


func _on_message_edit_gui_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		_message_edit.release_focus()
		_message_edit.accept_event()


func _on_send_pressed() -> void:
	if _conversation.is_running():
		_conversation.cancel()
		return
	_send_message()


func _on_new_pressed() -> void:
	_conversation.clear()


func _on_setup_pressed() -> void:
	_assistant.call(&"open_setup_wizard")
