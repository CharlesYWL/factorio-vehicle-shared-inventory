"""Pack the Factorio mod into a Mod Portal compatible zip.

Always uses forward slashes in zip entries (required by the portal).
Excludes this script and other tooling: the portal rejects .py/.ps1 files.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent

FILES = (
    "info.json",
    "control.lua",
    "settings.lua",
    "changelog.txt",
    "thumbnail.png",
    "LICENSE",
    "README.md",
    "README.zh-CN.md",
)

FOLDERS = ("scripts", "locale")


def load_info() -> dict:
    return json.loads((ROOT / "info.json").read_text(encoding="utf-8"))


def changelog_section(version: str) -> str:
    text = (ROOT / "changelog.txt").read_text(encoding="utf-8")
    pattern = rf"^Version:\s*{re.escape(version)}\s*$"
    lines = text.splitlines()
    start = None
    for index, line in enumerate(lines):
        if re.match(pattern, line):
            start = index
            break
    if start is None:
        return f"Vehicle Shared Inventory {version}"

    collected = [lines[start]]
    for line in lines[start + 1 :]:
        if line.startswith("Version:"):
            break
        if set(line) == {"-"} and len(line) >= 20:
            break
        collected.append(line)
    return "\n".join(collected).strip()


def pack() -> tuple[Path, str, str]:
    info = load_info()
    name = info["name"]
    version = info["version"]
    stem = f"{name}_{version}"

    build_root = ROOT / "build"
    stage = build_root / stem
    zip_path = build_root / f"{stem}.zip"

    if build_root.exists():
        shutil.rmtree(build_root)
    stage.mkdir(parents=True)

    for filename in FILES:
        source = ROOT / filename
        if source.exists():
            shutil.copy2(source, stage / filename)
        elif filename == "thumbnail.png":
            print("warning: thumbnail.png is missing")

    for folder in FOLDERS:
        source = ROOT / folder
        if source.exists():
            shutil.copytree(source, stage / folder)

    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(stage.rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(build_root).as_posix())

    notes = ROOT / "build" / "release-notes.md"
    notes.write_text(
        changelog_section(version)
        + "\n\nUpload `"
        + zip_path.name
        + "` to the [Factorio Mod Portal](https://mods.factorio.com).\n",
        encoding="utf-8",
    )

    shutil.rmtree(stage)
    return zip_path, name, version


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--github-output",
        action="store_true",
        help="Write version and zip path to $GITHUB_OUTPUT",
    )
    args = parser.parse_args()

    zip_path, name, version = pack()
    print(f"Built {zip_path}")
    with zipfile.ZipFile(zip_path) as archive:
        for entry in archive.namelist():
            print(f"  {entry}")
            if "\\" in entry:
                raise SystemExit(f"zip entry has backslash: {entry}")

    if args.github_output:
        output = os.environ.get("GITHUB_OUTPUT")
        if not output:
            raise SystemExit("GITHUB_OUTPUT is not set")
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"name={name}\n")
            handle.write(f"version={version}\n")
            handle.write(f"tag=v{version}\n")
            handle.write(f"zip={zip_path.as_posix()}\n")


if __name__ == "__main__":
    main()
