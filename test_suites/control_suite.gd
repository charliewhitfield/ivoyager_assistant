# control_suite.gd
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

## Navigation, speed, pause, camera, GUI, action listing, and HUD visibility
## methods for [IVAssistantServer].[br][br]
##
## [code]list_actions[/code] here, with display names, replaces the built-in
## one while this suite is loaded.
##
## @deprecated: Classes now declare these members; use describe, get and call (SPECIFICATION.md §11).

var _selection_manager: IVSelectionManager
var _speed_manager: IVSpeedManager
var _timekeeper: IVTimekeeper
var _camera_handler: IVCameraHandler
var _body_huds_state: IVBodyHUDsState
var _sbg_huds_state: IVSBGHUDsState


func _on_simulator_started() -> void:
	var top_ui: Node = IVGlobal.program.get(&"TopUI")
	if top_ui:
		_selection_manager = top_ui.get(&"selection_manager")
	_speed_manager = IVGlobal.program.get(&"SpeedManager")
	_timekeeper = IVGlobal.program.get(&"Timekeeper")
	_camera_handler = IVGlobal.program.get(&"CameraHandler")
	_body_huds_state = IVGlobal.program.get(&"BodyHUDsState")
	_sbg_huds_state = IVGlobal.program.get(&"SBGHUDsState")


func _on_about_to_free() -> void:
	_selection_manager = null
	_speed_manager = null
	_timekeeper = null
	_camera_handler = null
	_body_huds_state = null
	_sbg_huds_state = null


func get_method_names() -> Array[String]:
	return [
		"select_body", "select_navigate", "set_pause", "set_speed",
		"set_time", "move_camera", "set_camera_fov", "show_hide_gui",
		"list_actions",
		"set_all_body_orbits_visibility", "set_body_orbit_visible_flags",
		"set_huds", "get_huds", "set_class_huds",
	]


func get_method_requirements() -> Dictionary:
	return {
		"select_body": ["program.TopUI"],
		"select_navigate": ["program.TopUI"],
		"move_camera": ["program.CameraHandler"],
		"set_speed": ["program.SpeedManager"],
		"set_time": ["program.Timekeeper", "core.allow_time_setting"],
		"set_all_body_orbits_visibility": ["program.BodyHUDsState"],
		"set_body_orbit_visible_flags": ["program.BodyHUDsState"],
		"set_huds": ["program.BodyHUDsState"],
		"get_huds": ["program.BodyHUDsState"],
		"set_class_huds": ["program.BodyHUDsState"],
	}


func dispatch(method: String, params: Dictionary) -> Variant:
	match method:
		"select_body":
			return _select_body(params)
		"select_navigate":
			return _select_navigate(params)
		"set_pause":
			return _set_pause(params)
		"set_speed":
			return _set_speed(params)
		"set_time":
			return _set_time(params)
		"move_camera":
			return _move_camera(params)
		"set_camera_fov":
			return _set_camera_fov(params)
		"show_hide_gui":
			return _show_hide_gui(params)
		"list_actions":
			return _list_actions()
		"set_all_body_orbits_visibility":
			return _set_all_body_orbits_visibility(params)
		"set_body_orbit_visible_flags":
			return _set_body_orbit_visible_flags(params)
		"set_huds":
			return _set_huds(params)
		"get_huds":
			return _get_huds()
		"set_class_huds":
			return _set_class_huds(params)
	return {"_error": {"code": ERR_UNKNOWN_METHOD,
			"message": "Unknown method: %s" % method}}


func _select_body(params: Dictionary) -> Variant:
	var body_or_err: Variant = IVAssistantTestSuite.parse_body(params.get("name"), "name")
	if body_or_err is Dictionary:
		return body_or_err
	var body: IVBody = body_or_err

	_selection_manager.select_by_name(body.name)
	return {"ok": true}


func _set_pause(params: Dictionary) -> Dictionary:
	var paused_var: Variant = params.get("paused")
	if typeof(paused_var) != TYPE_BOOL:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Missing or invalid 'paused' parameter (must be bool)"}}

	if !IVStateManager.can_user_pause():
		return {"_error": {"code": ERR_NOT_ALLOWED,
				"message": "User pause is not allowed"}}

	var paused: bool = paused_var
	IVStateManager.set_user_paused(paused)
	return {"ok": true}


func _set_speed(params: Dictionary) -> Dictionary:
	if params.has("real_time"):
		_speed_manager.change_speed(0)
	elif params.has("index"):
		var index: Variant = params["index"]
		if typeof(index) != TYPE_FLOAT and typeof(index) != TYPE_INT:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'index' must be an integer"}}
		var index_num: float = index
		_speed_manager.change_speed(int(index_num))
	elif params.has("delta"):
		var delta: Variant = params["delta"]
		if typeof(delta) != TYPE_FLOAT and typeof(delta) != TYPE_INT:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'delta' must be an integer"}}
		var delta_num: float = delta
		var d := int(delta_num)
		if d > 0:
			for _k in d:
				_speed_manager.increment_speed()
		elif d < 0:
			for _k in -d:
				_speed_manager.decrement_speed()
	else:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Provide 'index', 'delta', or 'real_time'"}}

	return {
		"ok": true,
		"speed_index": _speed_manager.speed_index,
		"speed_name": String(_speed_manager.get_speed_name()),
	}


func _select_navigate(params: Dictionary) -> Dictionary:
	var dir_var: Variant = params.get("direction")
	if typeof(dir_var) != TYPE_STRING or dir_var == "":
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Missing or invalid 'direction' parameter"}}

	var direction: String = dir_var
	var can_navigate := false

	match direction:
		"up":
			can_navigate = _selection_manager.has_up()
			if can_navigate:
				_selection_manager.select_up()
		"down":
			can_navigate = _selection_manager.has_down()
			if can_navigate:
				_selection_manager.select_down()
		"next":
			can_navigate = _selection_manager.has_next()
			if can_navigate:
				_selection_manager.select_next()
		"last":
			can_navigate = _selection_manager.has_last()
			if can_navigate:
				_selection_manager.select_last()
		"next_planet":
			can_navigate = _selection_manager.has_next_planet()
			if can_navigate:
				_selection_manager.select_next_planet()
		"last_planet":
			can_navigate = _selection_manager.has_last_planet()
			if can_navigate:
				_selection_manager.select_last_planet()
		"next_moon":
			can_navigate = _selection_manager.has_next_moon()
			if can_navigate:
				_selection_manager.select_next_moon()
		"last_moon":
			can_navigate = _selection_manager.has_last_moon()
			if can_navigate:
				_selection_manager.select_last_moon()
		"next_major_moon":
			can_navigate = _selection_manager.has_next_major_moon()
			if can_navigate:
				_selection_manager.select_next_major_moon()
		"last_major_moon":
			can_navigate = _selection_manager.has_last_major_moon()
			if can_navigate:
				_selection_manager.select_last_major_moon()
		"next_star":
			can_navigate = _selection_manager.has_next_star()
			if can_navigate:
				_selection_manager.select_next_star()
		"last_star":
			can_navigate = _selection_manager.has_last_star()
			if can_navigate:
				_selection_manager.select_last_star()
		"next_spacecraft":
			can_navigate = _selection_manager.has_next_spacecraft()
			if can_navigate:
				_selection_manager.select_next_spacecraft()
		"last_spacecraft":
			can_navigate = _selection_manager.has_last_spacecraft()
			if can_navigate:
				_selection_manager.select_last_spacecraft()
		"history_back":
			can_navigate = _selection_manager.has_history_back()
			if can_navigate:
				_selection_manager.select_history_back()
		"history_forward":
			can_navigate = _selection_manager.has_history_forward()
			if can_navigate:
				_selection_manager.select_history_forward()
		_:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "Invalid direction: %s" % direction}}

	if !can_navigate:
		return {"_error": {"code": ERR_NOT_ALLOWED,
				"message": "Cannot navigate '%s' from current selection" % direction}}

	var sel_name: StringName = _selection_manager.get_name()
	var gui_name: String = _selection_manager.get_gui_name()
	return {"ok": true, "name": String(sel_name), "gui_name": gui_name}


func _set_time(params: Dictionary) -> Dictionary:
	if params.has("time"):
		var time_var: Variant = params["time"]
		if typeof(time_var) != TYPE_FLOAT and typeof(time_var) != TYPE_INT:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'time' must be a number"}}
		var time_num: float = time_var
		_timekeeper.set_time(time_num)
		return {"ok": true, "time": time_num}

	elif params.has("date"):
		var date_var: Variant = params["date"]
		if typeof(date_var) != TYPE_ARRAY:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'date' must be an array"}}
		var date_arr: Array = date_var
		if date_arr.size() != 3 and date_arr.size() != 6:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'date' must have 3 or 6 elements: [Y,M,D] or [Y,M,D,h,m,s]"}}
		for i in date_arr.size():
			if typeof(date_arr[i]) != TYPE_FLOAT and typeof(date_arr[i]) != TYPE_INT:
				return {"_error": {"code": ERR_INVALID_PARAMS,
						"message": "'date' elements must be integers"}}
		var y_f: float = date_arr[0]
		var m_f: float = date_arr[1]
		var d_f: float = date_arr[2]
		var year := int(y_f)
		var month := int(m_f)
		var day := int(d_f)
		if !IVTimekeeper.is_valid_gregorian_date(year, month, day):
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "Invalid date: %d-%d-%d" % [year, month, day]}}
		if date_arr.size() == 6:
			var h_f: float = date_arr[3]
			var min_f: float = date_arr[4]
			var s_f: float = date_arr[5]
			_timekeeper.set_time_from_date_clock_elements(
					year, month, day, int(h_f), int(min_f), int(s_f))
		else:
			_timekeeper.set_time_from_date_clock_elements(year, month, day)
		var current: float = IVGlobal.times[0]
		return {"ok": true, "time": current}

	elif params.has("os_time"):
		_timekeeper.synchronize_with_operating_system()
		var current: float = IVGlobal.times[0]
		return {"ok": true, "time": current}

	else:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Provide 'time', 'date', or 'os_time'"}}


func _move_camera(params: Dictionary) -> Dictionary:
	# Parse target (optional)
	var target_var: Variant = params.get("target")
	var has_target := target_var != null
	var target_sn := StringName()
	if has_target:
		if typeof(target_var) != TYPE_STRING:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'target' must be a string"}}
		var target_str: String = target_var
		target_sn = StringName(target_str)
		if !IVBody.bodies.has(target_sn):
			return {"_error": {"code": ERR_BODY_NOT_FOUND,
					"message": "Body not found: %s" % target_str}}

	# Parse view_position (optional)
	var view_position := Vector3(-INF, -INF, -INF)
	var vp_var: Variant = params.get("view_position")
	if vp_var != null:
		var vp_result: Variant = IVAssistantTestSuite.parse_vector3(vp_var, "view_position")
		if vp_result is Dictionary:
			return vp_result
		view_position = vp_result

	# Parse view_rotations (optional)
	var view_rotations := Vector3(-INF, -INF, -INF)
	var vr_var: Variant = params.get("view_rotations")
	if vr_var != null:
		var vr_result: Variant = IVAssistantTestSuite.parse_vector3(vr_var, "view_rotations")
		if vr_result is Dictionary:
			return vr_result
		view_rotations = vr_result

	# Parse instant (optional, default false)
	var instant := false
	var instant_var: Variant = params.get("instant")
	if instant_var != null:
		if typeof(instant_var) != TYPE_BOOL:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'instant' must be a boolean"}}
		var instant_bool: bool = instant_var
		instant = instant_bool

	# Parse tracking (optional). This decides what a view_position MEANS: "ecliptic" is
	# the ecliptic frame, "orbit" the target's orbit frame, and "ground" the target's own
	# rotating frame -- so latitude is a latitude ON the body, which is the only one of the
	# three that lets a caller pose relative to a body's equator (or its ring plane).
	var tracking_flag := 0
	var tracking_var: Variant = params.get("tracking")
	if tracking_var != null:
		if typeof(tracking_var) != TYPE_STRING:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'tracking' must be a string"}}
		var tracking: String = tracking_var
		match tracking:
			"ground":
				tracking_flag = IVCamera.CameraFlags.CAMERAFLAGS_TRACK_GROUND
			"orbit":
				tracking_flag = IVCamera.CameraFlags.CAMERAFLAGS_TRACK_ORBIT
			"ecliptic":
				tracking_flag = IVCamera.CameraFlags.CAMERAFLAGS_TRACK_ECLIPTIC
			_:
				return {"_error": {"code": ERR_INVALID_PARAMS,
						"message": "'tracking' must be 'ground', 'orbit' or 'ecliptic'"}}

	# Execute camera move
	if has_target:
		_camera_handler.move_to_by_name(target_sn, tracking_flag, view_position, view_rotations,
				instant)
	else:
		_camera_handler.move_to(null, tracking_flag, view_position, view_rotations, instant)

	return {"ok": true}


# Zoom is the one camera property a viewer changes constantly and no other method
# reaches. It takes a focal length as well as an fov because the GUI widget is
# denominated that way and a caller reasoning about apparent size thinks in
# millimetres; the two are one number through IVMath, and both are reported back.
func _set_camera_fov(params: Dictionary) -> Dictionary:
	var camera := _get_camera()
	if !camera:
		return {"_error": {"code": ERR_INVALID_PARAMS, "message": "No current IVCamera"}}
	var fov_var: Variant = params.get("fov")
	var focal_length_var: Variant = params.get("focal_length")
	if (fov_var == null) == (focal_length_var == null):
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Supply exactly one of 'fov' or 'focal_length'"}}
	if fov_var != null:
		if typeof(fov_var) != TYPE_FLOAT and typeof(fov_var) != TYPE_INT:
			return {"_error": {"code": ERR_INVALID_PARAMS, "message": "'fov' must be a number"}}
		var fov: float = fov_var
		if fov <= 0.0 or fov >= 180.0:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'fov' must be in (0, 180)"}}
		camera.set_field_of_view(fov)
	else:
		if (typeof(focal_length_var) != TYPE_FLOAT
				and typeof(focal_length_var) != TYPE_INT):
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'focal_length' must be a number"}}
		var focal_length: float = focal_length_var
		if focal_length <= 0.0:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'focal_length' must be > 0"}}
		camera.set_focal_length(focal_length)
	return {"fov": camera.fov, "focal_length": IVMath.get_focal_length_from_fov(camera.fov)}


# The viewport's own current camera rather than IVCameraHandler's private member,
# so this keeps working for a project that swaps cameras.
func _get_camera() -> IVCamera:
	var viewport := IVGlobal.get_viewport()
	if !viewport:
		return null
	var camera := viewport.get_camera_3d()
	return camera as IVCamera


func _show_hide_gui(params: Dictionary) -> Dictionary:
	var vis_var: Variant = params.get("visible")
	if typeof(vis_var) != TYPE_BOOL:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Missing or invalid 'visible' parameter (must be bool)"}}
	var vis: bool = vis_var
	IVGlobal.show_hide_gui_requested.emit(false, vis)
	return {"ok": true, "visible": vis}


func _list_actions() -> Dictionary:
	var actions := {}
	for action: StringName in IVInputMapManager.defaults:
		var label: StringName = IVInputMapManager.action_texts.get(action, &"")
		var display_name := tr(label) if label else String(action)
		actions[String(action)] = display_name
	return {"actions": actions}


# Body-HUD visibility (orbits/names/symbols) is persisted via
# [member IVBodyHUDsState.PERSIST_PROPERTIES] and may be restored from a prior
# user session by the project (e.g. planetarium's view cacher). Tests that
# depend on a particular state must set it explicitly and restore on exit.
# Both methods return the previous full [member IVBodyHUDsState.orbit_visible_flags]
# so the caller can pass it to [code]set_body_orbit_visible_flags[/code] later
# to restore exactly.
func _set_all_body_orbits_visibility(params: Dictionary) -> Variant:
	var visible_var: Variant = params.get("visible")
	if typeof(visible_var) != TYPE_BOOL:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Missing or invalid 'visible' parameter (must be bool)"}}
	var visible: bool = visible_var
	var previous_flags: int = _body_huds_state.orbit_visible_flags
	_body_huds_state.set_all_orbits_visibility(visible)
	return {
		"ok": true,
		"previous_flags": previous_flags,
		"orbit_visible_flags": _body_huds_state.orbit_visible_flags,
		"all_flags": _body_huds_state.all_flags,
	}


func _set_body_orbit_visible_flags(params: Dictionary) -> Variant:
	var flags_var: Variant = params.get("flags")
	if typeof(flags_var) != TYPE_INT and typeof(flags_var) != TYPE_FLOAT:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Missing or invalid 'flags' parameter (must be int)"}}
	var flags_num: float = flags_var
	var flags := int(flags_num)
	var previous_flags: int = _body_huds_state.orbit_visible_flags
	_body_huds_state.set_orbit_visible_flags(flags)
	return {
		"ok": true,
		"previous_flags": previous_flags,
		"orbit_visible_flags": _body_huds_state.orbit_visible_flags,
		"all_flags": _body_huds_state.all_flags,
	}


# Hides or shows every 3D HUD at once, absolutely rather than by toggling, through the GUI's
# hide-HUDs path. An evaluation screenshot needs a frame with nothing drawn over the
# subject, and a hotkey toggle cannot promise one - its result depends on the state it
# found. Hiding this way leaves the visibility flags alone and is not persisted, so a test
# run can't carry hidden HUDs into the user's next session.
func _set_huds(params: Dictionary) -> Variant:
	var visible_var: Variant = params.get("visible")
	if typeof(visible_var) != TYPE_BOOL:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Missing or invalid 'visible' parameter (must be bool)"}}
	var visible: bool = visible_var
	_body_huds_state.set_huds_hidden(!visible)
	return {
		"ok": true,
		"visible": visible,
		"huds_hidden": _body_huds_state.huds_hidden,
		"orbit_visible_flags": _body_huds_state.orbit_visible_flags,
		"name_visible_flags": _body_huds_state.name_visible_flags,
		"symbol_visible_flags": _body_huds_state.symbol_visible_flags,
		"small_bodies_huds": _sbg_huds_state != null,
	}


# Each HUD's visibility setting by body class and small-body group, the state the
# GUI's HUD checkboxes show, plus the raw flags the per-flag setters take back.
func _get_huds() -> Dictionary:
	var body_classes := {}
	var class_flags := _get_body_class_flags()
	for body_class in class_flags:
		var flag := class_flags[body_class]
		body_classes[body_class] = {
			"names": _body_huds_state.is_name_visible(flag),
			"symbols": _body_huds_state.is_symbol_visible(flag),
			"orbits": _body_huds_state.is_orbit_visible(flag),
		}
	var result := {
		"huds_hidden": _body_huds_state.huds_hidden,
		"body_classes": body_classes,
		"name_visible_flags": _body_huds_state.name_visible_flags,
		"symbol_visible_flags": _body_huds_state.symbol_visible_flags,
		"orbit_visible_flags": _body_huds_state.orbit_visible_flags,
		"all_flags": _body_huds_state.all_flags,
	}
	if !_sbg_huds_state:
		return result
	var groups := {}
	for sbg_name: StringName in IVSmallBodiesGroup.small_bodies_groups:
		var sbg: IVSmallBodiesGroup = IVSmallBodiesGroup.small_bodies_groups[sbg_name]
		groups[String(sbg_name)] = {
			"alias": String(sbg.sbg_alias),
			"symbols": _sbg_huds_state.is_symbols_visible(sbg.sbg_alias),
			"orbits": _sbg_huds_state.is_orbits_visible(sbg.sbg_alias),
		}
	result["small_body_groups"] = groups
	return result


# One HUD for a set of body classes or small-body groups, bound where the GUI's HUD
# checkboxes are (IVHUDsCheckBox), so a class is shown or hidden exactly as a user's
# click does it.
func _set_class_huds(params: Dictionary) -> Variant:
	var hud_var: Variant = params.get("hud")
	if typeof(hud_var) != TYPE_STRING or !["names", "symbols", "orbits"].has(hud_var):
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "'hud' must be 'names', 'symbols' or 'orbits'"}}
	var hud: String = hud_var
	var visible_var: Variant = params.get("visible")
	if typeof(visible_var) != TYPE_BOOL:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Missing or invalid 'visible' parameter (must be bool)"}}
	var visible: bool = visible_var
	var body_classes_var: Variant = params.get("body_classes")
	var groups_var: Variant = params.get("groups")
	if (body_classes_var == null) == (groups_var == null):
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Supply exactly one of 'body_classes' or 'groups'"}}
	var is_body_classes := body_classes_var != null
	var names_or_err: Variant = _parse_names(body_classes_var if is_body_classes else groups_var,
			"body_classes" if is_body_classes else "groups")
	if names_or_err is Dictionary:
		return names_or_err
	var names: Array[String] = names_or_err
	var previous: Dictionary
	if is_body_classes:
		previous = _set_body_class_huds(hud, names, visible)
	else:
		previous = _set_group_huds(hud, names, visible)
	if previous.has("_error"):
		return previous
	return {
		"ok": true,
		"hud": hud,
		"visible": visible,
		"previous": previous,
		"huds_hidden": _body_huds_state.huds_hidden,
	}


# Returns each class's previous visibility, or an _error Dictionary.
func _set_body_class_huds(hud: String, names: Array[String], visible: bool) -> Dictionary:
	var class_flags := _get_body_class_flags()
	var body_flags := 0
	var previous := {}
	for body_class_name in names:
		var body_class := body_class_name.trim_prefix("BODYFLAGS_")
		if !class_flags.has(body_class):
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "Unknown body class: %s (classes: %s)"
					% [body_class_name, ", ".join(class_flags.keys())]}}
		var flag := class_flags[body_class]
		body_flags |= flag
		match hud:
			"names":
				previous[body_class] = _body_huds_state.is_name_visible(flag)
			"symbols":
				previous[body_class] = _body_huds_state.is_symbol_visible(flag)
			"orbits":
				previous[body_class] = _body_huds_state.is_orbit_visible(flag)
	match hud:
		"names":
			_body_huds_state.set_name_visibility(body_flags, visible)
		"symbols":
			_body_huds_state.set_symbol_visibility(body_flags, visible)
		"orbits":
			_body_huds_state.set_orbit_visibility(body_flags, visible)
	return previous


# Returns each group's previous visibility, or an _error Dictionary. Takes a group's
# name or its alias.
func _set_group_huds(hud: String, names: Array[String], visible: bool) -> Dictionary:
	if !_sbg_huds_state:
		return {"_error": {"code": ERR_NOT_ALLOWED,
				"message": "This project has no small-body HUDs"}}
	if hud == "names":
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Small-body groups have no names HUD"}}
	var aliases: Array[StringName] = []
	var previous := {}
	for group_name in names:
		var sbg := _find_small_bodies_group(group_name)
		if !sbg:
			return {"_error": {"code": ERR_BODY_NOT_FOUND,
					"message": "Small bodies group not found: %s" % group_name}}
		aliases.append(sbg.sbg_alias)
		if hud == "symbols":
			previous[String(sbg.name)] = _sbg_huds_state.is_symbols_visible(sbg.sbg_alias)
		else:
			previous[String(sbg.name)] = _sbg_huds_state.is_orbits_visible(sbg.sbg_alias)
	if hud == "symbols":
		_sbg_huds_state.set_visible_symbols_groups(aliases, visible)
	else:
		_sbg_huds_state.set_visible_orbits_groups(aliases, visible)
	return previous


# The single body flags a HUD checkbox can each set (visual_groups.tsv), keyed by their
# IVBody.BodyFlags name without its prefix.
func _get_body_class_flags() -> Dictionary[String, int]:
	var body_flags_enum: Dictionary = IVBody.BodyFlags
	var class_flags: Dictionary[String, int] = {}
	var flags := _body_huds_state.all_flags
	var flag := 1
	while flags:
		if flags & 1:
			var key: Variant = body_flags_enum.find_key(flag)
			class_flags[str(key).trim_prefix("BODYFLAGS_")] = flag
		flag <<= 1
		flags >>= 1
	return class_flags


func _find_small_bodies_group(group_name: String) -> IVSmallBodiesGroup:
	var key := StringName(group_name)
	if IVSmallBodiesGroup.small_bodies_groups.has(key):
		return IVSmallBodiesGroup.small_bodies_groups[key]
	for sbg: IVSmallBodiesGroup in IVSmallBodiesGroup.small_bodies_groups.values():
		if sbg.sbg_alias == key:
			return sbg
	return null


# Accepts one name or an array of them; returns Array[String] or an _error Dictionary.
func _parse_names(value: Variant, param_name: String) -> Variant:
	var names: Array[String] = []
	if typeof(value) == TYPE_STRING:
		var single_name: String = value
		names.append(single_name)
	elif typeof(value) == TYPE_ARRAY:
		var array: Array = value
		for item: Variant in array:
			if typeof(item) != TYPE_STRING:
				names.clear()
				break
			var item_name: String = item
			names.append(item_name)
	if names.is_empty() or names.has(""):
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "'%s' must be a name or a non-empty array of names" % param_name}}
	return names
