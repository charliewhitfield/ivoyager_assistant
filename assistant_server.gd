# assistant_server.gd
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
extends Node

## Singleton [IVAssistantServer] is a TCP server providing a JSON-RPC-style
## interface for AI-assisted testing.
##
## The server knows Godot, not the project. A project's classes declare what a
## client may read and call ([IVAssistantAutomation]); Godot-level tools
## ([IVAssistantGodotTools]) and widget operation ([IVAssistantWidgets]) are
## built in, and [IVAssistantDispatcher] answers each request. It runs only in
## debug builds unless configured otherwise, and never on the web. See
## SPECIFICATION.md for protocol and configuration details.

# Error codes
const ERR_UNKNOWN_METHOD := 1
const ERR_INVALID_PARAMS := 2
const ERR_NOT_FOUND := 3
const ERR_NOT_ALLOWED := 5

## Protocol version reported in [code]get_project_info[/code]. Bumped when
## requests or responses change.
const ASSISTANT_PROTOCOL_VERSION := 5

## Methods the server itself handles; [IVAssistantDispatcher] handles the rest.
const SERVER_METHODS: Array[String] = ["get_project_info", "quit"]

## Lifecycle roles a project may map to its own signals and methods in
## [code]AUTOMATION_LIFECYCLE[/code] (SPECIFICATION.md §11.6).
const LIFECYCLE_SIGNALS: Array[StringName] = [&"initialized", &"started", &"stopping",
		&"quitting"]

var _tcp_server: TCPServer
var _clients: Array[StreamPeerTCP] = []
var _buffers: Dictionary = {} # StreamPeerTCP -> PackedByteArray
var _port: int
var _instance_id: String # echoed in get_project_info; lets a launcher find its own process
var _assistant_name: String
var _context_content: String
var _listening := false # TCP server is active
var _sim_started := false # lifecycle "started" has fired (or the project declares no lifecycle)
var _is_ready := false # readiness gate is open
var _ready_delay_counter := -1 # -1 = predicate not yet true; 0..N = countdown
## Consecutive frames [member ready_predicate] must hold true before
## [member _is_ready] flips. Configured via [code]ivoyager_assistant.cfg[/code].
var _min_ready_delay_frames := 10
var _dispatcher: IVAssistantDispatcher
var _lifecycle_object: Object # declares AUTOMATION_LIFECYCLE, or null
var _quit_method := &""

## Project-supplied readiness condition. Polled each frame after the lifecycle
## "started" signal fires; the readiness gate opens after this returns true for
## [member _min_ready_delay_frames] consecutive frames. Default predicate is
## trivially true (gate opens after the frame delay alone). See SPECIFICATION.md §7.4.
var ready_predicate := func() -> bool: return true


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	if OS.has_feature("web"):
		# No TCPServer on the web: stay inert rather than error on a doomed listen().
		set_process(false)
		return
	var config := IVAssistantPluginUtils.get_ivoyager_config(
			"res://addons/ivoyager_assistant/ivoyager_assistant.cfg")
	var enabled: bool = config.get_value("assistant_server", "enabled", true)
	var debug_only: bool = config.get_value("assistant_server", "debug_only", true)
	if !enabled:
		print("IVAssistantServer: disabled by config")
		set_process(false)
		return
	if debug_only and !OS.is_debug_build():
		print("IVAssistantServer: skipping (not a debug build)")
		set_process(false)
		return
	_port = config.get_value("assistant_server", "port", 29071)
	_apply_cmdline_user_args()
	_assistant_name = config.get_value("assistant", "assistant_name", "")
	_min_ready_delay_frames = config.get_value("assistant_server", "min_ready_delay_frames", 10)
	var context_file: String = config.get_value("assistant_server", "context_file", "")
	if context_file:
		_context_content = _load_context_file(context_file)
	_dispatcher = IVAssistantDispatcher.new(get_tree())
	# Other autoloads may follow this one; the lifecycle declaration is read once all are in.
	_connect_lifecycle.call_deferred()


## Whether the readiness gate is open, which [code]get_project_info[/code]
## reports as [code]ready[/code]. True after the lifecycle "started" signal has
## fired AND [member ready_predicate] has returned true for
## [member _min_ready_delay_frames] consecutive frames.
func is_ready() -> bool:
	return _is_ready


func _connect_lifecycle() -> void:
	var found := _dispatcher.automation.find_lifecycle()
	_lifecycle_object = found[0]
	var lifecycle: Dictionary = found[1]
	if !_lifecycle_object:
		# A project without lifecycle declarations is ready as soon as it runs.
		_on_initialized()
		_on_started()
		return
	var handlers: Dictionary[StringName, Callable] = {
		&"initialized": _on_initialized,
		&"started": _on_started,
		&"stopping": _on_stopping,
		&"quitting": _on_quitting,
	}
	for role in LIFECYCLE_SIGNALS:
		var signal_name: StringName = lifecycle.get(role, &"")
		if !signal_name:
			continue
		if !_lifecycle_object.has_signal(signal_name):
			push_error("IVAssistantServer: AUTOMATION_LIFECYCLE names missing signal '%s'"
					% signal_name)
			continue
		var handler := handlers[role]
		var arg_count := _get_signal_arg_count(_lifecycle_object, signal_name)
		if arg_count:
			handler = handler.unbind(arg_count)
		_lifecycle_object.connect(signal_name, handler)
	_quit_method = lifecycle.get(&"quit", &"")
	if !lifecycle.has(&"initialized"):
		_on_initialized()


func _on_initialized() -> void:
	_tcp_server = TCPServer.new()
	var err := _tcp_server.listen(_port, "127.0.0.1")
	if err != OK:
		push_error("IVAssistantServer: failed to listen on port %d (error %d)" % [_port, err])
		return
	_listening = true
	print("IVAssistantServer: listening on 127.0.0.1:%d" % _port)


func _on_started() -> void:
	_sim_started = true


func _on_stopping() -> void:
	_sim_started = false
	_is_ready = false
	_ready_delay_counter = -1


func _on_quitting() -> void:
	_shutdown()


func _shutdown() -> void:
	if _tcp_server:
		_tcp_server.stop()
		_tcp_server = null
	for client in _clients:
		client.disconnect_from_host()
	_clients.clear()
	_buffers.clear()
	_listening = false
	_sim_started = false
	_is_ready = false
	_ready_delay_counter = -1


func _process(_delta: float) -> void:
	if !_listening:
		return

	# Evaluate readiness gate. Once flipped, stays flipped until reset by
	# _on_stopping or _shutdown.
	if _sim_started and !_is_ready:
		if ready_predicate.call():
			if _ready_delay_counter < 0:
				_ready_delay_counter = 0
			elif _ready_delay_counter >= _min_ready_delay_frames:
				_is_ready = true
			else:
				_ready_delay_counter += 1
		else:
			_ready_delay_counter = -1

	# Accept new connections
	while _tcp_server.is_connection_available():
		var peer := _tcp_server.take_connection()
		if peer:
			_clients.append(peer)
			_buffers[peer] = PackedByteArray()

	# Process each client
	var to_remove: Array[int] = []
	for i in _clients.size():
		var client := _clients[i]
		client.poll()

		var status := client.get_status()
		if status != StreamPeerTCP.STATUS_CONNECTED:
			if status == StreamPeerTCP.STATUS_NONE or status == StreamPeerTCP.STATUS_ERROR:
				to_remove.append(i)
			continue

		var available := client.get_available_bytes()
		if available <= 0:
			continue

		var data := client.get_data(available)
		if data[0] != OK:
			continue

		var buf: PackedByteArray = _buffers[client]
		var received: PackedByteArray = data[1]
		buf.append_array(received)
		_buffers[client] = buf

		# Extract complete lines
		_process_buffer(client)

	# Remove disconnected clients (reverse order)
	for i in range(to_remove.size() - 1, -1, -1):
		var client := _clients[to_remove[i]]
		_buffers.erase(client)
		_clients.remove_at(to_remove[i])


func _process_buffer(client: StreamPeerTCP) -> void:
	var buf: PackedByteArray = _buffers[client]
	while true:
		var newline_pos := -1
		for j in buf.size():
			if buf[j] == 10: # '\n'
				newline_pos = j
				break
		if newline_pos == -1:
			break

		var line_bytes := buf.slice(0, newline_pos)
		buf = buf.slice(newline_pos + 1)
		_buffers[client] = buf

		var line := line_bytes.get_string_from_utf8().strip_edges()
		if line.is_empty():
			continue

		var response := _handle_request(line)
		var response_bytes := (response + "\n").to_utf8_buffer()
		client.put_data(response_bytes)


# One line holds a request or a JSON-RPC 2.0 batch array, answered in order.
func _handle_request(line: String) -> String:
	var parsed: Variant = JSON.parse_string(line)
	var response: Variant
	if typeof(parsed) == TYPE_ARRAY:
		var requests: Array = parsed
		if requests.is_empty():
			response = _error_response(null, ERR_INVALID_PARAMS, "Empty batch")
		else:
			var responses := []
			for request: Variant in requests:
				responses.append(_handle_one(request))
			response = responses
	else:
		response = _handle_one(parsed)
	_dispatcher.release()
	return JSON.stringify(response)


func _handle_one(parsed: Variant) -> Dictionary:
	if typeof(parsed) != TYPE_DICTIONARY:
		return _error_response(null, ERR_INVALID_PARAMS, "Invalid JSON")
	var request: Dictionary = parsed
	var id: Variant = request.get("id")
	if typeof(id) == TYPE_FLOAT:
		var id_number: float = id
		if id_number == roundf(id_number):
			id = int(id_number)
	var method: Variant = request.get("method")
	var params: Variant = request.get("params", {})

	if typeof(method) != TYPE_STRING:
		return _error_response(id, ERR_INVALID_PARAMS, "Missing or invalid 'method'")
	if params != null and typeof(params) != TYPE_DICTIONARY:
		return _error_response(id, ERR_INVALID_PARAMS, "'params' must be an object")

	var method_str: String = method
	var p: Dictionary = params if params != null else {}
	var result: Variant = _dispatch(method_str, p)

	if result is Dictionary:
		var result_dict: Dictionary = result
		if result_dict.has("_error"):
			var err_info: Dictionary = result_dict["_error"]
			var err_code: int = err_info["code"]
			var err_msg: String = err_info["message"]
			return _error_response(id, err_code, err_msg)

	var response := {}
	if id != null:
		response["id"] = id
	response["result"] = result
	return response


func _error_response(id: Variant, code: int, message: String) -> Dictionary:
	var response := {}
	if id != null:
		response["id"] = id
	response["error"] = {"code": code, "message": message}
	return response


func _dispatch(method: String, params: Dictionary) -> Variant:
	match method:
		"get_project_info":
			return _get_project_info()
		"quit":
			return _quit(params)
	return _dispatcher.dispatch(method, params)


# ===========================================================================
# Built-in methods
# ===========================================================================

func _get_project_info() -> Dictionary:
	var project_name: String = ProjectSettings.get_setting("application/config/name", "")
	var project_version: String = ProjectSettings.get_setting("application/config/version", "")

	# A declared member is described by "describe", not here.
	var capabilities: Array[String] = []
	capabilities.append_array(SERVER_METHODS)
	capabilities.append_array(IVAssistantDispatcher.get_methods())
	capabilities.sort()
	var display_name := _assistant_name if _assistant_name else project_name

	var result: Dictionary = {
		"assistant_protocol_version": ASSISTANT_PROTOCOL_VERSION,
		"project_name": project_name,
		"project_version": project_version,
		"assistant_name": display_name,
		"started": _sim_started,
		"ready": _is_ready,
		"capabilities": capabilities,
		"process_id": OS.get_process_id(),
		"port": _port,
	}
	if _instance_id:
		result["instance_id"] = _instance_id
	if _context_content:
		result["context"] = _context_content
	return result


func _quit(params: Dictionary) -> Dictionary:
	var force: bool = params.get("force", false)
	# Deferred, so the response goes out first.
	if _quit_method:
		_lifecycle_object.call_deferred(_quit_method, force)
	else:
		get_tree().quit.call_deferred()
	return {"ok": true}


func _load_context_file(path: String) -> String:
	if !FileAccess.file_exists(path):
		push_warning("IVAssistantServer: context file not found: %s" % path)
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if !file:
		push_warning("IVAssistantServer: failed to open context file: %s" % path)
		return ""
	return file.get_as_text()


func _get_signal_arg_count(object: Object, signal_name: StringName) -> int:
	for info in object.get_signal_list():
		if info.name == signal_name:
			var args: Array = info.args
			return args.size()
	return 0


# Command-line user args (after "--") override config, so one machine can run several
# instances of a project at once. See SPECIFICATION.md §7.3.
func _apply_cmdline_user_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--assistant-port="):
			var value := arg.trim_prefix("--assistant-port=")
			if !value.is_valid_int():
				push_error("IVAssistantServer: bad %s" % arg)
				continue
			_port = value.to_int()
		elif arg.begins_with("--assistant-instance="):
			_instance_id = arg.trim_prefix("--assistant-instance=")
