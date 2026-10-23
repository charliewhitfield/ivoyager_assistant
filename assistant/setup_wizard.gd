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

## The width of the text, in multiples of the theme's font size.
var width_in_font_sizes := 34.0

var _connections: IVAssistantConnections
var _test: Callable # IVAssistant.test_connection
var _assistant_name: String
var _tool_set_names: Array[String]
var _provider_ids: Array[String] = []
var _local_models: Dictionary[String, Array] = {} # by provider, for the servers found
var _listed_models: Array[String] = []
var _request_count := 0 # each request's result is current only if no later one started
var _probing := false

var _content: VBoxContainer
var _row_labels: Array[Label] = []
var _intro: Label
var _providers: OptionButton
var _note: Label
var _link: LinkButton
var _key_row: HBoxContainer
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


## [param test] is [code]IVAssistant.test_connection[/code].
func _init(connections: IVAssistantConnections, test: Callable, assistant_name: String,
		tool_set_names: Array[String]) -> void:
	_connections = connections
	_test = test
	_assistant_name = assistant_name
	_tool_set_names = tool_set_names
	add_to_group(IVAssistantWidgets.PRIVATE_GROUP)
	process_mode = PROCESS_MODE_ALWAYS
	popup_window = false
	exclusive = false
	transient = true
	visible = false
	_build()


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
	_content.custom_minimum_size.x = width_in_font_sizes * font_size
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
	_find_local_servers()


func _build() -> void:
	# A theme's popup panel may be see-through, as the Planetarium's is.
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color.BLACK
	panel_style.set_content_margin_all(8.0)
	add_theme_stylebox_override(&"panel", panel_style)
	_content = VBoxContainer.new()
	add_child(_content)
	var heading := Label.new()
	_content.add_child(heading)
	heading.text = tr("Set up %s") % _assistant_name
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_intro = _add_text()
	_intro.text = tr("%s is an AI guide. Ask it about what you see, or to take you somewhere,"
			+ " and it operates the app for you. It runs on an AI model you choose: one on this"
			+ " computer, free if your computer can run one, or an online service with your own"
			+ " key, which charges for what you use or has a free tier.") % _assistant_name
	_providers = OptionButton.new()
	_add_row(tr("Model from"), _providers)
	_providers.item_selected.connect(_on_provider_selected)
	_note = _add_text()
	_link = LinkButton.new()
	_content.add_child(_link)
	_link.pressed.connect(_on_link_pressed)
	_key_edit = LineEdit.new()
	_key_edit.secret = true
	_key_edit.placeholder_text = tr("Paste your key")
	_key_row = _add_row(tr("Key"), _key_edit)
	_key_edit.text_changed.connect(_on_key_changed)
	_key_edit.text_submitted.connect(_list_models.unbind(1))
	_key_edit.focus_exited.connect(_on_key_focus_exited)
	_show_key = Button.new()
	_key_row.add_child(_show_key)
	_show_key.text = tr("Show")
	_show_key.toggle_mode = true
	_show_key.toggled.connect(_on_show_key_toggled)
	_remember_key = CheckBox.new()
	_content.add_child(_remember_key)
	_remember_key.text = tr("Remember the key on this device")
	_remember_key.button_pressed = true
	_key_note = _add_text()
	_model_edit = LineEdit.new()
	var model_row := _add_row(tr("Model"), _model_edit)
	_models_button = MenuButton.new()
	model_row.add_child(_models_button)
	_models_button.text = tr("Choose")
	_models_button.flat = false
	_models_button.get_popup().index_pressed.connect(_on_model_chosen)
	_tool_sets = OptionButton.new()
	_tool_set_row = _add_row(tr("Tools"), _tool_sets)
	for tool_set_name in _tool_set_names:
		_tool_sets.add_item(tool_set_name)
	_tool_set_row.visible = _tool_set_names.size() > 1
	_tool_set_row.tooltip_text = tr("The tools the model is given. A small model does best"
			+ " with a short list; a large one can use more.")
	_status = _add_text()
	var buttons := HBoxContainer.new()
	_content.add_child(buttons)
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 24)
	_connect_button = Button.new()
	buttons.add_child(_connect_button)
	_connect_button.text = tr("Test and connect")
	_connect_button.pressed.connect(_on_connect_pressed)
	_remove_button = Button.new()
	buttons.add_child(_remove_button)
	_remove_button.text = tr("Disconnect")
	_remove_button.tooltip_text = tr("Remove the connection and forget every key")
	_remove_button.pressed.connect(_on_remove_pressed)
	var close_button := Button.new()
	buttons.add_child(close_button)
	close_button.text = tr("Close")
	close_button.pressed.connect(hide)


func _add_text() -> Label:
	var label := Label.new()
	_content.add_child(label)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func _add_row(label_text: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	_content.add_child(row)
	var label := Label.new()
	row.add_child(label)
	label.text = label_text
	_row_labels.append(label)
	row.add_child(control)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return row


func _tr_value(provider: Dictionary, key: String) -> String:
	var text: String = provider[key]
	return tr(text)


# A popup grows to fit its content but never shrinks back on its own.
func _fit() -> void:
	size = Vector2i.ZERO


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
			item_text = tr("%s, on this computer") % item_text
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
	var provider_name: String = _tr_value(provider, "name")
	var note: String = _tr_value(provider, "note")
	if OS.has_feature("web") and provider["web_note"]:
		note += " " + _tr_value(provider, "web_note")
	_note.text = note.strip_edges()
	_note.visible = _note.text != ""
	var needs_key: bool = provider["needs_key"]
	if needs_key and provider["key_url"]:
		_link.text = tr("Get a key from %s") % provider_name
		_link.uri = provider["key_url"]
	else:
		_link.text = tr("About %s") % provider_name
		_link.uri = provider["site"]
	_link.visible = _link.uri != ""
	_key_row.visible = needs_key
	_remember_key.visible = needs_key
	_key_note.visible = needs_key
	var remembered_key := _connections.get_remembered_key(provider_id)
	_key_edit.text = remembered_key
	if is_saved and connection.api_key:
		_key_edit.text = connection.api_key
	_remember_key.button_pressed = remembered_key != "" or !is_saved
	if OS.has_feature("web"):
		_key_note.text = tr("Your key is stored only in this browser, for this site, and sent"
				+ " only to %s.") % provider_name
	else:
		_key_note.text = tr("Your key is stored only on this device, in this app's data, and"
				+ " sent only to %s.") % provider_name
	_model_edit.text = connection.model if is_saved else provider["model"]
	_model_edit.placeholder_text = tr("A model's id")
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


func _show_connection() -> void:
	var connection := _connections.connection
	_remove_button.disabled = connection == null
	if !connection:
		_status.text = tr("Not connected.")
		return
	_status.text = tr("Connected to %s, from %s.") % [connection.model,
			tr(connection.provider_name)]


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
	if !_local_models.has(provider_id):
		if provider_ids.has(provider_id) or !OS.has_feature("web"):
			_status.text = (tr("%s isn't running on this computer, or can't be reached.")
					% _tr_value(provider, "name"))
		return
	var models: Array[String] = []
	models.assign(_local_models[provider_id])
	_set_model_menu(models)
	if !_model_edit.text and models:
		_model_edit.text = models[0]
	if !models:
		_status.text = tr("%s is running but has no models. Download one that takes tools.") % (
				_tr_value(provider, "name"))


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
		_status.text = tr("Can't list the models: %s") % connection.error
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


func _on_key_changed(_text: String) -> void:
	_request_count += 1
	_set_model_menu([])


func _on_key_focus_exited() -> void:
	_list_models()


func _on_show_key_toggled(is_shown: bool) -> void:
	_key_edit.secret = !is_shown
	_show_key.text = tr("Hide") if is_shown else tr("Show")


func _on_model_chosen(index: int) -> void:
	_model_edit.text = _listed_models[index]


func _on_connect_pressed() -> void:
	var provider_id := _get_provider_id()
	var model := _model_edit.text.strip_edges()
	if !provider_id or !model:
		_status.text = tr("Choose a model.")
		return
	var key := _key_edit.text.strip_edges()
	if _key_row.visible and !key:
		_status.text = tr("Paste your key.")
		return
	var tool_set_name := ""
	if _tool_sets.selected >= 0:
		tool_set_name = _tool_sets.get_item_text(_tool_sets.selected)
	var connection := _connections.make_connection(provider_id, model, key, tool_set_name)
	_request_count += 1
	var request := _request_count
	_connect_button.disabled = true
	_status.text = tr("Asking %s to call a tool...") % model
	_fit()
	var result: Dictionary = await _test.call(connection)
	_connect_button.disabled = false
	if request != _request_count:
		return
	var message: String = result.message
	if result.ok:
		_connections.save_connection(connection, _remember_key.button_pressed)
		_remove_button.disabled = false
	_status.text = message
	_fit()


func _on_remove_pressed() -> void:
	_connections.remove_connection()
	_key_edit.text = ""
	_show_connection()
