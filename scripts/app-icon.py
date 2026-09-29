#!/usr/bin/env python3
"""Generate meteocool/AppIcon.icon, the Icon Composer document for the app icon.

The icon is the meteocool logo -- two light-blue clouds with a dark outline and
rain -- rebuilt as layers so Liquid Glass can add refraction, highlights and
shadows itself. The background is the document's own fill -- white, or
near-black when dark -- so the clear and tinted renditions can replace it; on
top of it, back to front:

  cloud  the logo's cloud fills and face details, with its outline on top
  rain   the logo's twelve raindrops, thickened to read at icon sizes

The outline and rain are navy on white and white on near-black, like the
light and dark logos. Shapes come from AppStore_Images/Logo/Logo Light.svg, a
512-unit grid. Run from the repo root:

    python3 scripts/app-icon.py

Preview a rendition with ictool, e.g.

    "$DEVELOPER_DIR/Applications/Icon Composer.app/Contents/Executables/ictool" \
        meteocool/AppIcon.icon --export-image --output-file icon.png \
        --platform iOS --rendition Default --width 1024 --height 1024 --scale 1
"""

import json
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "AppStore_Images/Logo/Logo Light.svg"
ICON = ROOT / "meteocool/AppIcon.icon"

INK = (26, 46, 66)          # the outline and rain; the logo's black, softened
PAPER_DARK = (16, 24, 34)   # the dark rendition's background

CANVAS = 1024
# The logo spans x 0..512, y 9..504 on its grid. Scale it into the middle of
# the icon grid, inside the mask, so nothing is clipped.
SCALE = 1.5
TX = CANVAS / 2 - 256 * SCALE
TY = CANVAS / 2 - 256.5 * SCALE

# The source drops are as thin as the outline, which is unreadable at icon
# sizes; stroking them thickens each one without moving it.
DROP_STROKE = 10


def svg(body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" '
            f'viewBox="0 0 {CANVAS} {CANVAS}"><g transform="translate({TX:.3f},{TY:.3f}) '
            f'scale({SCALE})">{body}</g></svg>\n')


def rgb(c):
    return "rgb({},{},{})".format(*c)


def fill(d, color):
    return f'<path d="{d}" style="fill:{color};"/>'


def main():
    paths = [d for d, _ in re.findall(r'<path d="([^"]+)" style="([^"]*)"', SOURCE.read_text())]
    back, front, shade, *details, outline = paths
    subpaths = [s for s in re.split(r"(?=M)", outline) if s]

    def top(s):
        return min(map(float, re.findall(r"-?\d+\.?\d*", s)[1::2]))

    # Raindrops are the outline's closed subpaths below the cloud.
    drops = [s for s in subpaths if top(s) > 305]
    lines = "".join(s for s in subpaths if top(s) <= 305)
    assert len(drops) == 12, f"expected 12 raindrops, found {len(drops)}"

    def rain(color):
        return "".join(f'<path d="{d}" style="fill:{color};stroke:{color};stroke-width:{DROP_STROKE};'
                       f'stroke-linejoin:round;"/>' for d in drops)

    art = {
        "cloud.svg": (fill(back, "rgb(139,205,216)") + fill(front, "rgb(185,232,239)")
                      + fill(shade, "rgb(171,223,235)")
                      + "".join(fill(d, "rgb(139,205,216)") for d in details)),
        "outline.svg": fill(lines, rgb(INK)),
        "outline-dark.svg": fill(lines, "white"),
        "rain.svg": rain(rgb(INK)),
        "rain-dark.svg": rain("white"),
    }

    if ICON.exists():
        shutil.rmtree(ICON)
    (ICON / "Assets").mkdir(parents=True)
    for name, body in art.items():
        (ICON / "Assets" / name).write_text(svg(body))

    def layer(name, light, dark):
        return {
            "name": name,
            "image-name-specializations": [
                {"value": light},
                {"appearance": "dark", "value": dark},
                {"appearance": "tinted", "value": dark},
            ],
        }

    def group(layers):
        return {
            "layers": [{**each, "glass": True} for each in layers],
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "translucency": {"enabled": False, "value": 0.5},
        }

    def solid(c):
        return {"solid": "srgb:" + ",".join(f"{v / 255:.5f}" for v in (*c, 255))}

    document = {
        "fill-specializations": [
            {"value": solid((255, 255, 255))},
            {"appearance": "dark", "value": solid(PAPER_DARK)},
        ],
        # Front to back; within a group, layers are front to back too.
        "groups": [
            group([layer("rain", "rain.svg", "rain-dark.svg")]),
            group([layer("outline", "outline.svg", "outline-dark.svg"),
                   layer("cloud", "cloud.svg", "cloud.svg")]),
        ],
        "supported-platforms": {"squares": ["iOS"]},
    }
    (ICON / "icon.json").write_text(json.dumps(document, indent=2) + "\n")


if __name__ == "__main__":
    main()
