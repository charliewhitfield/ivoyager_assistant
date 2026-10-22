# core_test_suite.gd
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

## Simulator state, start, screenshot and save/load methods for [IVAssistantServer].
##
## Also adds [code]ok_to_start[/code], [code]wait_for_start[/code] and
## [code]allow_time_setting[/code] to [code]get_project_info[/code].
## [code]screenshot[/code] here adds [code]hide_gui[/code] to the built-in one,
## which handles its other parameters.
##
## @deprecated: Classes now declare these members; use describe, get and call (SPECIFICATION.md §11).

var _save_singleton: Node # IVSave, if present (duck-typed)


func _init_test_suite(server: Node) -> void:
	super(server)
	_save_singleton = server.get_node_or_null(^"/root/IVSave")


func requires_sim_started() -> bool:
	return false


func get_method_names() -> Array[String]:
	return ["get_state", "start_game", "screenshot", "save_game", "load_game", "get_save_status"]


func get_method_requirements() -> Dictionary:
	return {
		"save_game": ["autoload.IVSave"],
		"load_game": ["autoload.IVSave"],
		"get_save_status": ["autoload.IVSave"],
	}


func add_project_info(info: Dictionary) -> void:
	info["ok_to_start"] = IVStateManager.ok_to_start
	info["wait_for_start"] = IVCoreSettings.wait_for_start
	info["allow_time_setting"] = IVCoreSettings.allow_time_setting


func dispatch(method: String, params: Dictionary) -> Variant:
	match method:
		"get_state":
			return _get_state()
		"start_game":
			return _start_game()
		"screenshot":
			if !IVStateManager.started:
				return {"_error": {"code": ERR_NOT_STARTED,
						"message": "Simulator not started"}}
			return _screenshot(params)
		"save_game":
			@warning_ignore("unsafe_method_access")
			if !_server.is_ready():
				return {"_error": {"code": ERR_NOT_STARTED,
						"message": "Simulator not ready"}}
			return _save_game(params)
		"load_game":
			@warning_ignore("unsafe_method_access")
			if !_server.is_ready():
				return {"_error": {"code": ERR_NOT_STARTED,
						"message": "Simulator not ready"}}
			return _load_game(params)
		"get_save_status":
			return _get_save_status()
	return {"_error": {"code": ERR_UNKNOWN_METHOD,
			"message": "Unknown method: %s" % method}}


func _get_state() -> Dictionary:
	var result := {
		"started": IVStateManager.started,
		"running": IVStateManager.running,
		"paused_tree": IVStateManager.paused_tree,
		"paused_by_user": IVStateManager.paused_by_user,
		"building_system": IVStateManager.building_system,
		"time": IVGlobal.times[0],
		"date": [IVGlobal.date[0], IVGlobal.date[1], IVGlobal.date[2]],
		"clock": [IVGlobal.clock[0], IVGlobal.clock[1], IVGlobal.clock[2]],
	}
	var speed_manager: IVSpeedManager = IVGlobal.program.get(&"SpeedManager")
	if speed_manager:
		result["speed_index"] = speed_manager.speed_index
		result["speed_name"] = speed_manager.get_speed_name()
		result["reversed_time"] = speed_manager.reversed_time
	else:
		result["speed_index"] = 0
		result["speed_name"] = ""
		result["reversed_time"] = false
	if _save_singleton:
		@warning_ignore_start("unsafe_property_access")
		var is_saving: bool = _save_singleton.is_saving
		var is_loading: bool = _save_singleton.is_loading
		@warning_ignore_restore("unsafe_property_access")
		result["is_saving"] = is_saving
		result["is_loading"] = is_loading
	return result


func _start_game() -> Dictionary:
	if IVStateManager.started:
		return {"_error": {"code": ERR_NOT_ALLOWED,
				"message": "Simulator already started"}}
	if !IVStateManager.ok_to_start:
		return {"_error": {"code": ERR_NOT_ALLOWED,
				"message": "Not ready to start"}}
	IVStateManager.start()
	return {"ok": true}


func _screenshot(params: Dictionary) -> Dictionary:
	var hide_gui_var: Variant = params.get("hide_gui", false)
	if typeof(hide_gui_var) != TYPE_BOOL:
		return {"_error": {"code": ERR_INVALID_PARAMS, "message": "'hide_gui' must be a boolean"}}
	@warning_ignore("unsafe_method_access")
	var godot_tools: IVAssistantTestSuite = _server.get_godot_tools()
	if !hide_gui_var:
		return godot_tools.dispatch("screenshot", params)
	IVGlobal.show_hide_gui_requested.emit(false, false)
	var redraw_params := params.duplicate()
	redraw_params["redraw"] = true
	var result: Dictionary = godot_tools.dispatch("screenshot", redraw_params)
	IVGlobal.show_hide_gui_requested.emit(false, true)
	return result


func _save_game(params: Dictionary) -> Dictionary:
	var save_type: String = params.get("type", "quicksave")
	if save_type != "quicksave" and save_type != "named" and save_type != "autosave":
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Invalid type '%s'. Use 'quicksave', 'named', or 'autosave'" % save_type}}
	@warning_ignore_start("unsafe_method_access")
	match save_type:
		"quicksave":
			_save_singleton.quicksave()
		"named":
			var path: String = params.get("path", "")
			_save_singleton.save_file(0, path) # 0 = NAMED_SAVE
		"autosave":
			_save_singleton.autosave()
	@warning_ignore_restore("unsafe_method_access")
	return {"ok": true}


func _load_game(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	@warning_ignore_start("unsafe_method_access")
	if path:
		_save_singleton.load_file(false, path)
	else:
		_save_singleton.quickload()
	@warning_ignore_restore("unsafe_method_access")
	return {"ok": true}


func _get_save_status() -> Dictionary:
	@warning_ignore_start("unsafe_property_access", "unsafe_method_access",
			"unsafe_call_argument")
	var save_dir: String = _save_singleton.get_directory()
	var result := {
		"is_saving": bool(_save_singleton.is_saving),
		"is_loading": bool(_save_singleton.is_loading),
		"directory": save_dir,
		"has_saves": bool(_save_singleton.has_file(save_dir)),
		"last_modified_path": String(_save_singleton.get_last_modified_file_path(save_dir)),
		"file_extension": String(_save_singleton.file_extension),
	}
	@warning_ignore_restore("unsafe_property_access", "unsafe_method_access",
			"unsafe_call_argument")
	return result
