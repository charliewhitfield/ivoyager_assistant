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

## Singleton [IVAssistantServer] is TCP server providing a JSON-RPC-style
## interface for AI testing and accessibility.
##
## The server knows Godot, not the project. A project's classes declare what a
## client may read and call ([IVAssistantAutomation]); Godot-level tools and
## widget operation are built in; project-specific helpers come from
## [IVAssistantTestSuite] instances registered in the
## [code][assistant_test_suites][/code] config section. See SPECIFICATION.md for
## protocol and configuration details.

# Error codes
const ERR_UNKNOWN_METHOD := 1
const ERR_INVALID_PARAMS := 2
const ERR_NOT_FOUND := 3
const ERR_NOT_STARTED := 4
const ERR_NOT_ALLOWED := 5

## Protocol version reported in [code]get_project_info[/code]. Bumped when
## requests or responses change.
const ASSISTANT_PROTOCOL_VERSION := 4

## Methods the server itself handles, before any suite.
const SERVER_METHODS: Array[String] = ["get_project_info", "describe", "get", "call", "quit"]

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
var _pending_config: ConfigFile # held between _ready and _on_initialized
var _automation: IVAssistantAutomation
var _lifecycle_object: Object # declares AUTOMATION_LIFECYCLE, or null
var _quit_method := &""

## Project-supplied readiness condition. Polled each frame after the lifecycle
## "started" signal fires; the readiness gate opens after this returns true for
## [member _min_ready_delay_frames] consecutive frames. Default predicate is
## trivially true (gate opens after the frame delay alone). See SPECIFICATION.md §7.4.
var ready_predicate := func() -> bool: return true

# Test suite infrastructure
var _godot_tools: IVAssistantGodotTools
var _widgets: IVAssistantWidgets
var _builtin_suites: Array[IVAssistantTestSuite] = []
var _test_suites: Array[IVAssistantTestSuite] = []
var _method_to_suite: Dictionary[String, IVAssistantTestSuite] = {} # active dispatch table
var _method_owner: Dictionary[String, IVAssistantTestSuite] = {} # all registered, even if gated
var _method_summaries: Dictionary[String, String] = {} # manifest summaries
# Deprecated requirement-token gating (SPECIFICATION.md §7.5)
var _method_requirements: Dictionary[String, PackedStringArray] = {}
var _gated_methods: Dictionary[String, PackedStringArray] = {} # unmet tokens per gated method


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	if OS.has_feature("web"):
		# TCPServer isn't available on web, so the server can't listen here. Web
		# accessibility support will need a different transport (e.g. WebSocket)
		# when added; until then stay inert rather than erroring on a doomed listen().
		set_process(false)
		return
	var config := IVAssistantPluginUtils.get_ivoyager_config(
			"res://addons/ivoyager_assistant/ivoyager_assistant.cfg")
	var enabled: bool = config.get_value("assistant", "enabled", true)
	var debug_only: bool = config.get_value("assistant", "debug_only", true)
	if !enabled:
		print("IVAssistantServer: disabled by config")
		set_process(false)
		return
	if debug_only and !OS.is_debug_build():
		print("IVAssistantServer: skipping (not a debug build)")
		set_process(false)
		return
	_port = config.get_value("assistant", "port", 29071)
	_apply_cmdline_user_args()
	_assistant_name = config.get_value("assistant", "assistant_name", "")
	_min_ready_delay_frames = config.get_value("assistant", "min_ready_delay_frames", 10)
	var context_file: String = config.get_value("assistant", "context_file", "")
	if context_file:
		_context_content = _load_context_file(context_file)
	_pending_config = config
	_automation = IVAssistantAutomation.new(get_tree())
	# Other autoloads may follow this one; the lifecycle declaration is read once all are in.
	_connect_lifecycle.call_deferred()


## Whether the readiness gate is open. True after the lifecycle "started"
## signal has fired AND [member ready_predicate] has returned true for
## [member _min_ready_delay_frames] consecutive frames. Test suites can call
## this for per-method gating where suite-level [method IVAssistantTestSuite.requires_sim_started]
## is too coarse.
func is_ready() -> bool:
	return _is_ready


## The object discovery and dispatch behind [code]describe[/code], [code]get[/code]
## and [code]call[/code], for suites that take an address.
func get_automation() -> IVAssistantAutomation:
	return _automation


## The built-in Godot-level tools, for a suite that extends one of them.
func get_godot_tools() -> IVAssistantGodotTools:
	return _godot_tools


func _connect_lifecycle() -> void:
	var found := _automation.find_lifecycle()
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
	# Suites load here so a suite's is_applicable() sees an initialized project.
	_load_builtin_suites()
	_load_test_suites(_pending_config)
	_pending_config = null
	_refresh_gating()
	_tcp_server = TCPServer.new()
	var err := _tcp_server.listen(_port, "127.0.0.1")
	if err != OK:
		push_error("IVAssistantServer: failed to listen on port %d (error %d)" % [_port, err])
		return
	_listening = true
	print("IVAssistantServer: listening on 127.0.0.1:%d" % _port)


func _on_started() -> void:
	_sim_started = true
	for suite in _builtin_suites + _test_suites:
		suite._on_simulator_started()
	_refresh_gating()


func _on_stopping() -> void:
	_sim_started = false
	_is_ready = false
	_ready_delay_counter = -1
	for suite in _builtin_suites + _test_suites:
		suite._on_about_to_free()


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
	_automation.invalidate()
	if typeof(parsed) == TYPE_ARRAY:
		var requests: Array = parsed
		if requests.is_empty():
			return JSON.stringify(_error_response(null, ERR_INVALID_PARAMS, "Empty batch"))
		var responses := []
		for request: Variant in requests:
			responses.append(_handle_one(request))
		return JSON.stringify(responses)
	return JSON.stringify(_handle_one(parsed))


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
		"describe":
			return _describe(params)
		"get":
			return _automation.get_properties(params)
		"call":
			return _automation.call_method(params)
		"quit":
			return _quit(params)

	var suite: IVAssistantTestSuite = _method_to_suite.get(method)
	if suite:
		if suite.requires_sim_started() and !_is_ready:
			return {"_error": {"code": ERR_NOT_STARTED,
					"message": "Simulator not ready"}}
		return suite.dispatch(method, params)

	return {"_error": {"code": ERR_UNKNOWN_METHOD,
			"message": "Unknown method: %s" % method}}


# ===========================================================================
# Built-in methods
# ===========================================================================

func _get_project_info() -> Dictionary:
	var project_name: String = ProjectSettings.get_setting("application/config/name", "")
	var project_version: String = ProjectSettings.get_setting("application/config/version", "")

	# Capabilities = server methods + suite methods + suite feature flags (e.g.
	# "gui_inspection"). A declared member is described by "describe", not here.
	var capability_set: Dictionary = {}
	for method_name in SERVER_METHODS:
		capability_set[method_name] = true
	for method_name: String in _method_to_suite:
		capability_set[method_name] = true
	for suite in _builtin_suites + _test_suites:
		for cap: String in suite.get_capabilities():
			capability_set[cap] = true
	var capabilities: Array[String] = []
	for cap: String in capability_set:
		capabilities.append(cap)
	capabilities.sort()

	var methods: Dictionary = {}
	for method_name in _method_to_suite:
		var entry: Dictionary = {}
		if _method_summaries.has(method_name):
			entry["summary"] = _method_summaries[method_name]
		methods[method_name] = entry

	var gated_out: Array[Dictionary] = []
	for method_name in _gated_methods:
		gated_out.append({"method": method_name, "unmet": _gated_methods[method_name]})

	var display_name := _assistant_name if _assistant_name else project_name

	var result: Dictionary = {
		"assistant_protocol_version": ASSISTANT_PROTOCOL_VERSION,
		"project_name": project_name,
		"project_version": project_version,
		"assistant_name": display_name,
		"started": _sim_started,
		"ready": _is_ready,
		"capabilities": capabilities,
		"methods": methods,
		"gated_out": gated_out,
		"process_id": OS.get_process_id(),
		"port": _port,
	}
	for suite in _test_suites:
		suite.add_project_info(result)
	if _instance_id:
		result["instance_id"] = _instance_id
	if _context_content:
		result["context"] = _context_content
	return result


# A client's whole context: declared objects, plus the user surface (the
# widgets a user can see now, and input actions) unless asked to leave them out.
func _describe(params: Dictionary) -> Dictionary:
	var result := _automation.describe(params)
	if params.get("widgets", true):
		var widgets: Dictionary = _widgets.list_widgets({"visible_only": true})
		result["widgets"] = widgets.get("widgets", [])
	if params.get("actions", true):
		var actions: Dictionary = _godot_tools.dispatch("list_actions", {})
		result["actions"] = actions.get("actions", {})
	return result


func _quit(params: Dictionary) -> Dictionary:
	var force: bool = params.get("force", false)
	# Deferred, so the response goes out first.
	if _quit_method:
		_lifecycle_object.call_deferred(_quit_method, force)
	else:
		get_tree().quit.call_deferred()
	return {"ok": true}


# ===========================================================================
# Test suite loading
# ===========================================================================

func _load_builtin_suites() -> void:
	_godot_tools = IVAssistantGodotTools.new()
	_widgets = IVAssistantWidgets.new()
	for suite: IVAssistantTestSuite in [_godot_tools, _widgets]:
		suite._init_test_suite(self)
		_builtin_suites.append(suite)
		_register_suite_methods(suite, "built-in")


func _load_test_suites(config: ConfigFile) -> void:
	var section := "assistant_test_suites"
	if !config.has_section(section):
		return
	for key in config.get_section_keys(section):
		var path: Variant = config.get_value(section, key)
		if path == null or path == "":
			continue
		var path_str: String = path
		var script: GDScript = load(path_str)
		if !script:
			push_error("IVAssistantServer: failed to load test suite '%s': %s" % [key, path_str])
			continue
		var suite: IVAssistantTestSuite = script.new()
		suite._init_test_suite(self)
		if !suite.is_applicable():
			print("IVAssistantServer: gated suite '%s' (not applicable)" % key)
			continue
		_test_suites.append(suite)
		_register_suite_methods(suite, key)
		print("IVAssistantServer: loaded test suite '%s'" % key)


# A configured suite may replace a built-in suite's method (a deprecated suite
# extends one that way), never a server method.
func _register_suite_methods(suite: IVAssistantTestSuite, key: String) -> void:
	var summaries: Dictionary = suite.get_method_summaries()
	var requirements: Dictionary = suite.get_method_requirements()
	for method_name in suite.get_method_names():
		if SERVER_METHODS.has(method_name):
			push_warning("IVAssistantServer: suite '%s' can't replace server method '%s'"
					% [key, method_name])
			continue
		if _method_owner.has(method_name) and !_builtin_suites.has(_method_owner[method_name]):
			push_warning("IVAssistantServer: method '%s' registered by multiple test suites; '%s' wins"
					% [method_name, key])
		_method_owner[method_name] = suite
		_method_requirements[method_name] = _normalize_requirements(
				requirements.get(method_name, []), method_name, key)
		var summary_var: Variant = summaries.get(method_name)
		if typeof(summary_var) == TYPE_STRING:
			var summary: String = summary_var
			_method_summaries[method_name] = summary


# Drops tokens outside the vocabulary, with an error; the method is then
# available as if its author named no restriction.
func _normalize_requirements(value: Variant, method_name: String,
		suite_key: String) -> PackedStringArray:
	var out := PackedStringArray()
	if typeof(value) != TYPE_ARRAY:
		return out
	var arr: Array = value
	for item: Variant in arr:
		if typeof(item) != TYPE_STRING:
			push_error("IVAssistantServer: requirement on method '%s' (suite '%s') must be a string, got %s"
					% [method_name, suite_key, type_string(typeof(item))])
			continue
		var token: String = item
		if !IVAssistantRequirementTokens.KNOWN_TOKENS.has(token):
			push_error("IVAssistantServer: unknown requirement token '%s' on method '%s' (suite '%s')"
					% [token, method_name, suite_key])
			continue
		out.append(token)
	return out


# Rebuilds the dispatch table from every registered method's requirement tokens,
# at suite load and on the lifecycle "started" signal.
func _refresh_gating() -> void:
	_method_to_suite.clear()
	_gated_methods.clear()
	for method_name in _method_owner:
		var unmet := PackedStringArray()
		for token in _method_requirements[method_name]:
			if !IVAssistantRequirementTokens.evaluate(token, _sim_started):
				unmet.append(token)
		if unmet.is_empty():
			_method_to_suite[method_name] = _method_owner[method_name]
		else:
			_gated_methods[method_name] = unmet


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
