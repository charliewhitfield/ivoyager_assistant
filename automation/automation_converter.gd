# automation_converter.gd
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
class_name IVAssistantConverter
extends RefCounted

## Converts between JSON values and the typed values of declared members.
##
## Type information comes from Godot's own property and method lists, so no
## class is known here. The JSON forms are listed in SPECIFICATION.md §11.4.
## A failed conversion returns null and sets [member error]; the caller clears
## it before the next conversion.

## Depth to which a returned object without a key is expanded into its declared
## properties. Guards against reference cycles.
const MAX_OBJECT_DEPTH := 3

## Message of the last failed conversion, or "".
var error := ""

var _automation_ref: WeakRef # IVAssistantAutomation, which holds this
var _variant_types: Dictionary[String, int] = {} # type_string() -> Variant.Type
var _enums: Dictionary[StringName, Dictionary] = {} # "Class.Enum" -> {name: value}; {} if unresolved


func _init(automation: IVAssistantAutomation) -> void:
	_automation_ref = weakref(automation)
	for type in TYPE_MAX:
		_variant_types[type_string(type)] = type


# *****************************************************************************
# JSON -> typed

## Converts [param value] to the type [param info] describes (a property or
## argument dictionary from Godot's lists). [param label] names the value in
## an error message.
func from_json(value: Variant, info: Dictionary, label: String) -> Variant:
	var type: int = info.get("type", TYPE_NIL)
	var usage: int = info.get("usage", 0)
	var class_name_: StringName = info.get("class_name", &"")
	if type == TYPE_NIL:
		return _variant_from_json(value)
	if type == TYPE_INT and usage & PROPERTY_USAGE_CLASS_IS_ENUM:
		return _enum_from_json(value, class_name_, label)
	if type == TYPE_OBJECT:
		if value == null:
			return null
		var object := _get_automation().resolve_for_class(value, class_name_)
		if !object:
			error = "%s: %s" % [label, _get_automation().error]
		return object
	if type == TYPE_ARRAY:
		return _array_from_json(value, info, label)
	if type == TYPE_DICTIONARY:
		return _dictionary_from_json(value, info, label)
	return _builtin_from_json(value, type, label)


func _builtin_from_json(value: Variant, type: int, label: String) -> Variant:
	var value_type := typeof(value)
	if value_type == TYPE_STRING and type != TYPE_STRING and type != TYPE_STRING_NAME \
			and type != TYPE_NODE_PATH and type != TYPE_FLOAT and type != TYPE_COLOR:
		# Any type Godot can print can come as its own text, e.g. "Basis(...)".
		var text: String = value
		var parsed: Variant = str_to_var(text)
		if typeof(parsed) == type:
			return parsed
		return _fail("%s: '%s' is not a %s" % [label, text, type_string(type)])
	match type:
		TYPE_BOOL:
			if value_type == TYPE_BOOL:
				return value
		TYPE_INT:
			if value_type == TYPE_FLOAT or value_type == TYPE_INT:
				var number: float = value
				if number == roundf(number):
					return int(number)
		TYPE_FLOAT:
			return _float_from_json(value, label)
		TYPE_STRING:
			if value_type == TYPE_STRING:
				return value
		TYPE_STRING_NAME:
			if value_type == TYPE_STRING:
				var text: String = value
				return StringName(text)
		TYPE_NODE_PATH:
			if value_type == TYPE_STRING:
				var text: String = value
				return NodePath(text)
		TYPE_COLOR:
			if value_type == TYPE_STRING:
				var html: String = value
				if Color.html_is_valid(html):
					return Color.html(html)
			elif value_type == TYPE_ARRAY:
				var floats := _floats_from_json(value, 3, 4, label)
				if floats.size() == 3:
					return Color(floats[0], floats[1], floats[2])
				if floats.size() == 4:
					return Color(floats[0], floats[1], floats[2], floats[3])
				return null
		TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_VECTOR3, TYPE_VECTOR3I, TYPE_VECTOR4, TYPE_VECTOR4I, \
				TYPE_QUATERNION, TYPE_PLANE, TYPE_RECT2, TYPE_RECT2I, TYPE_AABB:
			return _vector_from_json(value, type, label)
		TYPE_BASIS:
			return _basis_from_json(value, label)
		TYPE_TRANSFORM3D:
			if value_type == TYPE_DICTIONARY:
				var dict: Dictionary = value
				var basis_var: Variant = _basis_from_json(dict.get("basis"), label + ".basis")
				var origin_var: Variant = _vector_from_json(dict.get("origin"), TYPE_VECTOR3,
						label + ".origin")
				if error:
					return null
				var basis: Basis = basis_var
				var origin: Vector3 = origin_var
				return Transform3D(basis, origin)
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, \
				TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, \
				TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_VECTOR4_ARRAY, \
				TYPE_PACKED_COLOR_ARRAY:
			return _packed_from_json(value, type, label)
		_:
			return _fail("%s: a %s can't be given in JSON" % [label, type_string(type)])
	return _fail("%s must be %s" % [label, describe_json_form(type)])


# JSON has no integers, so a whole number becomes an int: the common intent, and
# what a declared method taking a Variant can coerce back if it needs a float.
func _variant_from_json(value: Variant) -> Variant:
	match typeof(value):
		TYPE_FLOAT:
			var number: float = value
			if number == roundf(number) and absf(number) < 9.0e15:
				return int(number)
			return number
		TYPE_ARRAY:
			var array: Array = value
			var result := []
			for item: Variant in array:
				result.append(_variant_from_json(item))
			return result
		TYPE_DICTIONARY:
			var dict: Dictionary = value
			var result := {}
			for key: Variant in dict:
				result[key] = _variant_from_json(dict[key])
			return result
	return value


func _float_from_json(value: Variant, label: String) -> Variant:
	match typeof(value):
		TYPE_FLOAT, TYPE_INT:
			var number: float = value
			return number
		TYPE_STRING:
			match value:
				"inf":
					return INF
				"-inf":
					return -INF
				"nan":
					return NAN
	return _fail("%s must be a number (or \"inf\", \"-inf\", \"nan\")" % label)


func _floats_from_json(value: Variant, min_size: int, max_size: int, label: String
		) -> Array[float]:
	var floats: Array[float] = []
	if typeof(value) != TYPE_ARRAY:
		_fail("%s must be an array of %s numbers" % [label, _count_text(min_size, max_size)])
		return floats
	var array: Array = value
	if array.size() < min_size or array.size() > max_size:
		_fail("%s must have %s elements" % [label, _count_text(min_size, max_size)])
		return floats
	for i in array.size():
		var number: Variant = _float_from_json(array[i], "%s[%d]" % [label, i])
		if error:
			floats.clear()
			return floats
		floats.append(number)
	return floats


func _vector_from_json(value: Variant, type: int, label: String) -> Variant:
	var size: int
	match type:
		TYPE_VECTOR2, TYPE_VECTOR2I:
			size = 2
		TYPE_VECTOR3, TYPE_VECTOR3I:
			size = 3
		TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_QUATERNION, TYPE_PLANE, TYPE_RECT2, TYPE_RECT2I:
			size = 4
		TYPE_AABB:
			size = 6
	var f := _floats_from_json(value, size, size, label)
	if error:
		return null
	match type:
		TYPE_VECTOR2:
			return Vector2(f[0], f[1])
		TYPE_VECTOR2I:
			return Vector2i(int(f[0]), int(f[1]))
		TYPE_VECTOR3:
			return Vector3(f[0], f[1], f[2])
		TYPE_VECTOR3I:
			return Vector3i(int(f[0]), int(f[1]), int(f[2]))
		TYPE_VECTOR4:
			return Vector4(f[0], f[1], f[2], f[3])
		TYPE_VECTOR4I:
			return Vector4i(int(f[0]), int(f[1]), int(f[2]), int(f[3]))
		TYPE_QUATERNION:
			return Quaternion(f[0], f[1], f[2], f[3])
		TYPE_PLANE:
			return Plane(f[0], f[1], f[2], f[3])
		TYPE_RECT2:
			return Rect2(f[0], f[1], f[2], f[3])
		TYPE_RECT2I:
			return Rect2i(int(f[0]), int(f[1]), int(f[2]), int(f[3]))
	return AABB(Vector3(f[0], f[1], f[2]), Vector3(f[3], f[4], f[5]))


func _basis_from_json(value: Variant, label: String) -> Variant:
	var columns: Array = value if typeof(value) == TYPE_ARRAY else []
	if columns.size() != 3:
		return _fail("%s must be 3 column vectors [[x], [y], [z]]" % label)
	var x_var: Variant = _vector_from_json(columns[0], TYPE_VECTOR3, label + "[0]")
	var y_var: Variant = _vector_from_json(columns[1], TYPE_VECTOR3, label + "[1]")
	var z_var: Variant = _vector_from_json(columns[2], TYPE_VECTOR3, label + "[2]")
	if error:
		return null
	var x: Vector3 = x_var
	var y: Vector3 = y_var
	var z: Vector3 = z_var
	return Basis(x, y, z)


func _packed_from_json(value: Variant, type: int, label: String) -> Variant:
	if typeof(value) != TYPE_ARRAY:
		return _fail("%s must be an array" % label)
	var element_type: int
	match type:
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY:
			element_type = TYPE_INT
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			element_type = TYPE_FLOAT
		TYPE_PACKED_STRING_ARRAY:
			element_type = TYPE_STRING
		TYPE_PACKED_VECTOR2_ARRAY:
			element_type = TYPE_VECTOR2
		TYPE_PACKED_VECTOR3_ARRAY:
			element_type = TYPE_VECTOR3
		TYPE_PACKED_VECTOR4_ARRAY:
			element_type = TYPE_VECTOR4
		TYPE_PACKED_COLOR_ARRAY:
			element_type = TYPE_COLOR
	var array: Array = value
	var elements := []
	for i in array.size():
		elements.append(_builtin_from_json(array[i], element_type, "%s[%d]" % [label, i]))
		if error:
			return null
	return type_convert(elements, type)


func _array_from_json(value: Variant, info: Dictionary, label: String) -> Variant:
	if typeof(value) != TYPE_ARRAY:
		return _fail("%s must be an array" % label)
	var array: Array = value
	var hint: int = info.get("hint", PROPERTY_HINT_NONE)
	var hint_string: String = info.get("hint_string", "")
	if hint != PROPERTY_HINT_ARRAY_TYPE or !hint_string:
		return _variant_from_json(array)
	var element_info := _info_from_hint_string(hint_string)
	var elements := []
	for i in array.size():
		elements.append(from_json(array[i], element_info, "%s[%d]" % [label, i]))
		if error:
			return null
	var element_type: int = element_info.type
	var element_class: StringName = element_info.get("class_name", &"")
	var element_script := _get_automation().get_global_script(element_class)
	return Array(elements, element_type, _get_native_class(element_class, element_script),
			element_script)


func _dictionary_from_json(value: Variant, info: Dictionary, label: String) -> Variant:
	if typeof(value) != TYPE_DICTIONARY:
		return _fail("%s must be an object" % label)
	var dict: Dictionary = value
	var hint: int = info.get("hint", PROPERTY_HINT_NONE)
	var hint_string: String = info.get("hint_string", "")
	if hint != PROPERTY_HINT_DICTIONARY_TYPE or hint_string.count(";") != 1:
		return _variant_from_json(dict)
	var key_info := _info_from_hint_string(hint_string.get_slice(";", 0))
	var value_info := _info_from_hint_string(hint_string.get_slice(";", 1))
	var result := {}
	for key: Variant in dict:
		var typed_key: Variant = from_json(key, key_info, "%s key" % label)
		var typed_value: Variant = from_json(dict[key], value_info, "%s[%s]" % [label, key])
		if error:
			return null
		result[typed_key] = typed_value
	var key_type: int = key_info.type
	var value_type: int = value_info.type
	var key_class: StringName = key_info.get("class_name", &"")
	var value_class: StringName = value_info.get("class_name", &"")
	var key_script := _get_automation().get_global_script(key_class)
	var value_script := _get_automation().get_global_script(value_class)
	return Dictionary(result, key_type, _get_native_class(key_class, key_script), key_script,
			value_type, _get_native_class(value_class, value_script), value_script)


func _enum_from_json(value: Variant, enum_name: StringName, label: String) -> Variant:
	var enumeration := get_enum(enum_name)
	match typeof(value):
		TYPE_FLOAT, TYPE_INT:
			var number: float = value
			if number == roundf(number):
				return int(number)
		TYPE_STRING:
			var key: String = value
			if enumeration.has(key):
				return enumeration[key]
			return _fail("%s: '%s' is not in %s (%s)" % [label, key, enum_name,
					", ".join(enumeration.keys())])
		TYPE_ARRAY: # flags
			var array: Array = value
			var flags := 0
			for item: Variant in array:
				var flag: Variant = _enum_from_json(item, enum_name, label)
				if error:
					return null
				var flag_value: int = flag
				flags |= flag_value
			return flags
	return _fail("%s must be a name in %s, an array of them (flags), or an integer" % [label,
			enum_name])


# A hint string names an element type: "int", "StringName", "IVBody", or Godot's
# encoded "<type>/<hint>:<hint_string>".
func _info_from_hint_string(hint_string: String) -> Dictionary:
	var type_text := hint_string
	if hint_string.contains(":"):
		type_text = hint_string.get_slice(":", 0).get_slice("/", 0)
		if type_text.is_valid_int():
			return {"type": type_text.to_int()}
	if _variant_types.has(type_text):
		return {"type": _variant_types[type_text]}
	return {"type": TYPE_OBJECT, "class_name": StringName(type_text)}


# *****************************************************************************
# typed -> JSON

## Converts [param value] to JSON. [param info] (optional) supplies enum names
## for an int; [param depth] guards expansion of objects.
func to_json(value: Variant, info := {}, depth := 0) -> Variant:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_STRING:
			return value
		TYPE_INT:
			var usage: int = info.get("usage", 0)
			if usage & PROPERTY_USAGE_CLASS_IS_ENUM:
				var enum_name: StringName = info.get("class_name", &"")
				var enumeration := get_enum(enum_name)
				var key: Variant = enumeration.find_key(value)
				if key != null:
					return key
			return value
		TYPE_FLOAT:
			var number: float = value
			return float_to_json(number)
		TYPE_STRING_NAME, TYPE_NODE_PATH:
			return str(value)
		TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4, TYPE_QUATERNION, TYPE_PLANE:
			var result := []
			for i in _component_count(typeof(value)):
				var component: float = value[i]
				result.append(float_to_json(component))
			return result
		TYPE_VECTOR2I, TYPE_VECTOR3I, TYPE_VECTOR4I:
			var result := []
			for i in _component_count(typeof(value)):
				var component: int = value[i]
				result.append(component)
			return result
		TYPE_RECT2, TYPE_RECT2I:
			var rect: Rect2 = value
			return [float_to_json(rect.position.x), float_to_json(rect.position.y),
					float_to_json(rect.size.x), float_to_json(rect.size.y)]
		TYPE_AABB:
			var aabb: AABB = value
			return to_json(aabb.position) + to_json(aabb.size)
		TYPE_BASIS:
			var basis: Basis = value
			return [to_json(basis.x), to_json(basis.y), to_json(basis.z)]
		TYPE_TRANSFORM3D:
			var transform: Transform3D = value
			return {"basis": to_json(transform.basis), "origin": to_json(transform.origin)}
		TYPE_TRANSFORM2D:
			var transform: Transform2D = value
			return [to_json(transform.x), to_json(transform.y), to_json(transform.origin)]
		TYPE_COLOR:
			var color: Color = value
			return "#" + color.to_html(color.a < 1.0)
		TYPE_ARRAY:
			var array: Array = value
			var element_info := {}
			if array.is_typed():
				element_info = {"type": array.get_typed_builtin()}
			var result := []
			for item: Variant in array:
				result.append(to_json(item, element_info, depth))
			return result
		TYPE_DICTIONARY:
			var dict: Dictionary = value
			var result := {}
			for key: Variant in dict:
				result[str(key)] = to_json(dict[key], {}, depth)
			return result
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, \
				TYPE_PACKED_STRING_ARRAY:
			return type_convert(value, TYPE_ARRAY)
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, \
				TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_VECTOR4_ARRAY, TYPE_PACKED_COLOR_ARRAY:
			var result := []
			for item: Variant in value:
				result.append(to_json(item))
			return result
		TYPE_OBJECT:
			var object: Object = value
			if !is_instance_valid(object):
				return null
			return _get_automation().object_to_json(object, depth)
	return str(value)


## Non-finite floats as text, since JSON has no form for them.
static func float_to_json(value: float) -> Variant:
	if is_finite(value):
		return value
	if is_nan(value):
		return "nan"
	return "inf" if value > 0.0 else "-inf"


# *****************************************************************************
# types

## Returns the name-to-value map of enum [param enum_name], a [code]Class.Enum[/code]
## name as Godot reports it (a global script class, a script path or a native
## class), or an empty dictionary if it can't be found.
func get_enum(enum_name: StringName) -> Dictionary:
	if _enums.has(enum_name):
		return _enums[enum_name]
	var enumeration := {}
	var split := String(enum_name).rfind(".")
	if split != -1:
		var owner_name := String(enum_name).left(split)
		var short_name := String(enum_name).substr(split + 1)
		var script: Script = _get_automation().get_global_script(owner_name)
		if !script and owner_name.begins_with("res://"):
			script = load(owner_name)
		if script:
			var constant: Variant = script.get_script_constant_map().get(short_name)
			if typeof(constant) == TYPE_DICTIONARY:
				enumeration = constant
		elif ClassDB.class_exists(owner_name):
			for constant_name in ClassDB.class_get_enum_constants(owner_name, short_name):
				enumeration[constant_name] = ClassDB.class_get_integer_constant(owner_name,
						constant_name)
	_enums[enum_name] = enumeration
	return enumeration


## A readable type name for [param info]: "float", "Array[StringName]",
## "IVBody", an enum's "Class.Enum", "Variant" or "void".
func get_type_name(info: Dictionary) -> String:
	var type: int = info.get("type", TYPE_NIL)
	var usage: int = info.get("usage", 0)
	var class_name_: String = info.get("class_name", "")
	var hint: int = info.get("hint", PROPERTY_HINT_NONE)
	var hint_string: String = info.get("hint_string", "")
	if usage & PROPERTY_USAGE_CLASS_IS_ENUM:
		return get_enum_display_name(class_name_)
	match type:
		TYPE_NIL:
			return "Variant" if usage & PROPERTY_USAGE_NIL_IS_VARIANT else "void"
		TYPE_OBJECT:
			return class_name_ if class_name_ else "Object"
		TYPE_ARRAY:
			if hint == PROPERTY_HINT_ARRAY_TYPE and hint_string:
				return "Array[%s]" % get_type_name(_info_from_hint_string(hint_string))
		TYPE_DICTIONARY:
			if hint == PROPERTY_HINT_DICTIONARY_TYPE and hint_string.count(";") == 1:
				return "Dictionary[%s, %s]" % [
						get_type_name(_info_from_hint_string(hint_string.get_slice(";", 0))),
						get_type_name(_info_from_hint_string(hint_string.get_slice(";", 1)))]
	return type_string(type)


## [param enum_name] with a script path replaced by the script's class name.
func get_enum_display_name(enum_name: String) -> String:
	if !enum_name.begins_with("res://"):
		return enum_name
	var split := enum_name.rfind(".")
	var script: Script = load(enum_name.left(split))
	var global_name := _get_automation().get_class_name_of_script(script) if script else &""
	if !global_name:
		return enum_name
	return String(global_name) + enum_name.substr(split)


## How a value of [param type] is written in JSON.
func describe_json_form(type: int) -> String:
	match type:
		TYPE_BOOL:
			return "a boolean"
		TYPE_INT:
			return "an integer"
		TYPE_FLOAT:
			return "a number"
		TYPE_STRING, TYPE_STRING_NAME, TYPE_NODE_PATH:
			return "a string"
		TYPE_COLOR:
			return "an HTML color string such as \"#ff8800\" or [r, g, b, a]"
	return "a %s" % type_string(type)


func _get_automation() -> IVAssistantAutomation:
	return _automation_ref.get_ref()


# Typed containers take a script class's native base, with the script beside it.
func _get_native_class(class_name_: StringName, script: Script) -> StringName:
	if script:
		return script.get_instance_base_type()
	return class_name_


func _component_count(type: int) -> int:
	match type:
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return 2
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return 3
	return 4


func _count_text(min_size: int, max_size: int) -> String:
	if min_size == max_size:
		return str(min_size)
	return "%d to %d" % [min_size, max_size]


func _fail(message: String) -> Variant:
	if !error:
		error = message
	return null
