# setup_wizard.gd
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
class_name IVAssistantSetupWizard
extends PopupPanel

## Where the user connects the assistant to a model: one on their own computer,
## or a service with their own key.
##
## [code]IVAssistant.open_setup_wizard()[/code] makes and opens it. It finds the
## local servers the project offers and lists their models, or takes a key and
## lists a service's, and saves a connection only once a test tool call has
## confirmed it. It stays open while the user works elsewhere, as when getting a
## key. Its look is the project's theme, on an opaque black panel. The user's
## assistant can't see or operate it
## ([constant IVAssistantWidgets.PRIVATE_GROUP]). See SPECIFICATION.md §12.4.

const WARNING_COLOR := Color(1.0, 0.42, 0.42)

## The width of the text, in multiples of the theme's font size.
var width_in_font_sizes := 34.0
## The space between groups of related content, in multiples of the theme's
## font size.
var group_separation_in_font_sizes := 0.8

var _connections: IVAssistantConnections
var _test: Callable # IVAssistant.test_connection
var _assistant_name: String
var _tool_set_names: Array[String]
var _feedback_url: String
var _provider_ids: Array[String] = []
var _local_models: Dictionary[String, Array] = {} # by provider, for the servers found
var _listed_models: Array[String] = []
var _request_count := 0 # each request's result is current only if no later one started
var _probing := false
var _status_key := ""
var _status_values: Array[String] = []

var _content: VBoxContainer
var _row_labels: Array[Label] = []
var _heading: Label
var _intro: Label
var _notice: RichTextLabel
var _providers: OptionButton
var _note: Label
var _link: LinkButton
var _key_group: VBoxContainer
var _key_edit: LineEdit
var _show_key: Button
var _remember_key: CheckBox
var _key_note: Label
var _model_edit: LineEdit
var _models_button: MenuButton
var _tool_set_row: HBoxContainer
var _tool_sets: OptionButton
var _status: Label
var _connect_button: Button
var _remove_button: Button


## [param test] is [code]IVAssistant.test_connection[/code]. A
## [param feedback_url] is linked from the experimental notice.
func _init(connections: IVAssistantConnections, test: Callable, assistant_name: String,
		tool_set_names: Array[String], feedback_url := "") -> void:
	_connections = connections
	_test = test
	_assistant_name = assistant_name
	_tool_set_names = tool_set_names
	_feedback_url = feedback_url
	add_to_group(IVAssistantWidgets.PRIVATE_GROUP)
	process_mode = PROCESS_MODE_ALWAYS
	popup_window = false
	exclusive = false
	transient = true
	visible = false
	_build()


func _notification(what: int) -> void:
	# Composed text, which a control can't retranslate itself.
	if what != NOTIFICATION_TRANSLATION_CHANGED or !_content:
		return
	_show_intro()
	_update_provider_items()
	var provider := _connections.get_provider(_get_provider_id())
	if provider:
		_show_provider_text(provider)
	_show_status()


func _shortcut_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		hide()
		set_input_as_handled()


## Opens the wizard on the user's connection, or on the first provider.
func open() -> void:
	if visible:
		grab_focus()
		return
	var font_size := _content.get_theme_font_size(&"font_size", &"Label")
	var width := width_in_font_sizes * font_size
	_content.custom_minimum_size.x = width
	_content.add_theme_constant_override(&"separation",
			roundi(group_separation_in_font_sizes * font_size))
	for label in _row_labels:
		label.custom_minimum_size.x = 6.0 * font_size
	_provider_ids = _connections.get_provider_ids()
	var connection := _connections.connection
	var provider_id := connection.provider_id if connection else ""
	if !_provider_ids.has(provider_id):
		provider_id = _provider_ids[0] if _provider_ids else ""
	_update_provider_items()
	_providers.select(_provider_ids.find(provider_id))
	_show_provider(provider_id)
	_show_connection()
	_fit()
	popup_centered()
	_fit_when_laid_out.call_deferred()
	_find_local_servers()


func _build() -> void:
	# A theme's popup panel may be see-through, as the Planetarium's is.
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color.BLACK
	panel_style.set_content_margin_all(8.0)
	add_theme_stylebox_override(&"panel", panel_style)
	_content = VBoxContainer.new()
	add_child(_content)
	var intro_group := _add_group()
	_heading = Label.new()
	intro_group.add_child(_heading)
	_heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_intro = _add_text(intro_group)
	_notice = RichTextLabel.new()
	intro_group.add_child(_notice)
	_notice.auto_translate_mode = AUTO_TRANSLATE_MODE_DISABLED
	_notice.bbcode_enabled = true
	_notice.fit_content = true
	_notice.scroll_active = false
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice.add_theme_color_override(&"default_color", WARNING_COLOR)
	_notice.meta_clicked.connect(_on_notice_meta_clicked)
	_show_intro()
	var provider_group := _add_group()
	_providers = OptionButton.new()
	_add_row(provider_group, &"LABEL_ASSISTANT_MODEL_FROM", _providers)
	_providers.item_selected.connect(_on_provider_selected)
	_note = _add_text(provider_group)
	_link = LinkButton.new()
	provider_group.add_child(_link)
	_link.pressed.connect(_on_link_pressed)
	_key_group = _add_group()
	_key_edit = LineEdit.new()
	_key_edit.secret = true
	_key_edit.placeholder_text = &"LABEL_ASSISTANT_KEY_PLACEHOLDER"
	var key_row := _add_row(_key_group, &"LABEL_ASSISTANT_KEY", _key_edit)
	_key_edit.text_changed.connect(_on_key_changed)
	_key_edit.text_submitted.connect(_list_models.unbind(1))
	_key_edit.focus_exited.connect(_on_key_focus_exited)
	_show_key = Button.new()
	key_row.add_child(_show_key)
	_show_key.text = &"BUTTON_ASSISTANT_SHOW_KEY"
	_show_key.toggle_mode = true
	_show_key.toggled.connect(_on_show_key_toggled)
	_remember_key = CheckBox.new()
	_key_group.add_child(_remember_key)
	_remember_key.text = &"CKBX_ASSISTANT_REMEMBER_KEY"
	_remember_key.button_pressed = true
	_key_note = _add_text(_key_group)
	var model_group := _add_group()
	_model_edit = LineEdit.new()
	_model_edit.placeholder_text = &"LABEL_ASSISTANT_MODEL_PLACEHOLDER"
	var model_row := _add_row(model_group, &"LABEL_ASSISTANT_MODEL", _model_edit)
	_models_button = MenuButton.new()
	model_row.add_child(_models_button)
	_models_button.text = &"BUTTON_ASSISTANT_CHOOSE_MODEL"
	_models_button.flat = false
	_models_button.get_popup().index_pressed.connect(_on_model_chosen)
	_tool_sets = OptionButton.new()
	_tool_set_row = _add_row(model_group, &"LABEL_ASSISTANT_TOOLS", _tool_sets)
	for tool_set_name in _tool_set_names:
		_tool_sets.add_item(tool_set_name)
	_tool_set_row.visible = _tool_set_names.size() > 1
	_tool_set_row.tooltip_text = &"HINT_ASSISTANT_TOOLS"
	var status_group := _add_group()
	_status = _add_text(status_group)
	var buttons := HBoxContainer.new()
	status_group.add_child(buttons)
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 24)
	_connect_button = Button.new()
	buttons.add_child(_connect_button)
	_connect_button.text = &"BUTTON_ASSISTANT_TEST_AND_CONNECT"
	_connect_button.pressed.connect(_on_connect_pressed)
	_remove_button = Button.new()
	buttons.add_child(_remove_button)
	_remove_button.text = &"BUTTON_ASSISTANT_DISCONNECT"
	_remove_button.tooltip_text = &"HINT_ASSISTANT_DISCONNECT"
	_remove_button.pressed.connect(_on_remove_pressed)
	var close_button := Button.new()
	buttons.add_child(close_button)
	close_button.text = &"BUTTON_ASSISTANT_CLOSE"
	close_button.pressed.connect(hide)


func _add_group() -> VBoxContainer:
	var group := VBoxContainer.new()
	_content.add_child(group)
	return group


func _add_text(group: VBoxContainer) -> Label:
	var label := Label.new()
	group.add_child(label)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func _add_row(group: VBoxContainer, text_key: StringName, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	group.add_child(row)
	var label := Label.new()
	row.add_child(label)
	label.text = text_key
	_row_labels.append(label)
	row.add_child(control)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return row


func _tr_value(provider: Dictionary, key: String) -> String:
	var text: String = provider[key]
	return tr(text)


func _show_intro() -> void:
	_heading.text = tr(&"TXT_ASSISTANT_SETUP_TITLE_CONSTRUCTOR") % _assistant_name
	_intro.text = tr(&"TXT_ASSISTANT_SETUP_INTRO_CONSTRUCTOR") % _assistant_name
	var notice_text := tr(&"TXT_ASSISTANT_EXPERIMENTAL")
	if _feedback_url:
		notice_text += " " + tr(&"TXT_ASSISTANT_FEEDBACK_CONSTRUCTOR") % _feedback_url
	_notice.text = notice_text


# The status is kept as a text key and values, to translate again when the
# language changes. Values translate too, since a provider's name may be a key.
func _set_status(text_key: String, values: Array[String] = []) -> void:
	_status_key = text_key
	_status_values = values
	_show_status()


func _show_status() -> void:
	var text := tr(_status_key)
	if _status_values:
		var translated_values: Array[String] = []
		for value in _status_values:
			translated_values.append(tr(value))
		text = text % translated_values
	_status.text = text


# A popup grows to fit its content but never shrinks back on its own.
func _fit() -> void:
	size = Vector2i.ZERO


# Wrapped text measures its height at the width it last had, which is none
# until the popup first lays it out, so a first fit is a word per line.
func _fit_when_laid_out() -> void:
	_fit()
	move_to_center()


func _get_provider_id() -> String:
	var index := _providers.selected
	return _provider_ids[index] if index >= 0 and index < _provider_ids.size() else ""


func _update_provider_items() -> void:
	var selected := _providers.selected
	_providers.clear()
	for provider_id in _provider_ids:
		var provider := _connections.get_provider(provider_id)
		var item_text: String = _tr_value(provider, "name")
		if provider["local"]:
			item_text = tr(&"TXT_ASSISTANT_LOCAL_PROVIDER_CONSTRUCTOR") % item_text
			if _local_models.has(provider_id):
				item_text += " ✓"
		_providers.add_item(item_text)
	if selected >= 0 and selected < _provider_ids.size():
		_providers.select(selected)


func _show_provider(provider_id: String) -> void:
	_request_count += 1
	_listed_models.clear()
	var provider := _connections.get_provider(provider_id)
	if !provider:
		return
	var connection := _connections.connection
	var is_saved := connection and connection.provider_id == provider_id
	_show_provider_text(provider)
	var needs_key: bool = provider["needs_key"]
	_key_group.visible = needs_key
	var remembered_key := _connections.get_remembered_key(provider_id)
	_key_edit.text = remembered_key
	if is_saved and connection.api_key:
		_key_edit.text = connection.api_key
	_remember_key.button_pressed = remembered_key != "" or !is_saved
	_model_edit.text = connection.model if is_saved else provider["model"]
	var tool_set_name := (connection.tool_set_name if is_saved
			else _connections.get_default_tool_set(provider_id))
	_tool_sets.select(_tool_set_names.find(tool_set_name))
	_set_model_menu([])
	if provider["local"]:
		if _local_models.has(provider_id):
			var models: Array[String] = []
			models.assign(_local_models[provider_id])
			_set_model_menu(models)
			if !_model_edit.text and models:
				_model_edit.text = models[0]
		elif OS.has_feature("web"):
			_find_local_servers([provider_id])
	elif _key_edit.text:
		_list_models()


func _show_provider_text(provider: Dictionary) -> void:
	var provider_name: String = _tr_value(provider, "name")
	var note: String = _tr_value(provider, "note")
	if OS.has_feature("web") and provider["web_note"]:
		note += " " + _tr_value(provider, "web_note")
	_note.text = note.strip_edges()
	_note.visible = _note.text != ""
	var needs_key: bool = provider["needs_key"]
	if needs_key and provider["key_url"]:
		_link.text = tr(&"TXT_ASSISTANT_GET_KEY_CONSTRUCTOR") % provider_name
		_link.uri = provider["key_url"]
	else:
		_link.text = tr(&"TXT_ASSISTANT_ABOUT_PROVIDER_CONSTRUCTOR") % provider_name
		_link.uri = provider["site"]
	_link.visible = _link.uri != ""
	var key_note_key := &"TXT_ASSISTANT_KEY_STORED_CONSTRUCTOR"
	if OS.has_feature("web"):
		key_note_key = &"TXT_ASSISTANT_KEY_STORED_WEB_CONSTRUCTOR"
	_key_note.text = tr(key_note_key) % provider_name


func _show_connection() -> void:
	var connection := _connections.connection
	_remove_button.disabled = connection == null
	if !connection:
		_set_status("TXT_ASSISTANT_NOT_CONNECTED")
		return
	_set_status("TXT_ASSISTANT_CONNECTED_TO_CONSTRUCTOR", [connection.model,
			connection.provider_name])


func _set_model_menu(models: Array[String]) -> void:
	_listed_models = models
	var menu := _models_button.get_popup()
	menu.clear()
	for model in models:
		menu.add_item(model)
	_models_button.disabled = models.is_empty()


func _find_local_servers(provider_ids: Array[String] = []) -> void:
	if _probing:
		return
	_probing = true
	var found := await _connections.find_local_servers(provider_ids)
	_probing = false
	_local_models.merge(found, true)
	_update_provider_items()
	var provider_id := _get_provider_id()
	var provider := _connections.get_provider(provider_id)
	if !provider or !provider["local"]:
		return
	var provider_name: String = provider["name"]
	if !_local_models.has(provider_id):
		if provider_ids.has(provider_id) or !OS.has_feature("web"):
			_set_status("TXT_ASSISTANT_SERVER_NOT_FOUND_CONSTRUCTOR", [provider_name])
		return
	var models: Array[String] = []
	models.assign(_local_models[provider_id])
	_set_model_menu(models)
	if !_model_edit.text and models:
		_model_edit.text = models[0]
	if !models:
		_set_status("TXT_ASSISTANT_SERVER_NO_MODELS_CONSTRUCTOR", [provider_name])


func _list_models() -> void:
	var provider_id := _get_provider_id()
	if !provider_id or !_key_edit.text or _listed_models:
		return
	_request_count += 1
	var request := _request_count
	var connection := _connections.make_connection(provider_id, "", _key_edit.text.strip_edges())
	var models := await connection.list_models()
	if request != _request_count:
		return
	if connection.error:
		_set_status("TXT_ASSISTANT_CANT_LIST_MODELS_CONSTRUCTOR", [connection.error])
		return
	_set_model_menu(models)
	if models and !models.has(_model_edit.text):
		_model_edit.text = models[0]
	_show_connection()


func _on_provider_selected(_index: int) -> void:
	_show_provider(_get_provider_id())
	_show_connection()
	_fit()


func _on_link_pressed() -> void:
	OS.shell_open(_link.uri)


func _on_notice_meta_clicked(meta: Variant) -> void:
	OS.shell_open(str(meta))


func _on_key_changed(_text: String) -> void:
	_request_count += 1
	_set_model_menu([])


func _on_key_focus_exited() -> void:
	_list_models()


func _on_show_key_toggled(is_shown: bool) -> void:
	_key_edit.secret = !is_shown
	_show_key.text = &"BUTTON_ASSISTANT_HIDE_KEY" if is_shown else &"BUTTON_ASSISTANT_SHOW_KEY"


func _on_model_chosen(index: int) -> void:
	_model_edit.text = _listed_models[index]


func _on_connect_pressed() -> void:
	var provider_id := _get_provider_id()
	var model := _model_edit.text.strip_edges()
	if !provider_id or !model:
		_set_status("TXT_ASSISTANT_NEEDS_MODEL")
		return
	var key := _key_edit.text.strip_edges()
	if _key_group.visible and !key:
		_set_status("TXT_ASSISTANT_NEEDS_KEY")
		return
	var tool_set_name := ""
	if _tool_sets.selected >= 0:
		tool_set_name = _tool_sets.get_item_text(_tool_sets.selected)
	var connection := _connections.make_connection(provider_id, model, key, tool_set_name)
	_request_count += 1
	var request := _request_count
	_connect_button.disabled = true
	_set_status("TXT_ASSISTANT_TESTING_CONSTRUCTOR", [model])
	_fit()
	var result: Dictionary = await _test.call(connection)
	_connect_button.disabled = false
	if request != _request_count:
		return
	var message: String = result.message
	if result.ok:
		_connections.save_connection(connection, _remember_key.button_pressed)
		_remove_button.disabled = false
	_set_status(message)
	_fit()


func _on_remove_pressed() -> void:
	_connections.remove_connection()
	_key_edit.text = ""
	_show_connection()
