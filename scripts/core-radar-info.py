#!/usr/bin/env python3
"""Copies meteocool/core's radar pages into the app: each radar's facts and texts.

The native map's page for a radar (RadarInfo.swift) says what core's says
(`RadarInfo.svelte`), from the same files: the facts, a file per country
(`src/radarInfo/radar-info-<country>.json`), and the texts, a file per
language and country (`src/radarInfo/text/radar-text-<lang>-<country>.json`),
for the app's own languages. Core ships them as chunks with hashed names, so
the app carries its own copy rather than fetching them. The photos are not
copied: the page loads them from the web map's origin (`public/radars/`).

    scripts/core-radar-info.py [path/to/core]   # default: ../core next to this repo

The files are copied as they are, so they stay comparable with core's; JSON
has no room for a "generated" note, so this one stands for them: do not edit
them, rerun the script after core's change and commit the result.
"""
import json
import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TARGET = ROOT / "meteocool" / "NativeMap" / "RadarInfo"
# The app's own languages, as scripts/core-strings.py has them; core has more.
LANGUAGES = ["en", "de", "da", "et", "fi", "hr", "lt", "nb", "nl", "sv"]


def find_core():
    if len(sys.argv) > 1:
        return pathlib.Path(sys.argv[1])
    for candidate in [ROOT.parent / "core", ROOT.parents[3] / "core" if len(ROOT.parents) > 3 else None,
                      pathlib.Path.home() / "meteocool" / "core"]:
        if candidate and (candidate / "src" / "radarInfo").is_dir():
            return candidate
    sys.exit("core not found: pass its path")


def copy(source, target):
    # Parsed first: a file core could not load is not copied either.
    json.loads(source.read_text(encoding="utf-8"))
    shutil.copyfile(source, target)


def main():
    core = find_core() / "src" / "radarInfo"
    if not core.is_dir():
        sys.exit(f"{core} not found")
    if TARGET.exists():
        shutil.rmtree(TARGET)
    (TARGET / "text").mkdir(parents=True)
    facts = sorted(core.glob("radar-info-*.json"))
    for source in facts:
        copy(source, TARGET / source.name)
    texts = [source for source in sorted((core / "text").glob("radar-text-*.json"))
             if source.name.split("-")[2] in LANGUAGES]
    for source in texts:
        copy(source, TARGET / "text" / source.name)
    print(f"{TARGET.relative_to(ROOT)}: {len(facts)} countries' facts, {len(texts)} text files")


if __name__ == "__main__":
    main()
