#!/usr/bin/env python3
"""speak - speech output for Claude Code (termux-rootbridge, part of --voice).

Reads text aloud with Piper (a local neural voice) through PulseAudio in Termux, the same way the microphone of
/voice comes in. Claude's answers are read by the Stop hook; a new answer ends the one still being read.

  speak.py --hook     Stop hook: reads last_assistant_message from the hook JSON on stdin, unless the switch is off
  speak.py --stop     end what is being read (UserPromptSubmit hook, rootbridge-speak --stop)
  speak.py [TEXT...]  read TEXT, or stdin, aloud (also when the switch is off)

What is read: the text without code blocks, tables, URLs and Markdown marks. With the file speak-first in the bridge
directory (`rootbridge voice speak first|all`) the hook reads only the first sentence of an answer.
The switch: the file speak-off in the bridge directory (Termux and the guest both see it; `rootbridge voice speak
on|off|toggle` in Termux, the widget "Vorlesen"). The player runs in its own process group, its id in speak.pid next to
it: Termux ends it from there (`rootbridge voice speak stop`, the widget "Stopp", `ptt start` before the microphone).

Errors of piper and play go to ~/.cache/rootbridge-speak.log (the hook and the player run detached); the command line
also says when Piper or the voice is missing.

Environment (tests, other voices): PIPER_VOICE (.onnx file), RB_SPEAK_PIPER (piper program), RB_SPEAK_PLAY (play of sox),
RB_SPEAK_DIR (bridge directory), RB_SPEAK_LOG (log file).
Python >= 3.8, standard library only.
"""
import json
import os
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
PIPER = os.environ.get("RB_SPEAK_PIPER", "/opt/piper/bin/piper")
PLAY = os.environ.get("RB_SPEAK_PLAY", "play")
VOICE = os.environ.get("PIPER_VOICE", "/opt/piper/voices/de_DE-kerstin-medium.onnx")
PULSE_COOKIE = "/data/data/com.termux/files/home/.config/pulse/cookie"
LOG = os.environ.get("RB_SPEAK_LOG", os.path.expanduser("~/.cache/rootbridge-speak.log"))
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


def first_sentence(text):
    """The first sentence of a speakable text: its first line (paragraph, heading, list item) up to the first end of a
    sentence. A dot after a number (\"20. November\"), a single letter or a known abbreviation (\"z. B.\") does not end it."""
    line = text.split("\n", 1)[0]
    for m in SENTENCE_END_RE.finditer(line):
        words = line[:m.start()].split()
        word = words[-1].lower() if words else ""
        if m.group() == "." and (word[-1:].isdigit() or len(word) == 1
                                 or word in ABBREVIATIONS or (words[-2:-1] and words[-2].lower() + word in ABBREVIATIONS)):
            continue
        return line[:m.end()]
    return line


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
    text = sys.stdin.buffer.read()
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


def hook():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    if os.path.exists(OFF) or not isinstance(data, dict):
        return
    message = data.get("last_assistant_message")
    if isinstance(message, str):
        text = speakable(message)
        if os.path.exists(FIRST):
            text = first_sentence(text)
        start(text)   # the hook stays silent towards Claude Code: a failure is in the log


def main(argv):
    if argv[:1] == ["--hook"]:
        hook()
    elif argv[:1] == ["--stop"]:
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
