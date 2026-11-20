#!/usr/bin/env python3
"""speak - speech output for Claude Code (termux-rootbridge, part of --voice).

Reads text aloud with Piper (a local neural voice) through PulseAudio in Termux, the same way the microphone of
/voice comes in. Claude's answers are read by the Stop hook, its short notes between tool calls ("Ich baue jetzt ...") by
the PreToolUse hook; a new text ends the one still being read.

  speak.py --hook     Stop hook: reads last_assistant_message from the hook JSON on stdin, unless the switch is off
  speak.py --progress PreToolUse hook: reads the newest text of Claude in this turn from transcript_path, once
  speak.py --stop     end what is being read (UserPromptSubmit hook, rootbridge-speak --stop)
  speak.py [TEXT...]  read TEXT, or stdin, aloud (also when the switch is off)

What is read: the text without code blocks, tables, URLs and Markdown marks. The English words of the list
speak-english.txt next to this file go to Piper as phonemes ([[...]]), so the German voice says them in English, and German
forms of English verbs as they are said ("gemergt" as "gemörtscht"). With the file speak-first in the bridge
directory (`rootbridge voice speak first|all`) the hooks read only a short version of an answer or note: its first paragraph,
at most SUMMARY_SENTENCES sentences, and the last question of the text when it stands further down.
--progress remembers the id of the note it read in speak-progress, so each note is read once.
The switch: the file speak-off in the bridge directory (Termux and the guest both see it; `rootbridge voice speak
on|off|toggle` in Termux, the widget "Vorlesen"). The player runs in its own process group, its id in speak.pid next to
it: Termux ends it from there (`rootbridge voice speak stop`, the widget "Stopp", `ptt start` before the microphone).

Errors of piper and play go to ~/.cache/rootbridge-speak.log (the hook and the player run detached); the command line
also says when Piper or the voice is missing.

Environment (tests, other voices): PIPER_VOICE (.onnx file), RB_SPEAK_PIPER (piper program), RB_SPEAK_PLAY (play of sox),
RB_SPEAK_DIR (bridge directory), RB_SPEAK_LOG (log file), RB_SPEAK_ENGLISH (the list of English words).
Python >= 3.8, standard library only.
"""
import fcntl
import json
import os
import stat
import re
import signal
import subprocess
import sys
import tempfile
import time

BRIDGE_DIR = os.environ.get("RB_SPEAK_DIR", "/data/data/com.termux/files/home/.rootbridge")
OFF = os.path.join(BRIDGE_DIR, "speak-off")
FIRST = os.path.join(BRIDGE_DIR, "speak-first")
PIDFILE = os.path.join(BRIDGE_DIR, "speak.pid")
PROGRESS = os.path.join(BRIDGE_DIR, "speak-progress")
STOPPED = os.path.join(BRIDGE_DIR, "speak-stopped")   # its mtime: the last stop (--stop here, rb_speak_stop in Termux)
TAIL_BYTES = 512 * 1024   # the newest note stands near the end of the transcript; the hook runs before every tool call
WAIT_SECONDS = 2          # how long --progress waits for its tool call (and the note before it) to reach the transcript
PIPER = os.environ.get("RB_SPEAK_PIPER", "/opt/piper/bin/piper")
PLAY = os.environ.get("RB_SPEAK_PLAY", "play")
VOICE = os.environ.get("PIPER_VOICE", "/opt/piper/voices/de_DE-kerstin-medium.onnx")
PULSE_COOKIE = "/data/data/com.termux/files/home/.config/pulse/cookie"
LOG = os.environ.get("RB_SPEAK_LOG", os.path.expanduser("~/.cache/rootbridge-speak.log"))
PROC = os.environ.get("RB_SPEAK_PROC", "/proc")
ENGLISH = os.environ.get("RB_SPEAK_ENGLISH", os.path.join(os.path.dirname(os.path.abspath(__file__)), "speak-english.txt"))
RUN_ARG = "--run"   # the player process; Termux recognises it by "speak.py --run" in its command line

FENCE_RE = re.compile(r"^\s*(```|~~~).*?^\s*\1[^\n]*$", re.S | re.M)
IMAGE_RE = re.compile(r"!\[[^\]]*\]\([^)]*\)")
LINK_RE = re.compile(r"\[([^\]]+)\]\([^)]*\)")
URL_RE = re.compile(r"<?https?://\S+>?")
MARKS_RE = re.compile(r"\*\*|__|`|~~")
EMPH_RE = re.compile(r"(?<!\w)[*_](\S(?:.*?\S)?)[*_](?!\w)")
PREFIX_RE = re.compile(r"^\s*(#{1,6}\s+|>\s?|[-*+]\s+(\[[ xX]\]\s+)?)")
RULE_RE = re.compile(r"^\s*([-*_]\s*){3,}$")
SENTENCE_END_RE = re.compile(r"[.!?](?=\s|$)")
# a dot after these does not end a sentence (lower case, without their dots)
SUMMARY_SENTENCES = 3
ABBREVIATIONS = {"z.b", "d.h", "u.a", "bzw", "ca", "usw", "vgl", "ggf", "inkl", "evtl", "etc", "nr", "dr", "bspw", "e.g", "i.e", "vs"}


def speakable(text):
    """The text of a Markdown answer as it should be read: one line per paragraph, list item or heading."""
    text = FENCE_RE.sub("", text)
    text = IMAGE_RE.sub("", text)
    text = LINK_RE.sub(r"\1", text)
    text = URL_RE.sub("", text)
    lines = []
    for line in text.splitlines():
        if line.lstrip().startswith("|") or RULE_RE.match(line):
            continue
        line = PREFIX_RE.sub("", line)
        line = EMPH_RE.sub(r"\1", MARKS_RE.sub("", line))
        line = " ".join(line.split())
        if line:
            lines.append(line)
    return "\n".join(lines)


def sentences(line):
    """The sentences of one line of a speakable text; the rest after the last end of a sentence counts as one.
    A dot after a number (\"20. November\"), a single letter or a known abbreviation (\"z. B.\") does not end one."""
    found, begin = [], 0
    for m in SENTENCE_END_RE.finditer(line):
        words = line[:m.start()].split()
        word = words[-1].lower() if words else ""
        if m.group() == "." and (word[-1:].isdigit() or len(word) == 1
                                 or word in ABBREVIATIONS or (words[-2:-1] and words[-2].lower() + word in ABBREVIATIONS)):
            continue
        found.append(line[begin:m.end()].strip())
        begin = m.end()
    rest = line[begin:].strip()
    return found + [rest] if rest else found


def summary(text):
    """The short version of a speakable text: its first line (paragraph, heading, list item), at most SUMMARY_SENTENCES
    sentences, and the last question of the text when it is not among them (a question at the end must be heard)."""
    lines = text.split("\n")
    head = sentences(lines[0])[:SUMMARY_SENTENCES]
    questions = [s for line in lines for s in sentences(line) if s.endswith("?")]
    if questions and questions[-1] not in head:
        head.append(questions[-1])
    return " ".join(head)


def english(text):
    """text with the words of the list ENGLISH replaced by what Piper should read: phonemes in [[...]] or a German spelling.
    A line of the list: the word as written (case matters), a tab, the replacement; # starts a comment. No list, no change."""
    words = {}
    try:
        with open(ENGLISH, encoding="utf-8") as fh:
            for line in fh:
                word, tab, replacement = line.strip().partition("\t")
                if tab and not word.startswith("#"):
                    words[word.strip()] = replacement.strip()
    except FileNotFoundError:
        return text
    except (OSError, ValueError) as e:   # ValueError: not UTF-8
        log("Liste englischer Wörter %s: %s" % (ENGLISH, e))
        return text
    if not words:
        return text
    pattern = r"(?<!\w)(%s)(?!\w)" % "|".join(map(re.escape, sorted(words, key=len, reverse=True)))
    return re.sub(pattern, lambda m: words[m.group(1)], text)


def log(message):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write("%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), message))
    except OSError:
        pass


def player_pid():
    """The pid in speak.pid when that process is our player (the file lies where others can write), else None."""
    try:
        with open(PIDFILE, encoding="ascii") as fh:
            pid = int(fh.read().strip())
        with open("/proc/%d/cmdline" % pid, "rb") as fh:
            cmdline = fh.read().replace(b"\0", b" ")
    except (OSError, ValueError):
        return None
    return pid if b"speak.py " + RUN_ARG.encode() in cmdline else None


def stop():
    pid = player_pid()
    if pid:
        try:
            os.killpg(pid, signal.SIGTERM)
        except OSError:
            pass


def mark_stopped():
    """Touch speak-stopped (not through a link): a --progress hook still waiting for its note does not start after it."""
    try:
        fd = os.open(STOPPED, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            os.utime(fd)
        finally:
            os.close(fd)
    except OSError:
        pass


def stopped_since(moment):
    try:
        return os.lstat(STOPPED).st_mtime >= moment
    except OSError:
        return False


def sample_rate():
    try:
        with open(VOICE + ".json", encoding="utf-8") as fh:
            return int(json.load(fh)["audio"]["sample_rate"])
    except (OSError, ValueError, KeyError, TypeError):
        return 22050


def start(text):
    """End what is being read and read text in a detached process (the hook and the caller do not wait).
    Returns an error message when Piper or the voice is missing, else None."""
    text = text.strip()
    if not text:
        return None
    for what, path in (("Piper", PIPER), ("die Stimme", VOICE)):
        if not os.path.exists(path):
            error = "%s fehlt: %s (bash install.sh --setup in Termux)" % (what, path)
            log(error)
            return error
    stop()
    proc = subprocess.Popen([sys.executable, "-I", os.path.abspath(__file__), RUN_ARG],
                            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            start_new_session=True)
    # registered here, before it can play: a stop that comes while the player is still starting must find it (Popen returns
    # after the exec, so its command line already says "speak.py --run"; it leads its own process group)
    write_pidfile(proc.pid)
    proc.stdin.write(text.encode("utf-8"))
    proc.stdin.close()
    return None


def write_pidfile(pid):
    tmp = "%s.%d" % (PIDFILE, pid)
    with open(tmp, "w", encoding="ascii") as fh:
        fh.write("%d\n" % pid)
    os.replace(tmp, PIDFILE)


def run():
    """The player: piper | play, in its own process group (the group id is in speak.pid while it reads)."""
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))   # a stop still removes speak.pid (finally below)
    text = english(sys.stdin.buffer.read().decode("utf-8", "replace")).encode("utf-8")
    env = dict(os.environ)
    env.setdefault("PULSE_SERVER", "127.0.0.1")
    if "PULSE_COOKIE" not in env and os.access(PULSE_COOKIE, os.R_OK):
        env["PULSE_COOKIE"] = PULSE_COOKIE
    me = str(os.getpid())   # start() registered it in speak.pid
    try:
        with tempfile.TemporaryFile() as err:   # what piper and play say, into the log only on a failure
            piper = subprocess.Popen([PIPER, "-m", VOICE, "--output-raw"], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=err, env=env)
            play = subprocess.Popen([PLAY, "-q", "-t", "raw", "-r", str(sample_rate()), "-e", "signed", "-b", "16",
                                     "-c", "1", "-", "-t", "pulseaudio"],
                                    stdin=piper.stdout, stdout=subprocess.DEVNULL, stderr=err, env=env)
            piper.stdout.close()
            try:
                piper.stdin.write(text)
                piper.stdin.close()
            except BrokenPipeError:
                pass
            codes = (piper.wait(), play.wait())
            if codes != (0, 0):
                err.seek(0)
                log("piper Exit %d, play Exit %d: %s" % (codes[0], codes[1],
                                                        err.read()[-2000:].decode("utf-8", "replace").strip()))
    except OSError as e:
        log("Abspielen ging nicht: %s" % e)
    finally:
        try:
            with open(PIDFILE, encoding="ascii") as fh:
                if fh.read().strip() == me:
                    os.remove(PIDFILE)
        except OSError:
            pass


def hook_input():
    """The hook JSON on stdin, or None when it is not an object or the switch is off."""
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return None
    if os.path.exists(OFF) or not isinstance(data, dict):
        return None
    return data


def recording():
    """True while Claude Code records for /voice: its recorder is SoX `rec ... --buffer 1024 -t raw ...` (the same test as
    find_recorders in ptt). The microphone would take what is read into the prompt."""
    try:
        pids = [p for p in os.listdir(PROC) if p.isdigit()]
    except OSError:
        return False
    for pid in pids:
        try:
            with open(os.path.join(PROC, pid, "cmdline"), "rb") as fh:
                args = fh.read().split(b"\0")
        except OSError:
            continue
        if args[0].endswith(b"rec") and b" --buffer 1024 -t raw " in b" " + b" ".join(args) + b" ":
            return True
    return False


def speak_answer(message):
    if recording():
        return
    text = speakable(message)
    if os.path.exists(FIRST):
        text = summary(text)
    start(text)   # the hooks stay silent towards Claude Code: a failure is in the log


def hook():
    data = hook_input()
    message = data and data.get("last_assistant_message")
    if isinstance(message, str):
        speak_answer(message)


def transcript_tail(path, tool_use_id):
    """The end of the transcript once it holds the tool call tool_use_id (Claude Code may run the hook before it writes
    the call and the note before it), at most WAIT_SECONDS; then as it is. None when it cannot be read."""
    end = time.time() + WAIT_SECONDS
    while True:
        try:
            with open(path, "rb") as fh:
                fh.seek(0, os.SEEK_END)
                fh.seek(max(0, fh.tell() - TAIL_BYTES))
                tail = fh.read()
        except OSError as e:
            log("Zwischenstand: Sitzungsprotokoll nicht lesbar, %s" % e)
            return None
        if not tool_use_id or tool_use_id.encode() in tail or time.time() >= end:
            return tail
        time.sleep(0.1)


def newest_note(tail):
    """(uuid, text) of the newest assistant entry with text in the transcript tail (JSON lines) since the last prompt of
    the user, or None. A user entry that only carries tool results is not a prompt."""
    for line in reversed(tail.split(b"\n")):
        try:
            entry = json.loads(line)
            content = entry["message"]["content"]
        except (ValueError, KeyError, TypeError):
            continue
        blocks = content if isinstance(content, list) else [{"type": "text", "text": content}]
        blocks = [b for b in blocks if isinstance(b, dict)]
        if entry.get("type") == "user":
            if any(b.get("type") == "tool_result" for b in blocks):
                continue
            return None
        if entry.get("type") == "assistant":
            text = "\n".join(b["text"] for b in blocks if b.get("type") == "text" and isinstance(b.get("text"), str))
            if text.strip():
                return str(entry.get("uuid", "")), text
    return None


def open_progress():
    """speak-progress for reading and writing, not through a link and only a regular file (the bridge directory is shared)."""
    fd = os.open(PROGRESS, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise OSError("keine reguläre Datei")
    return os.fdopen(fd, "r+", encoding="utf-8")


def progress():
    begun = time.time()
    data = hook_input()
    path = data and data.get("transcript_path")
    tool_use_id = data and data.get("tool_use_id")
    tail = isinstance(path, str) and transcript_tail(path, tool_use_id if isinstance(tool_use_id, str) else None)
    note = tail and newest_note(tail)
    if not note:
        return
    # parallel tool calls run their hooks at the same time: the lock makes one of them claim the note and start the player
    try:
        with open_progress() as fh:
            fcntl.flock(fh, fcntl.LOCK_EX)
            if fh.read().strip() == note[0]:
                return
            fh.seek(0)
            fh.truncate()
            fh.write(note[0] + "\n")
            fh.flush()
            # switched off or stopped while it waited for the transcript: the note counts as read, nothing starts
            if not os.path.exists(OFF) and not stopped_since(begun):
                speak_answer(note[1])
                # a stop between that check and speak.pid missed the player: end it before Piper has the first sound
                if os.path.exists(OFF) or stopped_since(begun):
                    stop()
    except OSError as e:
        log("Zwischenstand nicht vorgelesen, %s: %s" % (PROGRESS, e))   # without the memory every tool call would read it again


def main(argv):
    if argv[:1] == ["--hook"]:
        hook()
    elif argv[:1] == ["--progress"]:
        progress()
    elif argv[:1] == ["--stop"]:
        mark_stopped()
        stop()
    elif argv[:1] == [RUN_ARG]:
        run()
    elif argv[:1] in (["-h"], ["--help"]):
        print(__doc__.strip())
    else:
        error = start(speakable(" ".join(argv) if argv else sys.stdin.read()))
        if error:
            print("rootbridge-speak: " + error, file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
