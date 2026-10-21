# requirement_tokens.gd
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
class_name IVAssistantRequirementTokens
extends Object

## The closed vocabulary of requirement tokens a test suite may name in
## [method IVAssistantTestSuite.get_method_requirements] (SPECIFICATION.md §7.5).
##
## @deprecated: A class gates its own members in is_automation_available() (SPECIFICATION.md §11).

## Tokens recognized; any other pushes an error at suite load and is dropped.
const KNOWN_TOKENS: Array[String] = [
	# IVCoreSettings flags
	"core.allow_time_setting",
	"core.allow_time_reversal",
	# IVGlobal.program members
	"program.TopUI",
	"program.SpeedManager",
	"program.Timekeeper",
	"program.CameraHandler",
	"program.ViewManager",
	"program.BodyHUDsState",
	# Optional autoloads (duck-typed)
	"autoload.IVSave",
	# IVCoreSettings.body_tables membership
	"body_table.stars",
	"body_table.planets",
	"body_table.moons",
	"body_table.asteroids",
	"body_table.spacecrafts",
	# Scene-tree widgets — resolved on simulator_started
	"widget.MouseTargetLabel",
	# Live RefCounted/Node instance pools — resolved on simulator_started
	"runtime.IVSmallBodiesGroup",
]


## Evaluates [param token] against current state. [code]widget.*[/code] and
## [code]runtime.*[/code] tokens are unmet until [param sim_started], when the
## scene tree is populated.
static func evaluate(token: String, sim_started: bool) -> bool:
	match token:
		"core.allow_time_setting":
			return IVCoreSettings.allow_time_setting
		"core.allow_time_reversal":
			return IVCoreSettings.allow_time_reversal
		"program.TopUI":
			return IVGlobal.program.has(&"TopUI")
		"program.SpeedManager":
			return IVGlobal.program.has(&"SpeedManager")
		"program.Timekeeper":
			return IVGlobal.program.has(&"Timekeeper")
		"program.CameraHandler":
			return IVGlobal.program.has(&"CameraHandler")
		"program.ViewManager":
			return IVGlobal.program.has(&"ViewManager")
		"program.BodyHUDsState":
			return IVGlobal.program.has(&"BodyHUDsState")
		"autoload.IVSave":
			var tree: SceneTree = Engine.get_main_loop()
			return tree.root.has_node(^"IVSave")
		"body_table.stars":
			return &"stars" in IVCoreSettings.body_tables
		"body_table.planets":
			return &"planets" in IVCoreSettings.body_tables
		"body_table.moons":
			return &"moons" in IVCoreSettings.body_tables
		"body_table.asteroids":
			return &"asteroids" in IVCoreSettings.body_tables
		"body_table.spacecrafts":
			return &"spacecrafts" in IVCoreSettings.body_tables
		"widget.MouseTargetLabel":
			if !sim_started:
				return false
			var top_node: Node = IVGlobal.program.get(&"TopUI")
			return top_node != null and top_node.find_child("MouseTargetLabel", true, false) != null
		"runtime.IVSmallBodiesGroup":
			if !sim_started:
				return false
			return !IVSmallBodiesGroup.small_bodies_groups.is_empty()
	push_error("IVAssistantRequirementTokens: unknown token '%s'" % token)
	return false
