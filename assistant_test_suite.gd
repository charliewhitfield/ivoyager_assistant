# assistant_test_suite.gd
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
class_name IVAssistantTestSuite
extends RefCounted

## Base class for test suites that extend [IVAssistantServer]'s API.
##
## A suite holds helpers specific to one project; what a class offers any
## client it declares itself (SPECIFICATION.md §11). Subclass this and register
## via the [code][assistant_test_suites][/code] config section. See
## SPECIFICATION.md §7.2.

# Error codes (shared with IVAssistantServer)
const ERR_UNKNOWN_METHOD := 1
const ERR_INVALID_PARAMS := 2
const ERR_NOT_FOUND := 3
const ERR_NOT_STARTED := 4
const ERR_NOT_ALLOWED := 5
## @deprecated: Use [constant ERR_NOT_FOUND], the same code.
const ERR_BODY_NOT_FOUND := ERR_NOT_FOUND

var _server: Node # IVAssistantServer (autoload, no class_name)


## Called after instantiation with the server node reference.
func _init_test_suite(server: Node) -> void:
	_server = server


## Called on the project's lifecycle "started" signal (SPECIFICATION.md §11.6).
func _on_simulator_started() -> void:
	pass


## Called on the project's lifecycle "stopping" signal — clear references.
func _on_about_to_free() -> void:
	pass


## Return method names this suite handles.
func get_method_names() -> Array[String]:
	return []


## Return capability strings for [code]get_project_info[/code]. Most suites can
## leave this empty: the server already advertises every active (non-gated)
## method name in [code]capabilities[/code]. Override only to add feature-group
## identifiers (e.g. [code]"mouse_target_id"[/code]) that aren't method names.
func get_capabilities() -> Array[String]:
	return []


## Optional human-readable summaries. Map<method_name, String>. Surfaces in
## [code]get_project_info[/code]'s [code]methods[/code] map. Methods absent
## from the dict get an empty summary.
func get_method_summaries() -> Dictionary:
	return {}


## Per-method requirement tokens. Map<method_name, Array[String]>, from the
## vocabulary of [IVAssistantRequirementTokens] (SPECIFICATION.md §7.5).
## A method with an unmet token is left out of dispatch and reported under
## [code]gated_out[/code] in [code]get_project_info[/code]. Tokens are
## evaluated when the suite loads and again on the lifecycle "started" signal.
##
## @deprecated: A class gates its own members in is_automation_available() (SPECIFICATION.md §11).
func get_method_requirements() -> Dictionary:
	return {}


## Adds fields to [code]get_project_info[/code]'s result.
##
## @deprecated: Clients read project state from declared properties (SPECIFICATION.md §11).
func add_project_info(_info: Dictionary) -> void:
	pass


## Return false to opt this whole suite out of registration. Default true.
## Called once after [method _init_test_suite], when the project's lifecycle
## "initialized" signal fires, and before methods are registered.
func is_applicable() -> bool:
	return true


## Whether this suite's methods wait for the readiness gate (SPECIFICATION.md §7.4).
## If true, the server returns ERR_NOT_STARTED automatically until it opens.
## If false, the suite handles the check internally.
func requires_sim_started() -> bool:
	return true


## Handle a method call. Return a result Dictionary or an [code]_error[/code]
## Dictionary.
func dispatch(_method: String, _params: Dictionary) -> Variant:
	return {"_error": {"code": ERR_UNKNOWN_METHOD,
			"message": "Method not implemented"}}


## Returns the object a client's [param address] names (SPECIFICATION.md §11.3),
## or null; [method get_resolve_error] then says why.
func resolve(address: Variant) -> Object:
	@warning_ignore("unsafe_method_access")
	var automation: IVAssistantAutomation = _server.get_automation()
	return automation.resolve(address)


## Why the last [method resolve] failed.
func get_resolve_error() -> String:
	@warning_ignore("unsafe_method_access")
	var automation: IVAssistantAutomation = _server.get_automation()
	return automation.error


# ===========================================================================
# Static utilities for use by test suites
# ===========================================================================

## Parses a 3-element numeric array from a JSON-RPC param into a [Vector3].
## Returns the [Vector3] on success or an [code]_error[/code] [Dictionary] on
## failure. [param param_name] is used in error messages.
static func parse_vector3(value: Variant, param_name: String) -> Variant:
	if typeof(value) != TYPE_ARRAY:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "'%s' must be an array of 3 numbers" % param_name}}
	var arr: Array = value
	if arr.size() != 3:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "'%s' must have exactly 3 elements" % param_name}}
	for i in 3:
		if typeof(arr[i]) != TYPE_FLOAT and typeof(arr[i]) != TYPE_INT:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'%s' elements must be numbers" % param_name}}
	var x: float = arr[0]
	var y: float = arr[1]
	var z: float = arr[2]
	return Vector3(x, y, z)


## Parses a required body-name param into an [IVBody]. Returns the body on
## success or an [code]_error[/code] [Dictionary] on failure. [param param_name]
## is used in error messages.
##
## @deprecated: A declared method takes an IVBody parameter by its key (SPECIFICATION.md §11.4).
static func parse_body(value: Variant, param_name: String) -> Variant:
	if typeof(value) != TYPE_STRING or value == "":
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Missing or invalid '%s' parameter" % param_name}}
	var name_str: String = value
	var sn := StringName(name_str)
	if !IVBody.bodies.has(sn):
		return {"_error": {"code": ERR_NOT_FOUND,
				"message": "Body not found: %s" % name_str}}
	return IVBody.bodies[sn]


## Returns [param body]'s position summed up the parent chain at [param time]
## (in heliocentric coordinates for solar-system bodies).
##
## @deprecated: Kept for the deprecated Core suites.
static func get_global_position(body: IVBody, time: float) -> Vector3:
	var pos := Vector3.ZERO
	var current: IVBody = body
	while current:
		if current.has_orbit():
			pos += current.get_position_vector(time)
		current = current.parent
	return pos


## Converts a [param position] in [param viewport]'s 2D coordinates (a mouse position,
## or a [method Camera3D.unproject_position] result) to window pixels, the pixels of a
## screenshot and of a synthesized mouse event. A project's display scale makes
## the two differ; report window pixels to clients.
static func to_window_pixels(viewport: Viewport, position: Vector2) -> Vector2:
	return viewport.get_final_transform() * position
