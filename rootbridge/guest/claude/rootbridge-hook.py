#!/usr/bin/env python3
"""rootbridge-hook - PostToolUse and UserPromptSubmit hook of Claude Code and Codex (termux-rootbridge).

The daemon in Termux decides about every Android-root request (androidsu) itself, in an Android dialog. When it
refuses one it leaves a note for the agent that asked: events/<agent pid>-<ns> in the bridge directory (line 1 the
decision, line 2 the command). This hook hands the notes of its own agent to that agent as additionalContext, so the
agent learns that the user said no and does not try to get around it.

The notes are only informative: a forged one can mislead the agent, but it gives it no rights (the daemon alone
decides). The hook never blocks anything: every error is silent.

stdin : hook JSON (hook_event_name)
stdout: hookSpecificOutput JSON with additionalContext, or nothing
Python >= 3.8, standard library only.
"""
import glob
import json
import os
import re
import sys

CONF_PATH = os.environ.get("ROOTBRIDGE_CONF", "/etc/termux-rootbridge.conf")
DEFAULT_BRIDGE_DIR = "/data/data/com.termux/files/home/.rootbridge"
PROC = os.environ.get("RB_PROC_DIR", "/proc")
EVENTS = ("PostToolUse", "UserPromptSubmit")
HINT = " Keine Umgehung versuchen (su, adb, magisk, Dateien im Bridge-Ordner); frage den Nutzer, wie es weitergehen soll."
MESSAGES = {
    "DENY-USER": "Der Nutzer hat die Root-Anfrage %s in Termux abgelehnt.",
    "ASK-TIMEOUT": "Der Nutzer hat auf die Root-Anfrage %s in Termux nicht rechtzeitig geantwortet; sie wurde abgelehnt.",
    "ASK-FAIL": "Die Root-Anfrage %s wurde abgelehnt, weil die Rückfrage in Termux nicht angezeigt werden konnte.",
}


def bridge_dir():
    try:
        with open(CONF_PATH, encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("BRIDGE_DIR="):
                    return line.partition("=")[2].strip().strip("'\"") or DEFAULT_BRIDGE_DIR
    except OSError:
        pass
    return DEFAULT_BRIDGE_DIR


def agent_pid():
    """Pid of the Claude Code or Codex process above this hook (the daemon names notes after the same one)."""
    pid = os.getppid()
    for _ in range(16):
        if pid <= 1:
            return None
        try:
            with open("%s/%d/comm" % (PROC, pid), encoding="utf-8") as fh:
                if fh.read().strip() in ("claude", "codex"):
                    return pid
            with open("%s/%d/status" % (PROC, pid), encoding="utf-8") as fh:
                pid = int(re.search(r"^PPid:\s*(\d+)", fh.read(), re.M).group(1))
        except (OSError, AttributeError, ValueError):
            return None
    return None


def take_notes(directory, pid):
    """The messages for the notes of this agent; the notes are removed."""
    messages = []
    for path in sorted(glob.glob(os.path.join(directory, "events", "%d-*" % pid))):
        if ".tmp." in path:
            continue
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                decision, command = (fh.read().split("\n") + ["", ""])[:2]
            os.remove(path)
        except OSError:
            continue
        template = MESSAGES.get(decision.strip())
        if template:
            quoted = "`%s`" % re.sub(r"[\x00-\x1f\x7f`]", " ", command).strip()[:200]
            messages.append("termux-rootbridge: " + template % quoted + HINT)
    return messages


def main():
    try:
        data = json.loads(sys.stdin.read())
        event = data.get("hook_event_name") if isinstance(data, dict) else None
        if event not in EVENTS:
            return 0
        pid = agent_pid()
        messages = take_notes(bridge_dir(), pid) if pid else []
        if messages:
            out = {"hookSpecificOutput": {"hookEventName": event, "additionalContext": "\n".join(messages)}}
            sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
    except Exception:  # a hook that only informs must never get in the way
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
