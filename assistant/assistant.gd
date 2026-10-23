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
## (SPECIFICATION.md §11.1). Inert unless the project enables it in
## [code]ivoyager_assistant.cfg[/code] under [code][assistant][/code]. See
## SPECIFICATION.md §1 and §2, and CODING_PLAN.md Phase 5 for the parts still
## to come: connections to models, the conversation loop and the chat box.

const ERR_NOT_ALLOWED := 5

## The assistant's display name: [code]assistant_name[/code] in the config,
## else the project's name.
var assistant_name := ""

var _dispatcher: IVAssistantDispatcher # null while disabled


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


## Whether the project enables the assistant.
func is_enabled() -> bool:
	return _dispatcher != null


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
