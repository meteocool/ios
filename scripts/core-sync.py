#!/usr/bin/env python3
"""What meteocool/core has that the native map has not caught up with.

The native map (meteocool/NativeMap) ports core's web map. This script reads
three things and lays them side by side:

- core's history since the commit the port was last synced to
  (`core` in scripts/core-sync.json),
- the core files each Swift file says it ports: a comment naming the file,
  `lib/archive.ts` or `StormPanel.svelte`, anywhere in it,
- the core files the ledger sets aside (`webOnly`, `unported`), each with why.

    scripts/core-sync.py                 # commits to port, each file with its Swift side
    scripts/core-sync.py coverage        # core files no Swift file names and the ledger omits
    scripts/core-sync.py export [dir]    # core at the target ref, to read and to run
                                         # scripts/core-strings.py on (default build/core)
    scripts/core-sync.py mark [ref]      # record the port as synced to ref

Options: --core path/to/core (default: ../core, or ~/meteocool/core),
--ref REF (default origin/develop; fetched first unless --no-fetch).

AGENTS.md, "Syncing with core", says how a sync goes.
"""
import argparse
import fnmatch
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LEDGER = ROOT / "scripts" / "core-sync.json"
# Where ports of core live, and the checks ported from core's unit tests.
SWIFT = ["meteocool/NativeMap", "meteocool/lib", "tests", "meteocoolUITests"]
# The part of core the native map ports. Generated code, data and assets are
# reported as hints, not as files to port.
PORTED = ["src", "scripts/tests"]
HINTS = [
    ("src/locale/", "strings changed: scripts/core-sync.py export, then scripts/core-strings.py build/core"),
    ("spec/", "the API's spec changed: check NativeMapEndpoints.swift and the decoders (StormData.swift, RadarFrames.swift)"),
    ("src/api/generated/", None),
    ("src/radarInfo/", "the radars' pages changed: scripts/core-radar-info.py build/core"),
    ("public/", None),
    ("tests/ui/", "core's UI tests changed: see what meteocoolUITests should cover"),
    ("src/colormaps.ts", "palettes changed: scripts/colormaps.py"),
]
# A core file as a comment names it: `lib/archive.ts`, `StormPanel.svelte`, a
# unit test (`stormStore.test.ts`), an asset copied into the app (`assets/snow.png`).
CITATION = re.compile(r"(?<![A-Za-z0-9_./-])((?:[A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+(?:\.test)?\.(?:svelte|ts|css|mjs|js|json|svg|png|webp))\b")


def git(core, *args):
    done = subprocess.run(["git", "-C", str(core), *args], capture_output=True, text=True)
    if done.returncode != 0:
        sys.exit(f"git {' '.join(args)}: {done.stderr.strip()}")
    return done.stdout


def find_core(given):
    candidates = [pathlib.Path(given)] if given else [ROOT.parent / "core", pathlib.Path.home() / "meteocool" / "core"]
    for candidate in candidates:
        if (candidate / ".git").exists():
            return candidate
    sys.exit("core not found: pass --core path/to/core")


def citations():
    """Core file names as Swift comments write them -> the Swift files."""
    cited = {}
    for folder in SWIFT:
        for path in sorted((ROOT / folder).rglob("*.swift")):
            for line in path.read_text(encoding="utf-8").splitlines():
                comment = line.partition("//")[2]
                for name in CITATION.findall(comment):
                    cited.setdefault(name, set()).add(str(path.relative_to(ROOT)))
    return cited


def swift_for(core_path, cited):
    """The Swift files naming `core_path`, by its name or the end of its path.

    A unit test (`scripts/tests/x.test.ts`) goes with what names `x.ts`.
    """
    if core_path.startswith("scripts/tests/") and core_path.endswith(".test.ts"):
        stem = pathlib.PurePosixPath(core_path).name[: -len(".test.ts")]
        found = set()
        for name, files in cited.items():
            if pathlib.PurePosixPath(name).name in (f"{stem}.ts", f"{stem}.test.ts"):
                found |= files
        return found
    found = set()
    for name, files in cited.items():
        if core_path == name or core_path.endswith("/" + name):
            found |= files
    return found


def set_aside(core_path, ledger):
    for kind in ("webOnly", "unported"):
        for pattern, why in ledger.get(kind, {}).items():
            if fnmatch.fnmatch(core_path, pattern):
                return kind, why
    return None


def in_ported(path):
    if any(path.startswith(prefix) for prefix, _ in HINTS):
        return False
    return any(path == root or path.startswith(root + "/") for root in PORTED)


def describe(path, cited, ledger):
    swift = swift_for(path, cited)
    if swift:
        return "-> " + ", ".join(sorted(swift))
    aside = set_aside(path, ledger)
    if aside:
        return f"{aside[0]}: {aside[1]}"
    return "NEW: no Swift file names it and the ledger omits it"


def status(core, ref, ledger, cited):
    base = ledger["core"]
    head = git(core, "rev-parse", ref).strip()
    print(f"synced to core {base[:8]}, {ref} is {head[:8]}")
    for sha, what in ledger.get("pending", {}).items():
        print(f"\npending from before {base[:8]}: {sha[:8]} {what}")
    commits = git(core, "log", "--reverse", "--no-merges", "--format=%H%x09%s", f"{base}..{head}").splitlines()
    if not commits:
        print("nothing new in core")
    hints = []
    for line in commits:
        sha, subject = line.split("\t", 1)
        print(f"\n{sha[:8]} {subject}")
        for path in git(core, "show", "--format=", "--name-only", sha).split():
            for prefix, hint in HINTS:
                if path.startswith(prefix) and hint and hint not in hints:
                    hints.append(hint)
            if in_ported(path):
                print(f"    {path}  {describe(path, cited, ledger)}")
    for hint in hints:
        print(f"\nnote: {hint}")


def coverage(core, ref, ledger, cited):
    missing = [path for path in git(core, "ls-tree", "-r", "--name-only", ref, "--", *PORTED).split()
               if in_ported(path) and not swift_for(path, cited) and not set_aside(path, ledger)]
    for path in missing:
        print(path)
    print(f"\n{len(missing)} core files are neither named by a Swift file nor set aside in {LEDGER.relative_to(ROOT)}",
          file=sys.stderr)
    return 1 if missing else 0


def export(core, ref, target):
    target.mkdir(parents=True, exist_ok=True)
    archive = subprocess.Popen(["git", "-C", str(core), "archive", ref], stdout=subprocess.PIPE)
    subprocess.run(["tar", "-x", "-C", str(target)], stdin=archive.stdout, check=True)
    if archive.wait() != 0:
        sys.exit("git archive failed")
    print(f"core at {git(core, 'rev-parse', '--short', ref).strip()} in {target}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", nargs="?", default="status", choices=["status", "coverage", "export", "mark"])
    parser.add_argument("argument", nargs="?")
    parser.add_argument("--core")
    parser.add_argument("--ref", default="origin/develop")
    parser.add_argument("--no-fetch", action="store_true")
    options = parser.parse_args()

    core = find_core(options.core)
    ledger = json.loads(LEDGER.read_text())
    if not options.no_fetch and options.ref.startswith("origin/"):
        subprocess.run(["git", "-C", str(core), "fetch", "--quiet", "origin"], check=False)

    if options.command == "status":
        status(core, options.ref, ledger, citations())
    elif options.command == "coverage":
        sys.exit(coverage(core, options.ref, ledger, citations()))
    elif options.command == "export":
        export(core, options.ref, pathlib.Path(options.argument) if options.argument else ROOT / "build" / "core")
    elif options.command == "mark":
        ledger["core"] = git(core, "rev-parse", options.argument or options.ref).strip()
        LEDGER.write_text(json.dumps(ledger, indent=2, ensure_ascii=False) + "\n")
        print(f"synced to core {ledger['core'][:8]}")


if __name__ == "__main__":
    main()
