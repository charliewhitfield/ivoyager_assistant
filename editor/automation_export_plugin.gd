# automation_export_plugin.gd
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
class_name IVAssistantExportPlugin
extends EditorExportPlugin

## Adds to an export what the Assistant reads at runtime: the doc comments of
## every declaring script, and the text files the config names.
##
## An export ships scripts without comments, so the descriptions
## [code]describe[/code] gives, and the user's assistant reads, would be lost.
## This parses the scripts that declare automation members, and the scripts they
## extend, into [constant IVAssistantDocs.DIGEST_PATH]. An export gets it where
## the user's assistant is enabled or the TCP server can run (see
## [code]ivoyager_assistant.cfg[/code]), not otherwise. It gets the
## assistant's [code]instructions_file[/code] where the assistant is enabled,
## and the server's [code]context_file[/code] where the server can run, since
## an export leaves out text files.


func _get_name() -> String:
	return "IVAssistantAutomationDocs"


func _export_begin(features: PackedStringArray, is_debug: bool, _path: String, _flags: int
		) -> void:
	var config := IVAssistantPluginUtils.get_ivoyager_config(
			"res://addons/ivoyager_assistant/ivoyager_assistant.cfg")
	var assistant_enabled: bool = config.get_value("assistant", "enabled", false)
	var server_enabled: bool = config.get_value("assistant_server", "enabled", true)
	var server_debug_only: bool = config.get_value("assistant_server", "debug_only", true)
	var server_runs := (server_enabled and (is_debug or !server_debug_only)
			and !features.has("web"))
	if !assistant_enabled and !server_runs:
		return
	var instructions_file: String = config.get_value("assistant", "instructions_file", "")
	var context_file: String = config.get_value("assistant_server", "context_file", "")
	if assistant_enabled:
		_add_text_file(instructions_file)
	if server_runs:
		_add_text_file(context_file)
	var tree: SceneTree = Engine.get_main_loop()
	var automation := IVAssistantAutomation.new(tree)
	var paths: Dictionary[String, bool] = {}
	for path in _find_scripts("res://"):
		var script: Script = load(path)
		if !script or !automation.script_participates(script):
			continue
		while script:
			if script.resource_path.ends_with(".gd"):
				paths[script.resource_path] = true
			script = script.get_base_script()
	var digest := IVAssistantDocs.build_digest(PackedStringArray(paths.keys()))
	add_file(IVAssistantDocs.DIGEST_PATH, JSON.stringify(digest).to_utf8_buffer(), false)
	print("IVAssistantExportPlugin: added doc comments of %d scripts" % paths.size())


func _add_text_file(path: String) -> void:
	if !path:
		return
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		push_error("IVAssistantExportPlugin: can't read '%s'" % path)
		return
	add_file(path, bytes, false)


func _find_scripts(dir_path: String) -> PackedStringArray:
	var paths := PackedStringArray()
	if FileAccess.file_exists(dir_path.path_join(".gdignore")):
		return paths
	for file_name in DirAccess.get_files_at(dir_path):
		if file_name.get_extension() == "gd":
			paths.append(dir_path.path_join(file_name))
	for subdir in DirAccess.get_directories_at(dir_path):
		if subdir.begins_with("."):
			continue
		paths.append_array(_find_scripts(dir_path.path_join(subdir)))
	return paths
