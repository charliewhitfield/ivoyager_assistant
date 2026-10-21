# automation_docs.gd
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
class_name IVAssistantDocs
extends RefCounted

## Reads the [code]##[/code] doc comments that describe declared members.
##
## No runtime API exposes doc comments, so they are parsed from source. An
## export ships scripts without comments; there the digest that
## [IVAssistantExportPlugin] adds to the export stands in for the source
## (SPECIFICATION.md §11.5). Text comes back plain, BBCode reduced to Markdown.

## Where an export carries the digest of the declaring scripts' doc comments.
const DIGEST_PATH := "res://addons/ivoyager_assistant/automation_docs.json"

static var _declaration_regex: RegEx
static var _trailing_doc_regex: RegEx
static var _bbcode_regexes: Array[RegEx] = []
static var _bbcode_replacements: Array[String] = []

var _digest: Dictionary # loaded on first need
var _has_digest := false
var _parsed: Dictionary[String, Dictionary] = {} # script path -> parse_source() result


static func _static_init() -> void:
	_declaration_regex = RegEx.create_from_string(
			r"^(?:@\w+(?:\([^)]*\))?\s+)*(?:static\s+)?(func|var|const|signal|enum|class)\s+(\w+)")
	_trailing_doc_regex = RegEx.create_from_string(r"\s##\s?(.*)$")
	var pairs := [
		[r"\[codeblock[^\]]*\]\n?", "\n```\n"],
		[r"\n?\[/codeblock\]", "\n```\n"],
		[r"\[/?code\]", "`"],
		[r"\[br\]\s*", "\n"],
		[r"\[url=([^\]]+)\]([^\[]*)\[/url\]", "$2 ($1)"],
		[r"\[url\]([^\[]*)\[/url\]", "$1"],
		[r"\[method ([^\]]+)\]", "`$1()`"],
		[r"\[(?:param|member|signal|constant|enum|annotation|theme_item) ([^\]]+)\]", "`$1`"],
		[r"\[/?(?:b|i|u|s|kbd|center)\]", ""],
		[r"\[/?(?:color|font)[^\]]*\]", ""],
		[r"\[([A-Z]\w*)\]", "$1"],
		[r"\[lb\]", "["],
		[r"\[rb\]", "]"],
		[r"[ \t]+\n", "\n"],
		[r"\n{3,}", "\n\n"],
	]
	for pair: Array in pairs:
		var pattern: String = pair[0]
		var replacement: String = pair[1]
		_bbcode_regexes.append(RegEx.create_from_string(pattern))
		_bbcode_replacements.append(replacement)


## Returns the class description of [param script], or of its nearest
## documented base. Only the title (the first paragraph) unless [param full].
func get_class_doc(script: Script, full := false) -> String:
	while script:
		var docs := get_script_docs(script)
		var key := "class" if full else "title"
		var text: String = docs.get(key, "")
		if text:
			return text
		script = script.get_base_script()
	return ""


## Returns the doc comment of [param member] from the script in [param script]'s
## chain that declares it.
func get_member_doc(script: Script, member: StringName) -> String:
	while script:
		var members: Dictionary = get_script_docs(script).get("members", {})
		if members.has(member):
			return members[member]
		script = script.get_base_script()
	return ""


## Returns [method parse_source]'s result for [param script], from its source or,
## in an export, from the digest.
func get_script_docs(script: Script) -> Dictionary:
	var path := script.resource_path
	if _parsed.has(path):
		return _parsed[path]
	var docs := {}
	if script.has_source_code():
		docs = parse_source(script.source_code)
	else:
		docs = _get_digest().get(path, {})
	_parsed[path] = docs
	return docs


## Parses GDScript [param source] into [code]{"title": String, "class": String,
## "members": {name: String}}[/code]: the class description, its first paragraph,
## and each top-level member's doc comment, as plain text.
static func parse_source(source: String) -> Dictionary:
	var class_lines := PackedStringArray()
	var members := {}
	var block := PackedStringArray()
	var past_header := false
	var past_members := false
	for line in source.split("\n"):
		line = line.strip_edges(false, true)
		if line.begins_with("##"):
			block.append(line)
			continue
		if line.is_empty():
			# The first block standing alone after the header is the class description.
			if block and past_header and !past_members and !class_lines:
				class_lines = block.duplicate()
			block.clear()
			continue
		if line.begins_with("#") or line.begins_with("\t") or line.begins_with(" "):
			if !line.begins_with("#"):
				block.clear()
			continue
		if line.begins_with("class_name ") or line.begins_with("extends ") \
				or line.begins_with("@tool") or line.begins_with("@abstract") \
				or line.begins_with("@icon"):
			past_header = true
			block.clear()
			continue
		var found := _declaration_regex.search(line)
		if !found:
			if !line.begins_with("@"): # an annotation may sit between a doc and its member
				block.clear()
			continue
		past_members = true
		var text := _join_doc_lines(block)
		if !text:
			var trailing := _trailing_doc_regex.search(line)
			if trailing:
				text = trailing.get_string(1)
		if text:
			members[found.get_string(2)] = to_plain(text)
		block.clear()
	var title_lines := PackedStringArray()
	for line in class_lines:
		if line.strip_edges() == "##":
			break
		title_lines.append(line)
	return {
		"title": to_plain(_join_doc_lines(title_lines)),
		"class": to_plain(_join_doc_lines(class_lines)),
		"members": members,
	}


## Reduces Godot's doc-comment BBCode to plain text with Markdown code spans.
static func to_plain(bbcode: String) -> String:
	var text := bbcode
	for i in _bbcode_regexes.size():
		text = _bbcode_regexes[i].sub(text, _bbcode_replacements[i], true)
	return text.strip_edges()


## Builds the export digest: [method parse_source] for each script in
## [param paths], keyed by path.
static func build_digest(paths: PackedStringArray) -> Dictionary:
	var scripts := {}
	for path in paths:
		var source := FileAccess.get_file_as_string(path)
		if source:
			scripts[path] = parse_source(source)
	return {"scripts": scripts}


# Comment lines join with spaces, as in Godot's own docs; a codeblock keeps its lines.
static func _join_doc_lines(lines: PackedStringArray) -> String:
	var text := ""
	var in_codeblock := false
	for line in lines:
		var content := line.substr(2)
		if content.begins_with(" "):
			content = content.substr(1)
		if text:
			text += "\n" if in_codeblock else " "
		text += content
		if content.contains("[codeblock"):
			in_codeblock = true
		if content.contains("[/codeblock]"):
			in_codeblock = false
	return text


func _get_digest() -> Dictionary:
	if _has_digest:
		return _digest
	_has_digest = true
	_digest = {}
	if !FileAccess.file_exists(DIGEST_PATH):
		return _digest
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DIGEST_PATH))
	if typeof(parsed) == TYPE_DICTIONARY:
		var digest: Dictionary = parsed
		var scripts: Variant = digest.get("scripts")
		if typeof(scripts) == TYPE_DICTIONARY:
			_digest = scripts
	return _digest
