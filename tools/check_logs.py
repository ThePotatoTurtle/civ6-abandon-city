#!/usr/bin/env python3
"""check_logs.py - scan the game logs of the last run for ABN-related problems.

Usage:
    python tools/check_logs.py [--logs DIR] [--match REGEX] [--all-errors] [--tail N]

Default log folder: %LOCALAPPDATA%\\Firaxis Games\\Sid Meier's Civilization VI\\Logs (the live one; the
Documents\\My Games copy is stale). Override with --logs or the ABN_CIV6_LOGS environment variable.
The game recreates the logs on every launch, so this always reads the last run. Lua.log is buffered
while playing: the full output may only be there after exiting to the main menu or desktop.

Scans
  Database.log       ERROR blocks (with their "While executing" / "from file" context lines) that mention
                     the match pattern; any failed "Validating Foreign Key Constraints".
  Modding.log        which ABN components were applied; warnings/errors near ABN lines.
  Lua.log            Runtime/Syntax errors + stack tracebacks that mention the pattern; ABN lines that say
                     ERROR/FAIL; count of ABN lines.
  UserInterface.log  errors mentioning the pattern (XML context load failures, missing textures).
Exit code 1 if any ABN-related error was found.
"""
from __future__ import annotations

import argparse
import datetime
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import abnlib as L  # noqa: E402

DEFAULT_MATCH = r"ABN"
ERR_RE = re.compile(r"\bERROR\b|Runtime Error|Syntax Error|stack traceback|\bFailed\b|\bfailed\b|Error:|not found", re.I)


def read_lines(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read().splitlines()
    except OSError:
        return None


def stamp(path):
    try:
        return datetime.datetime.fromtimestamp(os.path.getmtime(path)).strftime("%Y-%m-%d %H:%M:%S")
    except OSError:
        return "?"


def scan_database(lines, pat, all_errors):
    findings, other = [], 0
    i = 0
    while i < len(lines):
        ln = lines[i]
        if re.search(r"\bERROR\b", ln):
            block = [ln]
            j = i + 1
            while j < len(lines) and not re.search(r"\bERROR\b|Validating|Passed Validation", lines[j]) and len(block) < 8:
                block.append(lines[j])
                j += 1
            text = "\n".join(block)
            if pat.search(text) or all_errors:
                findings.append((i + 1, block))
            else:
                other += 1
            i = j
            continue
        if "Validating Foreign Key Constraints" in ln and i + 1 < len(lines) and "Passed Validation" not in lines[i + 1]:
            block = lines[i:i + 12]
            findings.append((i + 1, ["FOREIGN KEY VALIDATION FAILED (the whole modded DB is rejected):"] + block))
        i += 1
    return findings, other


def scan_generic(lines, pat, all_errors, context=6):
    findings = []
    i = 0
    while i < len(lines):
        ln = lines[i]
        if re.search(r"Runtime Error|Syntax Error|stack traceback", ln):
            block = [ln]
            j = i + 1
            while j < len(lines) and len(block) < 14 and (lines[j].startswith(("\t", " ")) or "stack traceback" in lines[j] or
                                                         re.search(r"\.lua:\d+", lines[j]) or "[C]" in lines[j]):
                block.append(lines[j])
                j += 1
            if pat.search("\n".join(block)) or all_errors:
                findings.append((i + 1, block))
            i = j
            continue
        if pat.search(ln) and ERR_RE.search(ln):
            findings.append((i + 1, [ln]))
        i += 1
    return findings


def main(argv=None):
    L.configure_stdout()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--logs", default=L.LOGS_DIR)
    ap.add_argument("--match", default=DEFAULT_MATCH, help="regex that marks a line/block as ABN-related (default: ABN)")
    ap.add_argument("--all-errors", action="store_true", help="also report errors that do not mention the pattern")
    ap.add_argument("--tail", type=int, default=0, help="also print the last N ABN lines of Lua.log")
    a = ap.parse_args(argv)
    pat = re.compile(a.match)
    logs = a.logs
    if not os.path.isdir(logs):
        print("check_logs: log folder not found: %s" % logs)
        return 2
    print("check_logs: %s (pattern /%s/)" % (logs, a.match))
    abn_errors = 0

    # Database.log
    p = os.path.join(logs, "Database.log")
    lines = read_lines(p)
    if lines is None:
        print("\n[Database.log] missing")
    else:
        f, other = scan_database(lines, pat, a.all_errors)
        print("\n[Database.log] written %s: %d ABN-related error block(s), %d other error block(s)%s" % (
            stamp(p), len(f), other, "" if a.all_errors else " (use --all-errors to list them)"))
        for n, block in f:
            print("  line %d:" % n)
            for b in block:
                print("    " + b)
        abn_errors += len(f)

    # Modding.log
    p = os.path.join(logs, "Modding.log")
    lines = read_lines(p)
    if lines is None:
        print("\n[Modding.log] missing")
    else:
        comp = [(i + 1, ln) for i, ln in enumerate(lines) if pat.search(ln)]
        print("\n[Modding.log] written %s: %d line(s) mention the pattern" % (stamp(p), len(comp)))
        applied = [ln for _, ln in comp if re.search(r"^\[[\d.]+\]\s+\* ", ln)]
        mods = sorted({re.sub(r"^\[[\d.]+\]\s*", "", ln) for _, ln in comp if re.search(r"[0-9a-f]{8}-[0-9a-f]{4}-", ln)})
        for m in mods:
            print("  mod: " + m)
        for ln in sorted(set(re.sub(r"^\[[\d.]+\]\s*", "", x) for x in applied)):
            print("  component: " + ln.strip())
        errs = [(n, ln) for n, ln in comp if ERR_RE.search(ln) or "Warning" in ln]
        for n, ln in errs:
            print("  line %d: %s" % (n, ln))
        abn_errors += sum(1 for _, ln in errs if ERR_RE.search(ln))
        if not comp:
            print("  (no ABN mod entries: was the mod enabled for this game?)")

    # Lua.log
    p = os.path.join(logs, "Lua.log")
    lines = read_lines(p)
    if lines is None:
        print("\n[Lua.log] missing")
    else:
        f = scan_generic(lines, pat, a.all_errors)
        count = sum(1 for ln in lines if pat.search(ln))
        print("\n[Lua.log] written %s: %d ABN line(s), %d ABN-related error(s)  (Lua.log is buffered: exit to the menu for full output)" % (
            stamp(p), count, len(f)))
        for n, block in f:
            print("  line %d:" % n)
            for b in block:
                print("    " + b)
        abn_errors += len(f)
        if a.tail:
            abn = [ln for ln in lines if pat.search(ln)]
            print("  last %d ABN line(s):" % min(a.tail, len(abn)))
            for ln in abn[-a.tail:]:
                print("    " + ln)

    # UserInterface.log
    p = os.path.join(logs, "UserInterface.log")
    lines = read_lines(p)
    if lines is not None:
        f = scan_generic(lines, pat, a.all_errors)
        print("\n[UserInterface.log] written %s: %d ABN-related error(s)" % (stamp(p), len(f)))
        for n, block in f:
            print("  line %d:" % n)
            for b in block:
                print("    " + b)
        abn_errors += len(f)

    print("\ncheck_logs: %s - %d ABN-related error(s)" % ("FAIL" if abn_errors else "PASS", abn_errors))
    return 1 if abn_errors else 0


if __name__ == "__main__":
    sys.exit(main())
