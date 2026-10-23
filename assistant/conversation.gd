# conversation.gd
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
class_name IVAssistantConversation
extends RefCounted

## The user's conversation with the assistant, and the loop that carries it: the
## user's words go to the model, the tools it calls run, and their results go
## back, until the model answers.
##
## [code]IVAssistant.conversation[/code] is the user's, through their connection
## ([member IVAssistantConnections.connection]); [IVAssistantChatBox] shows it.
## [method send] starts a turn, whatever the user's words came from, and the
## signals report it: its start, each reply's text, each tool call, and its
## end. One turn runs at a time, on the main thread; [method cancel] ends it.
## The conversation starts over when the user's connection changes. See
## SPECIFICATION.md §12.5.

## Emitted when [method send] starts a turn with the user's [param text].
signal turn_started(text: String)
## Emitted with the text of each of the model's replies in a turn. A reply that
## calls tools may have text too, so a turn may emit several.
signal reply_received(text: String)
## Emitted as each tool the model calls is about to run.
signal tool_called(tool_name: String, arguments: Dictionary)
## Emitted when a turn ends. [param error] is "" if the model answered, else why
## the turn stopped, for the user to read. [param unsent_text] is the user's
## words if the model never answered them, which are then not in the
## conversation; else "".
signal turn_finished(error: String, unsent_text: String)
## Emitted when the conversation starts over: [method clear], or a change of the
## user's connection.
signal cleared()

## The assistant's display name.
var assistant_name := ""
## The providers and the user's connection.
var connections: IVAssistantConnections
## The most requests to the model in one turn. A turn that reaches it stops with
## an error, so that a model calling tools without end can't run up a bill.
var max_requests_per_turn := 20
## The conversation so far, in the provider's own form (see
## [IVAssistantConnection]). Read it; [method send] and [method clear] change it.
var messages: Array[Dictionary] = []

var _instructions: String
var _get_tool_set: Callable # IVAssistant.get_tool_set
var _connection: IVAssistantConnection # the conversation's, from its first turn
var _tool_set: IVAssistantToolSet
var _is_running := false
var _is_canceled := false
var _turn := 0 # a running turn that finds a later number here was cleared


## [param get_tool_set] is [code]IVAssistant.get_tool_set[/code].
func _init(user_connections: IVAssistantConnections, instructions: String,
		get_tool_set: Callable, display_name: String) -> void:
	connections = user_connections
	_instructions = instructions
	_get_tool_set = get_tool_set
	assistant_name = display_name
	connections.connection_changed.connect(clear)


## Whether a turn is running.
func is_running() -> bool:
	return _is_running


## Sends the user's [param text] to the model, then runs the tools it calls and
## sends their results, until it answers or the turn stops; a coroutine. Does
## nothing while a turn is running or with no connection. Call it once the
## simulator has started: the first turn builds the connection's tool set.
func send(text: String) -> void:
	var connection := connections.connection
	if _is_running or !connection or !text.strip_edges():
		return
	if connection != _connection:
		_start(connection)
	_is_running = true
	_is_canceled = false
	_turn += 1
	var turn := _turn
	var turn_start := messages.size()
	messages.append(connection.make_user_message(text))
	turn_started.emit(text)
	var definitions: Array[Dictionary] = []
	if _tool_set:
		definitions = _tool_set.definitions
	var error := ""
	var n_requests := 0
	while true:
		if n_requests == max_requests_per_turn:
			error = tr("Stopped after %s requests to the model without an answer.") % n_requests
			break
		n_requests += 1
		var reply := await connection.send(_instructions, definitions, messages)
		if turn != _turn:
			return # cleared
		if _is_canceled:
			error = tr("Stopped.")
			break
		if !reply:
			error = connection.error
			break
		messages.append(reply.message)
		var reply_text: String = reply.text
		reply_text = reply_text.strip_edges()
		if reply_text:
			reply_received.emit(reply_text)
		var tool_calls: Array[Dictionary] = reply.tool_calls
		if !tool_calls:
			var stop: String = reply.stop
			error = _get_stop_error(stop)
			break
		messages.append_array(connection.make_tool_results(_run_tools(tool_calls)))
	var unsent_text := ""
	if messages.size() == turn_start + 1: # some providers reject two user messages in a row
		messages.resize(turn_start)
		unsent_text = text
	_is_running = false
	turn_finished.emit(error, unsent_text)


## Ends the running turn, which finishes with error "Stopped.".
func cancel() -> void:
	if !_is_running:
		return
	_is_canceled = true
	_connection.cancel()


## Ends any running turn, without [signal turn_finished], and starts the
## conversation over.
func clear() -> void:
	_turn += 1
	if _is_running:
		_connection.cancel()
	_is_running = false
	messages.clear()
	_connection = null
	_tool_set = null
	cleared.emit()


func _start(connection: IVAssistantConnection) -> void:
	messages.clear()
	_connection = connection
	_tool_set = _get_tool_set.call(connection.tool_set_name)
	if !_tool_set:
		push_warning("IVAssistantConversation: the app has no tool set '%s'"
				% connection.tool_set_name)


func _run_tools(tool_calls: Array[Dictionary]) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	for tool_call in tool_calls:
		var tool_name: String = tool_call.name
		var arguments: Dictionary = tool_call.arguments
		var id: String = tool_call.id
		tool_called.emit(tool_name, arguments)
		var result: Variant
		if arguments.has("_unparsed"):
			result = {"_error": {"message": "The arguments aren't a JSON object: %s"
					% arguments._unparsed}}
		elif _tool_set:
			result = _tool_set.call_tool(tool_name, arguments)
		else:
			result = {"_error": {"message": "Unknown tool: %s (there are none)" % tool_name}}
		results.append(_make_result(id, result))
	return results


func _make_result(id: String, result: Variant) -> Dictionary:
	if result is Dictionary:
		var result_dict: Dictionary = result
		if result_dict.has("_error"):
			var error_dict: Dictionary = result_dict._error
			return {"id": id, "content": str(error_dict.get("message", "")), "is_error": true}
	var content := ""
	if result is String:
		content = result
	elif result == null:
		content = "Done."
	else:
		content = JSON.stringify(result)
	return {"id": id, "content": content, "is_error": false}


func _get_stop_error(stop: String) -> String:
	match stop:
		"length":
			return tr("The reply was cut off.")
		"refusal":
			return tr("The model declined to answer.")
	return ""
