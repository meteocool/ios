#!/usr/bin/env python3
"""Copies where meteocool's radars reach out of meteocool/core for the
native map's no-radar wash (`meteocool/NativeMap/radar-wash.json`).

core draws a light wash over everywhere no radar reaches: the world, with
the radars' reach cut out (`radarCoverageInv` in core's
`src/layers/extents.ts`), and on forecast steps only DWD's
(`dwdCoverageInv`). This copies those holes, EPSG:3857 metres, as
`{"radar": [ring, …], "dwd": [ring, …]}`.

    scripts/radar-wash.py [path/to/core]   # default: ../core next to this repo

Rerun it after core's extents change and commit the result.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def find_core():
    if len(sys.argv) > 1:
        return pathlib.Path(sys.argv[1])
    for candidate in [ROOT.parent / "core", pathlib.Path.home() / "meteocool" / "core"]:
        if (candidate / "src" / "layers" / "extents.ts").exists():
            return candidate
    sys.exit("core not found: pass its path")


def rings(source, name):
    pattern = re.compile(re.escape(name) + r"\.appendLinearRing\(\s*new LinearRing\(\[(.*?)\]\)", re.S)
    out = []
    for match in pattern.finditer(source):
        points = re.findall(r"\[\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*\]", match.group(1))
        out.append([[round(float(x), 1), round(float(y), 1)] for x, y in points])
    if not out:
        sys.exit(f"no rings for {name}: has extents.ts changed shape?")
    return out


def main():
    source = (find_core() / "src/layers/extents.ts").read_text()
    wash = {"crs": "EPSG:3857", "radar": rings(source, "radarCoverageInv"), "dwd": rings(source, "dwdCoverageInv")}
    target = ROOT / "meteocool" / "NativeMap" / "radar-wash.json"
    target.write_text(json.dumps(wash, separators=(",", ":")) + "\n")
    print(f"{target.relative_to(ROOT)}: {len(wash['radar'])} radar rings, {len(wash['dwd'])} DWD rings")


if __name__ == "__main__":
    main()
