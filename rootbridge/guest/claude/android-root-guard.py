#!/usr/bin/env python3
"""android-root-guard - Claude Code PreToolUse hook (termux-root-bridge v2).

Every execution that can reach Android root (androidsu, adb, fastboot, su,
magisk, ...) has to be confirmed inside the Claude Code session. The hook
answers with permissionDecision "ask", which Claude Code shows as a normal
permission prompt - also in bypassPermissions mode.

For a literal `androidsu '<cmd>'` call the hook additionally issues a
single-use ticket bound to sha256(<cmd>) and injects it into the command via
updatedInput (ROOTBRIDGE_TICKET=<id> androidsu '<cmd>'). The Termux-side
daemon only runs commands with a valid ticket. A denied prompt therefore
means: the command never runs.

stdin : PreToolUse hook JSON
stdout: hookSpecificOutput JSON, or nothing (= no opinion, normal flow)
Python >= 3.8, standard library only.
"""
import hashlib
import json
import os
import re
import secrets
import sys
import time

CONF_PATH = os.environ.get("ROOTBRIDGE_CONF", "/etc/termux-root-bridge.conf")
DEFAULT_BRIDGE_DIR = "/data/data/com.termux/files/home/.rootbridge"
DEFAULT_TTL = 1800

BUILTIN_PROTECTED = [
    "/etc/claude-code",
    "/etc/termux-root-bridge.conf",
    "/usr/local/lib/termux-root-bridge",
    "/usr/local/bin/androidsu",
    "/usr/local/bin/rootbridge-open",
    "/usr/local/bin/rootbridge-claude",
    "/usr/local/bin/xdg-open",
    "/data/data/com.termux/files/home/.rootbridge",
    "/data/data/com.termux/files/home/.config/termux-root-bridge",
    "/data/data/com.termux/files/usr/bin/rootbridge",
    "/data/data/com.termux/files/usr/bin/rootbridge-daemon",
    "/data/data/com.termux/files/usr/lib/termux-root-bridge",
]

# Commands that always need a confirmation.
ROOT_ALWAYS = {"su", "magisk", "magiskboot", "magiskpolicy", "resetprop",
               "setprop", "ksud", "apd", "supolicy"}
ADB_SAFE = {"devices", "version", "help", "get-state", "get-serialno",
            "get-devpath", "start-server", "kill-server"}
FASTBOOT_SAFE = {"devices", "help"}
BRIDGE_CLI = {"rootbridge", "rootbridge-daemon"}
BRIDGE_CLI_SAFE = {"status", "help", "--help", "-h", "login", "attach",
                   "start", "shell", "version", "--version"}

# Programs that run other programs or interpret code: their arguments (and
# script files they get) are scanned for root-related names.
RUNNERS = {"bash", "sh", "dash", "zsh", "ksh", "ash", "busybox", "eval",
           "source", ".", "xargs", "find", "script", "python", "python3",
           "perl", "ruby", "node", "lua", "awk", "gawk", "sudo", "doas",
           "parallel", "watch", "nsenter", "chroot", "proot", "proot-distro",
           "tmux", "screen", "expect", "ssh", "strace", "ltrace", "gdb",
           "unbuffer", "flock", "chronic", "nice", "ionice", "cpulimit"}
WRAPPERS = {"command", "nohup", "builtin", "setsid", "time", "exec", "env",
            "nice", "timeout", "stdbuf"}
RESERVED = {"if", "then", "else", "elif", "fi", "while", "until", "do",
            "done", "for", "case", "esac", "in", "!", "{", "}", "function",
            "select"}

# Commands that only read; mentioning a protected path with them is fine.
READONLY = {"cat", "ls", "head", "tail", "grep", "egrep", "fgrep", "rg",
            "stat", "file", "wc", "diff", "cmp", "sha256sum", "md5sum",
            "less", "more", "tree", "readlink", "realpath", "basename",
            "dirname", "test", "[", "echo", "printf", "jq", "namei", "du",
            "df", "type", "which", "whereis", "command"}
FIND_WRITE_FLAGS = {"-delete", "-exec", "-execdir", "-ok", "-okdir",
                    "-fprint", "-fprintf", "-fls", "-fprint0"}

DANGER = re.compile(
    r"(?<![\w.-])(androidsu|adb|fastboot|su|magisk|magiskboot|resetprop|"
    r"setprop|ksud|apd|supolicy|rootbridge|rootbridge-daemon)(?![\w-])")
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
MAX_SCAN = 512 * 1024


class Unparsable(Exception):
    pass


# --------------------------------------------------------------------------
# configuration
# --------------------------------------------------------------------------
def load_conf(path=None):
    conf = {"BRIDGE_DIR": DEFAULT_BRIDGE_DIR, "TICKET_TTL": str(DEFAULT_TTL),
            "PROTECTED_PATHS": ""}
    try:
        with open(path or CONF_PATH, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                conf[key.strip()] = val.strip().strip("'\"")
    except OSError:
        pass
    return conf


def protected_paths(conf):
    extra = [p for p in conf.get("PROTECTED_PATHS", "").split(":") if p]
    return BUILTIN_PROTECTED + extra


# --------------------------------------------------------------------------
# shell tokenizer (quote aware, no execution)
# --------------------------------------------------------------------------
class Word:
    __slots__ = ("text", "lit", "start", "end")

    def __init__(self, text, lit, start, end):
        self.text, self.lit, self.start, self.end = text, lit, start, end


class Simple:
    def __init__(self):
        self.words = []      # command words (no redirections)
        self.redirs = []     # (operator, Word)
        self.subs = []       # (abs_offset or None, inner_text)
        self.start = None    # offset of the first token
        self.heredoc = False

    def empty(self):
        return not self.words and not self.redirs and not self.subs


def _find_backtick(s, i):
    j = i + 1
    while j < len(s):
        if s[j] == "\\":
            j += 2
            continue
        if s[j] == "`":
            return j
        j += 1
    raise Unparsable("backtick")


def _find_close(s, i, open_ch, close_ch):
    """s[i] == open_ch; return index of the matching close_ch."""
    depth, j, n = 0, i, len(s)
    while j < n:
        c = s[j]
        if c == "\\":
            j += 2
            continue
        if c == "'":
            k = s.find("'", j + 1)
            if k < 0:
                raise Unparsable("quote")
            j = k + 1
            continue
        if c == '"':
            j += 1
            while j < n and s[j] != '"':
                if s[j] == "\\":
                    j += 2
                    continue
                if s[j] == "$" and j + 1 < n and s[j + 1] == "(":
                    j = _find_close(s, j + 1, "(", ")") + 1
                    continue
                j += 1
            if j >= n:
                raise Unparsable("dquote")
            j += 1
            continue
        if c == open_ch:
            depth += 1
        elif c == close_ch:
            depth -= 1
            if depth == 0:
                return j
        j += 1
    raise Unparsable("unbalanced")


def tokenize(s, base=0):
    """Split a shell command line into simple commands."""
    cmds, cur = [], Simple()
    buf, lit, inword, wstart = [], True, False, 0
    redir_op = None
    i, n = 0, len(s)

    def end_word(end):
        nonlocal buf, lit, inword, redir_op
        if not inword:
            return
        w = Word("".join(buf), lit, wstart, end)
        if redir_op is not None:
            cur.redirs.append((redir_op, w))
            redir_op = None
        else:
            if cur.start is None:
                cur.start = w.start
            cur.words.append(w)
        buf, lit, inword = [], True, False

    def end_cmd():
        nonlocal cur, redir_op
        redir_op = None
        if not cur.empty():
            cmds.append(cur)
        cur = Simple()

    def begin(pos):
        nonlocal inword, wstart
        if not inword:
            inword, wstart = True, pos

    while i < n:
        c = s[i]
        if c in " \t":
            end_word(i)
            i += 1
        elif c == "\n":
            end_word(i)
            end_cmd()
            i += 1
        elif c == "#" and not inword:
            while i < n and s[i] != "\n":
                i += 1
        elif c == "\\":
            if i + 1 < n and s[i + 1] == "\n":
                i += 2
                continue
            begin(i)
            if i + 1 < n:
                buf.append(s[i + 1])
            i += 2
        elif c == "'":
            begin(i)
            k = s.find("'", i + 1)
            if k < 0:
                raise Unparsable("quote")
            buf.append(s[i + 1:k])
            i = k + 1
        elif c == '"':
            begin(i)
            i += 1
            while True:
                if i >= n:
                    raise Unparsable("dquote")
                d = s[i]
                if d == '"':
                    i += 1
                    break
                if d == "\\" and i + 1 < n:
                    nxt = s[i + 1]
                    buf.append(nxt if nxt in '\\"$`' else "\\" + nxt)
                    i += 2
                elif d == "$" and i + 1 < n and s[i + 1] == "(":
                    k = _find_close(s, i + 1, "(", ")")
                    cur.subs.append((base + i + 2, s[i + 2:k]))
                    buf.append(s[i:k + 1])
                    lit = False
                    i = k + 1
                elif d == "`":
                    k = _find_backtick(s, i)
                    cur.subs.append((None, s[i + 1:k]))
                    buf.append(s[i:k + 1])
                    lit = False
                    i = k + 1
                elif d == "$" and i + 1 < n and (
                        s[i + 1].isalnum() or s[i + 1] in "_{@*#?$!-"):
                    buf.append(d)
                    lit = False
                    i += 1
                else:
                    buf.append(d)
                    i += 1
        elif c == "`":
            begin(i)
            k = _find_backtick(s, i)
            cur.subs.append((None, s[i + 1:k]))
            buf.append(s[i:k + 1])
            lit = False
            i = k + 1
        elif c == "$":
            begin(i)
            nxt = s[i + 1] if i + 1 < n else ""
            if nxt == "(":
                k = _find_close(s, i + 1, "(", ")")
                cur.subs.append((base + i + 2, s[i + 2:k]))
                buf.append(s[i:k + 1])
                lit = False
                i = k + 1
            elif nxt == "{":
                k = _find_close(s, i + 1, "{", "}")
                buf.append(s[i:k + 1])
                lit = False
                i = k + 1
            elif nxt == "'":
                k = i + 2
                while k < n and s[k] != "'":
                    k += 2 if s[k] == "\\" else 1
                if k >= n:
                    raise Unparsable("ansi-c quote")
                buf.append(s[i:k + 1])
                lit = False
                i = k + 1
            elif nxt and (nxt.isalnum() or nxt in "_@*#?$!-"):
                buf.append(c)
                lit = False
                i += 1
            else:
                buf.append(c)
                i += 1
        elif c in "<>":
            if i + 1 < n and s[i + 1] == "(":
                begin(i)
                k = _find_close(s, i + 1, "(", ")")
                cur.subs.append((base + i + 2, s[i + 2:k]))
                buf.append(s[i:k + 1])
                lit = False
                i = k + 1
                continue
            # an all-digit word directly before the operator is an fd number
            if inword and "".join(buf).isdigit() and lit:
                buf, inword = [], False
            else:
                end_word(i)
            j = i
            while j < n and s[j] in "<>&|-":
                j += 1
            op = s[i:j]
            if "<<" in op and "<<<" not in op:
                cur.heredoc = True
            redir_op = op
            i = j
        elif c in ";|&":
            end_word(i)
            if c == "&" and i + 1 < n and s[i + 1] == ">":
                j = i + 1
                while j < n and s[j] in ">":
                    j += 1
                redir_op = s[i:j]
                i = j
                continue
            end_cmd()
            j = i + 1
            while j < n and s[j] in ";|&":
                j += 1
            i = j
        elif c in "()":
            end_word(i)
            end_cmd()
            i += 1
        else:
            begin(i)
            # unquoted glob / tilde / brace characters are expansions
            if c in "*?[{}" or (c == "~" and len(buf) == 0):
                lit = False
            buf.append(c)
            i += 1
    end_word(n)
    end_cmd()
    return cmds


# --------------------------------------------------------------------------
# analysis
# --------------------------------------------------------------------------
class Ctx:
    def __init__(self, conf, cwd):
        self.conf = conf
        self.cwd = cwd or os.getcwd()
        self.protected = protected_paths(conf)
        self.asks = []        # reason lines
        self.denies = []      # reason lines
        self.tickets = []     # (abs_insert_offset, command_string)


def _base(word):
    return os.path.basename(word.text) if word.text else ""


def _short(text, limit=300):
    text = text.replace("\n", "\\n")
    return text if len(text) <= limit else text[:limit] + "..."


def _skip_wrapper(words, idx):
    """Return index of the wrapped command word, -1 for a pure lookup,
    None if the wrapper cannot be resolved safely."""
    name = _base(words[idx])
    j, n = idx + 1, len(words)

    def is_opt(w):
        return w.text.startswith("-") and w.text != "-"

    if name == "command":
        while j < n and is_opt(words[j]):
            if words[j].text in ("-v", "-V"):
                return -1
            j += 1
    elif name in ("nohup", "builtin", "setsid", "time"):
        while j < n and is_opt(words[j]):
            j += 1
    elif name == "exec":
        while j < n and is_opt(words[j]):
            if words[j].text in ("-c", "-a"):
                return None
            j += 1
    elif name == "env":
        while j < n:
            t = words[j].text
            if is_opt(words[j]):
                if t in ("-i", "--ignore-environment", "-u", "--unset", "-S",
                         "--split-string", "-C", "--chdir", "-0", "-"):
                    return None
                j += 1
            elif ASSIGN.match(t):
                j += 1
            else:
                break
    elif name == "nice":
        while j < n and is_opt(words[j]):
            j += 2 if words[j].text in ("-n", "--adjustment") else 1
    elif name == "timeout":
        while j < n and is_opt(words[j]):
            j += 2 if words[j].text in ("-k", "-s", "--kill-after",
                                         "--signal") else 1
        j += 1  # duration
    elif name == "stdbuf":
        while j < n and is_opt(words[j]):
            j += 2 if words[j].text in ("-i", "-o", "-e") else 1
    else:
        return None
    return j if j < n else None


def _adb_sub(args):
    i = 0
    while i < len(args):
        t = args[i].text
        if t in ("-s", "-t", "-H", "-P", "-L"):
            i += 2
            continue
        if t.startswith("-"):
            i += 1
            continue
        return t
    return None


def _scan_file(path, ctx):
    """True if the readable text file mentions root-related commands."""
    p = path if os.path.isabs(path) else os.path.join(ctx.cwd, path)
    try:
        if not os.path.isfile(p) or os.path.getsize(p) > MAX_SCAN:
            return False
        with open(p, "rb") as fh:
            data = fh.read(MAX_SCAN)
    except OSError:
        return False
    if b"\0" in data[:2048]:
        return False
    return bool(DANGER.search(data.decode("utf-8", "replace")))


def _mentions_protected(text, ctx):
    if ".rootbridge" in text:
        return True
    for p in ctx.protected:
        if p in text:
            return True
    return False


def _path_protected(path, ctx):
    cands = {os.path.normpath(path)}
    try:
        cands.add(os.path.realpath(path))
    except OSError:
        pass
    for c in cands:
        for p in ctx.protected:
            if c == p or c.startswith(p.rstrip("/") + "/"):
                return True
        if "/.rootbridge" in c or c.endswith("/.rootbridge"):
            return True
    return False


def analyze(text, base, depth, ctx):
    """Analyse a shell command line. `base` is the absolute offset of `text`
    inside the original command (None = rewriting not possible)."""
    if depth > 4:
        ctx.asks.append("Verschachtelung zu tief: " + _short(text, 120))
        return
    try:
        cmds = tokenize(text, base if base is not None else 0)
    except Unparsable:
        _fallback(text, ctx, "Befehl nicht eindeutig lesbar")
        return
    if any(c.heredoc for c in cmds):
        _fallback(text, ctx, "Heredoc im Befehl")
        return
    for sc in cmds:
        for off, inner in sc.subs:
            analyze(inner, off if base is not None else None, depth + 1, ctx)
        _simple(sc, text, base, ctx)


def _fallback(text, ctx, why):
    if DANGER.search(text):
        ctx.asks.append("%s, enthält Root-Aufrufe: %s" % (why, _short(text)))
    elif _mentions_protected(text, ctx):
        ctx.asks.append("%s, berührt Bridge-/Guard-Dateien: %s"
                        % (why, _short(text)))


def _simple(sc, text, base, ctx):
    words = sc.words
    i = 0
    while i < len(words) and words[i].text in RESERVED:
        i += 1
    ticket_off = words[i].start if i < len(words) else None
    while i < len(words) and ASSIGN.match(words[i].text):
        i += 1
    hops = 0
    while i < len(words) and _base(words[i]) in WRAPPERS and hops < 6:
        j = _skip_wrapper(words, i)
        if j == -1:
            return
        if j is None:
            raw = " ".join(w.text for w in words)
            if DANGER.search(raw):
                ctx.asks.append("Root-Aufruf hinter Wrapper: " + _short(raw))
            _tamper(sc, ctx)
            return
        i, hops = j, hops + 1
    if i >= len(words):
        _tamper(sc, ctx)
        return

    cmd = _base(words[i])
    args = words[i + 1:]

    if cmd == "androidsu":
        if not args:
            return
        bad = [w.text for w in args if not w.lit]
        if bad:
            ctx.denies.append(
                "androidsu nur mit wörtlichem, einfach gequotetem Befehl "
                "aufrufen (kein $VAR, $(...), Backticks, Glob oder ~), damit "
                "die Freigabe genau den ausgeführten Befehl zeigt. "
                "Nicht wörtlich: " + _short(" ".join(bad), 120))
            return
        cmdstr = " ".join(w.text for w in args).rstrip("\n")
        if base is None or ticket_off is None:
            ctx.asks.append("ANDROID-ROOT (ohne Ticket, Position nicht "
                            "änderbar): " + _short(cmdstr))
        else:
            ctx.tickets.append((base + ticket_off, cmdstr))
            ctx.asks.append("ANDROID-ROOT: " + _short(cmdstr))
    elif cmd in ROOT_ALWAYS:
        ctx.asks.append("ANDROID-ROOT (%s): %s" % (cmd, _short(
            " ".join(w.text for w in words[i:]))))
    elif cmd == "adb":
        sub = _adb_sub(args)
        if sub is not None and sub not in ADB_SAFE:
            ctx.asks.append("adb %s: %s" % (sub, _short(
                " ".join(w.text for w in args))))
    elif cmd == "fastboot":
        first = args[0].text if args else None
        if first is not None and first not in FASTBOOT_SAFE and not (
                first.startswith("-") and first in ("--version", "-h",
                                                    "--help")):
            ctx.asks.append("fastboot: " + _short(
                " ".join(w.text for w in args)))
    elif cmd in BRIDGE_CLI:
        sub = args[0].text if args else None
        if sub is not None and sub not in BRIDGE_CLI_SAFE:
            ctx.asks.append("%s %s (Bridge/Guard-Verwaltung)" % (cmd, sub))
    else:
        scan = cmd in RUNNERS or cmd.startswith("python") or (
            "/" in words[i].text)
        if scan:
            raw = " ".join(w.text for w in args)
            if DANGER.search(raw):
                ctx.asks.append("Indirekter Root-Aufruf über %s: %s" % (
                    cmd, _short(raw)))
            else:
                paths = [w.text for w in args if not w.text.startswith("-")]
                if "/" in words[i].text:
                    paths.append(words[i].text)
                for pth in paths:
                    if _scan_file(pth, ctx):
                        ctx.asks.append("Skript %s enthält Root-Aufrufe"
                                        % _short(pth, 120))
                        break
    _tamper(sc, ctx, cmd, args)


def _tamper(sc, ctx, cmd=None, args=()):
    """Writing to bridge/guard files needs a confirmation."""
    for op, w in sc.redirs:
        if (">" in op) and _path_protected(w.text, ctx):
            ctx.asks.append("Schreibzugriff auf Bridge/Guard: " + _short(
                w.text, 160))
            return
    mention = [w.text for w in list(sc.words)] + [
        w.text for _, w in sc.redirs]
    if not any(_mentions_protected(t, ctx) for t in mention):
        return
    if cmd in READONLY:
        return
    if cmd == "find" and not any(a.text in FIND_WRITE_FLAGS for a in args):
        return
    ctx.asks.append("Änderung an Bridge-/Guard-Dateien: " + _short(
        " ".join(mention), 200))


# --------------------------------------------------------------------------
# tickets
# --------------------------------------------------------------------------
def make_ticket(conf, cmdstr, display):
    tdir = os.path.join(conf["BRIDGE_DIR"], "tickets")
    os.makedirs(tdir, mode=0o700, exist_ok=True)
    now = int(time.time())
    # drop expired tickets of earlier runs
    try:
        for name in os.listdir(tdir):
            fp = os.path.join(tdir, name)
            try:
                if now - os.path.getmtime(fp) > 2 * int(conf["TICKET_TTL"]):
                    os.unlink(fp)
            except OSError:
                pass
    except OSError:
        pass
    tid = secrets.token_hex(16)
    digest = hashlib.sha256(cmdstr.encode("utf-8")).hexdigest()
    expires = now + int(conf["TICKET_TTL"])
    tmp = os.path.join(tdir, ".%s.tmp" % tid)
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("%d\n%s\n%s\n" % (expires, digest, display.replace("\n", " ")))
    os.chmod(tmp, 0o600)
    os.replace(tmp, os.path.join(tdir, tid))
    return tid


# --------------------------------------------------------------------------
# hook entry
# --------------------------------------------------------------------------
def decide(data, conf=None, issue_tickets=True):
    """Return None (no opinion) or the hook output dict."""
    conf = conf or load_conf()
    tool = data.get("tool_name", "")
    tin = data.get("tool_input") or {}
    ctx = Ctx(conf, data.get("cwd"))

    command = tin.get("command") if isinstance(tin, dict) else None
    if isinstance(command, str) and tool in ("Bash", "Monitor"):
        analyze(command, 0, 0, ctx)
    elif tool in ("Write", "Edit", "NotebookEdit", "MultiEdit"):
        path = tin.get("file_path") or tin.get("notebook_path") or ""
        if path and _path_protected(path, ctx):
            ctx.asks.append("Änderung an Bridge-/Guard-Datei: " + path)
    else:
        return None

    if ctx.denies:
        return _out("deny", " | ".join(ctx.denies))
    if not ctx.asks:
        return None

    updated = None
    reasons = ["⚠ termux-root-bridge"] + ctx.asks
    if ctx.tickets and isinstance(command, str):
        if issue_tickets:
            try:
                new, shift = command, 0
                for off, cmdstr in sorted(ctx.tickets):
                    tid = make_ticket(conf, cmdstr, cmdstr)
                    ins = "ROOTBRIDGE_TICKET=%s " % tid
                    new = new[:off + shift] + ins + new[off + shift:]
                    shift += len(ins)
                updated = dict(tin)
                updated["command"] = new
            except OSError as exc:
                reasons.append("Ticket nicht erstellbar (%s): androidsu "
                               "wird ohne Ticket abgelehnt." % exc)
    return _out("ask", "\n".join(reasons), updated)


def _out(kind, reason, updated=None):
    spec = {"hookEventName": "PreToolUse", "permissionDecision": kind,
            "permissionDecisionReason": reason}
    if updated is not None:
        spec["updatedInput"] = updated
    return {"hookSpecificOutput": spec}


def main():
    try:
        raw = sys.stdin.read()
        data = json.loads(raw)
        if not isinstance(data, dict):
            raise ValueError("kein JSON-Objekt")
        result = decide(data)
    except Exception as exc:  # fail closed: ask instead of silently allowing
        result = _out("ask", "⚠ termux-root-bridge: Guard-Fehler (%s: %s) - "
                      "bitte prüfen, bevor du bestätigst."
                      % (type(exc).__name__, exc))
    if result is not None:
        sys.stdout.write(json.dumps(result, ensure_ascii=False))
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
