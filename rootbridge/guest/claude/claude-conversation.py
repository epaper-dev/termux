#!/usr/bin/env python3
"""Find a saved, non-sidechain Claude conversation for a working directory.

Read transcript metadata only; never start Claude or make an API request. Project
folder names are an internal encoding, so compare each message's cwd instead.
"""
import json
import os
from pathlib import Path
import sys
import uuid


def _message_entry(line, session_id):
    """The transcript line as a dict if it is a message of the main conversation `session_id`, otherwise None."""
    try:
        entry = json.loads(line)
    except ValueError:
        return None
    if not isinstance(entry, dict):
        return None
    if entry.get("type") not in ("user", "assistant") or entry.get("isSidechain"):
        return None
    if entry.get("sessionId") != session_id:
        return None
    message = entry.get("message")
    if not isinstance(message, dict) or not message.get("content"):
        return None
    return entry


def _transcript_in_cwd(transcript, wanted):
    """Whether the first usable message of this transcript was written in the directory `wanted`."""
    try:
        session_id = str(uuid.UUID(transcript.stem))
    except ValueError:
        return False
    try:
        with transcript.open(encoding="utf-8", errors="replace") as stream:
            for line in stream:
                entry = _message_entry(line, session_id)
                if entry is None:
                    continue
                saved_cwd = entry.get("cwd")
                if isinstance(saved_cwd, str) and os.path.isabs(saved_cwd):
                    # Do not read a large conversation belonging to another project.
                    return os.path.realpath(saved_cwd) == wanted
    except OSError:
        pass
    return False


def has_conversation(config_dir, cwd):
    wanted = os.path.realpath(cwd)
    projects = Path(config_dir) / "projects"
    try:
        # Subagent transcripts live in nested directories and are not resumable main sessions.
        return any(_transcript_in_cwd(transcript, wanted) for transcript in projects.glob("*/*.jsonl"))
    except OSError:
        return False


if __name__ == "__main__":
    sys.exit(0 if has_conversation(*sys.argv[1:]) else 1)
