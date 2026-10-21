# automation.gd
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
@tool
class_name IVAssistantAutomation
extends RefCounted

## Finds the objects that declare automation members and serves a client's
## [code]describe[/code], [code]get[/code] and [code]call[/code] on them.
##
## Knows only Godot and the convention of SPECIFICATION.md §11: a class lists
## what a client may call and read in [code]AUTOMATION_*[/code] constants, owns
## its gates in [code]is_automation_available()[/code], and names further
## objects in [code]get_automation_objects()[/code]. Objects are found among
## the autoloads, the objects they name, and the scene tree, and are looked up
## again at each request, so objects freed on a reset simply drop out.

const ERR_UNKNOWN_METHOD := 1
const ERR_INVALID_PARAMS := 2
const ERR_NOT_FOUND := 3
const ERR_NOT_ALLOWED := 5

const METHODS_CONSTANT := "AUTOMATION_METHODS"
const PROPERTIES_CONSTANT := "AUTOMATION_PROPERTIES"
const KEY_CONSTANT := &"AUTOMATION_KEY"
const LIFECYCLE_CONSTANT := &"AUTOMATION_LIFECYCLE"
const AVAILABLE_METHOD := &"is_automation_available"
const OBJECTS_METHOD := &"get_automation_objects"

## Dictionary keys of a keyed address that are not key properties. ("name" is
## an address word only without "class"; with it, it is a key, as for a node.)
const ADDRESS_WORDS: Array[String] = ["class", "path", "via"]

static var _autoload_names: Array[String] = []
static var _autoload_script_names: Dictionary[String, String] = {}

## Message of the last failed resolution, or "".
var error := ""

var converter: IVAssistantConverter
var docs := IVAssistantDocs.new()

var _tree: SceneTree
var _dirty := true
var _named: Dictionary[String, Object] = {} # address name -> object
var _names: Dictionary[int, String] = {} # instance id -> address name
var _objects: Array[Object] = [] # every participating object found
var _instances: Dictionary[StringName, Array] = {} # each class in an object's chain -> objects
var _declarations: Dictionary[Script, Declaration] = {}
var _global_script_paths: Dictionary[StringName, String] = {}
var _script_class_names: Dictionary[Script, StringName] = {}


## Names of the project's autoloads, in project order.
static func get_autoload_names() -> Array[String]:
	if _autoload_names:
		return _autoload_names
	for property in ProjectSettings.get_property_list():
		var property_name: String = property.name
		if property_name.begins_with("autoload/"):
			_autoload_names.append(property_name.trim_prefix("autoload/"))
	return _autoload_names


## Autoload names by the path of the script each autoload runs. An autoload
## script usually has no class name, so this names its class.
static func get_autoload_script_names() -> Dictionary[String, String]:
	if _autoload_script_names:
		return _autoload_script_names
	for autoload_name in get_autoload_names():
		var path: String = ProjectSettings.get_setting("autoload/" + autoload_name, "")
		path = path.trim_prefix("*")
		if path.begins_with("uid://"):
			path = ResourceUID.get_id_path(ResourceUID.text_to_id(path))
		if path.get_extension() == "gd":
			_autoload_script_names[path] = autoload_name
	return _autoload_script_names


func _init(tree: SceneTree) -> void:
	_tree = tree
	converter = IVAssistantConverter.new(self)
	if !Engine.is_editor_hint():
		_tree.node_added.connect(_on_tree_changed)
		_tree.node_removed.connect(_on_tree_changed)


## Marks discovery stale. The server calls this once per request, so objects
## named through [code]get_automation_objects()[/code] are current.
func invalidate() -> void:
	_dirty = true


# *****************************************************************************
# requests

## [code]describe[/code]: every declared object, class, member, signature,
## enum and availability. See SPECIFICATION.md §4.2.
func describe(params: Dictionary) -> Dictionary:
	_refresh()
	var full: bool = params.get("full", false)
	var include_instances: bool = params.get("instances", true)
	var objects := {}
	var classes := {}
	var enums := {}
	var described: Dictionary[Script, bool] = {}
	for address in _named:
		var object := _named[address]
		var declaration := get_declaration_of(object)
		var entry := _describe_declaration(declaration, full, enums)
		var unavailable := _get_unavailable(object, declaration)
		if unavailable:
			entry["unavailable"] = unavailable
		objects[address] = entry
		described[declaration.source_script] = true
	# Unnamed objects: one of a class is addressed by its class, several by key or path.
	var groups: Dictionary[StringName, Array] = {}
	for object in _objects:
		if _names.has(object.get_instance_id()):
			continue
		var declaration := get_declaration_of(object)
		if !groups.has(declaration.class_name_):
			groups[declaration.class_name_] = []
		groups[declaration.class_name_].append(object)
	for class_name_ in groups:
		var members: Array = groups[class_name_]
		var first: Object = members[0]
		var declaration := get_declaration_of(first)
		var entry := _describe_declaration(declaration, full, enums)
		described[declaration.source_script] = true
		if members.size() == 1 and declaration.key.is_empty():
			var unavailable := _get_unavailable(first, declaration)
			if unavailable:
				entry["unavailable"] = unavailable
			objects[String(class_name_)] = entry
			continue
		if declaration.key:
			entry["key"] = _to_strings(declaration.key)
		entry["count"] = members.size()
		if include_instances:
			var instances := []
			for object: Object in members:
				var instance := _get_address_fields(object, declaration)
				var unavailable := _get_unavailable(object, declaration)
				if unavailable:
					instance["unavailable"] = unavailable
				instances.append(instance)
			entry["instances"] = instances
		classes[String(class_name_)] = entry
	_describe_reachable_classes(described, classes, full, enums)
	return {"objects": objects, "classes": classes, "enums": enums}


## [code]get[/code]: values of declared properties of one object.
func get_properties(params: Dictionary) -> Dictionary:
	var object := resolve(params.get("object"))
	if !object:
		return _error(ERR_NOT_FOUND, error)
	var declaration := get_declaration_of(object)
	var names: Array = declaration.properties + declaration.key
	if params.has("properties"):
		var requested: Variant = params["properties"]
		if typeof(requested) == TYPE_STRING:
			requested = [requested]
		if typeof(requested) != TYPE_ARRAY:
			return _error(ERR_INVALID_PARAMS, "'properties' must be a name or an array of names")
		names = requested
	var result := {}
	for property_name: Variant in names:
		var property := StringName(str(property_name))
		if !declaration.properties.has(property) and !declaration.key.has(property):
			return _error(ERR_UNKNOWN_METHOD, "%s declares no property '%s' (properties: %s)"
					% [declaration.class_name_, property, ", ".join(_to_strings(
					declaration.properties + declaration.key))])
		if !_is_available(object, declaration, property):
			return _error(ERR_NOT_ALLOWED, "%s.%s is not available now"
					% [declaration.class_name_, property])
		var info: Dictionary = declaration.property_infos.get(property, {})
		result[String(property)] = converter.to_json(object.get(property), info)
	return result


## [code]call[/code]: calls one declared method with arguments converted from
## JSON, and returns its converted result.
func call_method(params: Dictionary) -> Variant:
	var object := resolve(params.get("object"))
	if !object:
		return _error(ERR_NOT_FOUND, error)
	var declaration := get_declaration_of(object)
	var method_var: Variant = params.get("method")
	if typeof(method_var) != TYPE_STRING or !method_var:
		return _error(ERR_INVALID_PARAMS, "Missing or invalid 'method'")
	var method := StringName(str(method_var))
	if !declaration.methods.has(method):
		return _error(ERR_UNKNOWN_METHOD, "%s declares no method '%s' (methods: %s)"
				% [declaration.class_name_, method, ", ".join(_to_strings(declaration.methods))])
	if !_is_available(object, declaration, method):
		return _error(ERR_NOT_ALLOWED, "%s.%s is not available now"
				% [declaration.class_name_, method])
	var info: Dictionary = declaration.method_infos.get(method, {})
	if !info:
		return _error(ERR_UNKNOWN_METHOD, "%s declares '%s', which it doesn't have"
				% [declaration.class_name_, method])
	converter.error = ""
	converter.name_scope = _get_enum_names(declaration)
	var args: Variant = _convert_args(info, params.get("args"))
	converter.name_scope = {}
	if converter.error:
		var message := converter.error
		converter.error = ""
		return _error(ERR_INVALID_PARAMS, "%s.%s: %s" % [declaration.class_name_, method, message])
	var arg_values: Array = args
	var result: Variant = object.callv(method, arg_values)
	var return_info: Dictionary = info.get("return", {})
	return converter.to_json(result, return_info)


# *****************************************************************************
# addresses

## Returns the object [param address] names, or null with [member error] set.
## An address is a name (an autoload, a role from [code]get_automation_objects()[/code],
## or a class with one instance), or a dictionary: [code]{"class": ..., <key>: ...}[/code],
## [code]{"path": ...}[/code] or [code]{"name": ...}[/code], any of them with
## [code]"via"[/code], declared properties to follow to an object they hold.
func resolve(address: Variant) -> Object:
	error = ""
	_refresh()
	var object: Object
	var via: Array = []
	match typeof(address):
		TYPE_STRING:
			var text: String = address
			object = _resolve_name(text)
		TYPE_DICTIONARY:
			var dict: Dictionary = address
			var via_var: Variant = dict.get("via", [])
			via = [via_var] if typeof(via_var) == TYPE_STRING else via_var
			if dict.has("path"):
				object = _resolve_path(str(dict["path"]))
			elif dict.has("class"):
				object = _resolve_key(StringName(str(dict["class"])), dict)
			elif dict.has("name"):
				object = _resolve_name(str(dict["name"]))
			else:
				error = "An address dictionary needs 'class', 'path' or 'name'"
		TYPE_NIL:
			error = "Missing 'object'"
		_:
			error = "An address is a name or a dictionary"
	for hop: Variant in via:
		if !object:
			break
		object = _follow(object, StringName(str(hop)))
	return object


## Returns the object for a parameter typed [param class_name_]: an address,
## or for a class with a one-property key just that value ("PLANET_EARTH").
func resolve_for_class(value: Variant, class_name_: StringName) -> Object:
	_refresh()
	error = ""
	if typeof(value) == TYPE_STRING and !_named.has(str(value)) and !_instances.has(StringName(
			str(value))) and !str(value).begins_with("/"):
		var matches: Array[Object] = []
		for object: Object in _get_instances_of(class_name_):
			var declaration := get_declaration_of(object)
			if declaration.key.size() == 1 and json_equal(
					converter.to_json(object.get(declaration.key[0])), value):
				matches.append(object)
		if matches.size() == 1:
			return matches[0]
		if matches.size() > 1:
			error = "'%s' matches %d objects: %s" % [value, matches.size(), _list_addresses(matches)]
			return null
	var object := resolve(value)
	if object and !is_instance_of_class(object, class_name_):
		error = "%s is not a %s" % [JSON.stringify(object_to_json(object)), class_name_]
		return null
	if !object and !error:
		error = "No %s '%s'" % [class_name_, value]
	return object


## Returns [param object] as JSON: its address if it has one, its declared
## properties if it declares any, else its class (and path, for a node).
func object_to_json(object: Object, depth := 0) -> Variant:
	var declaration := get_declaration_of(object)
	var class_name_ := get_object_class_name(object)
	if declaration and declaration.key:
		return _get_address_fields(object, declaration, true)
	if _names.has(object.get_instance_id()):
		return _names[object.get_instance_id()]
	var result := {"class": String(class_name_)}
	if declaration and declaration.properties and depth < IVAssistantConverter.MAX_OBJECT_DEPTH:
		for property in declaration.properties:
			var info: Dictionary = declaration.property_infos.get(property, {})
			result[String(property)] = converter.to_json(object.get(property), info, depth + 1)
		return result
	if object is Node:
		var node: Node = object
		if node.is_inside_tree():
			result["path"] = str(node.get_path())
	return result


# *****************************************************************************
# declarations

## Returns what [param object]'s script chain declares, or null for an object
## without a script.
func get_declaration_of(object: Object) -> Declaration:
	var script: Script = object.get_script()
	if !script:
		return null
	return get_declaration(script)


## Returns what [param script]'s chain declares (cached).
func get_declaration(script: Script) -> Declaration:
	if _declarations.has(script):
		return _declarations[script]
	var declaration := Declaration.new()
	declaration.source_script = script
	var level := script
	while level:
		var constants := level.get_script_constant_map()
		for constant_name: StringName in constants:
			var name_text := String(constant_name)
			var value: Variant = constants[constant_name]
			if _is_numbered_constant(name_text, METHODS_CONSTANT):
				_append_names(declaration.methods, value)
			elif _is_numbered_constant(name_text, PROPERTIES_CONSTANT):
				_append_names(declaration.properties, value)
			elif constant_name == KEY_CONSTANT and declaration.key.is_empty():
				_append_names(declaration.key, value)
			elif constant_name == LIFECYCLE_CONSTANT and !declaration.lifecycle:
				declaration.lifecycle = value
			elif _is_enum(value):
				var level_name := get_class_name_of_script(level)
				var owner_name := String(level_name) if level_name else level.resource_path
				declaration.enums[StringName(owner_name + "." + name_text)] = value
		level = level.get_base_script()
	for info in script.get_script_method_list():
		var method: StringName = info.name
		if !declaration.method_infos.has(method):
			declaration.method_infos[method] = info
	for info in script.get_script_property_list():
		var property: StringName = info.name
		if !declaration.property_infos.has(property):
			declaration.property_infos[property] = info
	var native := script.get_instance_base_type()
	for method in declaration.methods:
		if !declaration.method_infos.has(method):
			for info in ClassDB.class_get_method_list(native):
				if info.name == method:
					declaration.method_infos[method] = info
	for property in declaration.properties + declaration.key:
		if !declaration.property_infos.has(property):
			for info in ClassDB.class_get_property_list(native):
				if info.name == property:
					declaration.property_infos[property] = info
	declaration.has_available = declaration.method_infos.has(AVAILABLE_METHOD)
	declaration.has_objects = declaration.method_infos.has(OBJECTS_METHOD)
	var global_name := get_class_name_of_script(script)
	declaration.class_name_ = global_name if global_name else native
	for method in declaration.methods:
		if !declaration.method_infos.has(method):
			push_warning("%s declares method '%s', which it doesn't have"
					% [declaration.class_name_, method])
	_declarations[script] = declaration
	return declaration


## Returns the most-derived global class name in [param script]'s chain, or
## for an autoload's own script its autoload name, or &"" if none is named.
func get_class_name_of_script(script: Script) -> StringName:
	if _script_class_names.has(script):
		return _script_class_names[script]
	var level := script
	var result := &""
	while level:
		if level.get_global_name():
			result = level.get_global_name()
			break
		var autoload_name: String = get_autoload_script_names().get(level.resource_path, "")
		if autoload_name:
			result = StringName(autoload_name)
			break
		level = level.get_base_script()
	_script_class_names[script] = result
	return result


## Returns [param object]'s most-derived global class name, else its native class.
func get_object_class_name(object: Object) -> StringName:
	var script: Script = object.get_script()
	if script:
		var global_name := get_class_name_of_script(script)
		if global_name:
			return global_name
	return StringName(object.get_class())


## Returns the script of global class or autoload [param class_name_], or null.
func get_global_script(class_name_: StringName) -> Script:
	if !class_name_:
		return null
	if _global_script_paths.is_empty():
		for info in ProjectSettings.get_global_class_list():
			_global_script_paths[info["class"]] = info.path
		var autoload_script_names := get_autoload_script_names()
		for path in autoload_script_names:
			var autoload_name := StringName(autoload_script_names[path])
			if !_global_script_paths.has(autoload_name):
				_global_script_paths[autoload_name] = path
	if !_global_script_paths.has(class_name_):
		return null
	return load(_global_script_paths[class_name_])


## Whether [param object] is a [param class_name_], native or global script class.
func is_instance_of_class(object: Object, class_name_: StringName) -> bool:
	if !class_name_ or object.is_class(class_name_):
		return true
	var script: Script = object.get_script()
	while script:
		if script.get_global_name() == class_name_:
			return true
		script = script.get_base_script()
	return false


## The first autoload whose script declares [code]AUTOMATION_LIFECYCLE[/code],
## and the declaration; [code][null, {}][/code] if none does.
func find_lifecycle() -> Array:
	for autoload_name in get_autoload_names():
		var node := _tree.root.get_node_or_null(NodePath(autoload_name))
		if !node:
			continue
		var declaration := get_declaration_of(node)
		if declaration and declaration.lifecycle:
			return [node, declaration.lifecycle]
	return [null, {}]


## Whether a script in a scene or an export participates: declares any
## [code]AUTOMATION_*[/code] constant or automation method.
func script_participates(script: Script) -> bool:
	var declaration := get_declaration(script)
	if declaration.participates() or declaration.lifecycle:
		return true
	for method in declaration.method_infos:
		if String(method).contains("automation"):
			return true
	return false


## Whether two JSON values are equal, an integer equal to the same float.
func json_equal(a: Variant, b: Variant) -> bool:
	var a_type := typeof(a)
	var b_type := typeof(b)
	if (a_type == TYPE_INT or a_type == TYPE_FLOAT) and (b_type == TYPE_INT or b_type == TYPE_FLOAT):
		var a_number: float = a
		var b_number: float = b
		return a_number == b_number
	if a_type == TYPE_ARRAY and b_type == TYPE_ARRAY:
		var a_array: Array = a
		var b_array: Array = b
		if a_array.size() != b_array.size():
			return false
		for i in a_array.size():
			if !json_equal(a_array[i], b_array[i]):
				return false
		return true
	if a_type == TYPE_DICTIONARY and b_type == TYPE_DICTIONARY:
		var a_dict: Dictionary = a
		var b_dict: Dictionary = b
		if a_dict.size() != b_dict.size():
			return false
		for key: Variant in a_dict:
			if !b_dict.has(key) or !json_equal(a_dict[key], b_dict[key]):
				return false
		return true
	if a_type != b_type:
		return false
	return a == b


# *****************************************************************************
# private

func _refresh() -> void:
	if !_dirty:
		return
	_dirty = false
	_named.clear()
	_names.clear()
	_objects.clear()
	_instances.clear()
	var seen: Dictionary[int, bool] = {}
	var queue: Array[Object] = []
	for autoload_name in get_autoload_names():
		var node := _tree.root.get_node_or_null(NodePath(autoload_name))
		if node and _participates(node):
			_add_named(autoload_name, node)
			queue.append(node)
	var i := 0
	while i < queue.size():
		var object := queue[i]
		i += 1
		if !get_declaration_of(object).has_objects:
			continue
		var named_objects: Dictionary = object.call(OBJECTS_METHOD)
		for role: Variant in named_objects:
			var named: Variant = named_objects[role]
			if typeof(named) != TYPE_OBJECT or !is_instance_valid(named):
				continue
			var named_object: Object = named
			if _names.has(named_object.get_instance_id()) or !_participates(named_object):
				continue
			_add_named(str(role), named_object)
			queue.append(named_object)
	for object in queue:
		seen[object.get_instance_id()] = true
		_add_instance(object)
	for node in _tree.root.find_children("*", "", true, false):
		if seen.has(node.get_instance_id()) or !_participates(node):
			continue
		_add_instance(node)


func _participates(object: Object) -> bool:
	var declaration := get_declaration_of(object)
	return declaration != null and declaration.participates()


func _add_named(address: String, object: Object) -> void:
	_named[address] = object
	_names[object.get_instance_id()] = address


func _add_instance(object: Object) -> void:
	_objects.append(object)
	var script: Script = object.get_script()
	while script:
		var global_name := script.get_global_name()
		if global_name:
			if !_instances.has(global_name):
				_instances[global_name] = []
			_instances[global_name].append(object)
		script = script.get_base_script()


func _resolve_name(address: String) -> Object:
	if _named.has(address):
		return _named[address]
	if address.begins_with("/"):
		return _resolve_path(address)
	var class_name_ := StringName(address)
	var instances: Array = _instances.get(class_name_, [])
	if instances.size() == 1:
		return instances[0]
	if instances.size() > 1:
		var first: Object = instances[0]
		var declaration := get_declaration_of(first)
		var needed := "its key: " + ", ".join(_to_strings(declaration.key)) if declaration.key \
				else "'path'"
		error = "There are %d %s; address one by %s" % [instances.size(), address, needed]
		return null
	error = "No object '%s' (call describe for addresses)" % address
	return null


func _resolve_path(path: String) -> Object:
	var node := _tree.root.get_node_or_null(NodePath(path))
	if !node:
		error = "No node at '%s'" % path
		return null
	if !_participates(node):
		error = "Node '%s' declares no automation members" % path
		return null
	return node


func _resolve_key(class_name_: StringName, address: Dictionary) -> Object:
	var candidates: Array = _instances.get(class_name_, [])
	if candidates.is_empty():
		error = "No %s (call describe for classes)" % class_name_
		return null
	var matches: Array[Object] = []
	for object: Object in candidates:
		if _key_matches(object, address):
			matches.append(object)
	if matches.size() == 1:
		return matches[0]
	if matches.is_empty():
		error = "No %s matches %s" % [class_name_, JSON.stringify(address)]
	else:
		error = "%d %s match %s: %s" % [matches.size(), class_name_, JSON.stringify(address),
				_list_addresses(matches)]
	return null


func _key_matches(object: Object, address: Dictionary) -> bool:
	var declaration := get_declaration_of(object)
	for field: Variant in address:
		if ADDRESS_WORDS.has(str(field)):
			continue
		var property := StringName(str(field))
		if !declaration.key.has(property) and !declaration.properties.has(property):
			return false
		var info: Dictionary = declaration.property_infos.get(property, {})
		if !json_equal(converter.to_json(object.get(property), info), address[field]):
			return false
	return true


func _follow(object: Object, property: StringName) -> Object:
	var declaration := get_declaration_of(object)
	if !declaration.properties.has(property):
		error = "%s declares no property '%s' to follow" % [declaration.class_name_, property]
		return null
	if !_is_available(object, declaration, property):
		error = "%s.%s is not available now" % [declaration.class_name_, property]
		return null
	var value: Variant = object.get(property)
	if typeof(value) != TYPE_OBJECT or !is_instance_valid(value):
		error = "%s.%s holds no object" % [declaration.class_name_, property]
		return null
	var next: Object = value
	if !_participates(next):
		error = "%s.%s holds a %s, which declares no automation members" % [
				declaration.class_name_, property, get_object_class_name(next)]
		return null
	return next


func _get_instances_of(class_name_: StringName) -> Array:
	if _instances.has(class_name_):
		return _instances[class_name_]
	var result := []
	for object in _objects:
		if object.is_class(class_name_):
			result.append(object)
	return result


func _get_address_fields(object: Object, declaration: Declaration, with_class := false
		) -> Dictionary:
	var result := {}
	if with_class:
		result["class"] = String(declaration.class_name_)
	if declaration.key.is_empty() and object is Node:
		var node: Node = object
		result["path"] = str(node.get_path())
		return result
	for property in declaration.key:
		var info: Dictionary = declaration.property_infos.get(property, {})
		result[String(property)] = converter.to_json(object.get(property), info)
	return result


func _list_addresses(objects: Array[Object]) -> String:
	var texts := PackedStringArray()
	for object: Object in objects.slice(0, 10):
		texts.append(JSON.stringify(object_to_json(object)))
	if objects.size() > 10:
		texts.append("...")
	return ", ".join(texts)


func _is_available(object: Object, declaration: Declaration, member: StringName) -> bool:
	if !declaration.has_available:
		return true
	var available: Variant = object.call(AVAILABLE_METHOD, member)
	return available == true


func _get_unavailable(object: Object, declaration: Declaration) -> Array[String]:
	var unavailable: Array[String] = []
	if !declaration.has_available:
		return unavailable
	for member in declaration.methods + declaration.properties:
		if !_is_available(object, declaration, member):
			unavailable.append(String(member))
	return unavailable


func _convert_args(info: Dictionary, args: Variant) -> Array:
	var arg_infos: Array = info.get("args", [])
	var defaults: Array = info.get("default_args", [])
	var n_required := arg_infos.size() - defaults.size()
	var values := []
	match typeof(args):
		TYPE_NIL:
			pass
		TYPE_ARRAY:
			var array: Array = args
			if array.size() > arg_infos.size():
				converter.error = "takes at most %d arguments" % arg_infos.size()
				return values
			for i in array.size():
				var arg_info: Dictionary = arg_infos[i]
				var arg_name: String = arg_info.name
				values.append(converter.from_json(array[i], arg_info, arg_name))
		TYPE_DICTIONARY:
			var dict: Dictionary = args
			var last := -1
			var arg_names: Array[String] = []
			for i in arg_infos.size():
				var arg_info: Dictionary = arg_infos[i]
				var arg_name: String = arg_info.name
				arg_names.append(arg_name)
				if dict.has(arg_name):
					last = i
			for arg_name: Variant in dict:
				if !arg_names.has(str(arg_name)):
					converter.error = "no argument '%s' (arguments: %s)" % [arg_name,
							", ".join(arg_names)]
					return values
			for i in last + 1:
				var arg_info: Dictionary = arg_infos[i]
				var arg_name: String = arg_info.name
				if dict.has(arg_name):
					values.append(converter.from_json(dict[arg_name], arg_info, arg_name))
					continue
				if i < n_required:
					break
				var default: Variant = defaults[i - n_required]
				var type: int = arg_info.type
				if default == null and type != TYPE_NIL and type != TYPE_OBJECT:
					converter.error = ("'%s' must be given, since a later argument is" % arg_name)
					return values
				values.append(default)
		_:
			converter.error = "'args' must be an object of named arguments or an array"
			return values
	if !converter.error and values.size() < n_required:
		var missing := PackedStringArray()
		for i in range(values.size(), n_required):
			var arg_info: Dictionary = arg_infos[i]
			var arg_name: String = arg_info.name
			missing.append(arg_name)
		converter.error = "missing argument(s): %s" % ", ".join(missing)
	return values


func _describe_declaration(declaration: Declaration, full: bool, enums: Dictionary) -> Dictionary:
	var script := declaration.source_script
	var entry := {"class": String(declaration.class_name_)}
	var description := docs.get_class_doc(script, full)
	if description:
		entry["description"] = description
	entry["surface"] = "user" if ClassDB.is_parent_class(script.get_instance_base_type(),
			&"Control") else "test"
	var methods := {}
	for method in declaration.methods:
		var info: Dictionary = declaration.method_infos.get(method, {})
		if !info:
			continue
		var method_entry := {}
		var doc := docs.get_member_doc(script, method)
		if doc:
			method_entry["description"] = doc
		var args := []
		var arg_infos: Array = info.get("args", [])
		var defaults: Array = info.get("default_args", [])
		var n_required := arg_infos.size() - defaults.size()
		for i in arg_infos.size():
			var arg_info: Dictionary = arg_infos[i]
			var arg := {"name": arg_info.name, "type": converter.get_type_name(arg_info)}
			if i >= n_required:
				arg["optional"] = true
				var default: Variant = defaults[i - n_required]
				if default != null:
					arg["default"] = converter.to_json(default, arg_info)
			_note_enum(arg_info, enums)
			args.append(arg)
		method_entry["args"] = args
		var return_info: Dictionary = info.get("return", {})
		method_entry["returns"] = converter.get_type_name(return_info)
		_note_enum(return_info, enums)
		methods[String(method)] = method_entry
	if methods:
		entry["methods"] = methods
	var properties := {}
	for property in declaration.properties:
		var info: Dictionary = declaration.property_infos.get(property, {})
		var property_entry := {"type": converter.get_type_name(info)}
		var doc := docs.get_member_doc(script, property)
		if doc:
			property_entry["description"] = doc
		_note_enum(info, enums)
		properties[String(property)] = property_entry
	if properties:
		entry["properties"] = properties
	if declaration.enums:
		var enum_names: Array[String] = []
		for enum_name in declaration.enums:
			var display_name := converter.get_enum_display_name(enum_name)
			enum_names.append(display_name)
			enums[display_name] = declaration.enums[enum_name]
		entry["enums"] = enum_names
	return entry


# Classes no object exposes directly but a declared property holds, such as an
# orbit a body holds; a client reaches them with an address's "via".
# Classes no object exposes directly but a declared member holds or returns,
# such as the orbit a body holds or the views a view manager holds. A client
# reads them as values, and addresses one held in a property with "via".
func _describe_reachable_classes(described: Dictionary[Script, bool], classes: Dictionary,
		full: bool, enums: Dictionary) -> void:
	var queue: Array[Script] = described.keys()
	var i := 0
	while i < queue.size():
		var declaration := get_declaration(queue[i])
		i += 1
		var reaches: Array[Array] = [] # [info, path]
		for property in declaration.properties:
			reaches.append([declaration.property_infos.get(property, {}),
					"%s.%s" % [declaration.class_name_, property]])
		for method in declaration.methods:
			var method_info: Dictionary = declaration.method_infos.get(method, {})
			reaches.append([method_info.get("return", {}),
					"%s.%s()" % [declaration.class_name_, method]])
		for reach in reaches:
			var info: Dictionary = reach[0]
			var path: String = reach[1]
			var script := get_global_script(_get_held_class(info))
			if !script:
				continue
			var reached := get_declaration(script)
			if !reached.participates():
				continue
			var reached_name := String(reached.class_name_)
			if described.has(script):
				var reached_entry: Dictionary = classes.get(reached_name, {})
				var paths: Array = reached_entry.get("reached_by", [])
				if reached_entry.has("reached_by") and !paths.has(path):
					paths.append(path)
				continue
			described[script] = true
			queue.append(script)
			var entry := _describe_declaration(reached, full, enums)
			entry["reached_by"] = [path]
			classes[reached_name] = entry


# The class of an object, or of a typed array's elements or a typed dictionary's
# values, that [param info] describes; &"" if none.
func _get_held_class(info: Dictionary) -> StringName:
	var hint: int = info.get("hint", PROPERTY_HINT_NONE)
	var hint_string: String = info.get("hint_string", "")
	match info.get("type", TYPE_NIL):
		TYPE_OBJECT:
			return info.get("class_name", &"")
		TYPE_ARRAY:
			if hint == PROPERTY_HINT_ARRAY_TYPE:
				return StringName(hint_string)
		TYPE_DICTIONARY:
			if hint == PROPERTY_HINT_DICTIONARY_TYPE and hint_string.count(";") == 1:
				return StringName(hint_string.get_slice(";", 1))
	return &""


# Every enum value name the declaring chain defines, for an integer argument
# given by name.
func _get_enum_names(declaration: Declaration) -> Dictionary:
	var names := {}
	for enum_name in declaration.enums:
		names.merge(declaration.enums[enum_name], true)
	return names


func _note_enum(info: Dictionary, enums: Dictionary) -> void:
	var usage: int = info.get("usage", 0)
	if !(usage & PROPERTY_USAGE_CLASS_IS_ENUM):
		return
	var enum_name: String = info.get("class_name", "")
	var display_name := converter.get_enum_display_name(enum_name)
	if !enums.has(display_name):
		enums[display_name] = converter.get_enum(StringName(enum_name))


func _is_numbered_constant(constant_name: String, base: String) -> bool:
	if !constant_name.begins_with(base):
		return false
	var suffix := constant_name.substr(base.length())
	return suffix.is_empty() or suffix.is_valid_int()


func _is_enum(value: Variant) -> bool:
	if typeof(value) != TYPE_DICTIONARY:
		return false
	var dict: Dictionary = value
	if dict.is_empty():
		return false
	for key: Variant in dict:
		if typeof(key) != TYPE_STRING and typeof(key) != TYPE_STRING_NAME:
			return false
		if typeof(dict[key]) != TYPE_INT:
			return false
	return true


func _append_names(names: Array[StringName], value: Variant) -> void:
	if typeof(value) != TYPE_ARRAY:
		return
	var array: Array = value
	for item: Variant in array:
		var item_name := StringName(str(item))
		if !names.has(item_name):
			names.append(item_name)


func _to_strings(names: Array[StringName]) -> Array[String]:
	var result: Array[String] = []
	for item in names:
		result.append(String(item))
	return result


func _error(code: int, message: String) -> Dictionary:
	return {"_error": {"code": code, "message": message}}


func _on_tree_changed(_node: Node) -> void:
	_dirty = true


## What one script's chain declares. Built once per script.
class Declaration:
	var source_script: Script
	var class_name_: StringName # most-derived global class name, else the native class
	var methods: Array[StringName] = []
	var properties: Array[StringName] = []
	var key: Array[StringName] = []
	var lifecycle := {}
	var has_available := false
	var has_objects := false
	var method_infos: Dictionary[StringName, Dictionary] = {}
	var property_infos: Dictionary[StringName, Dictionary] = {}
	var enums: Dictionary[StringName, Dictionary] = {} # enum constants of the chain, "Class.Enum"

	func participates() -> bool:
		return !methods.is_empty() or !properties.is_empty() or !key.is_empty() or has_objects
