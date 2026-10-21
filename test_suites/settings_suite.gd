# settings_suite.gd
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
extends IVAssistantTestSuite

## User-settings methods for [IVAssistantServer].
##
## Binds where [IVOptionsPopup] does, to [method IVSettingsManager.change_setting],
## and names an enumerated setting's values from the popup's own
## [member IVOptionsPopup.option_enumerations]. Every registered setting is
## reachable, including those the popup doesn't show. Settings exist before the
## simulator starts, so these methods work from a splash screen too.[br][br]
##
## @deprecated: Classes now declare these members; use describe, get and call (SPECIFICATION.md §11).

var _options_popup: IVOptionsPopup


func requires_sim_started() -> bool:
	return false


func get_method_names() -> Array[String]:
	return ["get_options", "set_option"]


func get_method_summaries() -> Dictionary:
	return {
		"get_options": "Read user settings: value, default, type, enumeration names and restart state (all, or one 'setting').",
		"set_option": "Change a user setting as the Options popup does; 'persist' also writes the settings file.",
	}


func dispatch(method: String, params: Dictionary) -> Variant:
	match method:
		"get_options":
			return _get_options(params)
		"set_option":
			return _set_option(params)
	return {"_error": {"code": ERR_UNKNOWN_METHOD,
			"message": "Unknown method: %s" % method}}


func _get_options(params: Dictionary) -> Variant:
	var setting_var: Variant = params.get("setting")
	if setting_var != null:
		var setting_or_err: Variant = _parse_setting(setting_var)
		if setting_or_err is Dictionary:
			return setting_or_err
		var setting: StringName = setting_or_err
		var description := _describe_setting(setting)
		description["setting"] = String(setting)
		return description
	var settings := {}
	for setting in IVSettingsManager.get_setting_keys():
		settings[String(setting)] = _describe_setting(setting)
	return {
		"settings": settings,
		"restart_pending": IVSettingsManager.is_restart_pending(),
		"cache_current": IVSettingsManager.is_cache_current(),
	}


# Unpersisted by default, as the popup's changes are until its Confirm button: a test
# run must not leave its settings in the user's next session.
func _set_option(params: Dictionary) -> Variant:
	var setting_or_err: Variant = _parse_setting(params.get("setting"))
	if setting_or_err is Dictionary:
		return setting_or_err
	var setting: StringName = setting_or_err
	if !params.has("value"):
		return {"_error": {"code": ERR_INVALID_PARAMS, "message": "Missing 'value' parameter"}}
	var value_or_err: Variant = _parse_value(setting, params["value"])
	if value_or_err is Dictionary:
		return value_or_err
	var persist := false
	var persist_var: Variant = params.get("persist")
	if persist_var != null:
		if typeof(persist_var) != TYPE_BOOL:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'persist' must be a boolean"}}
		var persist_bool: bool = persist_var
		persist = persist_bool

	var previous: Variant = IVSettingsManager.get_setting(setting)
	IVSettingsManager.change_setting(setting, value_or_err, !persist)
	return {
		"ok": true,
		"setting": String(setting),
		"value": _to_json_value(IVSettingsManager.get_setting(setting)),
		"previous": _to_json_value(previous),
		"restart_pending": IVSettingsManager.is_restart_pending_for(setting),
		"cache_current": IVSettingsManager.is_cache_current(),
	}


func _describe_setting(setting: StringName) -> Dictionary:
	var default_value: Variant = IVSettingsManager.get_default(setting)
	var description := {
		"value": _to_json_value(IVSettingsManager.get_setting(setting)),
		"default": _to_json_value(default_value),
		"type": type_string(typeof(default_value)),
		"restart_pending": IVSettingsManager.is_restart_pending_for(setting),
	}
	var enumeration := _get_enumeration(setting)
	if enumeration:
		description["enumeration"] = _get_enumeration_names(enumeration)
	return description


func _parse_setting(value: Variant) -> Variant:
	if typeof(value) != TYPE_STRING or value == "":
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Missing or invalid 'setting' parameter"}}
	var setting_str: String = value
	var setting := StringName(setting_str)
	if !IVSettingsManager.has_setting(setting):
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Unknown setting: %s (call get_options for valid names)" % setting_str}}
	return setting


# The setting's default decides the type, and JSON brings every number as a float.
func _parse_value(setting: StringName, value: Variant) -> Variant:
	var type := typeof(IVSettingsManager.get_default(setting))
	var value_type := typeof(value)
	var is_number := value_type == TYPE_FLOAT or value_type == TYPE_INT
	match type:
		TYPE_BOOL:
			if value_type == TYPE_BOOL:
				return value
		TYPE_INT:
			if value_type == TYPE_STRING:
				var enumeration_name: String = value
				return _parse_enumeration_name(setting, enumeration_name)
			if is_number:
				var number: float = value
				if number == roundf(number):
					return _check_enumeration_range(setting, int(number))
		TYPE_FLOAT:
			if is_number:
				var number: float = value
				return number
		TYPE_STRING:
			if value_type == TYPE_STRING:
				return value
		TYPE_STRING_NAME:
			if value_type == TYPE_STRING:
				var string: String = value
				return StringName(string)
		TYPE_COLOR:
			if value_type == TYPE_STRING:
				var html: String = value
				if Color.html_is_valid(html):
					return Color.html(html)
		_:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "Setting '%s' holds a %s, which set_option can't set"
					% [setting, type_string(type)]}}
	return {"_error": {"code": ERR_INVALID_PARAMS, "message": "'value' for setting '%s' must be %s"
			% [setting, _get_expected_value_text(setting, type)]}}


func _parse_enumeration_name(setting: StringName, enumeration_name: String) -> Variant:
	var enumeration := _get_enumeration(setting)
	if !enumeration:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Setting '%s' has no enumeration; give an integer" % setting}}
	var key := StringName(enumeration_name)
	if !enumeration.has(key):
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Setting '%s' has no enumeration name '%s' (names: %s)"
				% [setting, enumeration_name, ", ".join(_get_enumeration_names(enumeration))]}}
	var enumeration_value: int = enumeration[key]
	return enumeration_value


func _check_enumeration_range(setting: StringName, value: int) -> Variant:
	var enumeration := _get_enumeration(setting)
	if enumeration and (value < 0 or value >= enumeration.size()):
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "'value' for setting '%s' must be in [0, %d) or a name (%s)"
				% [setting, enumeration.size(), ", ".join(_get_enumeration_names(enumeration))]}}
	return value


func _get_expected_value_text(setting: StringName, type: int) -> String:
	match type:
		TYPE_BOOL:
			return "a boolean"
		TYPE_INT:
			if _get_enumeration(setting):
				return "an integer or an enumeration name"
			return "an integer"
		TYPE_FLOAT:
			return "a number"
		TYPE_COLOR:
			return "an HTML color string such as \"#ff8800\""
	return "a string"


# An empty dictionary for a setting the popup doesn't enumerate, or where the
# project has no popup.
func _get_enumeration(setting: StringName) -> Dictionary:
	var options_popup := _get_options_popup()
	if !options_popup or !options_popup.option_enumerations.has(setting):
		return {}
	var source: Array = options_popup.option_enumerations[setting]
	var object_key: StringName = source[0]
	var property: StringName = source[1]
	var object: Object = IVGlobal.program.get(object_key)
	if !object:
		return {}
	var enumeration: Variant = object.get(property)
	if typeof(enumeration) != TYPE_DICTIONARY:
		return {}
	return enumeration


# In value order: Core's enumerations are inserted that way, as the popup requires.
func _get_enumeration_names(enumeration: Dictionary) -> Array[String]:
	var names: Array[String] = []
	for key: StringName in enumeration:
		names.append(String(key))
	return names


# A project may have no Options popup, or keep it anywhere in the tree.
func _get_options_popup() -> IVOptionsPopup:
	if is_instance_valid(_options_popup):
		return _options_popup
	var options_popups := _server.get_tree().root.find_children("*", "IVOptionsPopup", true,
			false)
	if options_popups:
		_options_popup = options_popups[0]
	return _options_popup


# JSON has no Color, and a project can register a setting of any Variant type.
func _to_json_value(value: Variant) -> Variant:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_ARRAY, TYPE_DICTIONARY:
			return value
		TYPE_STRING_NAME:
			var string_name: StringName = value
			return String(string_name)
		TYPE_COLOR:
			var color: Color = value
			return "#" + color.to_html(color.a < 1.0)
	return var_to_str(value)
