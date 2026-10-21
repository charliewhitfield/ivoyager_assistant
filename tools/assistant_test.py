#!/usr/bin/env python3
"""Generic I, Voyager test runner for the ivoyager_assistant TCP server.

Implements the full test sequence from SPECIFICATION.md section 9.3:
discover, start simulation, verify state, exercise controls and widgets,
mouse hover, save/load cycle, and quit. Tests use the members a project's
classes declare (describe, get, call) and skip gracefully when a project
lacks them.

Usage:
    python assistant_test.py                  # game already running
    python assistant_test.py --launch         # start Godot automatically
    python assistant_test.py --launch --godot PATH --project DIR
                                              # a specific build, or another project
    python assistant_test.py --skip-save      # skip save/load cycle
    python assistant_test.py --skip-hover     # skip mouse-hover identification test
    python assistant_test.py --host HOST      # custom host (default: 127.0.0.1)
    python assistant_test.py --port PORT      # custom port (default: 29071,
                                              # or a free port with --launch)
    python assistant_test.py --launch --headless  # no rendering
"""

import argparse
import json
import socket
import subprocess
import sys
import threading
import time
import uuid

from godot_executable import find_godot_executable


DEFAULT_PORT = 29071
CREATE_SUSPENDED = 0x4


def _one_processor_per_core(kernel32):
    """An affinity mask of one logical processor in each core this process
    may run on, or 0 if the processors can't be read (Windows only)."""
    import ctypes
    from ctypes import wintypes

    class ProcessorInfo(ctypes.Structure):
        _fields_ = [
            ("processor_mask", ctypes.c_size_t),
            ("relationship", ctypes.c_int),
            ("reserved", ctypes.c_ulonglong * 2),
        ]

    RELATION_PROCESSOR_CORE = 0
    kernel32.GetCurrentProcess.restype = wintypes.HANDLE
    kernel32.GetProcessAffinityMask.argtypes = [
        wintypes.HANDLE, ctypes.POINTER(ctypes.c_size_t), ctypes.POINTER(ctypes.c_size_t)]
    process_mask = ctypes.c_size_t()
    system_mask = ctypes.c_size_t()
    if not kernel32.GetProcessAffinityMask(
            kernel32.GetCurrentProcess(), ctypes.byref(process_mask), ctypes.byref(system_mask)):
        return 0
    length = wintypes.DWORD(0)
    kernel32.GetLogicalProcessorInformation(None, ctypes.byref(length))
    infos = (ProcessorInfo * (length.value // ctypes.sizeof(ProcessorInfo)))()
    if not kernel32.GetLogicalProcessorInformation(infos, ctypes.byref(length)):
        return 0
    mask = 0
    for info in infos:
        if info.relationship == RELATION_PROCESSOR_CORE:
            allowed = info.processor_mask & process_mask.value
            mask |= allowed & -allowed
    return mask


def _hold_in_job(proc, one_per_core):
    """Holds `proc`, created suspended, in a job tied to this Python process,
    then resumes it (Windows only; elsewhere returns None).

    A test script that is killed outright (a timeout, a task runner stopping
    it) never reaches its cleanup, and the Godot it launched would run on
    holding its port. A job object that kills its members when its last
    handle closes lets the OS clean up instead. With `one_per_core` the job
    also holds its members to one logical processor of each core, since
    Windows puts the busy threads of games run at once two to a core.
    Returns the job, whose handle must stay open for as long as Godot should
    live. If `proc` can't be resumed, it is killed and the error raised.
    """
    if sys.platform != "win32":
        return None
    import ctypes
    from ctypes import wintypes

    class IoCounters(ctypes.Structure):
        _fields_ = [(name, ctypes.c_ulonglong) for name in (
            "read_ops", "write_ops", "other_ops",
            "read_bytes", "write_bytes", "other_bytes")]

    class BasicLimits(ctypes.Structure):
        _fields_ = [
            ("per_process_user_time_limit", ctypes.c_int64),
            ("per_job_user_time_limit", ctypes.c_int64),
            ("limit_flags", wintypes.DWORD),
            ("minimum_working_set_size", ctypes.c_size_t),
            ("maximum_working_set_size", ctypes.c_size_t),
            ("active_process_limit", wintypes.DWORD),
            ("affinity", ctypes.c_size_t),
            ("priority_class", wintypes.DWORD),
            ("scheduling_class", wintypes.DWORD),
        ]

    class ExtendedLimits(ctypes.Structure):
        _fields_ = [
            ("basic", BasicLimits),
            ("io", IoCounters),
            ("process_memory_limit", ctypes.c_size_t),
            ("job_memory_limit", ctypes.c_size_t),
            ("peak_process_memory_used", ctypes.c_size_t),
            ("peak_job_memory_used", ctypes.c_size_t),
        ]

    JOB_OBJECT_EXTENDED_LIMIT_INFORMATION = 9
    JOB_OBJECT_LIMIT_AFFINITY = 0x10
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    ntdll = ctypes.WinDLL("ntdll")
    kernel32.CreateJobObjectW.restype = wintypes.HANDLE
    handle = wintypes.HANDLE(int(proc._handle))
    try:
        job = kernel32.CreateJobObjectW(None, None)
        limits = ExtendedLimits()
        limits.basic.limit_flags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        affinity = _one_processor_per_core(kernel32) if one_per_core else 0
        if affinity:
            limits.basic.limit_flags |= JOB_OBJECT_LIMIT_AFFINITY
            limits.basic.affinity = affinity
        ok = bool(job) and kernel32.SetInformationJobObject(
            wintypes.HANDLE(job), JOB_OBJECT_EXTENDED_LIMIT_INFORMATION,
            ctypes.byref(limits), ctypes.sizeof(limits))
        ok = ok and kernel32.AssignProcessToJobObject(wintypes.HANDLE(job), handle)
        if not ok:
            print("GodotLauncher: could not hold Godot in a job (error %d); it will"
                  " outlive a killed script and share cores" % ctypes.get_last_error())
        # Popen keeps no handle to the main thread it created suspended.
        if ntdll.NtResumeProcess(handle) != 0:
            raise OSError("GodotLauncher: could not resume the Godot it launched")
    except BaseException:
        proc.kill()
        raise
    return job


_ports_handed_out = set()
_ports_lock = threading.Lock()


def pick_free_port():
    """A localhost port nothing is listening on now, for a launched instance.

    Never the same port twice in one Python process, so launchers started
    together from several threads cannot be handed one port before any of
    their games has bound it.
    """
    with _ports_lock:
        while True:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
                probe.bind(("127.0.0.1", 0))
                port = probe.getsockname()[1]
            if port not in _ports_handed_out:
                _ports_handed_out.add(port)
                return port


# =============================================================================
# Godot launcher with output capture + leak detection
# =============================================================================

class GodotLauncher:
    """Spawn Godot with captured stdout/stderr; detect leak warnings at quit.

    For test scripts that drive Godot via the Assistant TCP server with a
    --launch-style flag. Without output capture, Godot's quit-time diagnostics
    (RID/ObjectDB/resource leak warnings) flow to a detached console on Windows
    and are invisible to the test, so leaks slip past green test runs.

    Several launchers can run at once when each is given port=0, which
    picks a free port (read it back from launcher.port); the default is the
    config's 29071. Every launch also passes an instance id, and
    check_instance() proves a connected client reached that instance and
    not another one holding the port.

    A launched Godot does not outlive the Python process that launched it,
    even when that process is killed outright (Windows). It is also held to
    one logical processor of each core (Windows), because Windows otherwise
    puts the busy threads of games run at once two to a core and each runs
    slower than it would alone; one_per_core=False leaves them where the OS
    puts them.

    Usage:
        launcher = GodotLauncher(godot_exe, project_dir, port=0)
        launcher.start()
        client = AssistantClient(port=launcher.port)
        client.connect()
        launcher.check_instance(client)
        # ... run TCP test sequence, send quit ...
        launcher.shutdown_and_report()
        if launcher.leaks:
            success = False
    """

    DEFAULT_LEAK_MARKERS = (
        "leaked at exit",
        "resources still in use at exit",
        "were leaked.",
    )

    def __init__(self, godot, project, leak_markers=None, tail_lines=30,
                 extra_args=(), port=DEFAULT_PORT, one_per_core=True):
        self.godot = godot
        self.project = project
        self.extra_args = list(extra_args)
        self.port = port or pick_free_port()
        self.one_per_core = one_per_core
        self.instance_id = uuid.uuid4().hex
        self.leak_markers = tuple(
            m.lower() for m in (leak_markers or self.DEFAULT_LEAK_MARKERS))
        self.tail_lines = tail_lines
        self._proc = None
        self._job = None
        self._captured = []
        self._reader = None
        self.leaks = []

    def start(self):
        self._proc = subprocess.Popen(
            [self.godot] + self.extra_args + ["--path", self.project, "--",
             "--assistant-port=%d" % self.port,
             "--assistant-instance=%s" % self.instance_id],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            # Godot's console wrapper starts the game as a child process at
            # once, and only a child started inside the job is held by it.
            creationflags=CREATE_SUSPENDED if sys.platform == "win32" else 0,
        )
        self._job = _hold_in_job(self._proc, self.one_per_core)
        # Daemon reader thread keeps the kernel pipe drained so long runs
        # (e.g. economy tests spanning game-years) never block on a full buffer.
        self._reader = threading.Thread(target=self._drain, daemon=True)
        self._reader.start()

    def check_instance(self, client):
        """Raises unless `client` is connected to the instance this launched."""
        info = client.call("get_project_info").get("result", {})
        if info.get("instance_id") != self.instance_id:
            raise RuntimeError(
                "port %d is served by another Godot (process %s), not the one launched;"
                " is an orphaned instance holding it?" % (self.port, info.get("process_id")))

    def _drain(self):
        try:
            for line in iter(self._proc.stdout.readline, ""):
                self._captured.append(line)
        except (ValueError, OSError):
            pass
        finally:
            try:
                self._proc.stdout.close()
            except Exception:
                pass

    def shutdown_and_report(self, wait_timeout=10):
        """Wait for Godot to exit, print output tail, populate self.leaks."""
        if not self._proc:
            return
        try:
            self._proc.wait(timeout=wait_timeout)
        except subprocess.TimeoutExpired:
            print("\nGodot did not exit within %ds; killing." % wait_timeout)
            self._proc.kill()
            self._proc.wait(timeout=5)
        if self._reader:
            self._reader.join(timeout=2)

        tail = self._captured[-self.tail_lines:]
        if tail:
            print("\n--- Godot output (last %d lines) ---" % len(tail))
            for line in tail:
                sys.stdout.write(line if line.endswith("\n") else line + "\n")
            print("--- end Godot output ---")

        self.leaks = []
        for raw in self._captured:
            line = raw.rstrip("\r\n")
            if any(marker in line.lower() for marker in self.leak_markers):
                self.leaks.append(line)

        if self.leaks:
            print("\n*** Object/resource leaks detected at quit ***")
            for line in self.leaks:
                print("  " + line)
        else:
            print("\nNo object/resource leaks detected at quit.")


# =============================================================================
# TCP Client
# =============================================================================

class AssistantError(RuntimeError):
    """An error response; `code` is one of SPECIFICATION.md section 3.3."""

    def __init__(self, code, message):
        super().__init__("[%s] %s" % (code, message))
        self.code = code


class AssistantClient:
    """TCP client for the ivoyager_assistant JSON-RPC server."""

    def __init__(self, host="127.0.0.1", port=29071, timeout=10.0):
        self.host = host
        self.port = port
        self.timeout = timeout
        self._sock = None
        self._buffer = b""
        self._request_id = 0

    def connect(self, retries=30, delay=2.0):
        for attempt in range(retries):
            try:
                self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                self._sock.settimeout(self.timeout)
                self._sock.connect((self.host, self.port))
                return
            except (ConnectionRefusedError, OSError):
                self._sock = None
                if attempt < retries - 1:
                    time.sleep(delay)
        raise ConnectionError(
            "Could not connect to %s:%d after %d attempts" % (self.host, self.port, retries)
        )

    def close(self):
        if self._sock:
            self._sock.close()
            self._sock = None

    def call(self, method, params=None):
        """Sends one request; returns the whole response, "result" or "error"."""
        self._sock.sendall((json.dumps(self._make_request(method, params)) + "\n").encode("utf-8"))
        return self._recv_response()

    def batch(self, requests):
        """Sends [(method, params), ...] as one JSON-RPC batch, executed in order in
        one frame; returns the responses in order."""
        batch = [self._make_request(method, params) for method, params in requests]
        self._sock.sendall((json.dumps(batch) + "\n").encode("utf-8"))
        return self._recv_response()

    def describe(self, **params):
        """Every declared object, class, member, widget and action
        (SPECIFICATION.md section 4.2)."""
        return self.result("describe", params)

    def get(self, address, *properties):
        """Declared properties of the object at `address` (all if none named)."""
        params = {"object": address}
        if properties:
            params["properties"] = list(properties)
        return self.result("get", params)

    def invoke(self, address, method, **args):
        """Calls a declared method with named arguments; returns its result."""
        return self.result("call", {"object": address, "method": method, "args": args})

    def result(self, method, params=None):
        """Sends one request; returns its result or raises AssistantError."""
        return self.check(self.call(method, params))

    @staticmethod
    def check(response):
        """The result of one response, or AssistantError for an error response."""
        if "error" in response:
            raise AssistantError(response["error"].get("code"), response["error"].get("message"))
        return response.get("result")

    def _make_request(self, method, params):
        self._request_id += 1
        request = {"id": self._request_id, "method": method}
        if params:
            request["params"] = params
        return request

    def _recv_response(self):
        while True:
            newline_pos = self._buffer.find(b"\n")
            if newline_pos >= 0:
                line = self._buffer[:newline_pos]
                self._buffer = self._buffer[newline_pos + 1:]
                return json.loads(line.decode("utf-8"))
            chunk = self._sock.recv(4096)
            if not chunk:
                raise ConnectionError("Server closed connection")
            self._buffer += chunk


# =============================================================================
# Test Runner
# =============================================================================

class TestRunner:
    """Runs the generic I, Voyager test sequence (SPECIFICATION.md section 9)
    against the members a project's classes declare, as `describe` reports them.
    A step whose object or member the project lacks is skipped."""

    def __init__(self, client, skip_save=False, skip_hover=False):
        self.client = client
        self.skip_save = skip_save
        self.skip_hover = skip_hover
        self.capabilities = []
        self.described = {"objects": {}, "classes": {}, "enums": {}, "widgets": []}
        self.passed = 0
        self.failed = 0
        self.skipped = 0
        self.errors = []

    def has_cap(self, name):
        return name in self.capabilities

    def has_member(self, address, member):
        """Whether the object named `address` (or the class, for a keyed address)
        declares `member` and it is available now."""
        if isinstance(address, dict):
            entry = self.described["classes"].get(address.get("class"), {})
        else:
            entry = self.described["objects"].get(address, {})
        declared = member in entry.get("methods", {}) or member in entry.get("properties", {})
        return declared and member not in entry.get("unavailable", [])

    def instances(self, class_name):
        return self.described["classes"].get(class_name, {}).get("instances", [])

    def refresh(self):
        self.described = self.client.describe()

    def assert_true(self, condition, message):
        if condition:
            self.passed += 1
            print("  PASS: %s" % message)
        else:
            self.failed += 1
            self.errors.append(message)
            print("  FAIL: %s" % message)

    def assert_gt(self, value, threshold, name):
        self.assert_true(value > threshold, "%s = %s (expected > %s)" % (name, value, threshold))

    def assert_eq(self, value, expected, name):
        self.assert_true(value == expected, "%s = %s (expected %s)" % (name, value, expected))

    def skip(self, message):
        self.skipped += 1
        print("  SKIP: %s" % message)

    def poll(self, condition_fn, description, timeout=60, interval=1.0):
        """Poll condition_fn() until it is truthy; returns its value or None."""
        for _ in range(int(timeout / interval)):
            value = condition_fn()
            if value:
                return value
            time.sleep(interval)
        self.assert_true(False, "%s (timed out after %ds)" % (description, timeout))
        return None

    # =========================================================================
    # Test sequence
    # =========================================================================

    def run_all(self, print_summary=True):
        print("\n=== I, Voyager Generic Tests ===\n")

        self.test_1_discover()
        self.test_2_start()
        self.test_3_verify_state()
        self.test_4_exercise_controls()
        self.test_widgets()
        self.test_hover()
        self.test_5_save_load()

        if print_summary:
            self.print_summary()
        return self.failed == 0

    def print_summary(self):
        print("\n=== Results: %d passed, %d failed, %d skipped ===" % (
            self.passed, self.failed, self.skipped))
        if self.errors:
            print("\nFailures:")
            for err in self.errors:
                print("  - %s" % err)

    # 9.3 Step 1: Discover what the project declares
    def test_1_discover(self):
        print("[1. Discover]")
        info = self.client.result("get_project_info")
        self.capabilities = info.get("capabilities", [])
        self.assert_true(info.get("assistant_protocol_version", 0) >= 4,
                         "protocol version %s >= 4" % info.get("assistant_protocol_version"))
        for method in ("describe", "get", "call", "quit"):
            self.assert_true(self.has_cap(method), "%s capability" % method)
        self.refresh()
        objects = self.described["objects"]
        print("  Project: %s %s" % (info.get("project_name", ""), info.get("project_version", "")))
        print("  Objects: %s" % ", ".join(sorted(objects)))
        self.assert_true("IVStateManager" in objects, "describe: IVStateManager declared")

    # 9.3 Step 2: Start simulation
    def test_2_start(self):
        print("[2. Start simulation]")
        state = self.client.get("IVStateManager", "started")
        settings = self.client.get("IVCoreSettings", "wait_for_start")
        if settings.get("wait_for_start") and not state.get("started"):
            self.poll(lambda: self.has_member("IVStateManager", "start") or self.refresh(),
                      "IVStateManager.start available", timeout=120)
            print("  Calling IVStateManager.start...")
            self.client.invoke("IVStateManager", "start")
        ready = self.poll(lambda: self.client.result("get_project_info").get("ready"),
                          "Simulator started and ready", timeout=240)
        if ready:
            self.assert_true(True, "Simulator started and ready")
        self.refresh() # bodies and their widgets exist now

    # 9.3 Step 3: Verify state
    def test_3_verify_state(self):
        print("[3. Verify state]")
        state = self.client.get("IVStateManager", "started", "running")
        self.assert_true(state.get("started"), "IVStateManager.started")

        date = self.client.get("IVGlobal", "date")["date"]
        self.assert_gt(date[0], 0, "IVGlobal.date: year")
        self.assert_true(1 <= date[1] <= 12, "IVGlobal.date: month = %d (1-12)" % date[1])
        self.assert_true(1 <= date[2] <= 31, "IVGlobal.date: day = %d (1-31)" % date[2])

        if "SelectionManager" in self.described["objects"]:
            selection = self.client.get("SelectionManager", "selection")["selection"]
            self.assert_true(selection is not None, "SelectionManager.selection: %s" % selection)
        else:
            self.skip("no SelectionManager")

        if "IVCamera" in self.described["objects"]:
            target = self.client.get("IVCamera", "target")["target"]
            self.assert_true(target is not None, "IVCamera.target: %s" % target)
        else:
            self.skip("no IVCamera")

    # 9.3 Step 4: Exercise controls
    def test_4_exercise_controls(self):
        print("[4. Exercise controls]")

        bodies = [instance["name"] for instance in self.instances("IVBody")]
        if bodies:
            planet_flag = self.described["enums"].get("IVBody.BodyFlags", {}).get(
                "BODYFLAGS_PLANET", 0)
            responses = self.client.batch([("get", {"object": {"class": "IVBody", "name": name},
                                                    "properties": "flags"}) for name in bodies])
            planets = [name for name, response in zip(bodies, responses)
                       if AssistantClient.check(response)["flags"] & planet_flag]
            self.assert_gt(len(planets), 0, "IVBody planets found (%d)" % len(planets))
            self.assert_true("PLANET_EARTH" in planets, "IVBody: PLANET_EARTH is a planet")
            self.assert_true("PLANET_MARS" in planets, "IVBody: PLANET_MARS is a planet")
        else:
            self.skip("no IVBody instances")

        if self.has_member("SelectionManager", "select_by_name"):
            found = self.client.invoke("SelectionManager", "select_by_name", name="PLANET_MARS")
            self.assert_true(found, "SelectionManager.select_by_name: PLANET_MARS")
            self.assert_eq(self.client.invoke("SelectionManager", "get_name"), "PLANET_MARS",
                           "SelectionManager.get_name")
        else:
            self.skip("SelectionManager.select_by_name not declared")

        if self.has_member("CameraHandler", "move_to_by_name"):
            self.client.invoke("CameraHandler", "move_to_by_name", selection_name="PLANET_EARTH",
                               is_instant_move=True)
            self.assert_eq(self.client.get("IVCamera", "target")["target"],
                           {"class": "IVBody", "name": "PLANET_EARTH"}, "IVCamera.target")
        else:
            self.skip("CameraHandler.move_to_by_name not declared")

        if self.has_member("IVStateManager", "set_user_paused"):
            # One round trip: pause, read, unpause, read.
            responses = self.client.batch([
                ("call", {"object": "IVStateManager", "method": "set_user_paused",
                          "args": {"pause": True}}),
                ("get", {"object": "IVStateManager", "properties": "paused_by_user"}),
                ("call", {"object": "IVStateManager", "method": "set_user_paused",
                          "args": {"pause": False}}),
                ("get", {"object": "IVStateManager", "properties": "paused_by_user"}),
            ])
            results = [AssistantClient.check(response) for response in responses]
            self.assert_eq(results[1]["paused_by_user"], True, "paused_by_user after pause")
            self.assert_eq(results[3]["paused_by_user"], False, "paused_by_user after unpause")
        else:
            self.skip("IVStateManager.set_user_paused not available")

        if self.has_member("SpeedManager", "change_speed"):
            self.client.invoke("SpeedManager", "change_speed", new_speed_index=3)
            self.assert_eq(self.client.get("SpeedManager", "speed_index")["speed_index"], 3,
                           "SpeedManager.speed_index")
            self.client.invoke("SpeedManager", "change_speed", new_speed_index=0)
        else:
            self.skip("SpeedManager.change_speed not available")

    # The user surface: operate a widget the way a user does.
    def test_widgets(self):
        print("[Widgets]")
        widgets = self.client.result("list_widgets", {"visible_only": True})["widgets"]
        self.assert_gt(len(widgets), 0, "visible widgets (%d)" % len(widgets))
        pause = next((w for w in widgets if w["class"] == "IVPauseButton" and w["enabled"]), None)
        if pause:
            for pressed in (True, False):
                result = self.client.result("operate_widget",
                                            {"widget": pause["widget"], "pressed": pressed})
                self.assert_eq(result["state"].get("pressed"), pressed, "IVPauseButton pressed")
                self.assert_eq(self.client.get("IVStateManager", "paused_by_user")[
                    "paused_by_user"], pressed, "paused_by_user follows IVPauseButton")
        else:
            self.skip("no enabled IVPauseButton")
        speed = next((w for w in widgets if w["class"] == "IVSpeedButtons"), None)
        if speed:
            result = self.client.result("operate_widget", {"widget": speed["widget"], "value": 2})
            self.assert_eq(result["state"].get("value"), 2, "IVSpeedButtons value")
            self.client.result("operate_widget", {"widget": speed["widget"], "value": 0})
        else:
            self.skip("no IVSpeedButtons")

    # Optional: mouse-hover identification
    def test_hover(self):
        print("[Mouse hover identification]")
        if self.skip_hover:
            self.skip("hover test skipped (--skip-hover)")
            return
        if "IVMouseTargetLabel" not in self.described["objects"]:
            self.skip("no IVMouseTargetLabel")
            return
        if not self.has_member("CameraHandler", "move_to_by_name"):
            self.skip("CameraHandler.move_to_by_name not declared; cannot stage hover test")
            return

        # A GUI panel over the projected point would take the mouse from the world.
        hide_gui = self.has_member("IVShowHideUI", "show_hide_gui")
        if hide_gui:
            self.client.invoke("IVShowHideUI", "show_hide_gui", is_toggle=False, is_show=False)
        try:
            self._hover_body()
            self._hover_orbit_line()
            self._hover_asteroid_point()
        finally:
            if hide_gui:
                self.client.invoke("IVShowHideUI", "show_hide_gui", is_toggle=False,
                                   is_show=True)

    def _hover_text(self, position):
        self.client.result("warp_mouse", {"position": position})
        time.sleep(0.4)
        return self.client.get("IVMouseTargetLabel", "text")["text"]

    def _hover_body(self):
        # Body picking via WorldController. Move the camera to a body so it
        # sits at screen center, project, warp, read. Iterate candidates so a
        # nearby satellite occluding the planet's pick pixel (e.g. ISS in
        # front of Earth from some vantages) doesn't break the test — we just
        # move on to the next candidate.
        print("  -- Body picking")
        candidates = ["STAR_SUN", "PLANET_MARS", "PLANET_JUPITER", "PLANET_EARTH"]
        for body in candidates:
            self.client.invoke("CameraHandler", "move_to_by_name", selection_name=body,
                               is_instant_move=True)
            time.sleep(0.6)
            resp = self.client.call("project_to_screen", {"node": {"class": "IVBody", "name": body}})
            if "error" in resp or not resp["result"].get("on_screen", False):
                continue
            text = self._hover_text(resp["result"]["position"])
            bare = body.split("_", 1)[1].lower() if "_" in body else body.lower()
            if bare in text.lower():
                self.assert_true(
                    True,
                    "body hover: text contains %r (target=%s, got %r)" % (bare, body, text),
                )
                return

        self.assert_true(False, "body hover: no candidate body identified by hover")

    def _set_wide_solar_view(self):
        # Target Sun with a large perspective distance so multiple planet
        # orbits and the asteroid belt fit on screen at once. The .z component
        # of view_position is in target perspective-radii; for the Sun
        # (~700,000 km mean radius) z=1000 places the camera ~4.7 AU from Sun,
        # which frames Mercury → Jupiter and the main asteroid belt.
        self.client.invoke("SelectionManager", "select_by_name", name="STAR_SUN")
        self.client.invoke("CameraHandler", "move_to_by_name", selection_name="STAR_SUN",
                           view_position=[0.0, 0.5, 1000.0], is_instant_move=True)
        time.sleep(1.0)

    def _offset_at_time(self, body, at_time):
        """How far `body` will have moved at `at_time`: its position summed up the
        parent chain then, less now."""
        chain = []
        address = {"class": "IVBody", "name": body}
        while address:
            chain.append(address)
            address = self.client.get(address, "parent")["parent"]
        requests = []
        for link in chain:
            requests.append(("call", {"object": link, "method": "get_position_vector",
                                      "args": {"time": at_time}}))
            requests.append(("call", {"object": link, "method": "get_position_vector"}))
        results = [AssistantClient.check(response) for response in self.client.batch(requests)]
        offset = [0.0, 0.0, 0.0]
        for then, now in zip(results[0::2], results[1::2]):
            for i in range(3):
                offset[i] += then[i] - now[i]
        return offset

    def _hover_orbit_line(self):
        # Project a body at a future time (quarter-orbit ahead) and hover
        # there. Body itself isn't at that pixel, so the only thing that can
        # identify it is the orbit-line shader (today: IVFragmentIdentifier).
        # Expect "(orbit)" in the label — distinguishes from body picking.
        print("  -- Body-orbit line")
        if not self.has_member("BodyHUDsState", "set_all_orbits_visibility"):
            self.skip("orbit hover: BodyHUDsState.set_all_orbits_visibility not declared")
            return

        self._set_wide_solar_view()

        # IVBodyHUDsState.orbit_visible_flags is PERSIST_PROPERTIES and may
        # reflect the previous user session (e.g. planetarium's view cacher
        # restores it). Force-enable all body orbits so the orbit-line shader
        # is drawing, then restore exact prior state in the finally clause.
        previous_flags = self.client.get("BodyHUDsState", "orbit_visible_flags")[
            "orbit_visible_flags"]
        self.client.invoke("BodyHUDsState", "set_all_orbits_visibility", is_show=True)
        # Let visibility_changed propagate to orbit_visual.gd and the GPU
        # render a frame with orbit shaders active.
        time.sleep(0.5)

        try:
            current_time = self.client.get("Timekeeper", "time")["time"]
            candidates = ["PLANET_EARTH", "PLANET_MARS", "PLANET_JUPITER", "PLANET_VENUS"]
            for body in candidates:
                period = self.client.invoke({"class": "IVBody", "name": body, "via": "orbit"},
                                            "get_period")
                if not isinstance(period, (int, float)) or period <= 0.0:
                    continue
                for fraction in (0.25, 0.125, 0.0625, 0.5):
                    offset = self._offset_at_time(body, current_time + period * fraction)
                    resp = self.client.call("project_to_screen", {
                        "node": {"class": "IVBody", "name": body}, "offset": offset})
                    if "error" in resp or not resp["result"].get("on_screen", False):
                        continue
                    text = self._hover_text(resp["result"]["position"])
                    if "orbit" in text.lower():
                        self.assert_true(
                            True,
                            "orbit hover: text %r contains 'orbit' (target=%s, fraction=%g)"
                            % (text, body, fraction),
                        )
                        return

            self.skip("orbit hover: no candidate body's orbit line resolved an identification")
        finally:
            self.client.invoke("BodyHUDsState", "set_orbit_visible_flags",
                               orbit_visible_flags_=previous_flags)

    def _hover_asteroid_point(self):
        # Project an asteroid in a non-Trojan small-body group, hover. Identifies
        # an asteroid POINT (FragmentIdentifier sbg-point branch); text is the
        # asteroid's stored name.
        print("  -- Asteroid point")
        groups = [instance["name"] for instance in self.instances("IVSmallBodiesGroup")]
        if not groups or not self.has_member("SBGHUDsState", "change_symbols_visibility"):
            self.skip("asteroid hover: no small-body groups or SBGHUDsState")
            return
        responses = self.client.batch([("get", {
            "object": {"class": "IVSmallBodiesGroup", "name": name},
            "properties": ["sbg_alias", "lp_integer"]}) for name in groups])
        non_lp_groups = []
        for name, response in zip(groups, responses):
            properties = AssistantClient.check(response)
            if properties["lp_integer"] == -1:
                non_lp_groups.append((name, properties["sbg_alias"]))
        if not non_lp_groups:
            self.skip("asteroid hover: no non-Trojan small-body group")
            return

        self._set_wide_solar_view()

        # SBG points default to hidden (IVSBGHUDsState.symbols_visibilities is
        # empty unless the project preinitializer seeds it), so without this
        # toggle the FragmentIdentifier reads black pixels and never resolves.
        visibility_changes = []
        for _, alias in non_lp_groups:
            previous = self.client.invoke("SBGHUDsState", "is_symbols_visible", group=alias)
            self.client.invoke("SBGHUDsState", "change_symbols_visibility", group=alias,
                               is_show=True)
            visibility_changes.append((alias, previous))
        # Let the SBG points visuals respond and the GPU draw a frame with the points.
        time.sleep(0.5)

        try:
            # Bound the warp budget so the test cannot run for minutes if the
            # FragmentIdentifier fails to resolve (e.g. points are too small at
            # this view to land in the 9-pixel sample). 30 attempts × ~0.4s ≈ 12s.
            per_group_cap = 10
            total_cap = 30
            total_attempts = 0
            for name, _ in non_lp_groups:
                group = {"class": "IVSmallBodiesGroup", "name": name}
                primary = self.client.invoke(group, "get_primary")
                count = min(200, self.client.invoke(group, "get_number"))
                group_attempts = 0
                for index in range(count):
                    if group_attempts >= per_group_cap or total_attempts >= total_cap:
                        break
                    position, expected_name = [AssistantClient.check(response) for response in
                                               self.client.batch([
                        ("call", {"object": group, "method": "get_member_position",
                                  "args": {"index": index}}),
                        ("call", {"object": group, "method": "get_member_name",
                                  "args": {"index": index}}),
                    ])]
                    resp = self.client.call("project_to_screen",
                                            {"node": primary, "offset": position})
                    if "error" in resp or not resp["result"].get("on_screen", False):
                        continue
                    text = self._hover_text(resp["result"]["position"])
                    group_attempts += 1
                    total_attempts += 1
                    # POINT hover yields name; ORBIT hover yields name + " (orbit)".
                    # Either contains the asteroid's stored name as a substring.
                    if expected_name and expected_name in text:
                        self.assert_true(
                            True,
                            "asteroid hover: text %r contains %r (group=%s, index=%d)"
                            % (text, expected_name, name, index),
                        )
                        return
                if total_attempts >= total_cap:
                    break

            self.skip(
                "asteroid hover: %d on-screen attempt(s) across %d group(s) did not resolve"
                % (total_attempts, len(non_lp_groups)))
        finally:
            for alias, previous in visibility_changes:
                self.client.invoke("SBGHUDsState", "change_symbols_visibility", group=alias,
                                   is_show=previous)

    # 9.3 Step 5: Save/load cycle. The Save plugin declares no members yet, so this
    # uses the deprecated save methods (SPECIFICATION.md section 4.12).
    def test_5_save_load(self):
        print("[5. Save/load cycle]")

        if self.skip_save:
            self.skip("save/load skipped (--skip-save)")
            return

        has_save = self.has_cap("save_game") and self.has_cap("load_game")
        if not has_save:
            self.skip("save_game/load_game not in capabilities")
            return

        def get_state():
            return self.client.call("get_state").get("result", {})

        # Save
        resp = self.client.call("save_game", {"type": "quicksave"})
        result = resp.get("result", {})
        self.assert_true(result.get("ok", False), "save_game: quicksave initiated")

        # Poll until save completes
        state = self.poll(lambda: (lambda s: s if not s.get("is_saving", True) else None)(
            get_state()), "Save completed", timeout=30)
        if not state:
            return

        self.assert_true(True, "save_game: completed")

        # Verify save exists
        if self.has_cap("get_save_status"):
            resp = self.client.call("get_save_status")
            result = resp.get("result", {})
            self.assert_true(result.get("has_saves", False), "get_save_status: has saves")

        # Load
        resp = self.client.call("load_game")
        result = resp.get("result", {})
        self.assert_true(result.get("ok", False), "load_game: quickload initiated")

        # Poll until load completes and sim restarts
        state = self.poll(lambda: (lambda s: s if not s.get("is_loading", True)
                                   and s.get("started", False) else None)(get_state()),
                          "Load completed and simulator restarted", timeout=30)
        if not state:
            return

        self.assert_true(True, "load_game: completed and restarted")

        # Verify state is sane after load
        result = get_state()
        self.assert_true(result.get("started", False), "Post-load: started")
        self.assert_eq(result.get("is_saving", True), False, "Post-load: not saving")
        self.assert_eq(result.get("is_loading", True), False, "Post-load: not loading")


# =============================================================================
# Main
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Generic I, Voyager test runner (SPECIFICATION.md section 9)")
    parser.add_argument("--host", default="127.0.0.1", help="Server host")
    parser.add_argument("--port", type=int, default=None,
                        help="Server port (default: %d, or a free port with --launch)"
                             % DEFAULT_PORT)
    parser.add_argument("--launch", action="store_true",
                        help="Launch Godot before testing")
    parser.add_argument("--headless", action="store_true",
                        help="With --launch: pass --headless to Godot (no rendering;"
                             " skips the mouse-hover test)")
    parser.add_argument("--godot", default=None,
                        help="Path to Godot console executable (default: the newest build"
                             " of the project's major beside the project)")
    parser.add_argument("--project", default=".",
                        help="Path to project directory")
    parser.add_argument("--skip-save", action="store_true",
                        help="Skip save/load cycle")
    parser.add_argument("--skip-hover", action="store_true",
                        help="Skip mouse-hover identification test")
    args = parser.parse_args()

    launcher = None
    if args.launch:
        godot = args.godot or find_godot_executable(args.project, on_message=print)
        if not godot:
            print("No Godot console executable of the project's major; use --godot PATH")
            sys.exit(2)
        extra = ["--headless"] if args.headless else []
        launcher = GodotLauncher(godot, args.project, extra_args=extra, port=args.port or 0)
        print("Launching Godot: %s %s --path %s (port %d)"
              % (godot, " ".join(extra), args.project, launcher.port))
        launcher.start()
    port = launcher.port if launcher else args.port or DEFAULT_PORT

    client = AssistantClient(host=args.host, port=port)
    try:
        print("Connecting to %s:%d..." % (args.host, port))
        client.connect()
        if launcher:
            launcher.check_instance(client)
        print("Connected!\n")

        runner = TestRunner(client, skip_save=args.skip_save,
                            skip_hover=args.skip_hover or args.headless)
        success = runner.run_all()

        # 9.3 Step 6: Quit
        print("\n[6. Quit]")
        print("  Sending quit with force...")
        client.call("quit", {"force": True})
    except Exception as e:
        print("\nERROR: %s" % e)
        success = False
    finally:
        client.close()
        if launcher:
            launcher.shutdown_and_report()
            if launcher.leaks:
                success = False

    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
