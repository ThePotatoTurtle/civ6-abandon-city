#!/usr/bin/env python3
"""harvest_engine_globals.py - derive the list of engine-provided Lua globals from the game's own Lua.

Usage:
    python tools/harvest_engine_globals.py [--game PATH-TO-Sid-Meiers-Civilization-VI]
    (default: the Civ VI folder in the Steam libraries from the registry and libraryfolders.vdf)

Writes tools/engine_globals.json. A name counts as an engine global when the game's Lua (Base + DLC UI,
gameplay and scenario scripts) reads it as a global in at least --min-files files and no game Lua file
ever assigns it (so it must come from the engine: enums like YieldTypes, managers like UnitManager,
functions like include). check_lua.py treats these as defined (typo check); api_audit.py still
reports any of them that is not in the the allowlist.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import abnlib as L  # noqa: E402

DEFAULT_GAME = L.find_game_dir()
OUT = os.path.join(L.TOOLS_DIR, "engine_globals.json")
LOWERCASE_ENGINE = {"include", "hstructure", "hmake"}
# enum / manager style names need fewer sightings than other PascalCase names
ENUM_LIKE = re.compile(r"(Types|Type|Directives|Results|Result|Events|Manager|Configuration|Configurations|Parameters|"
                       r"Operations|Options|Priority|Layers|States|Modes|Levels|Keys|Status)$")


def main(argv=None):
    L.configure_stdout()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--game", default=DEFAULT_GAME)
    ap.add_argument("--min-files", type=int, default=2)
    a = ap.parse_args(argv)
    if not a.game:
        ap.error("Civ VI install not found in any Steam library; pass --game")
    roots = [os.path.join(a.game, "Base"), os.path.join(a.game, "DLC")]
    roots = [r for r in roots if os.path.isdir(r)]
    if not roots:
        print("harvest: game folder not found: %s" % a.game)
        return 2
    readers = defaultdict(set)
    assigned = set()
    nfiles = 0
    for root in roots:
        for f in L.iter_files(root, {".lua"}):
            src, _ = L.read_text(f)
            try:
                toks, _c = L.lex(src)
            except L.LexError:
                continue
            nfiles += 1
            funcs = L.scan_functions(toks)
            locs = L.local_names(toks)
            assigned |= set(L.top_level_global_assignments(toks, funcs))
            for fd in funcs:
                if fd.name and not fd.is_local:
                    assigned.add(re.split(r"[.:]", fd.name)[0])
            n = len(toks)
            for i, t in enumerate(toks):
                if t.kind != "name":
                    continue
                prev = toks[i - 1] if i else None
                if prev is not None and ((prev.kind == "op" and prev.val in (".", ":")) or (prev.kind == "kw" and prev.val in ("local", "function"))):
                    continue
                nxt = toks[i + 1] if i + 1 < n else None
                # assignment anywhere (inside functions too): Name = ...
                if nxt is not None and nxt.kind == "op" and nxt.val == "=" and (prev is None or not (prev.kind == "op" and prev.val in ("{", ","))):
                    if t.val not in locs:
                        assigned.add(t.val)
                    continue
                # table-constructor keys {Name = ...}
                if nxt is not None and nxt.kind == "op" and nxt.val == "=":
                    continue
                if t.val in locs:
                    continue
                readers[t.val].add(f)
    def wanted(nm, files):
        if nm in assigned or nm in L.LUA51_GLOBALS or nm in L.LUA51_DISCOURAGED or nm in L.KEYWORDS:
            return False
        if nm in LOWERCASE_ENGINE:
            return True
        if not nm[0].isupper() or re.match(r"^[A-Z0-9_]+$", nm):
            return False  # lower-case names and ALL_CAPS constants are leaked locals / file constants
        if ENUM_LIKE.search(nm):
            return len(files) >= a.min_files
        return len(files) >= max(a.min_files, 4)

    names = sorted(nm for nm, files in readers.items() if wanted(nm, files))
    data = {
        "_source": "harvested by tools/harvest_engine_globals.py from %s (%d Lua files), %s" % (
            a.game, nfiles, datetime.date.today().isoformat()),
        "_rule": ("read as a global and never assigned by game Lua; PascalCase only (plus include/hstructure/hmake); "
                  "enum/manager-like names in >= %d files, other names in >= %d files" % (a.min_files, max(a.min_files, 4))),
        "globals": names,
    }
    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(data, fh, indent=1)
    print("harvest: %d engine globals from %d files -> %s" % (len(names), nfiles, os.path.relpath(OUT, L.PROJECT_DIR)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
