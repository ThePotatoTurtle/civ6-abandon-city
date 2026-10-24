"""Shared helpers for the ABN static tools (stdlib only).

Contents:
  Report            collects findings, prints them, computes the exit code
  lex()             Lua 5.1 tokenizer (comments and strings handled, line numbers kept)
  scan_functions()  function definitions with names, token ranges and handler registration
  scan_chains()     call / member chains starting at a name  (Players[]:GetUnits():FindID())
  ModInfo           parsed .modinfo
  find_mods(), iter_files(), file contexts (G / UI) and ABN:G-ONLY / ABN:UI-ONLY regions
"""
from __future__ import annotations

import os
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(TOOLS_DIR)
def _documents_dir():
    """The Windows Documents folder, following a redirect (OneDrive, another drive); ~/Documents elsewhere."""
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                            r"Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders") as k:
            return os.path.expandvars(winreg.QueryValueEx(k, "Personal")[0])
    except (ImportError, OSError):
        return os.path.join(os.path.expanduser("~"), "Documents")


def steam_libraries():
    """Steam library roots: the install folder from the registry plus every "path" in libraryfolders.vdf."""
    steam = None
    try:
        import winreg
        for hive, key, name in ((winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam", "SteamPath"),
                                (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath")):
            try:
                with winreg.OpenKey(hive, key) as k:
                    steam = os.path.normpath(winreg.QueryValueEx(k, name)[0])
                    break
            except OSError:
                pass
    except ImportError:
        pass
    libs = [steam] if steam else []
    if steam:
        try:
            with open(os.path.join(steam, "steamapps", "libraryfolders.vdf"), encoding="utf-8") as f:
                # the vdf escapes backslashes: "C:\\Program Files (x86)\\Steam"
                libs += [os.path.normpath(m.group(1).replace("\\\\", "\\"))
                         for m in re.finditer(r'"path"\s+"([^"]+)"', f.read())]
        except OSError:
            pass
    seen, out = set(), []
    for lib in libs:
        if lib.lower() not in seen:
            seen.add(lib.lower())
            out.append(lib)
    return out


def find_game_dir():
    """The Civ VI install folder in whichever Steam library has it (None when not found)."""
    for lib in steam_libraries():
        p = os.path.join(lib, "steamapps", "common", "Sid Meier's Civilization VI")
        if os.path.isdir(p):
            return p
    return None


# Documents side: Mods\ lives here (the game loads mods from this folder). Override with ABN_CIV6_USER_DIR.
GAME_USER_DIR = os.environ.get("ABN_CIV6_USER_DIR") or os.path.join(_documents_dir(), "My Games",
                                                                  "Sid Meier's Civilization VI")
MODS_DIR = os.path.join(GAME_USER_DIR, "Mods")
# AppData side: live logs and the live DB cache (the Documents copies are stale, from 2023)
GAME_APPDATA_DIR = os.path.join(os.environ.get("LOCALAPPDATA") or os.path.join(os.path.expanduser("~"), "AppData", "Local"),
                                "Firaxis Games", "Sid Meier's Civilization VI")
LOGS_DIR = os.environ.get("ABN_CIV6_LOGS") or os.path.join(GAME_APPDATA_DIR, "Logs")


def _newest(*paths):
    found = [p for p in paths if os.path.exists(p)]
    if not found:
        return paths[0]
    return max(found, key=os.path.getmtime)


# newest existing cache wins; override with --db or the ABN_CIV6_DB / ABN_CIV6_LOC_DB environment variables
GAMEPLAY_DB = os.environ.get("ABN_CIV6_DB") or _newest(
    os.path.join(GAME_APPDATA_DIR, "Cache", "DebugGameplay.sqlite"),
    os.path.join(GAME_USER_DIR, "Cache", "DebugGameplay.sqlite"))
LOCALIZATION_DB = os.environ.get("ABN_CIV6_LOC_DB") or _newest(
    os.path.join(GAME_APPDATA_DIR, "Cache", "DebugLocalization.sqlite"),
    os.path.join(GAME_USER_DIR, "Cache", "DebugLocalization.sqlite"))

# directories never scanned
PRUNE_DIRS = {".git", ".claude", "__pycache__", "research", "tools", "node_modules", ".vs"}

GS_GUID = "4873eb62-8ccc-4574-b784-dda455e74e68"
OFFICIAL_GUIDS = {
    GS_GUID: "Expansion: Gathering Storm",
    "1b28771a-c749-434b-9053-d1380c553de9": "Expansion: Rise and Fall",
}

# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------
LEVELS = ("ERROR", "WARN", "INFO")


@dataclass
class Finding:
    level: str
    path: str
    line: int
    code: str
    msg: str


class Report:
    def __init__(self, tool: str, base: str | None = None):
        self.tool = tool
        self.base = base
        self.items: list[Finding] = []
        self._seen: set = set()

    def add(self, level, path, line, code, msg):
        key = (level, path, line, code, msg)
        if key in self._seen:
            return
        self._seen.add(key)
        self.items.append(Finding(level, path or "", int(line or 0), code, msg))

    def error(self, path, line, code, msg):
        self.add("ERROR", path, line, code, msg)

    def warn(self, path, line, code, msg):
        self.add("WARN", path, line, code, msg)

    def info(self, path, line, code, msg):
        self.add("INFO", path, line, code, msg)

    def count(self, level):
        return sum(1 for f in self.items if f.level == level)

    def rel(self, path):
        if not path:
            return "-"
        try:
            base = self.base or PROJECT_DIR
            r = os.path.relpath(path, base)
            return path if r.startswith("..") else r
        except ValueError:
            return path

    def print(self, show_info=False, stream=None):
        stream = stream or sys.stdout
        order = {"ERROR": 0, "WARN": 1, "INFO": 2}
        items = sorted(self.items, key=lambda f: (order[f.level], f.path, f.line, f.code))
        for f in items:
            if f.level == "INFO" and not show_info:
                continue
            loc = self.rel(f.path) + (":%d" % f.line if f.line else "")
            stream.write("%s: %s [%s] %s\n" % (loc, f.level, f.code, f.msg))
        stream.write("%s: %d error(s), %d warning(s), %d info\n" % (
            self.tool, self.count("ERROR"), self.count("WARN"), self.count("INFO")))

    def exit_code(self, strict=False):
        if self.count("ERROR"):
            return 1
        if strict and self.count("WARN"):
            return 1
        return 0


def configure_stdout():
    for s in (sys.stdout, sys.stderr):
        try:
            s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass


# --------------------------------------------------------------------------
# File discovery
# --------------------------------------------------------------------------
def iter_files(root, exts=None):
    root = os.path.abspath(root)
    if os.path.isfile(root):
        if exts is None or os.path.splitext(root)[1].lower() in exts:
            yield root
        return
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in PRUNE_DIRS)
        for fn in sorted(filenames):
            if exts is None or os.path.splitext(fn)[1].lower() in exts:
                yield os.path.join(dirpath, fn)


def read_text(path):
    """Returns (text, had_bom). Decodes UTF-8, falls back to cp1252."""
    with open(path, "rb") as fh:
        data = fh.read()
    bom = data.startswith(b"\xef\xbb\xbf")
    if bom:
        data = data[3:]
    try:
        return data.decode("utf-8"), bom
    except UnicodeDecodeError:
        return data.decode("cp1252", errors="replace"), bom


def read_file(path):
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def find_modinfos(root):
    return [p for p in iter_files(root, {".modinfo"})]


# --------------------------------------------------------------------------
# Lua lexer
# --------------------------------------------------------------------------
KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in",
    "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
}


class LexError(Exception):
    def __init__(self, line, msg):
        super().__init__("line %d: %s" % (line, msg))
        self.line = line
        self.msg = msg


@dataclass
class Tok:
    kind: str   # name, kw, str, num, op
    val: str
    line: int


_LONG_OPEN = re.compile(r"\[(=*)\[")
_NUM = re.compile(r"0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?")
_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_OPS3 = ("...",)
_OPS2 = ("..", "==", "~=", "<=", ">=", "//", "::", "<<", ">>")


def lex(src: str):
    """Tokenize Lua source. Returns (tokens, comments) where comments is a list of (line, text)."""
    toks: list[Tok] = []
    comments: list[tuple[int, str]] = []
    i, n, line = 0, len(src), 1
    if src.startswith("#"):  # shebang line
        while i < n and src[i] != "\n":
            i += 1
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            i += 1
            continue
        if c in " \t\r\f\v":
            i += 1
            continue
        if src.startswith("--", i):
            m = _LONG_OPEN.match(src, i + 2)
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, m.end())
                if j < 0:
                    raise LexError(line, "unfinished long comment")
                text = src[m.end():j]
                comments.append((line, text))
                line += text.count("\n")
                i = j + len(close)
            else:
                j = src.find("\n", i)
                if j < 0:
                    j = n
                comments.append((line, src[i + 2:j]))
                i = j
            continue
        if c == "[":
            m = _LONG_OPEN.match(src, i)
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, m.end())
                if j < 0:
                    raise LexError(line, "unfinished long string")
                text = src[m.end():j]
                if text.startswith("\r\n"):
                    text = text[2:]
                elif text.startswith("\n"):
                    text = text[1:]
                toks.append(Tok("str", text, line))
                line += src[m.end():j].count("\n")
                i = j + len(close)
                continue
        if c in "\"'":
            q = c
            j = i + 1
            buf = []
            start_line = line
            while True:
                if j >= n:
                    raise LexError(start_line, "unfinished string")
                ch = src[j]
                if ch == "\\":
                    nxt = src[j + 1] if j + 1 < n else ""
                    if nxt == "\n":
                        line += 1
                        buf.append("\n")
                    else:
                        buf.append({"n": "\n", "t": "\t", "r": "\r"}.get(nxt, nxt))
                    j += 2
                    continue
                if ch == "\n":
                    raise LexError(start_line, "unfinished string")
                if ch == q:
                    break
                buf.append(ch)
                j += 1
            toks.append(Tok("str", "".join(buf), start_line))
            i = j + 1
            continue
        if c.isdigit() or (c == "." and i + 1 < n and src[i + 1].isdigit()):
            m = _NUM.match(src, i)
            toks.append(Tok("num", m.group(0), line))
            i = m.end()
            continue
        m = _NAME.match(src, i)
        if m:
            w = m.group(0)
            toks.append(Tok("kw" if w in KEYWORDS else "name", w, line))
            i = m.end()
            continue
        if src.startswith("...", i):
            toks.append(Tok("op", "...", line))
            i += 3
            continue
        two = src[i:i + 2]
        if two in _OPS2:
            toks.append(Tok("op", two, line))
            i += 2
            continue
        toks.append(Tok("op", c, line))
        i += 1
    return toks, comments


def skip_balanced(toks, i):
    """toks[i] is an opening bracket; returns index after the matching close."""
    pairs = {"(": ")", "[": "]", "{": "}"}
    stack = [pairs[toks[i].val]]
    j = i + 1
    while j < len(toks) and stack:
        t = toks[j]
        if t.kind == "op":
            if t.val in pairs:
                stack.append(pairs[t.val])
            elif stack and t.val == stack[-1]:
                stack.pop()
        j += 1
    return j


# --------------------------------------------------------------------------
# Structure: functions, blocks, chains
# --------------------------------------------------------------------------
@dataclass
class FuncDef:
    name: str | None          # "ABN_Util.SortedKeys", "OnFoo", "M:Bar" or None (anonymous)
    start: int                # token index of 'function'
    end: int                  # token index of matching 'end'
    line: int
    end_line: int
    is_local: bool = False
    registered_to: str | None = None   # "Events.PlayerDefeat" when passed inline to .Add(
    depth: int = 0            # nesting depth (0 = top-level function)


def _name_chain_back(toks, j):
    """Reads a dotted name ending at toks[j] backwards. Returns (text, start_index) or (None, j)."""
    parts = []
    k = j
    while k >= 0 and toks[k].kind == "name":
        parts.append(toks[k].val)
        if k - 1 >= 0 and toks[k - 1].kind == "op" and toks[k - 1].val in (".", ":"):
            parts.append(toks[k - 1].val)
            k -= 2
            continue
        break
    if not parts:
        return None, j
    return "".join(reversed(parts)), k


def _chain_text_back_before_add(toks, j):
    """toks[j] == '(' of X.Y.Add( ; returns 'X.Y' if the callee is ...Add / ...Remove."""
    if j - 1 < 0 or toks[j - 1].kind != "name":
        return None
    text, _ = _name_chain_back(toks, j - 1)
    if not text:
        return None
    m = re.match(r"^(.*)\.(Add|Remove)$", text)
    return m.group(1) if m else None


def scan_functions(toks):
    """Finds all function definitions. Returns list[FuncDef] (ordered by start)."""
    funcs: list[FuncDef] = []
    stack = []  # entries: ("function", FuncDef) or ("block", None)
    i = 0
    n = len(toks)
    while i < n:
        t = toks[i]
        if t.kind == "kw":
            if t.val == "function":
                name = None
                is_local = i > 0 and toks[i - 1].kind == "kw" and toks[i - 1].val == "local"
                j = i + 1
                if j < n and toks[j].kind == "name":
                    parts = [toks[j].val]
                    j += 1
                    while j + 1 < n and toks[j].kind == "op" and toks[j].val in (".", ":") and toks[j + 1].kind == "name":
                        parts.append(toks[j].val + toks[j + 1].val)
                        j += 2
                    name = "".join(parts)
                registered = None
                if name is None:
                    p = i - 1
                    if p >= 0 and toks[p].kind == "op" and toks[p].val == "=":
                        text, k = _name_chain_back(toks, p - 1)
                        if text:
                            name = text
                            is_local = k >= 0 and toks[k].kind == "kw" and toks[k].val == "local"
                    elif p >= 0 and toks[p].kind == "op" and toks[p].val == "(":
                        registered = _chain_text_back_before_add(toks, p)
                fd = FuncDef(name, i, -1, t.line, -1, is_local, registered,
                             depth=sum(1 for s in stack if s[0] == "function"))
                funcs.append(fd)
                stack.append(("function", fd))
            elif t.val in ("if", "do", "repeat"):
                stack.append(("block", None))
            elif t.val in ("end", "until"):
                if stack:
                    kind, fd = stack.pop()
                    if kind == "function":
                        fd.end = i
                        fd.end_line = t.line
        i += 1
    for fd in funcs:
        if fd.end < 0:
            fd.end = n - 1
            fd.end_line = toks[-1].line if toks else fd.line
    return funcs


def block_balance(toks):
    """Weak structural check used when no Lua runtime exists. Returns list of (line, msg)."""
    problems = []
    stack = []
    br = {"(": ")", "[": "]", "{": "}"}
    bstack = []
    for t in toks:
        if t.kind == "kw":
            if t.val in ("function", "if", "do", "repeat"):
                stack.append((t.val, t.line))
            elif t.val == "end":
                if not stack or stack[-1][0] == "repeat":
                    problems.append((t.line, "'end' without matching block opener"))
                else:
                    stack.pop()
            elif t.val == "until":
                if not stack or stack[-1][0] != "repeat":
                    problems.append((t.line, "'until' without 'repeat'"))
                else:
                    stack.pop()
        elif t.kind == "op":
            if t.val in br:
                bstack.append((br[t.val], t.line))
            elif t.val in (")", "]", "}"):
                if not bstack or bstack[-1][0] != t.val:
                    problems.append((t.line, "unbalanced '%s'" % t.val))
                else:
                    bstack.pop()
            elif t.val in ("//", "::", "<<", ">>", "&", "|", "~"):
                problems.append((t.line, "operator '%s' is not Lua 5.1" % t.val))
        if t.kind == "name" and t.val == "goto":
            problems.append((t.line, "'goto' is not Lua 5.1"))
    for kind, line in stack:
        problems.append((line, "'%s' block is never closed" % kind))
    for close, line in bstack:
        problems.append((line, "bracket opened here is never closed (expected '%s')" % close))
    return problems


@dataclass
class Chain:
    head: str
    parts: list        # e.g. ['Players', '[]', ':GetUnits', '()', ':FindID', '()']
    line: int
    idx: int           # token index of head
    first_arg: object = None   # for X.Y.Add(fn): the token index of the first argument of the first call


def scan_chains(toks):
    """Every primary-expression chain that starts with a plain name."""
    chains = []
    n = len(toks)
    for i, t in enumerate(toks):
        if t.kind != "name":
            continue
        if i > 0:
            p = toks[i - 1]
            if p.kind == "op" and p.val in (".", ":"):
                continue
            if p.kind == "kw" and p.val in ("function", "local"):
                continue
        parts = [t.val]
        j = i + 1
        first_arg = None
        while j < n:
            u = toks[j]
            if u.kind == "op" and u.val == "." and j + 1 < n and toks[j + 1].kind == "name":
                parts.append("." + toks[j + 1].val)
                j += 2
            elif u.kind == "op" and u.val == ":" and j + 1 < n and toks[j + 1].kind == "name":
                parts.append(":" + toks[j + 1].val)
                j += 2
            elif u.kind == "op" and u.val == "[":
                parts.append("[]")
                j = skip_balanced(toks, j)
            elif u.kind == "op" and u.val == "(":
                if first_arg is None:
                    first_arg = j + 1
                parts.append("()")
                j = skip_balanced(toks, j)
            elif u.kind == "str":
                parts.append("()")
                j += 1
            elif u.kind == "op" and u.val == "{" and len(parts) > 0 and parts[-1] != "()":
                # f{...} call syntax
                parts.append("()")
                j = skip_balanced(toks, j)
            else:
                break
        # skip names that are table-constructor keys ({ Foo = 1 }) or assignment targets of locals
        chains.append(Chain(t.val, parts, t.line, i, first_arg))
    return chains


def scan_method_calls(toks):
    """All ':Name(' method calls. Returns list of (method, line, token_index)."""
    out = []
    for i in range(len(toks) - 2):
        a, b, c = toks[i], toks[i + 1], toks[i + 2]
        if a.kind == "op" and a.val == ":" and b.kind == "name" and (
                (c.kind == "op" and c.val in ("(", "{")) or c.kind == "str"):
            out.append((b.val, b.line, i + 1))
    return out


def local_names(toks):
    """Crude set of names declared local anywhere (locals, params, loop vars)."""
    names = set()
    n = len(toks)
    for i, t in enumerate(toks):
        if t.kind == "kw" and t.val == "local":
            j = i + 1
            if j < n and toks[j].kind == "kw" and toks[j].val == "function":
                if j + 1 < n and toks[j + 1].kind == "name":
                    names.add(toks[j + 1].val)
                continue
            while j < n and toks[j].kind == "name":
                names.add(toks[j].val)
                if j + 1 < n and toks[j + 1].kind == "op" and toks[j + 1].val == ",":
                    j += 2
                else:
                    break
        elif t.kind == "kw" and t.val == "function":
            j = i + 1
            while j < n and not (toks[j].kind == "op" and toks[j].val == "("):
                j += 1
            j += 1
            while j < n and not (toks[j].kind == "op" and toks[j].val == ")"):
                if toks[j].kind == "name":
                    names.add(toks[j].val)
                j += 1
        elif t.kind == "kw" and t.val == "for":
            j = i + 1
            while j < n and not (toks[j].kind == "kw" and toks[j].val in ("in", "do")) and not (toks[j].kind == "op" and toks[j].val == "="):
                if toks[j].kind == "name":
                    names.add(toks[j].val)
                j += 1
    return names


def top_level_global_assignments(toks, funcs):
    """Names assigned as globals outside functions: 'X = ...', 'function X(', 'function X.Y('.
    Returns dict root_name -> first line."""
    inside = [False] * len(toks)
    for fd in funcs:
        if fd.depth == 0:
            for k in range(fd.start, fd.end + 1):
                inside[k] = True
    n = len(toks)
    locs = set()
    for i, t in enumerate(toks):
        if inside[i] or not (t.kind == "kw" and t.val == "local"):
            continue
        j = i + 1
        while j < n and toks[j].kind == "name":
            locs.add(toks[j].val)
            if j + 1 < n and toks[j + 1].kind == "op" and toks[j + 1].val == ",":
                j += 2
            else:
                break
    out = {}
    bdepth = []
    depth = 0
    for t in toks:
        if t.kind == "op" and t.val in ("{", "(", "["):
            depth += 1
        elif t.kind == "op" and t.val in ("}", ")", "]"):
            depth -= 1
        bdepth.append(depth)
    for fd in funcs:
        if fd.depth == 0 and fd.name and not fd.is_local and bdepth[fd.start] == 0:
            root = re.split(r"[.:]", fd.name)[0]
            if root not in locs:
                out.setdefault(root, fd.line)
    for i, t in enumerate(toks):
        depth = bdepth[i]
        if inside[i] or depth != 0 or t.kind != "name":
            continue
        if i > 0 and ((toks[i - 1].kind == "op" and toks[i - 1].val in (".", ":")) or
                      (toks[i - 1].kind == "kw" and toks[i - 1].val in ("local", "function"))):
            continue
        if i + 1 < n and toks[i + 1].kind == "op" and toks[i + 1].val == "=" and t.val not in locs:
            out.setdefault(t.val, t.line)
    return out


def string_literals(toks):
    return [(t.val, t.line, i) for i, t in enumerate(toks) if t.kind == "str"]


# --------------------------------------------------------------------------
# modinfo
# --------------------------------------------------------------------------
@dataclass
class Action:
    section: str          # InGameActions / FrontEndActions
    type: str             # UpdateDatabase, AddGameplayScripts, ...
    id: str | None
    criteria: str | None
    props: dict
    files: list           # list of (relpath, priority attr)
    line: int = 0


@dataclass
class ModInfo:
    path: str
    root: str
    id: str | None = None
    version: str | None = None
    props: dict = field(default_factory=dict)
    deps: list = field(default_factory=list)       # (id, title)
    refs: list = field(default_factory=list)
    criteria: list = field(default_factory=list)
    actions: list = field(default_factory=list)
    files: list = field(default_factory=list)      # list of relpaths
    parse_error: str | None = None
    parse_error_line: int = 0


def _local(tag):
    return tag.split("}", 1)[-1]


def parse_modinfo(path) -> ModInfo:
    mi = ModInfo(path=path, root=os.path.dirname(os.path.abspath(path)))
    try:
        tree = ET.parse(path)
    except ET.ParseError as e:
        mi.parse_error = str(e)
        mi.parse_error_line = getattr(e, "position", (0, 0))[0]
        return mi
    root = tree.getroot()
    mi.id = root.get("id")
    mi.version = root.get("version")
    for child in root:
        tag = _local(child.tag)
        if tag == "Properties":
            for p in child:
                mi.props[_local(p.tag)] = (p.text or "").strip()
        elif tag in ("Dependencies", "References", "Blocks"):
            for m in child:
                entry = (m.get("id"), m.get("title"))
                (mi.deps if tag == "Dependencies" else mi.refs).append(entry)
        elif tag == "ActionCriteria":
            for c in child:
                mi.criteria.append(c.get("id"))
        elif tag in ("InGameActions", "FrontEndActions"):
            for a in child:
                props = {}
                files = []
                for sub in a:
                    st = _local(sub.tag)
                    if st == "Properties":
                        for p in sub:
                            props[_local(p.tag)] = (p.text or "").strip()
                    elif st == "File":
                        files.append(((sub.text or "").strip(), sub.get("priority")))
                mi.actions.append(Action(tag, _local(a.tag), a.get("id"), a.get("criteria"), props, files))
        elif tag == "Files":
            for f in child:
                mi.files.append((f.text or "").strip())
    return mi


def norm_rel(p):
    return p.replace("\\", "/").strip()


# --------------------------------------------------------------------------
# Lua file contexts
# --------------------------------------------------------------------------
SHARED_BASENAMES = {"abn_config", "abn_util", "abn_rules"}
_CTX_OVERRIDE = re.compile(r"ABN:CONTEXT\s+(G|UI|both)\b", re.I)
_INCLUDE = re.compile(r"""\binclude\s*\(?\s*["']([^"']+)["']""")


def lua_includes(src):
    out = []
    for m in _INCLUDE.finditer(src):
        name = m.group(1)
        if name.lower().endswith(".lua"):
            name = name[:-4]
        out.append(name)
    return out


class LuaProject:
    """All .lua files under a root, with context (G/UI) and include graph."""

    def __init__(self, root):
        self.root = os.path.abspath(root)
        self.files = list(iter_files(self.root, {".lua"}))
        self.by_base = {}
        for f in self.files:
            self.by_base.setdefault(os.path.splitext(os.path.basename(f))[0].lower(), []).append(f)
        self.src = {}
        self.includes = {}
        for f in self.files:
            text, _ = read_text(f)
            self.src[f] = text
            self.includes[f] = lua_includes(text)
        self.mods = [parse_modinfo(p) for p in find_modinfos(self.root)]
        self.ctx = self._contexts()

    def resolve_include(self, name, from_file=None):
        cands = self.by_base.get(os.path.basename(name).lower(), [])
        if not cands:
            return None
        if from_file and len(cands) > 1:
            # prefer the same mod
            for c in cands:
                if os.path.commonpath([c, from_file]).startswith(self._mod_root(from_file) or "\0"):
                    return c
        return cands[0]

    def _mod_root(self, f):
        best = None
        for mi in self.mods:
            if os.path.abspath(f).lower().startswith(mi.root.lower() + os.sep):
                if best is None or len(mi.root) > len(best):
                    best = mi.root
        return best

    def _contexts(self):
        ctx = {f: set() for f in self.files}
        entry = {}
        for mi in self.mods:
            for a in mi.actions:
                for rel, _ in a.files:
                    full = os.path.normpath(os.path.join(mi.root, rel))
                    if a.type == "AddGameplayScripts" and full.lower().endswith(".lua"):
                        entry.setdefault(full, set()).add("G")
                    elif a.type == "AddUserInterfaces" and full.lower().endswith(".xml"):
                        lua = os.path.splitext(full)[0] + ".lua"
                        entry.setdefault(lua, set()).add("UI")
                    elif a.type == "ReplaceUIScript":
                        pass
                rep = a.props.get("LuaReplace")
                if a.type == "ReplaceUIScript" and rep:
                    entry.setdefault(os.path.normpath(os.path.join(mi.root, rep)), set()).add("UI")
        lower = {f.lower(): f for f in self.files}
        # Lua states: one per entry point (file, ctx)
        self.entries = []
        for f, cs in entry.items():
            real = lower.get(f.lower())
            if real:
                for c in sorted(cs):
                    self.entries.append((real, c))
        # propagate through includes
        work = []
        for f, c in entry.items():
            real = lower.get(f.lower())
            if real:
                ctx[real] |= c
                work.append(real)
        seen = set()
        while work:
            f = work.pop()
            for inc in self.includes.get(f, []):
                tgt = self.resolve_include(inc, f)
                if tgt and not ctx[f] <= ctx[tgt]:
                    ctx[tgt] |= ctx[f]
                    work.append(tgt)
                elif tgt and (f, tgt) not in seen:
                    seen.add((f, tgt))
        # fallbacks + overrides
        for f in self.files:
            m = _CTX_OVERRIDE.search(self.src[f][:2000])
            if m:
                v = m.group(1).lower()
                ctx[f] = {"G", "UI"} if v == "both" else {v.upper()}
                continue
            if ctx[f]:
                continue
            base = os.path.splitext(os.path.basename(f))[0].lower()
            parts = [p.lower() for p in os.path.relpath(f, self.root).replace("\\", "/").split("/")]
            if base in SHARED_BASENAMES:
                ctx[f] = {"G", "UI"}
            elif "scripts" in parts[:-1]:
                ctx[f] = {"G"}
            elif "ui" in parts[:-1]:
                ctx[f] = {"UI"}
            elif re.search(r"(gameplay|script)", base):
                ctx[f] = {"G"}
            else:
                ctx[f] = {"UI"}
        return ctx

    def closure(self, f):
        """f plus every project file it include()s, transitively (one Lua state)."""
        cache = self.__dict__.setdefault("_closure", {})
        if f in cache:
            return cache[f]
        seen = {f}
        work = [f]
        while work:
            x = work.pop()
            for inc in self.includes.get(x, []):
                y = self.resolve_include(inc, x)
                if y and y not in seen:
                    seen.add(y)
                    work.append(y)
        cache[f] = seen
        return seen

    def component(self, f):
        """Files connected with f through include edges (either direction)."""
        adj = {}
        for a in self.files:
            for inc in self.includes[a]:
                b = self.resolve_include(inc, a)
                if b:
                    adj.setdefault(a, set()).add(b)
                    adj.setdefault(b, set()).add(a)
        seen = {f}
        work = [f]
        while work:
            x = work.pop()
            for y in adj.get(x, ()):
                if y not in seen:
                    seen.add(y)
                    work.append(y)
        return seen


# the marker must be the whole comment ("-- ABN:G-ONLY begin"), so prose that mentions it does not count
_REGION = re.compile(r"^\s*ABN:(G|UI)-ONLY\s+(begin|end)\b", re.I)


def region_map(comments):
    """Returns (regions, problems). regions: list of (start_line, end_line, ctx)."""
    regions, problems = [], []
    open_ = None
    for line, text in comments:
        m = _REGION.search(text)
        if not m:
            continue
        c, what = m.group(1).upper(), m.group(2).lower()
        if what == "begin":
            if open_:
                problems.append((line, "ABN:%s-ONLY begin inside an open ABN:%s-ONLY region (line %d)" % (c, open_[1], open_[0])))
            open_ = (line, c)
        else:
            if not open_ or open_[1] != c:
                problems.append((line, "ABN:%s-ONLY end without matching begin" % c))
            else:
                regions.append((open_[0], line, c))
            open_ = None
    if open_:
        problems.append((open_[0], "ABN:%s-ONLY region never closed" % open_[1]))
    return regions, problems


def line_context(file_ctx, regions, line):
    for a, b, c in regions:
        if a <= line <= b:
            return {c}
    return set(file_ctx)


def load_json(path, default):
    import json
    if not os.path.exists(path):
        return default
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


# --------------------------------------------------------------------------
# Global name sets
# --------------------------------------------------------------------------
LUA51_GLOBALS = {
    "assert", "collectgarbage", "error", "getfenv", "getmetatable", "ipairs", "next", "pairs",
    "pcall", "print", "rawequal", "rawget", "rawset", "select", "setfenv", "setmetatable",
    "tonumber", "tostring", "type", "unpack", "xpcall", "_G", "_VERSION", "loadstring",
    "coroutine", "math", "string", "table", "os",
}
# present in stock Lua 5.1 but not usable / not wanted in a Civ VI mod
LUA51_DISCOURAGED = {"dofile", "load", "loadfile", "module", "require", "package", "io", "debug", "newproxy", "gcinfo"}

# PLAN 6.1 engine globals (luacheck list); api_allowlist.json roots are added at runtime
PLAN_ENGINE_GLOBALS = [
    "Game", "Players", "Map", "UnitManager", "CityManager", "GameInfo", "GameEvents", "Events",
    "LuaEvents", "NotificationManager", "PlayerManager", "GameConfiguration", "Locale",
    "ParameterTypes", "CityTransferTypes", "MilitaryFormationTypes", "DirectionTypes", "Units",
    "PlayersVisibility", "DealManager", "DealItemTypes", "UI", "UIManager", "ContextPtr", "Controls",
    "PopupPriority", "Mouse", "KeyEvents", "Keys", "PlayerOperations", "CityCommandTypes",
    "CityDestroyDirectives", "UnitOperationTypes", "InterfaceModeTypes", "Modding", "MapLayers",
    "include", "unpack",
]


def engine_globals():
    """Engine globals: PLAN 6.1 list + engine_globals.json (harvested from the game's Lua) +
    api_allowlist.json roots + api_allowlist_extra.json globals."""
    names = set(PLAN_ENGINE_GLOBALS) | harvested_engine_globals()
    al = load_json(os.path.join(TOOLS_DIR, "api_allowlist.json"), {})
    names |= set(al.get("globals", {}).keys())
    ex = load_json(os.path.join(TOOLS_DIR, "api_allowlist_extra.json"), {})
    names |= set(ex.get("globals", {}).keys())
    return names


def harvested_engine_globals():
    return set(load_json(os.path.join(TOOLS_DIR, "engine_globals.json"), {}).get("globals", []))


def base_include_exports():
    ex = load_json(os.path.join(TOOLS_DIR, "api_allowlist_extra.json"), {})
    return {k.lower(): set(v) for k, v in ex.get("base_includes", {}).items() if not k.startswith("_")}
