#!/usr/bin/env python3
"""Generate meteocool/Licences.json, the open-source licences in Settings.

Two sources:
- `LICENSE`, the app's own licence, and `licences/*.txt`, third-party code
  compiled into the app, in `NATIVE` below. Add an entry when the app takes
  in someone else's code.
- core's `public/third-party-licences.json`, written by core's
  `scripts/licences.mjs` from what its production build ships: the web map
  the app shows. It becomes one entry, "Web Map Libraries".

Usage:
    python3 scripts/licences.py [path/to/core]

The core checkout defaults to $MC_CORE, then ../core next to this repository.
Rerun it after core's dependencies change (core reruns its own script then)
and commit the output.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "meteocool" / "Licences.json"

# (name as Settings shows it, SPDX licence, file relative to the repository, what it is)
NATIVE = [
    ("meteocool", "AGPL-3.0", "LICENSE", "this app, https://github.com/meteocool/ios"),
    ("SwiftFSM", "MIT", "licences/SwiftFSM.txt", "meteocool/SwiftFSM.swift, the location button's states"),
    ("Py-ART Colour Maps", "BSD-3-Clause", "licences/Py-ART.txt",
     "the StepSeq, Homeyer and Lang radar palettes (StepSeq25, HomeyerRainbow, LangRainbow12), "
     "resampled for meteocool; meteocool/AR/Colormaps.swift"),
]


def core_path() -> Path:
    if len(sys.argv) > 1:
        return Path(sys.argv[1])
    if os.environ.get("MC_CORE"):
        return Path(os.environ["MC_CORE"])
    return ROOT.parent / "core"


def notice(group: dict) -> str:
    """One licence group of core's, as its imprint shows it."""
    packages = ", ".join(f"{p['name']} {p['version']}".strip() for p in group["packages"])
    body = group["text"].strip()
    if group["copyright"]:
        body = group["copyright"].strip() + "\n\n" + body
    return f"{packages}\n({group['license']})\n\n{body}"


def main() -> None:
    entries = []
    for name, licence, file, what in NATIVE:
        text = (ROOT / file).read_text().strip()
        entries.append({"name": name, "licence": licence, "text": f"{name}: {what}.\n\n{text}\n"})

    source = core_path() / "public" / "third-party-licences.json"
    groups = json.loads(source.read_text())
    # The detail line has room for licence families, not SPDX expressions.
    spdx = " ".join(group["license"] for group in groups)
    families = [name for name, token in [("MIT", "MIT"), ("BSD", "BSD"), ("ISC", "ISC"),
                                         ("Apache 2.0", "Apache-2.0"), ("CC BY 4.0", "CC-BY-4.0")] if token in spdx]
    count = sum(len(group["packages"]) for group in groups)
    intro = (f"meteocool's map is a web page, meteocool/core, shown in the app. "
             f"It is built with these {count} pieces of open-source software.")
    rule = "\n\n" + "─" * 32 + "\n\n"
    entries.append({
        "name": "Web Map Libraries",
        "licence": f"{count} packages · " + ", ".join(families),
        "text": intro + rule + rule.join(notice(group) for group in groups) + "\n",
    })

    OUTPUT.write_text(json.dumps(entries, ensure_ascii=False, indent=1) + "\n")
    print(f"Wrote {OUTPUT.relative_to(ROOT)}: {len(NATIVE)} native entries, {count} core packages in {len(groups)} texts")


if __name__ == "__main__":
    main()
