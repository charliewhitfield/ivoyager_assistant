# dispatcher.gd
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
class_name IVAssistantDispatcher
extends RefCounted

## Answers one request by its method: [code]describe[/code], [code]get[/code],
## [code]call[/code] and the built-in tools.
##
## The TCP server answers its clients through one, and the user's assistant
## the model's tool calls through another, so both reach the app by the same
## path. The user's assistant's dispatcher answers on the user's surface alone:
## the members classes mark as the user's, widgets and input actions. Needs only
## Godot. See SPECIFICATION.md §2.1, §4 and §11.1.

const ERR_UNKNOWN_METHOD := 1

## The methods answered here; the built-in tools answer theirs.
const METHODS: Array[String] = ["describe", "get", "call"]

## Answers only on the user's surface, for the user's assistant. Set at construction.
var user_only := false
var automation: IVAssistantAutomation
var godot_tools: IVAssistantGodotTools
var widgets: IVAssistantWidgets


## Every method [method dispatch] answers, or with [param user] those a user's
## assistant may use.
static func get_methods(user := false) -> Array[String]:
	var methods: Array[String] = []
	methods.append_array(METHODS)
	methods.append_array(IVAssistantGodotTools.USER_METHODS if user
			else IVAssistantGodotTools.METHODS)
	methods.append_array(IVAssistantWidgets.USER_METHODS if user else IVAssistantWidgets.METHODS)
	return methods


func _init(tree: SceneTree, is_user_only := false) -> void:
	user_only = is_user_only
	automation = IVAssistantAutomation.new(tree, is_user_only)
	godot_tools = IVAssistantGodotTools.new(tree, automation)
	widgets = IVAssistantWidgets.new(tree, automation)


## Returns [param method]'s result, or a Dictionary
## [code]{"_error": {"code": ..., "message": ...}}[/code] (SPECIFICATION.md §3.3).
## Call [method release] once a request, or a batch of them, is answered.
func dispatch(method: String, params: Dictionary) -> Variant:
	if user_only and !get_methods(true).has(method):
		return {"_error": {"code": ERR_UNKNOWN_METHOD,
				"message": "Unknown method: %s (methods: %s)" % [method,
				", ".join(get_methods(true))]}}
	match method:
		"describe":
			return describe(params)
		"get":
			return automation.get_properties(params)
		"call":
			return automation.call_method(params)
	if IVAssistantGodotTools.METHODS.has(method):
		return godot_tools.dispatch(method, params)
	if IVAssistantWidgets.METHODS.has(method):
		return widgets.dispatch(method, params)
	return {"_error": {"code": ERR_UNKNOWN_METHOD,
			"message": "Unknown method: %s" % method}}


## [code]describe[/code]: a client's whole context, the declared objects plus
## the user surface (the widgets a user can see now, and the input actions)
## unless asked to leave them out. See SPECIFICATION.md §4.2.
func describe(params: Dictionary) -> Dictionary:
	var result := automation.describe(params)
	if params.get("widgets", true):
		var visible_widgets := widgets.list_widgets({"visible_only": true})
		result["widgets"] = visible_widgets.get("widgets", [])
	if params.get("actions", true):
		var actions := godot_tools.list_actions({})
		result["actions"] = actions.get("actions", {})
	return result


## Lets go of every object discovery found. An object held between requests
## would outlive a reset in between, such as the procedural objects a game load
## frees.
func release() -> void:
	automation.release()
