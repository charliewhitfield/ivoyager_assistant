# godot_tools.gd
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
class_name IVAssistantGodotTools
extends RefCounted

## Built-in tools that need only Godot: screenshots, the mouse, input actions,
## projection to the screen and scene-tree inspection.
##
## Positions are window pixels, the pixels of a screenshot and of a synthesized
## mouse event; a project's display scale makes them finer than the GUI's.
## See SPECIFICATION.md §4.4 to §4.6.

## The methods these tools handle, by their protocol names.
const METHODS: Array[String] = ["screenshot", "warp_mouse", "get_mouse_position",
		"project_to_screen", "list_actions", "press_action", "find_nodes", "inspect_node",
		"read_node_text"]

const ERR_UNKNOWN_METHOD := 1
const ERR_INVALID_PARAMS := 2
const ERR_NOT_FOUND := 3

## Maximum number of nodes returned by [code]find_nodes[/code].
const MAX_FIND_RESULTS := 50
## Default child-tree depth for [code]inspect_node[/code] when [code]depth[/code]
## is not specified.
const DEFAULT_INSPECT_DEPTH := 2
## Default cap on text entries collected by [code]read_node_text[/code] when
## [code]max_labels[/code] is not specified.
const DEFAULT_MAX_LABELS := 200

var _tree: SceneTree
var _automation: IVAssistantAutomation


func _init(tree: SceneTree, automation: IVAssistantAutomation) -> void:
	_tree = tree
	_automation = automation


## Handles one of [constant METHODS]. Returns its result, or an
## [code]_error[/code] Dictionary.
func dispatch(method: String, params: Dictionary) -> Variant:
	match method:
		"screenshot":
			return _screenshot(params)
		"warp_mouse":
			return _warp_mouse(params)
		"get_mouse_position":
			return _get_mouse_position()
		"project_to_screen":
			return _project_to_screen(params)
		"list_actions":
			return list_actions(params)
		"press_action":
			return _press_action(params)
		"find_nodes":
			return _find_nodes(params)
		"inspect_node":
			return _inspect_node(params)
		"read_node_text":
			return _read_node_text(params)
	return {"_error": {"code": ERR_UNKNOWN_METHOD,
			"message": "Unknown method: %s" % method}}


## [code]list_actions[/code]: the user's input surface, with what each action
## is bound to. Godot's own ui_* actions are left out unless
## [code]include_ui[/code].
func list_actions(params: Dictionary) -> Dictionary:
	var include_ui: bool = params.get("include_ui", false)
	var actions := {}
	for action in InputMap.get_actions():
		var action_name := String(action)
		if action_name.begins_with("ui_") and !include_ui:
			continue
		var events: Array[String] = []
		for event in InputMap.action_get_events(action):
			events.append(event.as_text())
		actions[action_name] = events
	return {"actions": actions}


# Reads the root viewport, so it shows what is on screen. A batch that hides
# something first passes "redraw" to render a frame without it.
func _screenshot(params: Dictionary) -> Dictionary:
	var path_var: Variant = params.get("path")
	if typeof(path_var) != TYPE_STRING or path_var == "":
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Missing or invalid 'path' parameter"}}
	var path: String = path_var
	var redraw_var: Variant = params.get("redraw", false)
	if typeof(redraw_var) != TYPE_BOOL:
		return {"_error": {"code": ERR_INVALID_PARAMS, "message": "'redraw' must be a boolean"}}
	if redraw_var:
		RenderingServer.force_draw(true)
	var image := _tree.root.get_texture().get_image()
	var err := image.save_png(path)
	if err != OK:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Failed to save screenshot: %s" % error_string(err)}}
	return {"ok": true, "path": path, "size": [image.get_width(), image.get_height()]}


func _warp_mouse(params: Dictionary) -> Variant:
	var pos_or_err: Variant = _parse_vector2(params.get("position"), "position")
	if pos_or_err is Dictionary:
		return pos_or_err
	var screen_pos: Vector2 = pos_or_err
	var motion := InputEventMouseMotion.new()
	motion.position = screen_pos
	motion.global_position = screen_pos
	Input.parse_input_event(motion)
	return {"ok": true, "position": [screen_pos.x, screen_pos.y]}


func _get_mouse_position() -> Dictionary:
	var viewport := _tree.root
	var mouse_pos := _to_window_pixels(viewport, viewport.get_mouse_position())
	return {"position": [mouse_pos.x, mouse_pos.y]}


# A node3d is any Node3D address (e.g. a body by key) or a node path; an offset
# shifts its global position, so a client can project where it will be.
func _project_to_screen(params: Dictionary) -> Variant:
	var has_node := params.has("node")
	var has_world := params.has("world_position")
	if int(has_node) + int(has_world) != 1:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Provide exactly one of 'node' or 'world_position'"}}
	var world_pos: Vector3
	if has_node:
		var node_or_err: Variant = _resolve_node3d(params.get("node"))
		if node_or_err is Dictionary:
			return node_or_err
		var node: Node3D = node_or_err
		world_pos = node.global_position
		if params.has("offset"):
			var offset_or_err: Variant = _parse_vector3(params.get("offset"), "offset")
			if offset_or_err is Dictionary:
				return offset_or_err
			var offset: Vector3 = offset_or_err
			world_pos += offset
	else:
		var pos_or_err: Variant = _parse_vector3(params.get("world_position"),
				"world_position")
		if pos_or_err is Dictionary:
			return pos_or_err
		var parsed_pos: Vector3 = pos_or_err
		world_pos = parsed_pos

	var viewport := _tree.root
	var camera: Camera3D = viewport.get_camera_3d()
	if !camera:
		return {"_error": {"code": ERR_NOT_FOUND, "message": "No active Camera3D"}}
	var behind: bool = camera.is_position_behind(world_pos)
	var screen: Vector2 = camera.unproject_position(world_pos)
	var rect_size: Vector2 = viewport.get_visible_rect().size
	var on_screen := !behind and (
			screen.x >= 0.0 and screen.y >= 0.0
			and screen.x <= rect_size.x and screen.y <= rect_size.y)
	var pixel := _to_window_pixels(viewport, screen)
	return {
		"position": [pixel.x, pixel.y],
		"on_screen": on_screen,
		"behind_camera": behind,
		"world_position_used": [world_pos.x, world_pos.y, world_pos.z],
	}


func _press_action(params: Dictionary) -> Dictionary:
	var action_var: Variant = params.get("action")
	if typeof(action_var) != TYPE_STRING or action_var == "":
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Missing or invalid 'action' parameter"}}

	var action: String = action_var
	var sn := StringName(action)
	if !InputMap.has_action(sn):
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Unknown action: %s" % action}}

	var events := InputMap.action_get_events(sn)
	var key_event: InputEventKey
	for event: InputEvent in events:
		if event is InputEventKey:
			key_event = event
			break

	if !key_event:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Action '%s' has no key binding" % action}}

	var press: InputEventKey = key_event.duplicate()
	press.pressed = true
	Input.parse_input_event(press)

	var release: InputEventKey = key_event.duplicate()
	release.pressed = false
	Input.parse_input_event(release)

	return {"ok": true, "action": action}


func _resolve_node3d(address: Variant) -> Variant:
	var node: Node
	if typeof(address) == TYPE_STRING and str(address).begins_with("/"):
		node = _tree.root.get_node_or_null(NodePath(str(address)))
	else:
		var object := _automation.resolve(address)
		if object is Node:
			node = object
		elif !object:
			return {"_error": {"code": ERR_NOT_FOUND, "message": _automation.error}}
	if !(node is Node3D):
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "'node' must address a Node3D"}}
	return node


func _parse_vector2(value: Variant, param_name: String) -> Variant:
	if typeof(value) != TYPE_ARRAY:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "'%s' must be an array of 2 numbers" % param_name}}
	var arr: Array = value
	if arr.size() != 2:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "'%s' must have exactly 2 elements" % param_name}}
	for i in 2:
		if typeof(arr[i]) != TYPE_FLOAT and typeof(arr[i]) != TYPE_INT:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'%s' elements must be numbers" % param_name}}
	var x: float = arr[0]
	var y: float = arr[1]
	return Vector2(x, y)


func _parse_vector3(value: Variant, param_name: String) -> Variant:
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


# A viewport's 2D position (a mouse position, or an unproject_position() result)
# in window pixels, which a project's display scale makes differ.
func _to_window_pixels(viewport: Viewport, position: Vector2) -> Vector2:
	return viewport.get_final_transform() * position


# =============================================================================
# GUI inspection. Generic scene-tree introspection uses duck-typing and
# Variant-based Dictionary access, producing unavoidable warnings.
@warning_ignore_start("unsafe_cast", "unsafe_property_access", "unsafe_method_access",
		"untyped_declaration", "unsafe_call_argument", "confusable_local_declaration")


func _find_nodes(params: Dictionary) -> Variant:
	var root_path: String = params.get("root", "/root")
	var root_node := _tree.root.get_node_or_null(root_path)
	if !root_node:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Root node not found: %s" % root_path}}

	var class_filter: String = params.get("class", "")
	var script_class: String = params.get("script_class", "")
	var name_pattern: String = params.get("name_pattern", "")

	if class_filter.is_empty() and script_class.is_empty() and name_pattern.is_empty():
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "At least one of 'class', 'script_class', or"
				+ " 'name_pattern' is required"}}

	# owned=false to include procedurally-created nodes
	var candidates: Array[Node]
	if !class_filter.is_empty():
		candidates = root_node.find_children("*", class_filter, true, false)
	elif !name_pattern.is_empty():
		candidates = root_node.find_children(name_pattern, "", true, false)
	else:
		candidates = root_node.find_children("*", "", true, false)

	var results := []
	for node in candidates:
		if results.size() >= MAX_FIND_RESULTS:
			break

		# Filter by script_class if specified
		if !script_class.is_empty():
			var scr := node.get_script() as Script
			if !scr or scr.get_global_name() != script_class:
				continue

		var entry := {
			"path": String(node.get_path()),
			"class": node.get_class(),
			"name": String(node.name),
		}
		var scr := node.get_script() as Script
		if scr and !scr.get_global_name().is_empty():
			entry["script_class"] = String(scr.get_global_name())
		if node is CanvasItem:
			entry["visible"] = node.visible

		results.append(entry)

	return {"nodes": results, "count": results.size()}


func _inspect_node(params: Dictionary) -> Variant:
	var path: String = params.get("path", "")
	if path.is_empty():
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "'path' parameter is required"}}

	var node := _tree.root.get_node_or_null(path)
	if !node:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Node not found: %s" % path}}

	var depth: int = params.get("depth", DEFAULT_INSPECT_DEPTH)
	return _build_inspect_tree(node, depth)


func _read_node_text(params: Dictionary) -> Variant:
	var path: String = params.get("path", "")
	if path.is_empty():
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "'path' parameter is required"}}

	var node := _tree.root.get_node_or_null(path)
	if !node:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Node not found: %s" % path}}

	var max_labels: int = params.get("max_labels", DEFAULT_MAX_LABELS)
	var entries := []
	var truncated := _walk_text(node, entries, max_labels)

	return {
		"path": path,
		"entries": entries,
		"count": entries.size(),
		"truncated": truncated,
	}


func _build_inspect_tree(node: Node, depth: int) -> Dictionary:
	var result := {
		"name": String(node.name),
		"class": node.get_class(),
	}

	var scr := node.get_script() as Script
	if scr and !scr.get_global_name().is_empty():
		result["script_class"] = String(scr.get_global_name())

	if node is CanvasItem:
		result["visible"] = node.visible

	if node is Control:
		if node.accessibility_name:
			result["accessibility_name"] = node.accessibility_name
		if node.accessibility_description:
			result["accessibility_description"] = node.accessibility_description

	# Class-specific properties
	if node is Label:
		result["text"] = node.text
	elif node is RichTextLabel:
		result["text"] = node.get_parsed_text()
	elif node is TabContainer:
		result["current_tab"] = node.current_tab
		result["tab_count"] = node.get_tab_count()
		var tab_names := []
		for i in node.get_tab_count():
			tab_names.append(node.get_tab_title(i))
		result["tab_names"] = tab_names
	elif node is LineEdit:
		result["text"] = node.text
	elif node is TextEdit:
		result["text"] = node.text
	elif node is FoldableContainer:
		result["title"] = node.title
		result["folded"] = node.folded

	# Children
	if depth > 0 and node.get_child_count() > 0:
		var children := []
		for child in node.get_children():
			children.append(_build_inspect_tree(child, depth - 1))
		result["children"] = children

	return result


func _walk_text(node: Node, entries: Array, max_labels: int) -> bool:
	## Returns true if truncated.
	if entries.size() >= max_labels:
		return true

	# Skip invisible nodes
	if node is CanvasItem and !node.visible:
		return false

	# Emit structural markers
	if node is TabContainer:
		var tab_names := []
		for i in node.get_tab_count():
			tab_names.append(node.get_tab_title(i))
		entries.append({
			"type": "tab_container",
			"name": String(node.name),
			"current_tab": node.current_tab,
			"tab_names": tab_names,
		})
		# Only recurse the active tab
		var current: int = node.current_tab
		if current >= 0 and current < node.get_child_count():
			var active_child := node.get_child(current)
			if _walk_text(active_child, entries, max_labels):
				return true
		return false

	if node is FoldableContainer:
		entries.append({
			"type": "section",
			"title": node.title,
			"folded": node.folded,
		})
		if node.folded:
			return false # Don't recurse folded sections

	# Emit text content
	if node is Label and !node.text.is_empty() and node.text != " ":
		entries.append({
			"type": "label",
			"name": String(node.name),
			"text": node.text,
		})
	elif node is RichTextLabel:
		var parsed: String = node.get_parsed_text()
		if !parsed.is_empty():
			entries.append({
				"type": "rich_text",
				"name": String(node.name),
				"text": parsed,
			})

	# Recurse children
	for child in node.get_children():
		if _walk_text(child, entries, max_labels):
			return true

	return false
