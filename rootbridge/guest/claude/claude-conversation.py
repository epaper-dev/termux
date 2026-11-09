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


def has_conversation(config_dir, cwd):
    wanted = os.path.realpath(cwd)
    projects = Path(config_dir) / "projects"
    try:
        # Subagent transcripts live in nested directories and are not resumable main sessions.
        transcripts = projects.glob("*/*.jsonl")
        for transcript in transcripts:
            try:
                session_id = str(uuid.UUID(transcript.stem))
            except ValueError:
                continue
            try:
                with transcript.open(encoding="utf-8", errors="replace") as stream:
                    for line in stream:
                        try:
                            entry = json.loads(line)
                        except ValueError:
                            continue
                        if not isinstance(entry, dict):
                            continue
                        if entry.get("type") not in ("user", "assistant") or entry.get("isSidechain"):
                            continue
                        if entry.get("sessionId") != session_id:
                            continue
                        message = entry.get("message")
                        if not isinstance(message, dict) or not message.get("content"):
                            continue
                        saved_cwd = entry.get("cwd")
                        if isinstance(saved_cwd, str) and os.path.isabs(saved_cwd):
                            if os.path.realpath(saved_cwd) == wanted:
                                return True
                            # Do not read a large conversation belonging to another project.
                            break
            except OSError:
                continue
    except OSError:
        return False
    return False


if __name__ == "__main__":
    sys.exit(0 if has_conversation(*sys.argv[1:]) else 1)
