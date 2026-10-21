# save_suite.gd
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

## Save/load methods for [IVAssistantServer], for projects with the Save plugin.
##
## Duck-typed against the [code]IVSave[/code] autoload, and not applicable
## without it. These retire once the Save plugin declares its own automation
## members (SPECIFICATION.md §11).

var _save_singleton: Node # IVSave, if present (duck-typed)


func _init_test_suite(server: Node) -> void:
	super(server)
	_save_singleton = server.get_node_or_null(^"/root/IVSave")


func is_applicable() -> bool:
	return _save_singleton != null


func requires_sim_started() -> bool:
	return false


func get_method_names() -> Array[String]:
	return ["save_game", "load_game", "get_save_status"]


func dispatch(method: String, params: Dictionary) -> Variant:
	match method:
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
