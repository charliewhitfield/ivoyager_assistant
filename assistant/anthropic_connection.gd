# anthropic_connection.gd
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
class_name IVAssistantAnthropicConnection
extends IVAssistantConnection

## A connection through Anthropic's Messages API, to a Claude model.
##
## A reply's message goes back to the model as the API sent it, thinking blocks
## included. The instructions, tools and conversation are cached as a prefix.
## On the models in [constant FALLBACK_MODELS], a request the model declines is
## run again on another model the API chooses.

const API_VERSION := "2026-10-21"
## The longest reply, thinking included.
const MAX_TOKENS := 16000
## Models that take the API's server-side fallback.
const FALLBACK_MODELS: Array[String] = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5",
		"claude-sonnet-5-5"]
const FALLBACK_BETA := "server-side-fallback-2026-07-01"


func make_tool_results(results: Array[Dictionary]) -> Array[Dictionary]:
	var blocks: Array[Dictionary] = []
	for result in results:
		blocks.append({"type": "tool_result", "tool_use_id": result.id,
				"content": result.content, "is_error": result.get("is_error", false)})
	var messages: Array[Dictionary] = [{"role": "user", "content": blocks}]
	return messages


func _build_chat_body(instructions: String, tool_definitions: Array[Dictionary],
		messages: Array[Dictionary]) -> Dictionary:
	var body := {"model": model, "max_tokens": MAX_TOKENS, "messages": messages,
			"cache_control": {"type": "ephemeral"}}
	if instructions:
		body["system"] = instructions
	if FALLBACK_MODELS.has(model):
		body["fallbacks"] = "default"
	if !tool_definitions:
		return body
	var tools: Array[Dictionary] = []
	for definition in tool_definitions:
		var parameters: Dictionary = definition.parameters
		tools.append({"name": definition.name, "description": definition.description,
				"input_schema": adapt_parameters(parameters)})
	body["tools"] = tools
	return body


func _parse_chat_response(json: Variant) -> Dictionary:
	if not json is Dictionary:
		return {}
	var response: Dictionary = json
	var content_value: Variant = response.get("content")
	if not content_value is Array:
		return {}
	var content: Array = content_value
	var texts: Array[String] = []
	var tool_calls: Array[Dictionary] = []
	for block_value: Variant in content:
		if not block_value is Dictionary:
			continue
		var block: Dictionary = block_value
		match block.get("type"):
			"text":
				texts.append(str(block.get("text", "")))
			"tool_use":
				var input: Variant = block.get("input")
				var arguments: Dictionary = input if input is Dictionary else {}
				tool_calls.append({"id": str(block.get("id", "")),
						"name": str(block.get("name", "")), "arguments": arguments})
	var stop := "other"
	match response.get("stop_reason"):
		"end_turn", "stop_sequence":
			stop = "end"
		"tool_use":
			stop = "tool_calls"
		"max_tokens":
			stop = "length"
		"refusal":
			stop = "refusal"
	return {"message": {"role": "assistant", "content": content}, "text": "".join(texts),
			"tool_calls": tool_calls, "stop": stop}


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
		if entry is Dictionary:
			var entry_dict: Dictionary = entry
			models.append(str(entry_dict.get("id", "")))
	return models


func _get_headers() -> PackedStringArray:
	var headers := super()
	headers.append("x-api-key: " + api_key)
	headers.append("anthropic-version: " + API_VERSION)
	if FALLBACK_MODELS.has(model):
		headers.append("anthropic-beta: " + FALLBACK_BETA)
	if OS.has_feature("web"):
		headers.append("anthropic-dangerous-direct-browser-access: true")
	return headers


func _get_chat_url() -> String:
	return url + "/messages"


func _get_models_url() -> String:
	return url + "/models?limit=1000"
