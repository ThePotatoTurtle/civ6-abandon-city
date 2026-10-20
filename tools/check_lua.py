#!/usr/bin/env python3
"""check_lua.py - Lua 5.1 syntax check + global-variable lint for ABN (PLAN 6.1).

Usage:
    python tools/check_lua.py <root> [--basic] [--no-globals] [--luacheck auto|on|off] [--strict] [--info]

What it does for every .lua under <root>:
  1. Syntax: compiles the file with a real Lua 5.1 parser (lupa.lua51, `loadstring`; nothing is
     executed). Firaxis/Havok type annotations (`local x:number`), goto, //, bitwise ops all fail.
  2. Globals: dumps the compiled chunk (`string.dump`) and reads GETGLOBAL / SETGLOBAL from the
     Lua 5.1 bytecode. A global read that is neither Lua 5.1 stdlib, a Civ VI engine global
     (api_allowlist.json + api_allowlist_extra.json), nor assigned at top level by a file in the same
     include group is an ERROR (typos such as `Plyers`, missing include). Assigning a global inside
     a function that no file defines at top level is a WARN (missing `local`?).
  3. luacheck (optional): if `luacheck` is on PATH or in tools/bin, runs it with tools/.luacheckrc.
  --basic: no Lua runtime; weak block/bracket balance scan only.
Exit code 1 on any ERROR (or WARN with --strict).
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import struct
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import abnlib as L  # noqa: E402

# ---------------------------------------------------------------------------
# Lua runtime
# ---------------------------------------------------------------------------
_RT = None
_COMPILE = None


def lua_runtime():
    """Returns a lupa Lua 5.1 runtime or None."""
    global _RT, _COMPILE
    if _RT is not None:
        return _RT or None
    try:
        import lupa.lua51 as lua51  # type: ignore
    except Exception:
        _RT = False
        return None
    rt = lua51.LuaRuntime(encoding=None, unpack_returned_tuples=True)
    ver = rt.eval("_VERSION")
    if isinstance(ver, bytes):
        ver = ver.decode()
    if ver != "Lua 5.1":
        _RT = False
        return None
    _RT = rt
    _COMPILE = rt.eval(
        "function(src, name) local f, e = loadstring(src, name) "
        "if not f then return false, e end return true, string.dump(f) end")
    return rt


def compile_lua(src_bytes, chunkname):
    lua_runtime()
    ok, res = _COMPILE(src_bytes, chunkname.encode("utf-8"))
    if ok:
        return True, res
    if isinstance(res, bytes):
        res = res.decode("utf-8", "replace")
    return False, res


# ---------------------------------------------------------------------------
# Lua 5.1 bytecode reader (GETGLOBAL = 5, SETGLOBAL = 7)
# ---------------------------------------------------------------------------
class BytecodeError(Exception):
    pass


def read_globals(dump: bytes):
    """Returns list of (op, name, line, depth) where op is 'get' or 'set'."""
    if dump[:4] != b"\x1bLua" or dump[4] != 0x51:
        raise BytecodeError("not a Lua 5.1 chunk")
    little = dump[6] == 1
    s_int, s_size, s_ins, s_num = dump[7], dump[8], dump[9], dump[10]
    e = "<" if little else ">"
    fmt = {4: "i", 8: "q"}
    ufmt = {4: "I", 8: "Q"}
    pos = [12]

    def rd(fmtc, size):
        v = struct.unpack_from(e + fmtc, dump, pos[0])[0]
        pos[0] += size
        return v

    def r_int():
        return rd(fmt[s_int], s_int)

    def r_size():
        return rd(ufmt[s_size], s_size)

    def r_byte():
        v = dump[pos[0]]
        pos[0] += 1
        return v

    def r_str():
        n = r_size()
        if n == 0:
            return None
        s = dump[pos[0]:pos[0] + n - 1]
        pos[0] += n
        return s.decode("utf-8", "replace")

    out = []

    def func(depth):
        r_str()                 # source
        r_int(); r_int()        # linedefined, lastlinedefined
        pos[0] += 4             # nups, numparams, is_vararg, maxstacksize
        ncode = r_int()
        code = [rd(ufmt[s_ins], s_ins) for _ in range(ncode)]
        nk = r_int()
        consts = []
        for _ in range(nk):
            t = r_byte()
            if t == 0:
                consts.append(None)
            elif t == 1:
                consts.append(bool(r_byte()))
            elif t == 3:
                pos[0] += s_num
                consts.append(0)
            elif t == 4:
                consts.append(r_str())
            else:
                raise BytecodeError("bad constant type %d" % t)
        nproto = r_int()
        for _ in range(nproto):
            func(depth + 1)
        nline = r_int()
        lines = [r_int() for _ in range(nline)]
        nloc = r_int()
        for _ in range(nloc):
            r_str(); r_int(); r_int()
        nup = r_int()
        for _ in range(nup):
            r_str()
        for pc, ins in enumerate(code):
            op = ins & 0x3F
            if op in (5, 7):
                bx = ins >> 14
                name = consts[bx] if bx < len(consts) else None
                line = lines[pc] if pc < len(lines) else 0
                out.append(("get" if op == 5 else "set", name, line, depth))

    func(0)
    return out


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
_ANNOT_LOCAL = re.compile(r"^\s*local\s+[A-Za-z_]\w*\s*:\s*[A-Za-z_]")
_ANNOT_PARAM = re.compile(r"\bfunction\b[^(]*\([^)]*\b[A-Za-z_]\w*\s*:\s*[A-Za-z_]\w*")


def annotation_hits(src):
    """Havok/Firaxis type annotations (PLAN 6.1 rule check). Token based so strings/comments are ignored."""
    hits = []
    try:
        toks, _ = L.lex(src)
    except L.LexError:
        return hits
    n = len(toks)
    for i, t in enumerate(toks):
        # local name : Type
        if t.kind == "kw" and t.val == "local" and i + 3 < n and toks[i + 1].kind == "name" \
                and toks[i + 2].kind == "op" and toks[i + 2].val == ":" and toks[i + 3].kind == "name":
            hits.append(t.line)
        # function f(a : Type) or ): Type
        if t.kind == "kw" and t.val == "function":
            j = i + 1
            while j < n and not (toks[j].kind == "op" and toks[j].val == "("):
                j += 1
            k = j + 1
            while k < n and not (toks[k].kind == "op" and toks[k].val == ")"):
                if toks[k].kind == "op" and toks[k].val == ":" and k + 1 < n and toks[k + 1].kind == "name":
                    hits.append(toks[k].line)
                    break
                k += 1
            if k + 2 < n and toks[k + 1].kind == "op" and toks[k + 1].val == ":" and toks[k + 2].kind == "name" \
                    and toks[k + 2].line == toks[k].line and not (k + 3 < n and toks[k + 3].kind == "op" and toks[k + 3].val == "("):
                hits.append(toks[k + 1].line)
    return sorted(set(hits))


def find_luacheck():
    exe = shutil.which("luacheck")
    if exe:
        return exe
    for cand in ("luacheck.exe", "luacheck"):
        p = os.path.join(L.TOOLS_DIR, "bin", cand)
        if os.path.exists(p):
            return p
    return None


def run_luacheck(exe, files, rep, project_globals=()):
    cfg = os.path.join(L.TOOLS_DIR, ".luacheckrc")
    cmd = [exe, "--formatter", "plain", "--codes", "--no-color"]
    if os.path.exists(cfg):
        cmd += ["--config", cfg]
    if project_globals:
        cmd += ["--globals"] + sorted(project_globals)
    cmd += files
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    except Exception as e:  # pragma: no cover
        rep.warn("", 0, "luacheck", "could not run luacheck: %s" % e)
        return
    pat = re.compile(r"^(.*?):(\d+):(\d+): \((\w)(\d+)\) (.*)$")
    for line in proc.stdout.splitlines():
        m = pat.match(line.strip())
        if not m:
            continue
        path, ln, col, kind, code, msg = m.groups()
        level = "ERROR" if kind == "E" else "WARN"
        rep.add(level, os.path.abspath(path), int(ln), "luacheck-%s%s" % (kind, code), msg)


def check(root, basic=False, globals_check=True, luacheck="auto", rep=None):
    rep = rep or L.Report("check_lua", base=L.PROJECT_DIR)
    root = os.path.abspath(root)
    rt = None if basic else lua_runtime()
    if not basic and rt is None:
        rep.warn("", 0, "no-runtime", "lupa (Lua 5.1) not importable: falling back to --basic scan. Run: pip install lupa")
        basic = True
    proj = L.LuaProject(root)
    if not proj.files:
        rep.info(root, 0, "no-files", "no .lua files found")
        return rep
    gl_by_file = {}
    for f in proj.files:
        with open(f, "rb") as fh:
            raw = fh.read()
        if raw.startswith(b"\xef\xbb\xbf"):
            rep.warn(f, 1, "bom", "UTF-8 BOM at start of file (strip it; the game's Lua loader may choke on it)")
            raw = raw[3:]
        text = raw.decode("utf-8", "replace")
        for ln in annotation_hits(text):
            rep.error(f, ln, "type-annotation", "Havok/Firaxis type annotation (e.g. `local x:number`) is not plain Lua 5.1 (PLAN 0)")
        if basic:
            try:
                toks, _ = L.lex(text)
            except L.LexError as e:
                rep.error(f, e.line, "syntax", e.msg)
                continue
            for ln, msg in L.block_balance(toks):
                rep.error(f, ln, "syntax-basic", msg)
            continue
        chunk = "@" + os.path.relpath(f, L.PROJECT_DIR).replace("\\", "/") if f.lower().startswith(L.PROJECT_DIR.lower()) else "@" + f
        ok, res = compile_lua(raw, chunk)
        if not ok:
            m = re.match(r"^(?:.*?):(\d+): (.*)$", res, re.S)
            ln, msg = (int(m.group(1)), m.group(2)) if m else (0, res)
            rep.error(f, ln, "syntax", msg)
            continue
        if globals_check:
            try:
                gl_by_file[f] = read_globals(res)
            except (BytecodeError, struct.error, IndexError) as e:
                rep.warn(f, 0, "bytecode", "could not read bytecode for the globals check: %s" % e)

    if globals_check and gl_by_file:
        check_globals(proj, gl_by_file, rep)

    if luacheck != "off":
        exe = find_luacheck()
        if exe:
            pg = {n for g in gl_by_file.values() for op, n, _, d in g if op == "set" and d == 0 and n}
            run_luacheck(exe, proj.files, rep, pg)
        elif luacheck == "on":
            rep.error("", 0, "luacheck", "luacheck requested but not found on PATH or in tools/bin")
        else:
            rep.info("", 0, "luacheck", "luacheck not installed; built-in bytecode globals check used instead")
    return rep


def _inline_globals(src):
    names = set()
    for m in re.finditer(r"--\s*(?:luacheck:\s*globals|ABN:GLOBALS)\s+([^\n]+)", src):
        names |= set(re.findall(r"[A-Za-z_]\w*", m.group(1)))
    return names


def check_globals(proj, gl_by_file, rep):
    """Every Lua state is one entry point (AddGameplayScripts file, AddUserInterfaces context, ReplaceUIScript)
    plus everything it include()s. A global read in file F must be defined in every state F runs in
    (restricted to G or UI states inside ABN:G-ONLY / ABN:UI-ONLY regions). Files that belong to no
    state (no modinfo) fall back to their include-connected component."""
    engine = L.engine_globals()
    base_exports = L.base_include_exports()
    known_std = L.LUA51_GLOBALS
    top = {f: {n for op, n, _, d in g if op == "set" and d == 0 and n} for f, g in gl_by_file.items()}
    anyset = {f: {n for op, n, _, d in g if op == "set" and n} for f, g in gl_by_file.items()}

    def env(files):
        """(defined-at-top, defined-anywhere, base-exports, unresolved includes) for a set of files."""
        d_top, d_any, extra, unresolved = set(), set(), set(), set()
        for c in files:
            d_top |= top.get(c, set())
            d_any |= anyset.get(c, set())
            for inc in proj.includes.get(c, []):
                if proj.resolve_include(inc, c) is None:
                    exp = base_exports.get(os.path.basename(inc).lower())
                    if exp is None:
                        unresolved.add(inc)
                    else:
                        extra |= exp
        return d_top, d_any, extra, unresolved

    state_env = {}
    for entry, ctx in proj.entries:
        state_env[(entry, ctx)] = env(proj.closure(entry))

    for f, g in gl_by_file.items():
        inline = _inline_globals(proj.src[f])
        try:
            _t, comments = L.lex(proj.src[f])
            regions, _p = L.region_map(comments)
        except L.LexError:
            regions = []
        states = [(e, c) for (e, c) in proj.entries if f in proj.closure(e)]
        if not states:
            comp_env = env(proj.component(f))
        reported = set()
        for op, name, line, depth in g:
            if name is None:
                continue
            if op == "set":
                if name in engine and name != "include":
                    rep.error(f, line, "engine-global-overwritten", "assignment to engine global '%s'" % name)
                elif name in known_std:
                    rep.error(f, line, "std-global-overwritten", "assignment to Lua standard global '%s'" % name)
                elif depth > 0 and (name, "set") not in reported:
                    tops = set().union(*(state_env[s][0] for s in states)) if states else comp_env[0]
                    if name not in tops and name not in inline:
                        reported.add((name, "set"))
                        rep.warn(f, line, "global-assign-in-function",
                                 "global '%s' assigned inside a function and never defined at top level (missing 'local'?)" % name)
                continue
            if name in known_std or name in engine or name in inline or name in reported:
                continue
            if name in L.LUA51_DISCOURAGED:
                reported.add(name)
                rep.warn(f, line, "discouraged-global", "'%s' is Lua stdlib but not available/allowed in Civ VI mods" % name)
                continue
            if states:
                lctx = L.line_context(proj.ctx[f], regions, line)
                relevant = [s for s in states if s[1] in lctx] or states
                envs = [(s, state_env[s]) for s in relevant]
            else:
                envs = [(None, comp_env)]
            missing, only_late, unresolved = [], False, set()
            for s, (d_top, d_any, extra, unres) in envs:
                if name in d_top or name in extra:
                    continue
                if name in d_any:
                    only_late = True
                    continue
                missing.append(s)
                unresolved |= unres
            if not missing:
                if only_late:
                    reported.add(name)
                    rep.warn(f, line, "global-only-in-function",
                             "global '%s' is only ever assigned inside a function (make it a top-level definition or a local)" % name)
                continue
            reported.add(name)
            where = ""
            if missing[0] is not None and len(missing) < len(envs):
                where = " in the %s state of %s (defined in the other state(s) this file runs in)" % (
                    missing[0][1], os.path.basename(missing[0][0]))
            elif missing[0] is not None and len(envs) > 1:
                where = " in any state this file runs in"
            if unresolved:
                rep.warn(f, line, "undefined-global",
                         "global '%s' is not defined%s; it may come from base-game include(s) %s (list its globals in "
                         "api_allowlist_extra.json base_includes, or add a '-- ABN:GLOBALS %s' comment)" % (
                             name, where, ", ".join(sorted(unresolved)), name))
            else:
                rep.error(f, line, "undefined-global",
                          "undefined global '%s'%s (typo? missing include? not an engine global)" % (name, where))


def main(argv=None):
    L.configure_stdout()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("root", nargs="?", default=os.path.join(L.PROJECT_DIR, "ABN"))
    ap.add_argument("--basic", action="store_true", help="no Lua runtime: block/bracket balance scan only")
    ap.add_argument("--no-globals", action="store_true", help="skip the undefined-global check")
    ap.add_argument("--luacheck", choices=("auto", "on", "off"), default="auto")
    ap.add_argument("--strict", action="store_true", help="warnings fail too")
    ap.add_argument("--info", action="store_true", help="print INFO lines")
    a = ap.parse_args(argv)
    if not os.path.exists(a.root):
        print("check_lua: root not found: %s" % a.root)
        return 2
    rep = check(a.root, basic=a.basic, globals_check=not a.no_globals, luacheck=a.luacheck)
    rt = None if a.basic else lua_runtime()
    print("check_lua: runtime = %s" % ("lupa " + __import__("lupa").__version__ + " (Lua 5.1)" if rt else "none (--basic scan)"))
    rep.print(show_info=a.info)
    return rep.exit_code(a.strict)


if __name__ == "__main__":
    sys.exit(main())
