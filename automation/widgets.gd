# widgets.gd
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
class_name IVAssistantWidgets
extends RefCounted

## Built-in widget listing and operation: the user surface.
##
## A widget is a [Control] a user operates. Each Godot family is operated the
## way that fires everything a user's operation fires, so the widget's own
## handler runs; a composite widget declares its own value interface instead.
## Meaning comes from Godot's accessibility properties, identity from a
## declared [code]AUTOMATION_KEY[/code]. See SPECIFICATION.md §4.3 and §11.7.

## The methods these tools handle, by their protocol names.
const METHODS: Array[String] = ["list_widgets", "operate_widget"]

const ERR_UNKNOWN_METHOD := 1
const ERR_INVALID_PARAMS := 2
const ERR_NOT_FOUND := 3
const ERR_NOT_ALLOWED := 5

const VALUE_GETTER := &"get_automation_value"
const VALUE_SETTER := &"set_automation_value"
const OPTIONS_GETTER := &"get_automation_options"

## Widget families, as clients see them.
const FAMILY_COMPOSITE := "composite"
const FAMILY_BUTTON := "button"
const FAMILY_OPTION := "option"
const FAMILY_RANGE := "range"
const FAMILY_TABS := "tabs"
const FAMILY_FOLDABLE := "foldable"
const FAMILY_LINE_EDIT := "line_edit"
const FAMILY_TEXT_EDIT := "text_edit"

var _tree: SceneTree
var _automation: IVAssistantAutomation
var _class_counts: Dictionary[StringName, int] = {} # widgets per class, from _collect_widgets()


func _init(tree: SceneTree, automation: IVAssistantAutomation) -> void:
	_tree = tree
	_automation = automation


## Handles one of [constant METHODS]. Returns its result, or an
## [code]_error[/code] Dictionary.
func dispatch(method: String, params: Dictionary) -> Variant:
	match method:
		"list_widgets":
			return list_widgets(params)
		"operate_widget":
			return _operate_widget(params)
	return {"_error": {"code": ERR_UNKNOWN_METHOD,
			"message": "Unknown method: %s" % method}}


## [code]list_widgets[/code]: every widget under [code]root[/code], visible or
## not unless [code]visible_only[/code].
func list_widgets(params: Dictionary) -> Dictionary:
	var root_path: String = params.get("root", "/root")
	var root := _tree.root.get_node_or_null(NodePath(root_path))
	if !root:
		return {"_error": {"code": ERR_NOT_FOUND, "message": "No node at '%s'" % root_path}}
	var visible_only: bool = params.get("visible_only", false)
	var widgets := _collect_widgets(root)
	var openers := _get_openers(widgets)
	var entries := []
	for widget in widgets:
		if visible_only and !widget.is_visible_in_tree():
			continue
		entries.append(_describe_widget(widget, openers))
	return {"widgets": entries, "count": entries.size()}


func _operate_widget(params: Dictionary) -> Variant:
	var widgets := _collect_widgets(_tree.root)
	var widget_or_err: Variant = _resolve_widget(params.get("widget"), widgets)
	if widget_or_err is Dictionary:
		return widget_or_err
	var widget: Control = widget_or_err
	var address: Variant = _get_address(widget)
	if !widget.is_visible_in_tree():
		var openers := _get_openers(widgets)
		var opener := _find_opener(widget, openers)
		var hint := ""
		if opener:
			hint = "; operate %s to show it" % JSON.stringify(_get_address(opener))
		return {"_error": {"code": ERR_NOT_ALLOWED,
				"message": "Widget %s is hidden%s" % [JSON.stringify(address), hint]}}
	if !_is_enabled(widget):
		return {"_error": {"code": ERR_NOT_ALLOWED,
				"message": "Widget %s is disabled" % JSON.stringify(address)}}
	var family := _get_family(widget)
	var result: Variant
	match family:
		FAMILY_COMPOSITE:
			result = _operate_composite(widget, params)
		FAMILY_BUTTON:
			result = _operate_button(widget, params)
		FAMILY_OPTION:
			result = _operate_option(widget, params)
		FAMILY_RANGE:
			result = _operate_range(widget, params)
		FAMILY_TABS:
			result = _operate_tabs(widget, params)
		FAMILY_FOLDABLE:
			result = _operate_foldable(widget, params)
		FAMILY_LINE_EDIT:
			result = _operate_line_edit(widget, params)
		FAMILY_TEXT_EDIT:
			result = _operate_text_edit(widget, params)
	if result != null: # an _error
		return result
	return {"ok": true, "widget": address, "state": _get_state(widget)}


# *****************************************************************************
# operation

func _operate_composite(widget: Control, params: Dictionary) -> Variant:
	if !params.has("value"):
		return _param_error("Give 'value' (see the widget's state and options)")
	if !widget.has_method(VALUE_SETTER):
		return {"_error": {"code": ERR_NOT_ALLOWED, "message": "This widget can't be set"}}
	var declaration := _automation.get_declaration_of(widget)
	var info: Dictionary = declaration.method_infos.get(VALUE_SETTER, {})
	var arg_infos: Array = info.get("args", [{}])
	var arg_info: Dictionary = arg_infos[0] if arg_infos else {}
	_automation.converter.error = ""
	var value: Variant = _automation.converter.from_json(params["value"], arg_info, "value")
	if _automation.converter.error:
		var message := _automation.converter.error
		_automation.converter.error = ""
		return _param_error(message)
	var accepted: Variant = widget.call(VALUE_SETTER, value)
	if accepted == false:
		return {"_error": {"code": ERR_NOT_ALLOWED,
				"message": "The widget refused value %s (see its options)" % JSON.stringify(
				params["value"])}}
	return null


# Delivers ui_accept to the focused button, the keyboard user's path, which
# fires everything a click does; no script call does (SPECIFICATION.md §11.7).
func _operate_button(widget: Control, params: Dictionary) -> Variant:
	var button: BaseButton = widget
	if params.has("pressed"):
		var pressed_var: Variant = params.pressed
		if typeof(pressed_var) != TYPE_BOOL:
			return _param_error("'pressed' must be a boolean")
		if !button.toggle_mode:
			return _param_error("'pressed' applies only to a toggle button")
		var pressed: bool = pressed_var
		if button.button_pressed == pressed:
			return null
		if !pressed and button.button_group and !button.button_group.allow_unpress:
			return {"_error": {"code": ERR_NOT_ALLOWED,
					"message": "A grouped button is released by pressing another in its group"}}
	_press(button)
	return null


func _operate_option(widget: Control, params: Dictionary) -> Variant:
	var option_button: OptionButton = widget
	var index := _find_item(params.get("item"), option_button.item_count,
			option_button.get_item_text)
	if index < 0:
		return _param_error("'item' must be an index or the text of one of: %s"
				% ", ".join(_get_item_texts(option_button.item_count, option_button.get_item_text)))
	if option_button.is_item_disabled(index):
		return {"_error": {"code": ERR_NOT_ALLOWED, "message": "Item %d is disabled" % index}}
	option_button.select(index)
	option_button.item_selected.emit(index)
	return null


func _operate_range(widget: Control, params: Dictionary) -> Variant:
	var range_control: Range = widget
	var value_var: Variant = params.get("value")
	if typeof(value_var) != TYPE_FLOAT and typeof(value_var) != TYPE_INT:
		return _param_error("'value' must be a number in [%s, %s]" % [range_control.min_value,
				range_control.max_value])
	var value: float = value_var
	range_control.value = value
	return null


func _operate_tabs(widget: Control, params: Dictionary) -> Variant:
	var tab_container: TabContainer = widget
	var index := _find_item(params.get("tab"), tab_container.get_tab_count(),
			tab_container.get_tab_title)
	if index < 0:
		return _param_error("'tab' must be an index or the title of one of: %s"
				% ", ".join(_get_item_texts(tab_container.get_tab_count(),
				tab_container.get_tab_title)))
	if tab_container.is_tab_disabled(index) or tab_container.is_tab_hidden(index):
		return {"_error": {"code": ERR_NOT_ALLOWED, "message": "Tab %d is not available" % index}}
	tab_container.current_tab = index
	return null


func _operate_foldable(widget: Control, params: Dictionary) -> Variant:
	var foldable: FoldableContainer = widget
	var folded_var: Variant = params.get("folded")
	if typeof(folded_var) != TYPE_BOOL:
		return _param_error("'folded' must be a boolean")
	var folded: bool = folded_var
	if folded == foldable.folded:
		return null
	if folded:
		foldable.fold()
	else:
		foldable.expand()
	return null


func _operate_line_edit(widget: Control, params: Dictionary) -> Variant:
	var line_edit: LineEdit = widget
	var text_var: Variant = params.get("text")
	var submit: bool = params.get("submit", false)
	if typeof(text_var) != TYPE_STRING and !(text_var == null and submit):
		return _param_error("'text' must be a string")
	if text_var != null:
		var text: String = text_var
		line_edit.text = text
		line_edit.text_changed.emit(text)
	if submit:
		line_edit.text_submitted.emit(line_edit.text)
	return null


func _operate_text_edit(widget: Control, params: Dictionary) -> Variant:
	var text_edit: TextEdit = widget
	var text_var: Variant = params.get("text")
	if typeof(text_var) != TYPE_STRING:
		return _param_error("'text' must be a string")
	var text: String = text_var
	text_edit.text = text
	text_edit.text_changed.emit()
	return null


# The button may refuse focus, so it takes it for the press and gives it back.
func _press(button: BaseButton) -> void:
	var viewport := button.get_viewport()
	var previous_focus := viewport.gui_get_focus_owner()
	var focus_mode := button.focus_mode
	button.focus_mode = Control.FOCUS_ALL
	button.grab_focus()
	var press := InputEventAction.new()
	press.action = &"ui_accept"
	press.pressed = true
	viewport.push_input(press)
	var release := InputEventAction.new()
	release.action = &"ui_accept"
	release.pressed = false
	viewport.push_input(release)
	if !is_instance_valid(button):
		return
	button.focus_mode = focus_mode
	if is_instance_valid(previous_focus) and previous_focus.is_visible_in_tree():
		previous_focus.grab_focus()
	elif button.has_focus():
		button.release_focus()


# *****************************************************************************
# description

func _describe_widget(widget: Control, openers: Dictionary[Node, Control]) -> Dictionary:
	var entry := {
		"widget": _get_address(widget),
		"class": String(_automation.get_object_class_name(widget)),
		"family": _get_family(widget),
		"name": _get_widget_name(widget),
	}
	var description := widget.accessibility_description
	if !description:
		description = widget.atr(widget.tooltip_text)
	var widget_name: String = entry.name
	if description and !widget_name.ends_with(description):
		entry["description"] = description
	entry["state"] = _get_state(widget)
	entry["enabled"] = _is_enabled(widget)
	entry["visible"] = widget.is_visible_in_tree()
	var controls := []
	for path in widget.accessibility_controls_nodes:
		var controlled := widget.get_node_or_null(path)
		if controlled:
			controls.append(str(controlled.get_path()))
	if controls:
		entry["controls"] = controls
	if !widget.is_visible_in_tree():
		var opener := _find_opener(widget, openers)
		if opener:
			entry["opened_by"] = _get_address(opener)
	return entry


func _get_state(widget: Control) -> Dictionary:
	match _get_family(widget):
		FAMILY_COMPOSITE:
			var state := {"value": _to_json(widget.call(VALUE_GETTER))}
			if widget.has_method(OPTIONS_GETTER):
				state["options"] = _to_json(widget.call(OPTIONS_GETTER))
			return state
		FAMILY_BUTTON:
			var button: BaseButton = widget
			if button.toggle_mode:
				return {"pressed": button.button_pressed}
			return {}
		FAMILY_OPTION:
			var option_button: OptionButton = widget
			return {
				"selected": option_button.selected,
				"items": _get_item_texts(option_button.item_count, option_button.get_item_text),
			}
		FAMILY_RANGE:
			var range_control: Range = widget
			return {
				"value": IVAssistantConverter.float_to_json(range_control.value),
				"min": IVAssistantConverter.float_to_json(range_control.min_value),
				"max": IVAssistantConverter.float_to_json(range_control.max_value),
				"step": range_control.step,
			}
		FAMILY_TABS:
			var tab_container: TabContainer = widget
			return {
				"current_tab": tab_container.current_tab,
				"tabs": _get_item_texts(tab_container.get_tab_count(), tab_container.get_tab_title),
			}
		FAMILY_FOLDABLE:
			var foldable: FoldableContainer = widget
			return {"folded": foldable.folded, "title": foldable.title}
		FAMILY_LINE_EDIT:
			var line_edit: LineEdit = widget
			return {"text": line_edit.text}
		FAMILY_TEXT_EDIT:
			var text_edit: TextEdit = widget
			return {"text": text_edit.text}
	return {}


# Translated, as a user sees it: what labels the widget (a HUDs row), then what
# the widget names itself, else its text unless that is a symbol ("||", "+"),
# else its tooltip.
func _get_widget_name(widget: Control) -> String:
	var label_texts := PackedStringArray()
	for path in widget.accessibility_labeled_by_nodes:
		var label := widget.get_node_or_null(path)
		if label is Control:
			var label_control: Control = label
			var label_name := _get_text(label_control)
			if label_name:
				label_texts.append(label_name)
	var own_name := widget.accessibility_name # translated by its getter
	if !own_name:
		own_name = _get_text(widget)
	if !own_name or !_has_letters(own_name):
		var tooltip := widget.atr(widget.tooltip_text)
		if tooltip:
			own_name = tooltip
	if label_texts:
		return "%s: %s" % [" ".join(label_texts), own_name] if own_name else " ".join(label_texts)
	return own_name if own_name else String(widget.name)


func _get_text(control: Control) -> String:
	if control.accessibility_name:
		return control.accessibility_name
	if control is FoldableContainer:
		var foldable: FoldableContainer = control
		return control.atr(foldable.title)
	if control is RichTextLabel:
		var rich_text_label: RichTextLabel = control
		return rich_text_label.get_parsed_text()
	if &"text" in control:
		var text: Variant = control.get(&"text")
		if typeof(text) == TYPE_STRING:
			var text_string: String = text
			return control.atr(text_string)
	return ""


func _has_letters(text: String) -> bool:
	for i in text.length():
		var code := text.unicode_at(i)
		if (code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122) \
				or code > 127:
			return true
	return false


func _get_family(widget: Control) -> String:
	if widget.has_method(VALUE_GETTER):
		return FAMILY_COMPOSITE
	if widget is OptionButton:
		return FAMILY_OPTION
	if widget is BaseButton:
		return FAMILY_BUTTON
	if widget is Range and !(widget is ProgressBar or widget is ScrollBar
			or widget is TextureProgressBar):
		return FAMILY_RANGE
	if widget is TabContainer:
		return FAMILY_TABS
	if widget is FoldableContainer:
		return FAMILY_FOLDABLE
	if widget is LineEdit:
		return FAMILY_LINE_EDIT
	if widget is TextEdit:
		return FAMILY_TEXT_EDIT
	return ""


func _is_enabled(widget: Control) -> bool:
	if widget is BaseButton:
		var button: BaseButton = widget
		return !button.disabled
	if widget is LineEdit:
		var line_edit: LineEdit = widget
		return line_edit.editable
	if widget is TextEdit:
		var text_edit: TextEdit = widget
		return text_edit.editable
	if widget is SpinBox:
		var spin_box: SpinBox = widget
		return spin_box.editable
	if widget is Slider:
		var slider: Slider = widget
		return slider.editable
	return true


# *****************************************************************************
# identity

# Widgets in tree order. A composite is one unit, so the controls of its own
# scene aren't widgets, though children a project adds to it are; internal
# children (a SpinBox's LineEdit) never are.
func _collect_widgets(root: Node) -> Array[Control]:
	var widgets: Array[Control] = []
	_collect_widgets_recursive(root, widgets)
	_class_counts.clear()
	for widget in widgets:
		var class_name_ := _automation.get_object_class_name(widget)
		_class_counts[class_name_] = _class_counts.get(class_name_, 0) + 1
	return widgets


func _collect_widgets_recursive(node: Node, widgets: Array[Control], composite: Control = null
		) -> void:
	if node is Control and (!composite or node.owner != composite):
		var control: Control = node
		var family := _get_family(control)
		# A control neither mouse nor keyboard reaches is inert (a layout spacer).
		var is_inert := (control.mouse_filter == Control.MOUSE_FILTER_IGNORE
				and control.focus_mode == Control.FOCUS_NONE and family != FAMILY_COMPOSITE)
		if family and !is_inert:
			widgets.append(control)
			if family == FAMILY_COMPOSITE:
				composite = control
	for child in node.get_children():
		_collect_widgets_recursive(child, widgets, composite)


# The widget whose accessibility_controls_nodes reveals each controlled node, a
# panel or a popup Window.
func _get_openers(widgets: Array[Control]) -> Dictionary[Node, Control]:
	var openers: Dictionary[Node, Control] = {}
	for widget in widgets:
		for path in widget.accessibility_controls_nodes:
			var controlled := widget.get_node_or_null(path)
			if controlled:
				openers[controlled] = widget
	return openers


func _find_opener(widget: Control, openers: Dictionary[Node, Control]) -> Control:
	var node: Node = widget
	while node:
		if openers.has(node):
			return openers[node]
		node = node.get_parent()
	return null


# A declared key, else the class when it has one widget, else the path. Valid
# after _collect_widgets().
func _get_address(widget: Control) -> Variant:
	var declaration := _automation.get_declaration_of(widget)
	var class_name_ := _automation.get_object_class_name(widget)
	if declaration and declaration.key:
		var address := {"class": String(class_name_)}
		for property in declaration.key:
			var info: Dictionary = declaration.property_infos.get(property, {})
			address[String(property)] = _automation.converter.to_json(widget.get(property), info)
		return address
	if declaration and _class_counts.get(class_name_, 0) == 1:
		return {"class": String(class_name_)}
	return {"path": str(widget.get_path())}


func _resolve_widget(address: Variant, widgets: Array[Control]) -> Variant:
	var fields := {}
	match typeof(address):
		TYPE_STRING:
			var text: String = address
			fields = {"path": text} if text.begins_with("/") else {"class": text}
		TYPE_DICTIONARY:
			fields = address
		_:
			return _param_error("'widget' must be an address: a class, {\"class\": ..., <key>: ...}"
					+ " or {\"path\": ...} (see list_widgets)")
	if fields.has("path"):
		var node := _tree.root.get_node_or_null(NodePath(str(fields.path)))
		if node is Control and widgets.has(node):
			return node
		return {"_error": {"code": ERR_NOT_FOUND, "message": "No widget at '%s'" % fields.path}}
	if !fields.has("class"):
		return _param_error("A widget address needs 'class' or 'path'")
	var class_name_ := StringName(str(fields["class"]))
	var matches: Array[Control] = []
	for widget in widgets:
		if !_automation.is_instance_of_class(widget, class_name_):
			continue
		var declaration := _automation.get_declaration_of(widget)
		var is_match := true
		for field: Variant in fields:
			if field == "class":
				continue
			var property := StringName(str(field))
			var info: Dictionary = declaration.property_infos.get(property, {}) if declaration 					else {}
			if !(property in widget) or !_automation.json_equal(
					_automation.converter.to_json(widget.get(property), info), fields[field]):
				is_match = false
				break
		if is_match:
			matches.append(widget)
	if matches.size() == 1:
		return matches[0]
	if matches.is_empty():
		return {"_error": {"code": ERR_NOT_FOUND,
				"message": "No widget matches %s (see list_widgets)" % JSON.stringify(fields)}}
	var candidates := PackedStringArray()
	for widget: Control in matches.slice(0, 10):
		candidates.append(JSON.stringify(_get_address(widget)))
	return _param_error("%d widgets match %s: %s" % [matches.size(), JSON.stringify(fields),
			", ".join(candidates)])


func _find_item(item: Variant, count: int, get_text: Callable) -> int:
	match typeof(item):
		TYPE_FLOAT, TYPE_INT:
			var number: float = item
			var index := int(number)
			if index >= 0 and index < count:
				return index
		TYPE_STRING:
			for i in count:
				if get_text.call(i) == item:
					return i
	return -1


func _get_item_texts(count: int, get_text: Callable) -> Array[String]:
	var texts: Array[String] = []
	for i in count:
		texts.append(get_text.call(i))
	return texts


func _to_json(value: Variant) -> Variant:
	return _automation.converter.to_json(value)


func _param_error(message: String) -> Dictionary:
	return {"_error": {"code": ERR_INVALID_PARAMS, "message": message}}
