#!/usr/bin/env python3
"""Read-only, dependency-free project engine detector."""
from pathlib import Path
import argparse


def detect_engines(project_root: Path) -> list[str]:
    engines = []
    if list(project_root.glob("*.uproject")):
        engines.append("Unreal Engine")
    if (project_root / "project.godot").is_file():
        engines.append("Godot")
    if (project_root / "ProjectSettings" / "ProjectVersion.txt").is_file():
        engines.append("Unity")
    if (project_root / "game.project").is_file() or (project_root / "pdxinfo").is_file():
        engines.append("Playdate (candidate; confirm SDK/project layout)")
    return engines


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project_root", nargs="?", default=".")
    arguments = parser.parse_args()
    project_root = Path(arguments.project_root).resolve()
    for engine in detect_engines(project_root):
        print(engine)
    if not detect_engines(project_root):
        print("Unknown; inspect project files")


if __name__ == "__main__":
    main()
