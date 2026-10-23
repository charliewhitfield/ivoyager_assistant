# connections.gd
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
class_name IVAssistantConnections
extends RefCounted

## The model providers a project offers, and the user's connection to one.
##
## A project names the providers in [code]ivoyager_assistant.cfg[/code]:
## [code][assistant] providers[/code] lists the ones the setup wizard offers, in
## order, and each is described in a [code][assistant_provider_<id>][/code]
## section. Or it presets one, which every user gets and which hides the wizard.
## The user's connection and keys are kept on their own device, under
## [code]user://[/code]. See SPECIFICATION.md §12.4.[br][br]
##
## [IVAssistant] holds one as [code]IVAssistant.connections[/code].

## Emitted when [member connection] is saved or removed.
signal connection_changed()

signal _local_server_probed()

## Where the user's connection and remembered keys are kept.
const SAVE_PATH := "user://assistant/connection.cfg"
## A provider's keys, with the value each takes when its section omits it.
const PROVIDER_DEFAULTS := {
	"name": "", # display name
	"adapter": "openai", # "openai", "anthropic", or an IVAssistantConnection script's path
	"url": "", # the API base, without a trailing slash
	"local": false, # whether the server runs on the user's computer
	"small_models": false, # whether its models are small; true for a local server
	"needs_key": true, # whether the user gives a key; a local server needs none
	"key_url": "", # where the user gets a key
	"site": "", # where the user learns more, or downloads the server
	"model": "", # the model offered first
	"note": "", # what the wizard says about the provider
	"web": true, # whether a web build offers it: the service must allow calls from a page
	"web_note": "", # what the wizard adds in a web build
	"simple_schemas": false, # whether its tool parameters must be simplified
}

## The user's connection, or the project's preset, or null.
var connection: IVAssistantConnection
## The provider every user gets, which hides the setup wizard, or "".
var preset_provider := ""
## The tool set a new connection gets to a provider of small models, such as a
## local server.
var small_model_tool_set := "full"
## The tool set a new connection gets to a provider of large models.
var large_model_tool_set := "full"

var _provider_ids: Array[String] = []
var _providers: Dictionary[String, Dictionary] = {}
var _keys: Dictionary[String, String] = {} # remembered, by provider


func _init(config: ConfigFile) -> void:
	preset_provider = config.get_value("assistant", "preset_provider", "")
	small_model_tool_set = config.get_value("assistant", "small_model_tool_set",
			small_model_tool_set)
	large_model_tool_set = config.get_value("assistant", "large_model_tool_set",
			large_model_tool_set)
	for section in config.get_sections():
		if !section.begins_with("assistant_provider_"):
			continue
		var provider := PROVIDER_DEFAULTS.duplicate()
		provider["local"] = config.get_value(section, "local", false)
		provider["small_models"] = provider["local"]
		provider["needs_key"] = !provider["local"]
		for key in config.get_section_keys(section):
			provider[key] = config.get_value(section, key)
		_providers[section.trim_prefix("assistant_provider_")] = provider
	var offered: Array = config.get_value("assistant", "providers", [])
	for provider_id: String in offered:
		if !_providers.has(provider_id):
			push_warning("IVAssistantConnections: no section [assistant_provider_%s]"
					% provider_id)
			continue
		_provider_ids.append(provider_id)
	if preset_provider:
		assert(_providers.has(preset_provider), "No provider '%s'" % preset_provider)
		connection = make_connection(preset_provider)
		return
	_load()


## The providers the setup wizard offers in this build, in order. A web build
## leaves out those a page can't reach.
func get_provider_ids() -> Array[String]:
	if !OS.has_feature("web"):
		return _provider_ids.duplicate()
	var ids: Array[String] = []
	for provider_id in _provider_ids:
		if _providers[provider_id]["web"]:
			ids.append(provider_id)
	return ids


## Provider [param provider_id]'s description, with every key of
## [constant PROVIDER_DEFAULTS]; empty for an unknown provider.
func get_provider(provider_id: String) -> Dictionary:
	if !_providers.has(provider_id):
		return {}
	return _providers[provider_id].duplicate()


## Returns a connection to [param provider_id], unsaved, or null for an unknown
## provider. An empty [param model] or [param tool_set_name] takes the provider's
## or the project's default; an empty [param api_key] takes the key the user
## asked to remember.
func make_connection(provider_id: String, model := "", api_key := "", tool_set_name := ""
		) -> IVAssistantConnection:
	if !_providers.has(provider_id):
		return null
	var provider := _providers[provider_id]
	var adapter: String = provider["adapter"]
	var new_connection: IVAssistantConnection
	match adapter:
		"openai":
			new_connection = IVAssistantOpenAIConnection.new()
		"anthropic":
			new_connection = IVAssistantAnthropicConnection.new()
		_:
			var script: GDScript = load(adapter)
			new_connection = script.new()
	new_connection.provider_id = provider_id
	new_connection.provider_name = provider["name"]
	new_connection.url = provider["url"]
	new_connection.is_local = provider["local"]
	new_connection.simple_schemas = provider["simple_schemas"]
	new_connection.model = model if model else provider["model"]
	new_connection.api_key = api_key if api_key else _keys.get(provider_id, "")
	if !tool_set_name:
		tool_set_name = get_default_tool_set(provider_id)
	new_connection.tool_set_name = tool_set_name
	return new_connection


## The tool set a new connection to [param provider_id] gets, by its models'
## size.
func get_default_tool_set(provider_id: String) -> String:
	var provider: Dictionary = _providers.get(provider_id, PROVIDER_DEFAULTS)
	return small_model_tool_set if provider["small_models"] else large_model_tool_set


## The key the user asked to remember for [param provider_id], or "".
func get_remembered_key(provider_id: String) -> String:
	return _keys.get(provider_id, "")


## Makes [param new_connection] the user's and saves it, with its key if
## [param remember_key]. Without the key it lasts until the app quits.
func save_connection(new_connection: IVAssistantConnection, remember_key := true) -> void:
	if preset_provider:
		return
	connection = new_connection
	if remember_key and new_connection.api_key:
		_keys[new_connection.provider_id] = new_connection.api_key
	else:
		_keys.erase(new_connection.provider_id)
	_save()
	connection_changed.emit()


## Removes the user's connection and every key they asked to remember.
func remove_connection() -> void:
	if preset_provider:
		return
	connection = null
	_keys.clear()
	_save()
	connection_changed.emit()


## Asks each local server the project offers for its models. Returns the
## models of each that answered, by provider. A web build asks only
## [param provider_ids]: the browser may ask the user's permission to reach the
## computer's own servers.
func find_local_servers(provider_ids: Array[String] = []) -> Dictionary[String, Array]:
	var found: Dictionary[String, Array] = {}
	var probed_ids: Array[String] = provider_ids.duplicate()
	if !probed_ids:
		if OS.has_feature("web"):
			return found
		for provider_id in get_provider_ids():
			if _providers[provider_id]["local"]:
				probed_ids.append(provider_id)
	var pending: Array[int] = [probed_ids.size()]
	for provider_id in probed_ids:
		var probe := make_connection(provider_id)
		probe.list_timeout = 3.0
		_probe_local_server(probe, found, pending)
	while pending[0] > 0:
		await _local_server_probed
	return found


func _probe_local_server(probe: IVAssistantConnection, found: Dictionary[String, Array],
		pending: Array[int]) -> void:
	var models := await probe.list_models()
	if !probe.error:
		found[probe.provider_id] = models
	pending[0] -= 1
	_local_server_probed.emit()


func _load() -> void:
	var saved := ConfigFile.new()
	if saved.load(SAVE_PATH) != OK:
		return
	if saved.has_section("keys"):
		for provider_id in saved.get_section_keys("keys"):
			_keys[provider_id] = saved.get_value("keys", provider_id)
	var provider_id: String = saved.get_value("connection", "provider", "")
	if !_provider_ids.has(provider_id):
		return
	var model: String = saved.get_value("connection", "model", "")
	var tool_set_name: String = saved.get_value("connection", "tool_set", "")
	connection = make_connection(provider_id, model, "", tool_set_name)


func _save() -> void:
	var saved := ConfigFile.new()
	if connection:
		saved.set_value("connection", "provider", connection.provider_id)
		saved.set_value("connection", "model", connection.model)
		saved.set_value("connection", "tool_set", connection.tool_set_name)
	for provider_id in _keys:
		saved.set_value("keys", provider_id, _keys[provider_id])
	DirAccess.make_dir_recursive_absolute(SAVE_PATH.get_base_dir())
	var err := saved.save(SAVE_PATH)
	if err != OK:
		push_error("IVAssistantConnections: can't save %s (%s)" % [SAVE_PATH, error_string(err)])
