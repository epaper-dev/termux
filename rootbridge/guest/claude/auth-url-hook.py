#!/usr/bin/env python3
"""auth-url-hook - Claude Code PostToolUse hook (termux-rootbridge v2).

For claude.ai connectors and MCP servers that need a login, the tool
`mcp__<server>__authenticate` returns a very long authorization URL that
Claude then prints into the chat, where it wraps over many lines and is hard
to copy on a phone. This hook finds the URL in the tool result, opens it in
the Android browser (rootbridge-open) and copies it to the Android clipboard,
and tells Claude not to print it again.

Settings (/etc/termux-rootbridge.conf or environment):
  AUTH_OPEN=auto|copy|off     auto: open + copy (default), copy: only copy
  AUTH_REPLACE_OUTPUT=0|1     1: replace the tool result with a short note via
                              updatedToolOutput (default 0 until verified)

stdin : PostToolUse hook JSON     stdout: hook JSON or nothing
Python >= 3.8, standard library only.
"""
import json
import os
import re
import shutil
import subprocess
import sys

CONF_PATH = os.environ.get("ROOTBRIDGE_CONF", "/etc/termux-rootbridge.conf")
TOOL_RE = re.compile(r"^mcp__.+__(authenticate|complete_authentication)$")
URL_RE = re.compile(r"https://[^\s\"'<>`\\]+")
VALID_RE = re.compile(
    r"^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?"
    r"([/?#][^\s\x00-\x1f\"'<>`\\]*)?$")
HINTS = ("oauth", "authorize", "auth", "login", "signin", "sign-in",
         "client_id", "redirect_uri", "state=", "code_challenge")
MAX_URL = 8192


def load_conf(path=None):
    conf = {}
    try:
        with open(path or CONF_PATH, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, _, val = line.partition("=")
                    conf[key.strip()] = val.strip().strip("'\"")
    except OSError:
        pass
    for key in ("AUTH_OPEN", "AUTH_REPLACE_OUTPUT"):
        if os.environ.get(key):
            conf[key] = os.environ[key]
    return conf


def _unescape(text):
    text = text.replace("\\/", "/")
    return re.sub(r"\\u([0-9a-fA-F]{4})",
                  lambda m: chr(int(m.group(1), 16)), text)


def _walk(obj, out, depth=0):
    if depth > 12:
        return
    if isinstance(obj, str):
        out.append(obj)
    elif isinstance(obj, dict):
        for val in obj.values():
            _walk(val, out, depth + 1)
    elif isinstance(obj, (list, tuple)):
        for val in obj:
            _walk(val, out, depth + 1)


def find_urls(response):
    """All https URLs found anywhere in a tool_response of unknown shape."""
    strings = []
    _walk(response, strings)
    urls = []
    for text in strings:
        for cand in URL_RE.findall(_unescape(text)):
            cand = cand.rstrip(".,;:!?)]}>*_")
            if cand not in urls:
                urls.append(cand)
    return urls


def pick_url(urls):
    valid = [u for u in urls if len(u) <= MAX_URL and VALID_RE.match(u)]
    if not valid:
        return None
    scored = sorted(valid, key=lambda u: (
        -sum(1 for h in HINTS if h in u.lower()), -len(u)))
    return scored[0]


def host_of(url):
    host = url[len("https://"):]
    host = re.split(r"[/?#]", host, 1)[0]
    return host.split(":")[0]


def opener_path():
    explicit = os.environ.get("ROOTBRIDGE_OPEN")
    if explicit:
        return explicit
    return shutil.which("rootbridge-open") or "/usr/local/bin/rootbridge-open"


def run_opener(url, copy_only):
    cmd = [opener_path()] + (["--copy-only"] if copy_only else []) + [url]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=25)
        return proc.returncode
    except (OSError, subprocess.SubprocessError):
        return 127


def build_output(host, mode, rc, replace):
    if rc == 0:
        what = ("im Browser geöffnet und in die Zwischenablage kopiert"
                if mode == "auto" else "in die Zwischenablage kopiert")
        note = "Login-Link (%s) %s." % (host, what)
        ctx = ("Der Login-Link für %s wurde bereits %s. Gib die URL NICHT "
               "im Chat aus (sie ist sehr lang). Sage dem Nutzer nur, dass er "
               "sich im Browser anmelden soll, und wende danach das Ergebnis "
               "an." % (host, what))
        spec = {"hookEventName": "PostToolUse", "additionalContext": ctx}
        if replace:
            spec["updatedToolOutput"] = (
                note + " Nach der Anmeldung stehen die Tools des Servers "
                "automatisch zur Verfügung.")
        return {"systemMessage": "🔐 " + note, "hookSpecificOutput": spec}
    return {"systemMessage": "🔐 Login-Link (%s) konnte nicht automatisch "
                             "geöffnet werden (Code %s). Der Link steht im "
                             "Tool-Ergebnis." % (host, rc)}


def main():
    try:
        data = json.load(sys.stdin)
        if not isinstance(data, dict):
            return 0
        if not TOOL_RE.match(str(data.get("tool_name", ""))):
            return 0
        conf = load_conf()
        mode = conf.get("AUTH_OPEN", "auto")
        if mode not in ("auto", "copy"):
            return 0
        url = pick_url(find_urls(data.get("tool_response")))
        if url is None:
            return 0
        rc = run_opener(url, copy_only=(mode == "copy"))
        out = build_output(host_of(url), mode, rc,
                           conf.get("AUTH_REPLACE_OUTPUT", "0") == "1")
        sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
    except Exception:       # never break the tool result because of this hook
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
