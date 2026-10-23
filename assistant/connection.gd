# connection.gd
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
class_name IVAssistantConnection
extends RefCounted

## A connection to one model: a provider's endpoint, the model, the user's key
## and the tool set the model is given.
##
## Each subclass speaks one provider API: [IVAssistantOpenAIConnection] the
## OpenAI-compatible chat completions that most services and local servers
## offer, [IVAssistantAnthropicConnection] Anthropic's Messages API. A project
## adds its own by subclassing this, named by its script path in a provider's
## [code]adapter[/code]. Get one from
## [method IVAssistantConnections.make_connection]. See SPECIFICATION.md §12.4.[br][br]
##
## A conversation is an array of messages in the provider's own form, so that
## what a model returns goes back to it unchanged: start it with
## [method make_user_message], append each reply's [code]message[/code] and the
## messages of [method make_tool_results], and pass the array to [method send].[br][br]
##
## [method send] and [method list_models] are coroutines: await them. One runs at
## a time; a new one, or [method cancel], ends the one running. Call them on the
## main thread.

signal _http_completed(result: int, code: int, body: PackedByteArray)

## Why the last request failed, for the user to read, or "" if it didn't.
var error := ""
## The provider's id in the config ([code]"anthropic"[/code]).
var provider_id := ""
## The provider's display name.
var provider_name := ""
## The provider's API base, without a trailing slash
## ([code]"https://api.anthropic.com/v1"[/code]).
var url := ""
## The model's id, as the provider names it.
var model := ""
## The user's key, or "" for a server that needs none.
var api_key := ""
## The project's tool set the model is given (SPECIFICATION.md §12.2).
var tool_set_name := ""
## Whether the server runs on the user's own computer.
var is_local := false
## Whether the provider takes only part of JSON Schema in tool parameters;
## [method adapt_parameters] then simplifies them.
var simple_schemas := false
## Seconds a chat request may take.
var chat_timeout := 120.0
## Seconds a model listing may take.
var list_timeout := 15.0

var _http: HTTPRequest # the request in flight



## Sends the conversation [param messages] with [param instructions] and the
## tool definitions [param tool_definitions] ([member IVAssistantToolSet.definitions]).
## Returns the model's reply: [code]{"message": <to append to the
## conversation>, "text": String, "tool_calls": Array, "stop": String}[/code],
## or an empty Dictionary with [member error] set. Each tool call is
## [code]{"id": String, "name": String, "arguments": Dictionary}[/code];
## arguments that aren't a JSON object come as
## [code]{"_unparsed": <the text>}[/code]. [code]stop[/code] is
## [code]"end"[/code] (the model answered), [code]"tool_calls"[/code],
## [code]"length"[/code] (cut off), [code]"refusal"[/code] or [code]"other"[/code].
func send(instructions: String, tool_definitions: Array[Dictionary],
		messages: Array[Dictionary]) -> Dictionary:
	var body := _build_chat_body(instructions, tool_definitions, messages)
	var json: Variant = await _request(HTTPClient.METHOD_POST, _get_chat_url(), body,
			chat_timeout)
	if json == null:
		return {}
	var reply := _parse_chat_response(json)
	if !reply:
		error = "%s sent a reply that can't be read" % provider_name
		return reply
	if simple_schemas:
		var tool_calls: Array[Dictionary] = reply.tool_calls
		_restore_json_arguments(tool_calls, tool_definitions)
	return reply


## Returns the ids of the models the provider offers that take tools, if it
## says which, sorted. Empty with [member error] set if the listing failed.
func list_models() -> Array[String]:
	var json: Variant = await _request(HTTPClient.METHOD_GET, _get_models_url(), null,
			list_timeout)
	var models: Array[String] = []
	if json == null:
		return models
	models = _parse_models(json)
	models.sort()
	return models


## The user's words as a message.
func make_user_message(text: String) -> Dictionary:
	return {"role": "user", "content": text}


## The messages that return tool results to the model, to append to the
## conversation after the reply that called them. Each of [param results] is
## [code]{"id": <the call's id>, "content": String, "is_error": bool}[/code].
@warning_ignore("unused_parameter")
func make_tool_results(results: Array[Dictionary]) -> Array[Dictionary]:
	return []


## Ends the request in flight, which then fails with [member error] set.
func cancel() -> void:
	if !_http:
		return
	_http.cancel_request()
	_http_completed.emit(-1, 0, PackedByteArray())


## Returns [param parameters], a tool's JSON Schema, as the provider takes it.
## With [member simple_schemas], an argument of any type, of a choice of forms
## ([code]anyOf[/code]), or an object or array whose contents aren't described
## becomes text, which may be JSON, and [method send] turns that JSON back into
## a value. [code]default[/code] and [code]additionalProperties[/code] are left out.
func adapt_parameters(parameters: Dictionary) -> Dictionary:
	if !simple_schemas:
		return parameters
	return _simplify_schema(parameters)


## The host part of [member url], to name the server in messages.
func get_host() -> String:
	var host := url.trim_prefix("https://").trim_prefix("http://")
	return host.get_slice("/", 0)


# Virtual: a subclass returns the request body.
@warning_ignore("unused_parameter")
func _build_chat_body(instructions: String, tool_definitions: Array[Dictionary],
		messages: Array[Dictionary]) -> Dictionary:
	return {}


# Virtual: a subclass returns the reply, as send() describes it, or {} if it
# can't read [param json].
@warning_ignore("unused_parameter")
func _parse_chat_response(json: Variant) -> Dictionary:
	return {}


# Virtual: a subclass returns the model ids in [param json], a models listing.
@warning_ignore("unused_parameter")
func _parse_models(json: Variant) -> Array[String]:
	return []


# Virtual: a subclass returns its headers, the key's among them.
func _get_headers() -> PackedStringArray:
	return PackedStringArray(["Content-Type: application/json"])


func _get_chat_url() -> String:
	return url + "/chat/completions"


func _get_models_url() -> String:
	return url + "/models"


# Returns the response's JSON, or null with error set.
func _request(method: HTTPClient.Method, request_url: String, body: Variant,
		timeout: float) -> Variant:
	cancel()
	error = ""
	var tree: SceneTree = Engine.get_main_loop()
	var http := HTTPRequest.new()
	http.timeout = timeout
	tree.root.add_child(http)
	http.request_completed.connect(_on_request_completed)
	var body_text := "" if body == null else JSON.stringify(body)
	var err := http.request(request_url, _get_headers(), method, body_text)
	if err != OK:
		http.queue_free()
		error = "Can't send a request to %s (%s)" % [get_host(), error_string(err)]
		return null
	_http = http
	var completion: Array = await _http_completed
	if _http == http:
		_http = null
	http.queue_free()
	var result: int = completion[0]
	var code: int = completion[1]
	var response: PackedByteArray = completion[2]
	if result == -1:
		error = "Canceled"
		return null
	if result != HTTPRequest.RESULT_SUCCESS:
		error = _get_result_error(result)
		return null
	var text := response.get_string_from_utf8()
	var json: Variant = JSON.parse_string(text) if text else null
	if code >= 400:
		var message := _get_error_message(json)
		if !message:
			message = text.left(200) if text else "no message"
		error = "%s answered %s: %s" % [get_host(), code, message]
		return null
	if json == null:
		error = "%s sent a response that isn't JSON" % get_host()
	return json


func _on_request_completed(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	_http_completed.emit(result, code, body)


func _get_result_error(result: int) -> String:
	var host := get_host()
	match result:
		HTTPRequest.RESULT_TIMEOUT:
			return "%s didn't answer in time" % host
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "A secure connection to %s failed" % host
		HTTPRequest.RESULT_CANT_RESOLVE:
			return "Can't find %s; check the internet connection" % host
	if OS.has_feature("web"):
		return ("Can't reach %s. A web page can reach only a server that allows it"
				+ " (CORS), and a local one only with the browser's permission") % host
	return "Can't reach %s" % host


# The message of an error response from any provider this plugin knows.
func _get_error_message(json: Variant) -> String:
	if json is Array:
		var array: Array = json
		json = array[0] if array else null
	if not json is Dictionary:
		return ""
	var dict: Dictionary = json
	var error_value: Variant = dict.get("error")
	if error_value is String:
		return error_value
	if error_value is Dictionary:
		var error_dict: Dictionary = error_value
		return str(error_dict.get("message", ""))
	return str(dict.get("message", ""))


func _simplify_schema(schema: Dictionary) -> Dictionary:
	if _is_free_form(schema):
		var description := str(schema.get("description", ""))
		return {"type": "string",
				"description": (description + " (text, or JSON for another value)").strip_edges()}
	var simple := schema.duplicate()
	simple.erase("default")
	simple.erase("additionalProperties")
	match simple.get("type"):
		"object":
			var properties: Dictionary = simple["properties"]
			var simple_properties := {}
			for property: String in properties:
				var property_schema: Dictionary = properties[property]
				simple_properties[property] = _simplify_schema(property_schema)
			simple["properties"] = simple_properties
		"array":
			var items: Dictionary = simple["items"]
			simple["items"] = _simplify_schema(items)
	return simple


# Whether a simplified schema takes this as text.
func _is_free_form(schema: Dictionary) -> bool:
	match schema.get("type"):
		null:
			return true
		"object":
			return !schema.has("properties")
		"array":
			return !schema.has("items")
	return false


func _restore_json_arguments(tool_calls: Array[Dictionary],
		tool_definitions: Array[Dictionary]) -> void:
	for tool_call in tool_calls:
		var properties := {}
		for definition in tool_definitions:
			if definition.name == tool_call.name:
				var parameters: Dictionary = definition.parameters
				properties = parameters.get("properties", {})
				break
		var arguments: Dictionary = tool_call.arguments
		for argument: String in arguments:
			var value: Variant = arguments[argument]
			var property_schema: Dictionary = properties.get(argument, {})
			if not value is String or !_is_free_form(property_schema):
				continue
			var text: String = value
			var parsed: Variant = JSON.parse_string(text)
			if parsed != null:
				arguments[argument] = parsed
