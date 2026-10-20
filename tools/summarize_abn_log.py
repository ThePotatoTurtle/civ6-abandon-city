#!/usr/bin/env python3
"""summarize_abn_log.py - one line per check, spike lines by section, and the error count from Lua.log.

Usage:
    python tools/summarize_abn_log.py [--log PATH] [--max-lines N] [-v]

Reads Lua.log of the last game run (default: %LOCALAPPDATA%\\Firaxis Games\\Sid Meier's Civilization
VI\\Logs\\Lua.log, or the ABN_CIV6_LOGS folder). Lua.log is buffered while the game runs: quit to the
desktop (or the main menu) first.

Lines it reads (the prefix before "[ABN]" is ignored, e.g. "ABN_Dev_Gameplay: "):
    [ABN][CHECK] <ID> PASS|FAIL|INFO|CHECK <text>
        One line per check ID, in order of first appearance. The latest PASS/FAIL/CHECK line of an ID
        wins (a later INFO line does not hide a verdict); an ID with only INFO lines shows its latest
        INFO line. "(+n earlier)" counts the other lines of that ID.
    [ABN][SPIKE] <section> <text>      or      [ABN][SPIKE][<section>] <text>
        Grouped by section: sections named like S1/V3 first (natural order), then other names.
        A line without a section goes to "other". Up to --max-lines lines per section (default 10,
        the last ones); -v prints them all.
    Runtime Error / Syntax Error / stack traceback
        Counted; the first few are printed (all with -v).

Exit code: 0 when no check ends in FAIL or CHECK and there are no error lines, 1 otherwise,
2 when the log file is missing.
"""
from __future__ import annotations

import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import abnlib as L  # noqa: E402

PREFIX = "ABN"
TAG = re.escape("[%s]" % PREFIX)
CHECK_RE = re.compile(TAG + r"\[CHECK\]\s+(\S+)\s+(PASS|FAIL|INFO|CHECK)\b\s*(.*)$")
SPIKE_RE = re.compile(TAG + r"\[SPIKE\](?:\[([^\]]+)\])?\s*(.*)$")
SECTION_RE = re.compile(r"^([SV]\d+[a-z]?)\b[:\s]*(.*)$")
ERROR_RE = re.compile(r"Runtime Error|Syntax Error|stack traceback")


def parse(lines):
    """Returns (checks, spikes, errors).
    checks: {id: [(verdict, text, line_no)]} in order of first appearance;
    spikes: {section: [(text, line_no)]}; errors: [(line_no, line)]."""
    checks, spikes, errors = {}, {}, []
    for n, ln in enumerate(lines, 1):
        ln = ln.rstrip("\r\n")
        m = CHECK_RE.search(ln)
        if m:
            checks.setdefault(m.group(1), []).append((m.group(2), m.group(3).strip(), n))
            continue
        m = SPIKE_RE.search(ln)
        if m:
            section, text = m.group(1), m.group(2).strip()
            if section is None:
                ms = SECTION_RE.match(text)
                if ms:
                    section, text = ms.group(1), ms.group(2).strip()
            if section is None:
                section = "other"
            elif re.fullmatch(r"[sSvV]\d+[a-zA-Z]?", section):
                section = section[0].upper() + section[1:].lower()
            spikes.setdefault(section, []).append((text, n))
            continue
        if ERROR_RE.search(ln):
            errors.append((n, ln.strip()))
    return checks, spikes, errors


def result_of(entries):
    """(verdict, text, earlier_count) of one check ID."""
    verdicts = [e for e in entries if e[0] != "INFO"]
    last = verdicts[-1] if verdicts else entries[-1]
    return last[0], last[1], len(entries) - 1


def section_key(name):
    m = re.fullmatch(r"([SV])(\d+)([a-z]?)", name)
    if m:
        return (0, (m.group(1), int(m.group(2)), m.group(3)), name)
    if name == "other":
        return (2, 0, name)
    return (1, 0, name)


def summarize(lines, verbose=False, max_lines=10, out=None):
    out = out or sys.stdout
    checks, spikes, errors = parse(lines)
    bad = 0
    out.write("Checks (%d):\n" % len(checks))
    if not checks:
        out.write("  none\n")
    width = max([len(c) for c in checks] + [4])
    for cid, entries in checks.items():
        verdict, text, earlier = result_of(entries)
        if verdict in ("FAIL", "CHECK"):
            bad += 1
        more = "  (+%d earlier)" % earlier if earlier else ""
        out.write("  %-*s  %-5s  %s%s\n" % (width, cid, verdict, text, more))
        if verbose and earlier:
            for v, t, n in entries[:-1]:
                out.write("  %-*s    line %d: %s %s\n" % (width, "", n, v, t))
    out.write("\nSpike lines (%d):\n" % sum(len(v) for v in spikes.values()))
    if not spikes:
        out.write("  none\n")
    for name in sorted(spikes, key=section_key):
        items = spikes[name]
        out.write("  [%s] %d line(s)\n" % (name, len(items)))
        shown = items if verbose or len(items) <= max_lines else items[-max_lines:]
        if len(shown) < len(items):
            out.write("    ... %d earlier line(s) hidden (-v shows all)\n" % (len(items) - len(shown)))
        for text, n in shown:
            out.write("    %s\n" % text)
    out.write("\nErrors: %s\n" % ("none" if not errors else "%d error line(s)" % len(errors)))
    for n, ln in (errors if verbose else errors[:5]):
        out.write("  line %d: %s\n" % (n, ln))
    if errors and not verbose and len(errors) > 5:
        out.write("  ... %d more (-v shows all)\n" % (len(errors) - 5))
    status = "FAIL" if bad or errors else "PASS"
    out.write("\nsummarize_abn_log: %s - %d check(s), %d FAIL/CHECK, %d spike line(s), %d error line(s)\n" % (
        status, len(checks), bad, sum(len(v) for v in spikes.values()), len(errors)))
    return 1 if status == "FAIL" else 0


def main(argv=None):
    L.configure_stdout()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--log", default=os.path.join(L.LOGS_DIR, "Lua.log"), help="Lua.log to read")
    ap.add_argument("--max-lines", type=int, default=10, help="spike lines shown per section (default 10)")
    ap.add_argument("-v", "--verbose", action="store_true", help="every spike line, earlier check lines and every error line")
    a = ap.parse_args(argv)
    try:
        with open(a.log, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError as e:
        print("summarize_abn_log: cannot read %s (%s)" % (a.log, e.strerror or e))
        return 2
    print("summarize_abn_log: %s (%d lines)\n" % (a.log, len(lines)))
    return summarize(lines, verbose=a.verbose, max_lines=a.max_lines)


if __name__ == "__main__":
    sys.exit(main())
