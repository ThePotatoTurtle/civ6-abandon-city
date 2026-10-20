# Tools: static checks, install and logs

Offline checks for the Abandon City mod (internal prefix `ABN`; players only ever see "Abandon City"), plus the install script and log readers. Run everything from the project folder with Python 3.11+. Only `check_lua.py` needs an extra package: `pip install lupa`.

The tools were ported from the EFV mod's tooling. Rules that belonged to that mod (reason codes, notification plans, PLAN/DECISIONS blocks) are gone.

## Quick start

```
python tools\check_all.py                 # ABN\ and ABN_Dev\ (warns and exits 0 while neither folder exists)
python tools\check_all.py ABN ABN_Dev     # explicit folders (a mod folder or a folder of mods)
python tools\check_all.py ABN --strict    # warnings fail too
python tests\offline\run_tests.py         # fake-engine Lua tests
```

`check_all.py` runs `check_lua.py`, `validate_data.py` and `api_audit.py`; it exits non-zero on any error. Findings look like `path:line: LEVEL [code] message`. `--info` shows INFO lines, `--basic` skips the Lua runtime, `--db PATH` picks another gameplay database, `--no-checklist` hides the list of calls still waiting for an in-game test.

## check_lua.py: Lua syntax and globals

- Every file is compiled (never run) with the real Lua 5.1 parser from `lupa`. Type annotations (`local x:number`), `goto`, `//` and unclosed blocks fail with a line number.
- Global reads and writes are read from the bytecode. Each modinfo entry point plus everything it includes counts as one Lua state. A global that is read must be defined in every state the file runs in. Unknown reads are errors; a global assigned only inside a function is a warning; overwriting an engine global is an error.
- Markers: `-- ABN:GLOBALS Name1 Name2` declares extra globals; code between `-- ABN:G-ONLY begin/end` or `-- ABN:UI-ONLY begin/end` counts only for that context; `-- ABN:CONTEXT G|UI|both` overrides a file's context.

## validate_data.py: XML, modinfo, SQL and text

- XML, `.modinfo` and `.artdef` files are well formed. modinfo: valid ids, criteria on every action, listed files exist (exact case) and every file on disk is listed, Gathering Storm dependency, `AffectsSavedGames=1`.
- SQL: the game's cached gameplay database is copied to a temp folder and the mod's database files run there (leftover `ABN%` rows from earlier games are purged from the copy first). Unknown tables or columns, constraint failures and hash collisions fail.
- Text: duplicate keys, collisions with base-game keys, missing `LOC_*` keys used by Lua/SQL/XML/modinfo, placeholder counts, plural forms, unused keys (warning).
- Player-visible text: the literal word "ABN" in any en_US text value or modinfo Name/Teaser/Description/Authors is an error. `ABN_` keys, types and file names are fine. En and em dashes in text are errors (project style rule).
- Notification types need paired rows, an `ICON_<type>` alias and `_MESSAGE` / `_SUMMARY` keys when the mod defines `ABN_NOTIF_*` types.

DB paths: the newest of `%LOCALAPPDATA%\Firaxis Games\Sid Meier's Civilization VI\Cache\` and `<user dir>\Cache\`. Override with `--db` or `ABN_CIV6_DB` / `ABN_CIV6_LOC_DB`. Other environment variables: `ABN_CIV6_LOGS` (logs folder), `ABN_CIV6_USER_DIR` (the `My Games` folder holding `Mods`; default `C:\Users\goldf\OneDrive\OneNote\My Games\Sid Meier's Civilization VI`).

## api_audit.py: engine calls and multiplayer rules

- `api_allowlist.json` is hand-maintained. It starts with only `print`, `unpack` and `include`; Lua stdlib (string, table, math, coroutine) is built in. `api_allowlist_extra.json` holds further hand additions plus `base_includes` (globals defined by base-game UI files; copied from the EFV tools).
- Add an engine call only with evidence in `refs`: a base-game file and line, a research note, or a closed in-game spike. Entry shape: `{"ctx": {"G": "C", "UI": "C"}, "refs": [...], "note": "...", "only_paths": ["ABN_Dev/"]}`. Levels: `C` confirmed, `L` likely, `NV` new-verify, `PENDING` waits for a test. Anything but `C` prints a warning and lands in the checklist. Sections: `globals`, `static` (`Root.Member` / `Root:Method`), `methods` (name without receiver), `events` (`GameEvents.X`, `Events.X`, `LuaEvents.X`), `gameinfo` (table names), `forbidden` (extra banned names with a reason, in the extra file).
- `engine_globals.json` lists every global the game's own Lua reads but never defines. Rebuild with `python tools\harvest_engine_globals.py [--game PATH]` (default game path: `C:\Program Files (x86)\Steam\steamapps\common\Sid Meier's Civilization VI`).
- Errors: calls not on the list or used in the wrong context, unknown project functions, forbidden patterns (`math.random`, `os.*` in gameplay, `pairs(` over state in gameplay, `table.unpack`, `ExposedMembers`), state changes reachable from `Events.*` handlers in gameplay, and a UI request name (`"ABN_\w+"` strings) without a gameplay handler.

## install.ps1: install and follow the log

```
powershell -ExecutionPolicy Bypass -File tools\install.ps1                # checks, then copy ABN\
powershell -ExecutionPolicy Bypass -File tools\install.ps1 -Dev -Watch    # also ABN_Dev\, then follow Lua.log
powershell -ExecutionPolicy Bypass -File tools\install.ps1 -DevOnly       # only ABN_Dev\
powershell -ExecutionPolicy Bypass -File tools\install.ps1 -Uninstall     # remove Mods\ABN (ABN_Dev stays)
powershell -ExecutionPolicy Bypass -File tools\install.ps1 -CheckLogs     # scan the last run's logs only
```

- Stops at once while Civilization VI is running. Runs `check_all.py` first; errors stop the install unless `-Force` (`-SkipChecks` skips the checks, `-Strict` fails on warnings). `-WatchOnly` tails without installing.
- Mirrors the folders into the Mods folder (`-ModsDir`). It refuses targets outside `-ModsDir` or folders whose name does not start with `ABN`. Files deleted in the source are deleted in the copy too.
- `-Watch` follows `Lua.log`, filtered by `-Pattern` (default `ABN|Runtime Error|Syntax Error|stack traceback`). Lua.log is buffered while you play; read it after quitting to the menu or desktop.
- `-CheckLogs` runs `check_logs.py` on Database.log, Modding.log, Lua.log and UserInterface.log (default folder `%LOCALAPPDATA%\Firaxis Games\Sid Meier's Civilization VI\Logs`). Exit code 1 on errors that involve the mod.

## summarize_abn_log.py: results of an in-game test session

```
python tools\summarize_abn_log.py [--log PATH] [--max-lines N] [-v]
```

Reads `Lua.log` and prints one row per check ID (a per-step PASS/FAIL table) from lines like

```
[ABN][CHECK] <ID> <PASS|FAIL|CHECK|INFO> T<turn> <detail>
```

The latest PASS/FAIL/CHECK line of an ID decides; an ID with only INFO lines shows INFO. `[ABN][SPIKE] <section> <text>` lines are grouped by section. Runtime and syntax errors are counted. Exit code 1 on any FAIL, CHECK or error line, 2 when the log is missing. It is a generic skeleton: no step list is built in.

## Not ported

EFV's `test_tools.py` and its fixtures were not copied; add tests for the tools here when they get changed.
