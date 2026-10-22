#!/usr/bin/env python3
"""Select the Godot console executable matching a project's target version.

The rule is shared by Godot tooling that must launch the right engine build
(the GDScript warning checker and project test runners):

1. The target MAJOR (e.g. 4.7) comes from `config/features` in project.godot.
   That string is bumped only on major changes (4.5 -> 4.6 -> 4.7), so it
   authoritatively pins which Godot major line the project targets. A build of
   a *higher* major sitting in the parent directory is NOT the target.
2. Within that major, the highest version wins: patch number, then release
   stage dev < beta < rc < stable, then iteration. `config/features` does not
   capture minor/patch, so the within-major sort is still required. dev/beta/rc
   are always followed by an iteration digit; stable carries none and outranks
   every pre-release.

If config/features can't be read, or no build matches the pinned major, there
is no selection: a build of another major rewrites project.godot, import files
and scenes for its own version when it opens the project, so the caller must
name a build explicitly.

NOTE: this logic is intentionally duplicated in units that cannot import each
other -- keep the copies byte-identical:
  - godot skill:      ~/.claude/skills/godot/godot_executable.py
  - Astropolis repo:  tests/godot_executable.py  (must stay self-contained)
  - Assistant plugin: tools/godot_executable.py  (ivoyager_assistant)
"""

import glob
import os
import re

STAGE_RANK = {None: -1, "dev": 0, "beta": 1, "rc": 2, "stable": 3}


def read_target_major(project_dir):
    """(major, minor) from `config/features` in project.godot, or None."""
    try:
        with open(os.path.join(project_dir, "project.godot"),
                  encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return None
    features = re.search(r"config/features\s*=\s*PackedStringArray\((.*?)\)", text)
    if not features:
        return None
    version = re.search(r'"(\d+)\.(\d+)"', features.group(1))
    if not version:
        return None
    return (int(version.group(1)), int(version.group(2)))


def version_key(path):
    """Sort key for a Godot exe: (major, minor, patch, stage_rank, iteration).

    Filenames are Godot_v<major>.<minor>[.<patch>]-<stage>[<n>]_..., where stage
    is dev/beta/rc/stable.
    """
    match = re.search(
        r"v(\d+)\.(\d+)(?:\.(\d+))?(?:-(dev|beta|rc|stable)(\d+)?)?",
        os.path.basename(path))
    if not match:
        return (0, 0, 0, -1, 0)
    return (
        int(match.group(1)),
        int(match.group(2)),
        int(match.group(3) or 0),
        STAGE_RANK.get(match.group(4), -1),
        int(match.group(5) or 0),
    )


def find_godot_executable(project_dir, on_message=None):
    """Pick the Godot_v*_console.exe matching the project's target major.

    project_dir: path to the project (containing project.godot); console builds
    are searched in its parent directory. on_message: optional callable invoked
    with progress/warning strings (default: silent). Returns a path, or None
    when no build of the project's major is there or the major can't be read.
    """
    say = on_message or (lambda _msg: None)
    project_dir = os.path.abspath(project_dir)
    search_dir = os.path.dirname(project_dir)
    target_major = read_target_major(project_dir)
    if target_major is None:
        say("No config/features in %s; can't tell which Godot major the project "
            "targets." % os.path.join(project_dir, "project.godot"))
        return None
    say("config/features targets Godot %d.%d" % target_major)
    candidates = [path for path in glob.glob(os.path.join(search_dir, "Godot_v*_console.exe"))
                  if version_key(path)[:2] == target_major]
    if not candidates:
        say("No Godot %d.%d console build in %s." % (target_major + (search_dir,)))
        return None
    candidates.sort(key=version_key)
    return candidates[-1]


if __name__ == "__main__":
    import sys
    target = sys.argv[1] if len(sys.argv) > 1 else "."
    print("selected:", find_godot_executable(target, on_message=print))
