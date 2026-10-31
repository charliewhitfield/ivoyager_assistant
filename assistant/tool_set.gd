# tool_set.gd
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
class_name IVAssistantToolSet
extends RefCounted

## The tools a model is offered: their definitions, and their calls.
##
## A project names its sets in [code]ivoyager_assistant.cfg[/code] under
## [code][assistant_tool_sets][/code]. Each entry is a method the user's
## assistant answers ([code]"call"[/code], [code]"operate_widget"[/code], ...),
## or [code]"<object>.<method>"[/code], a user method of the object at that
## address ([code]"SelectionManager.select_by_name"[/code]), which becomes a
## tool with its own arguments. See SPECIFICATION.md §12.2.[br][br]
##
## Get one from [code]IVAssistant.get_tool_set()[/code]. Its definitions are
## generated from what exists when it is built, so build it once the simulator
## has started.

const ERR_UNKNOWN_METHOD := 1

const ADDRESS_SCHEMA := {
	"anyOf": [{"type": "string"}, {"type": "object"}],
	"description": "An object's name from describe (\"Timekeeper\"), or {\"class\": ..., <key>: ...}"
			+ " for one of several ({\"class\": \"IVBody\", \"name\": \"PLANET_MARS\"}). Add"
			+ " \"via\": a property, to reach the object it holds.",
}

## The tools for the methods the user's assistant answers, by method.
const METHOD_TOOLS := {
	"describe": {
		"description": "Lists what you can read and operate in the app: each object with its"
				+ " methods and properties (arguments, types and descriptions), the enums they"
				+ " use, what is unavailable now, the widgets the user can see and the keyboard"
				+ " actions. Call it before your first get or call.",
		"parameters": {"type": "object", "properties": {
			"widgets": {"type": "boolean", "default": true,
					"description": "Include the widgets the user can see now."},
			"instances": {"type": "boolean", "default": true,
					"description": "List each instance of a class with several, such as each body."},
			"full": {"type": "boolean", "default": false,
					"description": "Full class descriptions, not just their first paragraphs."},
		}},
	},
	"get": {
		"description": "Reads properties of one object, as describe lists them.",
		"parameters": {"type": "object", "properties": {
			"object": ADDRESS_SCHEMA,
			"properties": {"anyOf": [{"type": "string"}, {"type": "array",
					"items": {"type": "string"}}],
					"description": "A property or a list of them; all of them if omitted."},
		}, "required": ["object"]},
	},
	"call": {
		"description": "Calls a method of one object, as describe lists it, and returns its"
				+ " result.",
		"parameters": {"type": "object", "properties": {
			"object": ADDRESS_SCHEMA,
			"method": {"type": "string"},
			"args": {"type": "object", "description": "Arguments by name. One with a default"
					+ " may be omitted."},
		}, "required": ["object", "method"]},
	},
	"list_widgets": {
		"description": "Lists the controls of the user's interface with each one's address,"
				+ " name and state. A hidden one names the control that shows it (opened_by).",
		"parameters": {"type": "object", "properties": {
			"visible_only": {"type": "boolean", "default": false,
					"description": "Only the controls the user can see now."},
		}},
	},
	"operate_widget": {
		"description": "Operates one control as the user would, and returns its state after."
				+ " A button is pressed; give pressed for a toggle, value for a range or a"
				+ " composite, tab, folded, item or text for the others.",
		"parameters": {"type": "object", "properties": {
			"widget": {"anyOf": [{"type": "string"}, {"type": "object"}],
					"description": "A widget's address from list_widgets."},
			"pressed": {"type": "boolean"},
			"value": {},
			"tab": {"anyOf": [{"type": "integer"}, {"type": "string"}]},
			"folded": {"type": "boolean"},
			"item": {"anyOf": [{"type": "integer"}, {"type": "string"}]},
			"text": {"type": "string"},
			"submit": {"type": "boolean"},
		}, "required": ["widget"]},
	},
	"list_actions": {
		"description": "Lists the keyboard actions with their keys.",
		"parameters": {"type": "object", "properties": {}},
	},
	"press_action": {
		"description": "Presses the key of one keyboard action, as the user would.",
		"parameters": {"type": "object", "properties": {
			"action": {"type": "string", "description": "An action from list_actions."},
		}, "required": ["action"]},
	},
}

## The set's name in the config.
var name := ""
## Each tool's definition as a model's API takes one: [code]{"name": ...,
## "description": ..., "parameters": <JSON Schema>}[/code].
var definitions: Array[Dictionary] = []
## The set's entries that the app lacks now, each with why.
var omitted: Dictionary[String, String] = {}

var _request: Callable
var _calls: Dictionary[String, Array] = {} # tool name -> [method, object address, member]


## [param request] answers as [code]IVAssistant.request()[/code] does.
func _init(set_name: String, entries: Array, automation: IVAssistantAutomation,
		request: Callable) -> void:
	name = set_name
	_request = request
	var member_names: Dictionary[String, int] = {} # tool names shared by two entries
	for entry: Variant in entries:
		var method := str(entry).get_slice(".", 1)
		member_names[method] = member_names.get(method, 0) + 1
	for entry: Variant in entries:
		var entry_text := str(entry)
		if !entry_text.contains("."):
			_add_method_tool(entry_text)
			continue
		var object_name := entry_text.get_slice(".", 0)
		var method := entry_text.get_slice(".", 1)
		var tool_name := method
		if member_names[method] > 1:
			tool_name = "%s_%s" % [object_name, method]
		_add_member_tool(tool_name, object_name, StringName(method), automation)


## Runs tool [param tool_name] with [param arguments], the model's JSON object.
## Returns the result, or [code]{"_error": {"code": ..., "message": ...}}[/code]
## for the model to read as the tool's error (SPECIFICATION.md §3.3).
func call_tool(tool_name: String, arguments: Dictionary) -> Variant:
	if !_calls.has(tool_name):
		return {"_error": {"code": ERR_UNKNOWN_METHOD, "message": "Unknown tool: %s (tools: %s)"
				% [tool_name, ", ".join(_calls.keys())]}}
	var target := _calls[tool_name]
	var method: String = target[0]
	var object_name: String = target[1]
	if !object_name:
		return _request.call(method, arguments)
	return _request.call(method, {"object": object_name, "method": target[2], "args": arguments})


func _add_method_tool(method: String) -> void:
	if !IVAssistantDispatcher.get_methods(true).has(method) or !METHOD_TOOLS.has(method):
		omitted[method] = "not a method the user's assistant answers"
		return
	var method_tool: Dictionary = METHOD_TOOLS[method]
	var definition := method_tool.duplicate(true)
	definition["name"] = method
	definitions.append(definition)
	_calls[method] = [method, "", ""]


func _add_member_tool(tool_name: String, object_name: String, method: StringName,
		automation: IVAssistantAutomation) -> void:
	var entry := "%s.%s" % [object_name, method]
	var object := automation.resolve(object_name)
	if !object:
		omitted[entry] = automation.error
		return
	var declaration := automation.get_declaration_of(object)
	if !declaration.user_methods.has(method):
		omitted[entry] = "%s declares no user method '%s'" % [declaration.class_name_, method]
		return
	var info: Dictionary = declaration.method_infos.get(method, {})
	var properties := {}
	var required: Array[String] = []
	var arg_infos: Array = info.get("args", [])
	var defaults: Array = info.get("default_args", [])
	var n_required := arg_infos.size() - defaults.size()
	for i in arg_infos.size():
		var arg_info: Dictionary = arg_infos[i]
		var arg_name: String = arg_info.name
		var schema := automation.converter.get_json_schema(arg_info, declaration.enums)
		if i < n_required:
			required.append(arg_name)
		else:
			var default: Variant = defaults[i - n_required]
			if default != null:
				schema["default"] = automation.converter.to_json(default, arg_info)
		properties[arg_name] = schema
	var parameters := {"type": "object", "properties": properties}
	if required:
		parameters["required"] = required
	var description := automation.docs.get_member_doc(declaration.source_script, method)
	definitions.append({"name": tool_name, "description": description, "parameters": parameters})
	_calls[tool_name] = ["call", object_name, String(method)]
