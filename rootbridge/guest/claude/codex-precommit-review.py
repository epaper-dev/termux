#!/usr/bin/env python3
"""PreToolUse-Hook (Bash): Codex-Review vor `git commit`.

Ablauf:
  1. Nur aktiv, wenn der Bash-Befehl ein `git commit` AUSFÜHRT (find_commit): der Befehl wird wie von einer Shell
     zerlegt. Text in Anführungszeichen und in Heredocs zählt nicht (`echo "git commit"`, ein Python-Skript mit
     dieser Meldung); verfolgt werden `cd`, `git -C`, Präfixe (sudo, env, time, VAR=x ...), `bash -c '...'`, `eval`
     und $(...) / Backticks. Enthält ein Commit-Befehl unquotierte Klammern, wird er wegen des unklaren Shell-Kontexts
     blockiert (Commit separat ausführen). Lässt sich der Befehl nicht zerlegen, gilt die alte Textsuche (lieber ein Review zu
     viel als ein Commit ohne). Nicht erkannt werden Git-Aliase (`git ci`) und Skripte, die committen.
  2. Hash über staged + unstaged Diff (mit Binärinhalt) und, wenn derselbe Befehl vorher `git add` ausführt, über die
     noch nicht verfolgten Dateien, die dabei dazukommen können (sie stehen in keinem Diff; Codex bekommt ihre
     Liste). Wurde genau dieser Stand schon mit ALLOW geprüft, geht der Commit durch.
  3. Sonst Codex-Review (Plugin codex-companion) auf dem Working Tree.
     Codex antwortet in der ersten Zeile mit ALLOW oder BLOCK; blockieren soll es nur bei hoher Schwere
     (Bug, Sicherheitslücke, Secret, Datenverlust, verschluckter Fehler), Kleineres kommt als Hinweis hinter ALLOW. ALLOW ->
     Hash gemerkt, Commit erlaubt. BLOCK (oder unklare Antwort) -> Exit 2,
     die Ausgabe geht an Claude; der Hash wird NICHT gemerkt. Strikte
     Schleife: Ein beanstandeter Stand kommt erst durch, wenn er geändert
     und von Codex mit ALLOW bestätigt wurde.
  4. Review erforderlich (fail-closed): fehlt Codex, ist es nicht angemeldet
     oder bricht das Review ab (auch nach einem Wiederholungsversuch), wird
     der Commit blockiert. Der Hash wird dann nicht gemerkt. Ebenso, wenn sich der Stand nicht ermitteln lässt
     (git scheitert): nur "kein Git-Repository" lässt den Commit ohne Review, er würde ohnehin scheitern.

Notausgang (nur vom Nutzer zu setzen): CODEX_PRECOMMIT=off
"""
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import time

# Gesamtbudget aller Versuche in Sekunden. Muss unter dem Hook-Timeout in
# ~/.claude/settings.json (900 s) liegen, sonst bricht Claude Code den Hook ab,
# bevor er blockieren kann.
TIMEOUT_S = 840
ATTEMPTS = 2
# Denkaufwand des Reviews (ohne Angabe nähme Codex den Modellstandard, bei gpt-6.1-sol "low"). xhigh prüft gründlich,
# braucht bei großen Diffs aber lange: reicht TIMEOUT_S nicht, wird der Commit blockiert (fail-closed).
REVIEW_EFFORT = "xhigh"
STATE_DIR = os.path.expanduser("~/.claude/codex-precommit")
# Rückfall, wenn sich ein Befehl nicht zerlegen lässt (offene Anführungszeichen o. Ä.): die Textsuche.
COMMIT_RE = re.compile(r"(?:^|[;&|(\s])git\s+(?:-[Cc]\s+\S+\s+)*commit\b")
PROMPT = """<task>
Pre-commit review. The working tree of this repository has staged and/or unstaged changes that are about to be committed.
Inspect them yourself with `git diff --cached` and `git diff` (read-only; do not modify anything).
Look for real defects introduced by these changes: bugs, regressions, security problems, leaked secrets, data loss, broken error handling.
BLOCK only for high-severity defects: something that breaks working functionality, a security vulnerability, a leaked secret, data loss, or an error that is silently swallowed.
Do not block on medium or low severity findings, edge cases that need contrived input, style, naming, missing comments, refactoring preferences, or limitations that the code or its documentation already states. For those answer ALLOW and mention them briefly after the first line.
</task>

<compact_output_contract>
Your first line must be exactly one of:
- ALLOW: <short reason>
- BLOCK: <short reason>
After a BLOCK line, list each finding as `- [severity] file:line - problem and suggested fix`. Keep it short.
After an ALLOW line you may list minor notes the same way.
Do not put anything before the first line.
</compact_output_contract>"""

# Wörter vor dem eigentlichen Befehl, die find_commit überspringt: Gruppierung/Schlüsselwörter und Präfix-Programme.
# Wert = Optionen, die ein eigenes Argument brauchen.
WRAPPERS = {
    "{": (), "}": (), "!": (), "if": (), "then": (), "else": (), "elif": (), "do": (), "while": (), "until": (),
    "time": (), "command": (), "builtin": (), "exec": (), "nohup": (), "setsid": (),
    "sudo": ("-u", "-g", "-h", "-p", "-C", "-D", "-R", "-r", "-t", "-U", "-T"),
    "doas": ("-u", "-C"),
    "env": ("-u", "-C", "-S"),
    "xargs": ("-I", "-n", "-P", "-L", "-s", "-d", "-E", "-a"),
    "timeout": ("-s", "-k"),
    "nice": ("-n",), "ionice": ("-c", "-n", "-p"), "stdbuf": ("-i", "-o", "-e"),
}
POSITIONAL = {"timeout": 1}          # timeout DAUER Befehl
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "ash"}
SHELL_ARG_OPTS = {"-o", "+o", "-O", "+O", "--rcfile", "--init-file"}
GIT_ARG_OPTS = {"-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env"}
ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=.*", re.S)


def trace(msg):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(os.path.join(STATE_DIR, "hook.log"), "a") as fh:
            fh.write(f"{time.strftime('%F %T')} pid={os.getpid()} {msg}\n")
    except OSError:
        pass


def note(msg):
    sys.stderr.write(f"[codex-precommit] {msg}\n")


def run_bytes(args, cwd):
    """Wie run, aber als Bytes (ein Binär-Diff ist kein UTF-8) und mit englischen Meldungen (LC_ALL=C)."""
    return subprocess.run(args, cwd=cwd, capture_output=True, env=dict(os.environ, LC_ALL="C"))


def run(args, cwd, timeout=None):
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=timeout)


def fail(reason, detail=""):
    sys.stderr.write(
        f"Codex-Review vor dem Commit ist erforderlich, konnte aber nicht ausgeführt "
        f"werden: {reason}\nDer Commit wird blockiert. Nicht umgehen; dem Nutzer "
        f"melden (Notausgang: CODEX_PRECOMMIT=off).\n"
    )
    if detail:
        sys.stderr.write(detail[-1500:] + "\n")
    return 2


# ----------------------------------------------------------------------------------------- Befehl zerlegen
class ParseError(ValueError):
    pass


class UncertainContext(ParseError):
    pass


def _find_backtick(text, i):
    n = len(text)
    while i < n:
        if text[i] == "\\":
            i += 2
            continue
        if text[i] == "`":
            return i
        i += 1
    raise ParseError("offene Backticks")


def _scan_paren(text, i):
    """text[i] steht hinter '$(': Index der passenden ')' (Anführungszeichen und Verschachtelung beachtet)."""
    depth, n = 1, len(text)
    while i < n:
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == "'":
            j = text.find("'", i + 1)
            if j < 0:
                raise ParseError("offenes '")
            i = j + 1
            continue
        if c == '"':
            i = _scan_dquote(text, i + 1) + 1
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ParseError("offene Klammer")


def _scan_dquote(text, i):
    """text[i] steht hinter einem öffnenden '"': Index des schließenden."""
    n = len(text)
    while i < n:
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == '"':
            return i
        if c == "$" and text[i + 1:i + 2] == "(":
            i = _scan_paren(text, i + 2) + 1
            continue
        if c == "`":
            i = _find_backtick(text, i + 1) + 1
            continue
        i += 1
    raise ParseError('offenes "')


def _collect_subs(text, subs):
    """$(...) und `...` in einem Text (Inhalt in Anführungszeichen, nicht zitierter Heredoc): ihr Inhalt wird ausgeführt."""
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "\\":
            i += 2
        elif c == "$" and text[i + 1:i + 2] == "(":
            j = _scan_paren(text, i + 2)
            subs.append(text[i + 2:j])
            i = j + 1
        elif c == "`":
            j = _find_backtick(text, i + 1)
            subs.append(text[i + 1:j])
            i = j + 1
        else:
            i += 1


def tokenize(text):
    """-> (commands, subs, grouped). commands: eine Wortliste je einfachem Befehl (Anführungszeichen entfernt);
    subs: Texte von $(...) und `...`; grouped: unquotierte Klammern, deren Shell-Kontext nicht aufgelöst wird.
    Kommentare und Heredoc-Inhalte fallen weg."""
    commands, subs = [], []
    grouped = False
    words, word, in_word = [], [], False
    pending = []                         # Heredocs, deren Inhalt nach der nächsten Zeile kommt
    n, i = len(text), 0

    def end_word():
        nonlocal word, in_word
        if in_word:
            words.append("".join(word))
        word, in_word = [], False

    def end_command():
        nonlocal words
        end_word()
        if words:
            commands.append(words)
        words = []

    while i < n:
        c = text[i]
        if c in " \t":
            end_word()
            i += 1
        elif c == "\n":
            end_command()
            i += 1
            while pending:
                delim, strip_tabs, quoted = pending.pop(0)
                body = []
                while i < n:
                    j = text.find("\n", i)
                    line = text[i:] if j < 0 else text[i:j]
                    i = n if j < 0 else j + 1
                    if (line.lstrip("\t") if strip_tabs else line) == delim:
                        break
                    body.append(line)
                if not quoted:
                    _collect_subs("\n".join(body), subs)
        elif c == "#" and not in_word:
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif c == "\\":
            if text[i + 1:i + 2] == "\n":
                i += 2
            else:
                word.append(text[i + 1:i + 2])
                in_word = True
                i += 2
        elif c == "'":
            j = text.find("'", i + 1)
            if j < 0:
                raise ParseError("offenes '")
            word.append(text[i + 1:j])
            in_word = True
            i = j + 1
        elif c == '"':
            j = _scan_dquote(text, i + 1)
            inner = text[i + 1:j]
            _collect_subs(inner, subs)
            word.append(re.sub(r'\\(["\\$`\n])', lambda m: "" if m.group(1) == "\n" else m.group(1), inner))
            in_word = True
            i = j + 1
        elif c == "$" and text[i + 1:i + 2] == "(":
            j = _scan_paren(text, i + 2)
            subs.append(text[i + 2:j])
            word.append(text[i:j + 1])
            in_word = True
            i = j + 1
        elif c == "`":
            j = _find_backtick(text, i + 1)
            subs.append(text[i + 1:j])
            word.append(text[i:j + 1])
            in_word = True
            i = j + 1
        elif text.startswith("<<", i) and not text.startswith("<<<", i):
            end_word()
            j, strip_tabs = i + 2, False
            if text[j:j + 1] == "-":
                strip_tabs = True
                j += 1
            while text[j:j + 1] in (" ", "\t"):
                j += 1
            delim, quoted = [], False
            while j < n and text[j] not in " \t\n;&|()<>":
                ch = text[j]
                if ch in "'\"":
                    k = text.find(ch, j + 1)
                    if k < 0:
                        raise ParseError("offenes Anführungszeichen im Heredoc")
                    quoted = True
                    delim.append(text[j + 1:k])
                    j = k + 1
                elif ch == "\\":
                    quoted = True
                    delim.append(text[j + 1:j + 2])
                    j += 2
                else:
                    delim.append(ch)
                    j += 1
            pending.append(("".join(delim), strip_tabs, quoted))
            i = j
        elif c in ";&|()":
            end_command()
            if c in "()":
                grouped = True
            i += 1
        else:
            word.append(c)
            in_word = True
            i += 1
    end_command()
    return commands, subs, grouped


def _step(base, raw):
    target = os.path.expandvars(os.path.expanduser(raw))
    return target if os.path.isabs(target) else os.path.join(base, target)


def _classify_git(args):
    dirs, i = [], 0
    while i < len(args):
        t = args[i]
        if t == "-C":
            if i + 1 < len(args):
                dirs.append(args[i + 1])
            i += 2
        elif t in GIT_ARG_OPTS:
            i += 2
        elif t.startswith("-"):
            i += 1
        elif t == "commit":
            return ("git", dirs)
        elif t in ("add", "stage"):
            return ("add", dirs)
        else:
            return None
    return None


def classify(words):
    """Was ein einfacher Befehl tut: ("git", [-C-Ordner]) für `git commit`, ("add", ...) für `git add` / `git stage`,
    ("cd", Ziel), ("sh", Skripttext) für `bash -c '...'` / eval, sonst None."""
    i, n = 0, len(words)
    while i < n:
        w = words[i]
        if ASSIGNMENT.fullmatch(w):
            i += 1
            continue
        name = w if w in WRAPPERS else os.path.basename(w)
        if name not in WRAPPERS:
            break
        takes, positional = WRAPPERS[name], POSITIONAL.get(name, 0)
        i += 1
        while i < n:
            t = words[i]
            if t in takes:
                i += 2
            elif t.startswith("-") and t != "-":
                i += 1
            elif name == "env" and ASSIGNMENT.fullmatch(t):
                i += 1
            elif positional:
                positional -= 1
                i += 1
            else:
                break
    if i >= n:
        return None
    cmd, rest = words[i], words[i + 1:]
    base = os.path.basename(cmd)
    if base == "git":
        return _classify_git(rest)
    if base in SHELLS:
        k = 0
        while k < len(rest):
            t = rest[k]
            if t in SHELL_ARG_OPTS:
                k += 2
            elif t.startswith("-") and not t.startswith("--") and "c" in t[1:]:
                return ("sh", rest[k + 1]) if k + 1 < len(rest) else None
            elif t.startswith("-") or t.startswith("+"):
                k += 1
            else:
                break                    # ein Skript: sein Inhalt wird nicht untersucht
        return None
    if cmd == "eval":
        return ("sh", " ".join(rest))
    if cmd in ("cd", "pushd"):
        for t in rest:
            if t.startswith("-") and t != "-":
                continue
            return ("cd", t)
        return ("cd", "~")
    return None


def analyze(command, cwd, depth=0, adds=False):
    """None, wenn der Befehl kein `git commit` ausführt, sonst (Ordner, adds): der Ordner, in dem es (zuerst) läuft
    (folgt `cd` in vorangehenden Befehlen und `git -C`), und ob ein `git add` / `git stage` davor in demselben Befehl
    steht (dann kann der Commit Dateien enthalten, die jetzt noch in keinem Diff stehen)."""
    if depth > 5:
        raise ParseError("zu tief verschachtelt")
    commands, subs, grouped = tokenize(command)
    cur = cwd
    for words in commands:
        info = classify(words)
        if info is None:
            continue
        if info[0] == "cd":
            cur = _step(cur, info[1])
        elif info[0] == "add":
            adds = True
        elif info[0] == "git":
            if grouped:
                raise UncertainContext("Shell-Kontext mit Klammern nicht eindeutig; git commit separat ausführen.")
            for d in info[1]:
                cur = _step(cur, d)
            return cur, adds
        else:
            found = analyze(info[1], cur, depth + 1, adds)
            if found is not None:
                if grouped:
                    raise UncertainContext("Shell-Kontext mit Klammern nicht eindeutig; git commit separat ausführen.")
                return found
    for text in subs:
        found = analyze(text, cur, depth + 1, adds)
        if found is not None:
            if grouped:
                raise UncertainContext("Shell-Kontext mit Klammern nicht eindeutig; git commit separat ausführen.")
            return found
    return None


def find_commit(command, cwd, depth=0):
    """Wie analyze, nur der Ordner: None, wenn der Befehl kein `git commit` ausführt."""
    found = analyze(command, cwd, depth)
    return None if found is None else found[0]


def build_prompt(untracked):
    """PROMPT; mit den noch nicht verfolgten Dateien, die der Befehl per `git add` aufnehmen kann."""
    if not untracked:
        return PROMPT
    head, tail = PROMPT.split("\n\n<compact_output_contract>", 1)
    shown = untracked[:200]
    extra = (
        "\n\n<untracked_files>\nThe same command stages files before it commits, so these untracked files can be "
        "committed too and appear in neither diff. Read and review them as well (read-only):\n"
        + "\n".join(f"- {path}" for path in shown)
        + (f"\n... and {len(untracked) - len(shown)} more" if len(untracked) > len(shown) else "")
        + "\n</untracked_files>"
    )
    return head + extra + "\n\n<compact_output_contract>" + tail


def _file_digest(path, cap=8 * 1024 * 1024):
    """Inhalt (bis cap Bytes), Größe und, bei einem Link, das Ziel einer Datei, die in keinem Diff steht."""
    h = hashlib.sha256()
    try:
        info = os.lstat(path)
        if os.path.islink(path):
            h.update(os.readlink(path).encode("utf-8", "surrogateescape"))
        else:
            with open(path, "rb") as fh:
                h.update(fh.read(cap))
        h.update(str(info.st_size).encode())
    except OSError as exc:
        h.update(f"nicht lesbar: {exc}".encode())
    return h.digest()


def _version_key(path):
    """.../codex/<Version>/scripts/codex-companion.mjs: 1.0.10 kommt nach 1.0.9."""
    version = os.path.basename(os.path.dirname(os.path.dirname(path)))
    return [int(x) for x in re.findall(r"\d+", version)], version


def find_companion():
    pattern = os.path.expanduser(
        "~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs"
    )
    found = sorted(glob.glob(pattern), key=_version_key)
    return found[-1] if found else None


def main():
    trace("gestartet")
    if os.environ.get("CODEX_PRECOMMIT", "").lower() == "off":
        trace("CODEX_PRECOMMIT=off")
        return 0
    try:
        data = json.load(sys.stdin)
    except Exception as exc:
        trace(f"stdin kein JSON: {exc}")
        return 0
    command = (data.get("tool_input") or {}).get("command", "")
    start = data.get("cwd") or os.getcwd()
    if "commit" not in command:
        trace(f"kein git commit: {command[:60]!r}")
        return 0
    try:
        found = analyze(command, start)
    except UncertainContext as exc:
        return fail(str(exc))
    except Exception as exc:
        trace(f"Befehl nicht zerlegbar ({exc}), Textsuche")
        found = (start, True) if COMMIT_RE.search(command) else None   # unklar: auch die neuen Dateien prüfen
    if found is None:
        trace(f"kein git commit: {command[:60]!r}")
        return 0
    commit_dir, adds = found
    trace(f"git commit erkannt, cwd={data.get('cwd')!r}")

    cwd = commit_dir if os.path.isdir(commit_dir) else None
    if cwd is None:
        return fail("Zielverzeichnis des Commits nicht ermittelbar.")
    trace(f"Commit-Verzeichnis: {cwd!r}")
    # Was geprüft wird, muss sich ermitteln lassen: scheitert git, wird der Commit blockiert (fail-closed). Nur "kein
    # Git-Repository" lässt ihn durch, ein Commit dort scheitert ohnehin.
    try:
        top = run_bytes(["git", "rev-parse", "--show-toplevel"], cwd)
        if top.returncode != 0:
            if b"not a git repository" in top.stderr:
                return 0
            return fail("git rev-parse ist fehlgeschlagen.", top.stderr.decode("utf-8", "replace"))
        root = top.stdout.decode("utf-8", "surrogateescape").strip()
        if not root:
            return 0
        diffs = []
        for args in (["diff", "--cached", "--binary"], ["diff", "--binary"]):
            r = run_bytes(["git"] + args, root)
            if r.returncode != 0:
                return fail(f"git {' '.join(args)} ist fehlgeschlagen.", r.stderr.decode("utf-8", "replace"))
            diffs.append(r.stdout)
        untracked = []
        if adds:        # derselbe Befehl nimmt vielleicht neue Dateien auf, die in keinem Diff stehen
            r = run_bytes(["git", "ls-files", "--others", "--exclude-standard", "-z"], root)
            if r.returncode != 0:
                return fail("git ls-files ist fehlgeschlagen.", r.stderr.decode("utf-8", "replace"))
            untracked = [x for x in r.stdout.decode("utf-8", "surrogateescape").split("\0") if x]
    except OSError as exc:
        return fail(f"git lässt sich nicht ausführen: {exc}")
    if not diffs[0].strip() and not diffs[1].strip() and not untracked:
        return 0

    h = hashlib.sha256()
    for part in diffs:
        h.update(part)
        h.update(b"\0")
    for path in untracked:
        h.update(path.encode("utf-8", "surrogateescape"))
        h.update(b"\0")
        h.update(_file_digest(os.path.join(root, path)))
    digest = h.hexdigest()
    key = hashlib.sha256(root.encode()).hexdigest()[:16]
    os.makedirs(STATE_DIR, exist_ok=True)
    state_file = os.path.join(STATE_DIR, key)
    try:
        if open(state_file).read().strip() == digest:
            return 0
    except OSError:
        pass

    companion = find_companion()
    node = subprocess.run(["which", "node"], capture_output=True, text=True).stdout.strip()
    if not companion or not node:
        return fail("Codex-Plugin oder node nicht gefunden.")

    note("Codex prüft den Stand vor dem Commit ...")
    result = None
    deadline = time.monotonic() + TIMEOUT_S
    for attempt in range(1, ATTEMPTS + 1):
        remaining = deadline - time.monotonic()
        if remaining < 30:
            return fail(f"Zeitbudget von {TIMEOUT_S}s aufgebraucht (Versuch {attempt}/{ATTEMPTS}).")
        try:
            result = run([node, companion, "task", "--json", "--effort", REVIEW_EFFORT, build_prompt(untracked)],
                         root, timeout=remaining)
        except subprocess.TimeoutExpired:
            return fail(f"Timeout nach {TIMEOUT_S}s (Versuch {attempt}/{ATTEMPTS}).")
        if result.returncode == 0:
            break
        note(f"Versuch {attempt}/{ATTEMPTS} fehlgeschlagen (Exit {result.returncode}).")
    if result.returncode != 0:
        return fail(f"Exit {result.returncode} nach {ATTEMPTS} Versuchen.", result.stderr or result.stdout)

    try:
        output = str(json.loads(result.stdout).get("rawOutput") or "").strip()
    except Exception:
        output = result.stdout.strip()
    if not output:
        return fail("leere Antwort von Codex.")
    first = output.split("\n", 1)[0].strip()
    if first.startswith("ALLOW:"):
        with open(state_file, "w") as fh:
            fh.write(digest)
        note(output)            # mit den Hinweisen, die Codex hinter ALLOW anführt
        return 0

    sys.stderr.write(
        "Codex-Review vor dem Commit hat Findings geliefert. Behebe die Punkte "
        "und committe erneut (neuer Diff -> neues Review). Der Commit wird erst "
        "durchgelassen, wenn Codex mit ALLOW antwortet; ein unveränderter "
        "Wiederholungs-Commit wird erneut blockiert. Nicht umgehen. Sind Findings "
        "aus deiner Sicht unberechtigt, dem Nutzer melden (Notausgang: "
        "CODEX_PRECOMMIT=off, nur vom Nutzer zu setzen).\n\n"
        + output
        + "\n"
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
