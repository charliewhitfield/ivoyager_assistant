# openai_connection.gd
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
class_name IVAssistantOpenAIConnection
extends IVAssistantConnection

## A connection through OpenAI-compatible chat completions with tools: local
## servers (Ollama, LM Studio, llama.cpp's [code]llama-server[/code]) and most
## services.
##
## A reply's message goes back to the model as the server sent it, with any
## fields a provider needs returned (Gemini's thought signatures among them).


func make_tool_results(results: Array[Dictionary]) -> Array[Dictionary]:
	var messages: Array[Dictionary] = []
	for result in results:
		messages.append({"role": "tool", "tool_call_id": result.id, "content": result.content})
	return messages


func _build_chat_body(instructions: String, tool_definitions: Array[Dictionary],
		messages: Array[Dictionary]) -> Dictionary:
	var all_messages: Array[Dictionary] = []
	if instructions:
		all_messages.append({"role": "system", "content": instructions})
	all_messages.append_array(messages)
	var body := {"model": model, "messages": all_messages}
	if !tool_definitions:
		return body
	var tools: Array[Dictionary] = []
	for definition in tool_definitions:
		var parameters: Dictionary = definition.parameters
		tools.append({"type": "function", "function": {"name": definition.name,
				"description": definition.description,
				"parameters": adapt_parameters(parameters)}})
	body["tools"] = tools
	return body


func _parse_chat_response(json: Variant) -> Dictionary:
	if not json is Dictionary:
		return {}
	var response: Dictionary = json
	var choices: Variant = response.get("choices")
	if not choices is Array or !choices:
		return {}
	var choice_array: Array = choices
	var choice: Variant = choice_array[0]
	if not choice is Dictionary:
		return {}
	var choice_dict: Dictionary = choice
	var message_value: Variant = choice_dict.get("message")
	if not message_value is Dictionary:
		return {}
	var message_dict: Dictionary = message_value
	var message := message_dict.duplicate(true)
	for key: String in message.keys():
		if message[key] == null and key != "content":
			message.erase(key)
	var content: Variant = message.get("content")
	var text: String = content if content is String else ""
	var tool_calls: Array[Dictionary] = []
	var calls: Variant = message.get("tool_calls")
	if calls is Array:
		var call_array: Array = calls
		for i in call_array.size():
			if not call_array[i] is Dictionary:
				continue
			var tool_call: Dictionary = call_array[i]
			if !tool_call.get("id"):
				tool_call["id"] = "call_%s" % i # a server that names no calls
			var function: Dictionary = tool_call.get("function", {})
			tool_calls.append({"id": str(tool_call.id), "name": str(function.get("name", "")),
					"arguments": _parse_arguments(function.get("arguments"))})
	var finish_reason: Variant = choice_dict.get("finish_reason")
	var stop := "end"
	if tool_calls:
		stop = "tool_calls" # some servers finish with "stop" after calling tools
	elif finish_reason == "length":
		stop = "length"
	elif finish_reason == "content_filter":
		stop = "refusal"
	return {"message": message, "text": text, "tool_calls": tool_calls, "stop": stop}


func _parse_arguments(arguments: Variant) -> Dictionary:
	if arguments is Dictionary:
		return arguments # some servers send an object, not its text
	if arguments == null or (arguments is String and !arguments):
		return {}
	var parsed: Variant = JSON.parse_string(str(arguments))
	if parsed is Dictionary:
		return parsed
	return {"_unparsed": str(arguments)}


func _parse_models(json: Variant) -> Array[String]:
	var models: Array[String] = []
	if not json is Dictionary:
		return models
	var response: Dictionary = json
	var data: Variant = response.get("data")
	if not data is Array:
		return models
	var entries: Array = data
	for entry: Variant in entries:
		if not entry is Dictionary:
			continue
		var entry_dict: Dictionary = entry
		var features: Variant = entry_dict.get("supported_parameters",
				entry_dict.get("supported_features")) # OpenRouter's, Poe's
		if features is Array:
			var feature_array: Array = features
			if !feature_array.has("tools"):
				continue
		models.append(str(entry_dict.get("id", "")).trim_prefix("models/")) # Gemini's prefix
	return models


func _get_headers() -> PackedStringArray:
	var headers := super()
	if api_key:
		headers.append("Authorization: Bearer " + api_key)
	return headers
