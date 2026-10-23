# assistant.gd
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
extends Node

## Singleton [IVAssistant] is the user's assistant: an AI of the user's choosing
## that operates the app for them.
##
## It reaches the app in process, through the same declarations and dispatch a
## test client's requests use ([IVAssistantDispatcher]), so it runs in any
## build, release and web included. It sees only the user's surface: the
## members classes mark as the user's, widgets and input actions
## (SPECIFICATION.md §11.1). A model is given [member instructions] and a tool
## set ([method get_tool_set]), which the project names, through the user's
## connection ([member connections]), which the setup wizard makes. Inert
## unless the project enables it in [code]ivoyager_assistant.cfg[/code] under
## [code][assistant][/code]. See SPECIFICATION.md §12, and CODING_PLAN.md
## Phase 5 for the parts still to come: the conversation loop and the chat box.

const ERR_NOT_ALLOWED := 5
## The tool a connection test asks the model to call, beside its tool set's.
const TEST_TOOL := {
	"name": "confirm_connection",
	"description": "Confirms that the app can reach you. Call it when the app asks.",
	"parameters": {"type": "object", "properties": {
		"greeting": {"type": "string",
				"description": "One short sentence greeting the person you will help."},
	}, "required": ["greeting"]},
}
const TEST_REQUEST := ("This is a test of your connection to the app, sent by the app itself."
		+ " Call the tool confirm_connection with a short greeting for the person you will"
		+ " be helping. Call no other tool.")

## The assistant's display name: [code]assistant_name[/code] in the config,
## else the project's name.
var assistant_name := ""
## The model's instructions, the assistant's personality: the project's
## [code]instructions_file[/code], with [code]{assistant_name}[/code] filled in.
var instructions := ""
## The providers the project offers and the user's connection; null while
## disabled.
var connections: IVAssistantConnections

var _dispatcher: IVAssistantDispatcher # null while disabled
var _tool_set_entries: Dictionary[String, Array] = {}
var _setup_wizard: IVAssistantSetupWizard


func _ready() -> void:
	var config := IVAssistantPluginUtils.get_ivoyager_config(
			"res://addons/ivoyager_assistant/ivoyager_assistant.cfg")
	var configured_name: String = config.get_value("assistant", "assistant_name", "")
	var project_name: String = ProjectSettings.get_setting("application/config/name", "")
	assistant_name = configured_name if configured_name else project_name
	var enabled: bool = config.get_value("assistant", "enabled", false)
	if !enabled:
		return
	_dispatcher = IVAssistantDispatcher.new(get_tree(), true)
	var instructions_file: String = config.get_value("assistant", "instructions_file", "")
	if instructions_file:
		var text := FileAccess.get_file_as_string(instructions_file)
		if !text:
			push_error("IVAssistant: can't read instructions_file '%s'" % instructions_file)
		instructions = text.format({"assistant_name": assistant_name})
	if config.has_section("assistant_tool_sets"):
		for tool_set_name in config.get_section_keys("assistant_tool_sets"):
			var entries: Array = config.get_value("assistant_tool_sets", tool_set_name)
			_tool_set_entries[tool_set_name] = entries
	connections = IVAssistantConnections.new(config)


## Whether the project enables the assistant.
func is_enabled() -> bool:
	return _dispatcher != null


## The names of the tool sets the project offers, under
## [code][assistant_tool_sets][/code] in the config.
func get_tool_set_names() -> Array[String]:
	var names: Array[String] = []
	names.assign(_tool_set_entries.keys())
	return names


## Returns tool set [param tool_set_name] built from what exists now, or null
## if the project offers no such set or the assistant isn't enabled. Build it
## once the simulator has started; an entry the app lacks is left out and
## listed in [member IVAssistantToolSet.omitted].
func get_tool_set(tool_set_name: String) -> IVAssistantToolSet:
	if !_dispatcher or !_tool_set_entries.has(tool_set_name):
		return null
	var tool_set := IVAssistantToolSet.new(tool_set_name, _tool_set_entries[tool_set_name],
			_dispatcher.automation, request)
	_dispatcher.release()
	return tool_set


## Whether the user may choose their connection: the assistant is enabled and
## the project presets none.
func has_setup_wizard() -> bool:
	return _dispatcher != null and !connections.preset_provider


## Opens the setup wizard, where the user connects a model, if
## [method has_setup_wizard].
func open_setup_wizard() -> void:
	if !has_setup_wizard():
		return
	if !_setup_wizard:
		_setup_wizard = IVAssistantSetupWizard.new(connections, test_connection, assistant_name,
				get_tool_set_names())
		get_tree().root.add_child(_setup_wizard)
	_setup_wizard.open()


## Confirms [param connection] with one request: the model is given the
## instructions and its tool set, and asked to call [constant TEST_TOOL].
## Returns [code]{"ok": bool, "message": String}[/code], the message for the
## user. Build tool sets only once the simulator has started.
func test_connection(connection: IVAssistantConnection) -> Dictionary:
	var tool_set := get_tool_set(connection.tool_set_name)
	if !tool_set:
		return {"ok": false, "message": "The app has no tool set '%s'" % connection.tool_set_name}
	var definitions := tool_set.definitions.duplicate()
	definitions.append(TEST_TOOL)
	var messages: Array[Dictionary] = [connection.make_user_message(TEST_REQUEST)]
	var reply := await connection.send(instructions, definitions, messages)
	if !reply:
		return {"ok": false, "message": connection.error}
	var tool_calls: Array[Dictionary] = reply.tool_calls
	for tool_call in tool_calls:
		if tool_call.name != TEST_TOOL.name:
			continue
		var arguments: Dictionary = tool_call.arguments
		var greeting := str(arguments.get("greeting", "")).strip_edges()
		if !greeting:
			return {"ok": true, "message": "Connected: the model called the test tool."}
		return {"ok": true, "message": "Connected. %s says: \"%s\"" % [assistant_name, greeting]}
	if tool_calls:
		var tool_name: String = tool_calls[0].name
		return {"ok": true, "message": ("Connected, but the model called %s, not the test tool."
				+ " It may follow instructions poorly.") % tool_name}
	var text: String = reply.text
	match reply.stop:
		"refusal":
			return {"ok": false, "message": "The model declined the test."}
		"length":
			return {"ok": false, "message": "The model's reply was cut off before it called a tool."}
	return {"ok": false, "message": ("The model answered without calling a tool, so it may not"
			+ " take tools. It said: \"%s\"") % text.strip_edges().left(300)}


## Answers [param method] in process, as the TCP server answers a client's
## request but on the user's surface alone: [code]describe[/code],
## [code]get[/code], [code]call[/code], the widgets or the input actions, with
## [param params] as JSON would give them (SPECIFICATION.md §4). Returns the
## result, or a Dictionary
## [code]{"_error": {"code": ..., "message": ...}}[/code] (§3.3). Call it on
## the main thread.
func request(method: String, params := {}) -> Variant:
	if !_dispatcher:
		return {"_error": {"code": ERR_NOT_ALLOWED, "message": "The assistant is not enabled"}}
	var result: Variant = _dispatcher.dispatch(method, params)
	_dispatcher.release()
	return result
