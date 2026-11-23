#!/usr/bin/env python3
"""speak - speech output for Claude Code (termux-rootbridge, part of --voice).

Reads text aloud through PulseAudio in Termux, the same way the microphone of /voice comes in: in your own voice with
Articulino (speak-server.py keeps it loaded) when setup-guest.sh installed it and you recorded the voice (--record), else
with Piper (a local neural voice, de_DE-kerstin-medium); Piper also reads when the server does not come up. Claude's answers are read by the Stop hook, its short notes between tool calls ("Ich baue jetzt ...") by
the PreToolUse hook; a new text ends the one still being read.

  speak.py --hook     Stop hook: reads last_assistant_message from the hook JSON on stdin, unless the switch is off
  speak.py --progress PreToolUse hook: reads the newest text of Claude in this turn from transcript_path, once; before
                      ExitPlanMode also the whole plan (tool_input.plan), also with speak-first
  speak.py --stop     end what is being read and what waits (rootbridge-speak --stop)
  speak.py --command  UserPromptSubmit hook: a prompt that is one of our sentences does not go to Claude: a stop
                      sentence ("Beende die Sprachausgabe", "Hör auf zu reden", "Stop reading aloud", ...; STOP_PHRASES)
                      ends what is read, "Schalte die Sprachausgabe aus|ein" (OFF_PHRASES, ON_PHRASES) switches reading
                      off (and ends it) or on again. A stop ends what is being read and what waits, at once (never
                      through the queue); the sentences work also when the switch is off. "Lies weiter vor",
                      "Fahre mit dem Vorlesen fort" (RESUME_PHRASES) go on with the last text where it was stopped,
                      "Wiederhole den letzten Satz" (REPEAT_SENTENCE_PHRASES) reads that sentence again (and goes on
                      from there next time), "Wiederhole den Text nochmal" (REPEAT_TEXT_PHRASES) the whole text; in
                      place of what is read now, the texts that wait come afterwards. "Lies mir alles vor"
                      (WHOLE_PHRASES) reads the newest answer whole once (speak-answer), "Lies immer alles vor" /
                      "Lies nur die Kurzfassung vor" (ALL_PHRASES, SHORT_PHRASES) switch speak-first. "Welche Sprachbefehle gibt
                      es" (HELP_PHRASES) shows all of them in Claude Code. Two short beeps say how it went: high when
                      it was done, low when it stopped or switched off, or there was nothing to do (RB_SPEAK_BEEP=off:
                      none). The sentence goes to
                      prompt-clear: Termux empties the input line, where Claude Code puts a blocked prompt back
  speak.py --record   record your voice for Articulino from the microphone (RECORD_SECONDS, silence cut)
  speak.py --offer-record  rootbridge-claude before Claude Code starts: Articulino is installed but no voice is recorded
                      yet, so ask on the terminal (yes records, no asks again at the next start, "nie" never again;
                      no answer in OFFER_SECONDS, as when nobody watches the start: Claude Code starts)
  speak.py [TEXT...]  read TEXT, or stdin, aloud (also when the switch is off)
  speak.py --piper-worker VOICE  run by the player with the Python of Piper: the audio of each line of stdin, after its
                      length (Piper's --output-raw runs the sentences together)

What is read: the text without code blocks, tables, URLs and Markdown marks. The English words of the list
speak-english.txt next to this file go to Piper as phonemes ([[...]]) and to Articulino in [en]...[/en], so the German voice
says them in English, and German forms of English verbs as they are said ("gemergt" as "gemörtscht"). With the file speak-first in the bridge
directory (`rootbridge voice speak first|all`) the hooks read only a short version of an answer or note: its whole first
paragraph, and the last question of the text when it stands further down.
--progress remembers the id of the note it read in speak-progress, so each note is read once. The player reads sentence by
sentence (the next one is made while one plays) and notes in speak-last the sentences of its text and the one it is at.
The switch: the file speak-off in the bridge directory (Termux and the guest both see it; `rootbridge voice speak
on|off|toggle` in Termux, the widget "Vorlesen"). Texts are read one after another: each player has a ticket in speak-queue
and waits until the older ones are done. The one that reads runs in its own process group, its id in speak.pid next to
it: Termux ends it from there (`rootbridge voice speak stop`, the widget "Stopp"), and the waiting ones see the stop in
speak-stopped. While Claude Code records for /voice (and right after `ptt start`, speak-hold) the reading pauses and goes on
afterwards where it stopped.

Errors of piper and play go to ~/.cache/rootbridge-speak.log (the hook and the player run detached); the command line
also says when Piper or the voice is missing.

Environment (tests, other voices): PIPER_VOICE (.onnx file), RB_SPEAK_PIPER_PYTHON (the Python of the venv of Piper), RB_SPEAK_PLAY (play of sox),
RB_SPEAK_DIR (bridge directory), RB_SPEAK_LOG (log file), RB_SPEAK_ENGLISH (the list of English words),
RB_SPEAK_ARTICULINO (its venv, the model in model/), RB_SPEAK_VOICE_SAMPLE (your voice), RB_SPEAK_SERVER (speak-server.py),
RB_SPEAK_SOCKET (its socket), RB_SPEAK_SERVER_START (how long to wait for it), RB_SPEAK_REC (rec of sox),
RB_SPEAK_OFFER_SECONDS (how long --offer-record waits for an answer).
Python >= 3.8, standard library only.
"""
import contextlib
import fcntl
import json
import math
import os
import stat
import struct
import re
import queue
import select
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import wave

BRIDGE_DIR = os.environ.get("RB_SPEAK_DIR", "/data/data/com.termux/files/home/.rootbridge")
OFF = os.path.join(BRIDGE_DIR, "speak-off")
FIRST = os.path.join(BRIDGE_DIR, "speak-first")
PIDFILE = os.path.join(BRIDGE_DIR, "speak.pid")
QUEUE = os.path.join(BRIDGE_DIR, "speak-queue")       # a ticket "<time_ns>.<pid>" for each player; the oldest reads
PROGRESS = os.path.join(BRIDGE_DIR, "speak-progress")
FOCUS = os.path.join(BRIDGE_DIR, "speak-focus")       # the daemon's answer for the player: "<pid> <answer>"
ALIVE = os.path.join(BRIDGE_DIR, ".alive")             # the daemon's heartbeat (every round)
FOCUS_WAIT_SECONDS = 1.5   # a round of the daemon is 0.5 s, its question to Android up to 2 s more
PROMPT_CLEAR = os.path.join(BRIDGE_DIR, "prompt-clear")   # a sentence below, for Termux to take out of the input line
LAST = os.path.join(BRIDGE_DIR, "speak-last")         # JSON: the sentences of the last text read and the one it is at
LAST_MAX = 1 << 20
ANSWER = os.path.join(BRIDGE_DIR, "speak-answer")     # .<session>: the whole speakable text of its newest answer or note
ANSWER_DAYS = 7           # a speak-answer.<session> not written for so long goes
STOPPED = os.path.join(BRIDGE_DIR, "speak-stopped")   # its mtime: the last stop (--stop here, rb_speak_stop in Termux)
REC_STALE = os.path.join(BRIDGE_DIR, "rec-stale")     # "<pid> <start time>" of recorders the daemon no longer counts
HOLD = os.path.join(BRIDGE_DIR, "speak-hold")         # its mtime: ptt is about to record (rb_speak_hold in Termux)
HOLD_SECONDS = 3          # how long that pauses reading when no recorder comes (ptt waits PTT_WARMUP + 2 s for one)


def said(text):
    """A prompt as it is compared with the sentences below: lower case, without marks."""
    return " ".join(re.sub(r"[\W_]+", " ", text.lower()).split())


# A prompt that is one of these sentences (case and marks aside) is for us and stays from Claude (--command): stop what is
# read now, switch reading off for good (and stop), or on again. Sentences of three words or more, not single words:
# Claude Code sends a dictated prompt of several words by itself, one word waits for Enter. Written as they are shown
# ("Welche Sprachbefehle gibt es"); the *_PHRASES are what is compared.
STOP_SENTENCES = ("Beende die Sprachausgabe", "Stoppe die Sprachausgabe", "Stopp die Sprachausgabe",
                  "Beende die Sprachansage", "Stoppe die Sprachansage", "Stoppe jetzt die Sprachansage",
                  "Beende das Vorlesen", "Stoppe das Vorlesen", "Stopp das Vorlesen", "Hör auf zu reden",
                  "Höre auf zu reden", "Stop reading aloud", "Stop the speech", "Stop talking now")
OFF_SENTENCES = ("Schalte die Sprachausgabe aus", "Schalte das Vorlesen aus", "Sprachausgabe dauerhaft aus",
                 "Turn speech off", "Turn reading off", "Switch speech off")
ON_SENTENCES = ("Schalte die Sprachausgabe ein", "Schalte die Sprachausgabe an", "Schalte das Vorlesen ein",
                "Schalte das Vorlesen an", "Starte die Sprachausgabe", "Starte das Vorlesen", "Turn speech on",
                "Turn reading on", "Switch speech on")
# go on where the last text was stopped, read its sentence once more, or the whole text
RESUME_SENTENCES = ("Lies weiter vor", "Lese weiter vor", "Lies bitte weiter vor", "Lies den Text weiter",
                    "Fahre mit dem Vorlesen fort", "Continue reading aloud")
REPEAT_SENTENCE_SENTENCES = ("Wiederhole den letzten Satz", "Lies den letzten Satz nochmal",
                             "Lies den letzten Satz noch mal", "Repeat the last sentence")
REPEAT_TEXT_SENTENCES = ("Wiederhole den Text nochmal", "Wiederhole den Text noch mal", "Lies das nochmal vor",
                         "Lies das noch mal vor", "Wiederhole die letzte Ausgabe", "Repeat the last text")
# read the newest answer whole now (once; also after its short version was read); read whole answers (without code) or
# only their short version from now on (speak-first, as `rootbridge voice speak all|first`)
WHOLE_SENTENCES = ("Lies alles vor", "Lese alles vor", "Lies mir alles vor", "Lese mir alles vor",
                   "Lies die ganze Antwort vor", "Lies mir die ganze Antwort vor", "Lies den gesamten Text vor",
                   "Lies mir den gesamten Text vor", "Lese mir den gesamten Text vor", "Read everything aloud",
                   "Read the whole answer")
ALL_SENTENCES = ("Lies immer alles vor", "Lies mir immer alles vor", "Lese immer alles vor", "Lies ab jetzt alles vor",
                 "Lies ab jetzt immer alles vor", "Always read everything", "Always read the whole answer")
SHORT_SENTENCES = ("Lies nur die Kurzfassung vor", "Lies immer nur die Kurzfassung vor",
                   "Lies ab jetzt nur die Kurzfassung vor", "Lies die Kurzfassung vor", "Lies mir die Kurzfassung vor",
                   "Lese mir die Kurzfassung vor", "Lies nur die Zusammenfassung vor", "Lies nur das Wichtigste vor",
                   "Read only the summary", "Read only the short version", "Always read only the summary")
# shows all these sentences in Claude Code
HELP_SENTENCES = ("Welche Sprachbefehle gibt es", "Zeige die Sprachbefehle", "Zeig mir die Sprachbefehle",
                  "Zeige mir die Sprachbefehle", "Show the speech commands")
(STOP_PHRASES, OFF_PHRASES, ON_PHRASES, RESUME_PHRASES, REPEAT_SENTENCE_PHRASES, REPEAT_TEXT_PHRASES, WHOLE_PHRASES,
 ALL_PHRASES, SHORT_PHRASES, HELP_PHRASES) = (
    {said(sentence) for sentence in sentences}
    for sentences in (STOP_SENTENCES, OFF_SENTENCES, ON_SENTENCES, RESUME_SENTENCES, REPEAT_SENTENCE_SENTENCES,
                      REPEAT_TEXT_SENTENCES, WHOLE_SENTENCES, ALL_SENTENCES, SHORT_SENTENCES, HELP_SENTENCES))
MAX_WAIT = float(os.environ.get("RB_SPEAK_MAX_WAIT", 120))   # seconds a text may wait for its turn; older is dropped unread
CHUNK = 4096              # the audio goes to play in pieces of this size, through a pipe of this size: a pause is heard at once
PULSE_LATENCY_MS = 200    # what PulseAudio buffers for play: it runs out while Claude Code starts its recorder after ptt's key
TAIL_BYTES = 512 * 1024   # the newest note stands near the end of the transcript; the hook runs before every tool call
WAIT_SECONDS = 2          # how long --progress waits for its tool call (and the note before it) to reach the transcript
PIPER_PYTHON = os.environ.get("RB_SPEAK_PIPER_PYTHON", "/opt/piper/bin/python3")   # the venv of Piper: --piper-worker
PLAY = os.environ.get("RB_SPEAK_PLAY", "play")
LANGUAGE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "language")   # install-guest.sh: de or en


def language():
    """The language to read in: RB_SPEAK_LANGUAGE, else the file install-guest.sh writes, else German."""
    lang = os.environ.get("RB_SPEAK_LANGUAGE", "")
    if not lang:
        try:
            with open(LANGUAGE_FILE, encoding="ascii") as fh:
                lang = fh.read(8).strip()
        except (OSError, ValueError):
            pass
    return lang if lang in ("de", "en") else "de"


LANGUAGE = language()
PIPER_VOICES = os.environ.get("RB_SPEAK_PIPER_VOICES", "/opt/piper/voices")
GERMAN_VOICE = os.path.join(PIPER_VOICES, "de_DE-kerstin-medium.onnx")
ENGLISH_VOICE = os.path.join(PIPER_VOICES, "en_US-lessac-medium.onnx")
VOICE = os.environ.get("PIPER_VOICE", "")   # a voice of your own: as it is (a missing one is reported)
if not VOICE:
    VOICE = ENGLISH_VOICE if LANGUAGE == "en" else GERMAN_VOICE
    if not os.path.exists(VOICE) and os.path.exists(GERMAN_VOICE):
        VOICE = GERMAN_VOICE   # the English voice not loaded yet (install.sh --no-setup): the German one rather than none
PULSE_COOKIE = "/data/data/com.termux/files/home/.config/pulse/cookie"
LOG = os.environ.get("RB_SPEAK_LOG", os.path.expanduser("~/.cache/rootbridge-speak.log"))
PROC = os.environ.get("RB_SPEAK_PROC", "/proc")
ENGLISH = os.environ.get("RB_SPEAK_ENGLISH", os.path.join(os.path.dirname(os.path.abspath(__file__)), "speak-english.txt"))
ARTICULINO = os.environ.get("RB_SPEAK_ARTICULINO", "/opt/articulino")   # venv of setup-guest.sh, the model in model/
VOICE_SAMPLE = os.environ.get("RB_SPEAK_VOICE_SAMPLE", os.path.expanduser("~/.local/share/rootbridge/voice.wav"))
NEVER_RECORD = os.path.join(os.path.dirname(VOICE_SAMPLE), "voice-never")   # "nie" to --offer-record
OFFER_SECONDS = float(os.environ.get("RB_SPEAK_OFFER_SECONDS", 60))   # --offer-record: no answer, Claude Code starts
SERVER = os.environ.get("RB_SPEAK_SERVER", os.path.join(os.path.dirname(os.path.abspath(__file__)), "speak-server.py"))
# -2: the protocol with the language first (\x01<language>\n); a server of before still running (it ends after half an hour
# idle) is not asked, it would read that line as text
SOCKET = os.environ.get("RB_SPEAK_SOCKET", os.path.expanduser("~/.cache/rootbridge-speak-2.sock"))
REC = os.environ.get("RB_SPEAK_REC", "rec")
SERVER_RATE = 24000         # what speak-server.py sends
SERVER_START_SECONDS = float(os.environ.get("RB_SPEAK_SERVER_START", 30))   # loading takes about 5 s on the A9
RECORD_SECONDS = 12         # Articulino uses the first 8 s after the silence
MIN_VOICE_SECONDS = 3
PIPER_WORKER_ARG = "--piper-worker"   # speak.py with the Python of Piper: the voice loaded once, the audio sentence by sentence
FRAME = struct.Struct(">I")          # what --piper-worker writes before the audio of a sentence: its length
NO_MICROPHONE = os.environ.get("RB_SPEAK_NO_MICROPHONE",   # install-guest.sh puts it there for reading aloud only
                               os.path.join(os.path.dirname(os.path.abspath(__file__)), "no-microphone"))
RUN_ARG = "--run"   # the player process; Termux recognises it by "speak.py --run" in its command line
PAUSES_ARG = "pauses"   # last on its command line: this player pauses itself for a recording (rb_speak_hold in Termux)

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
    """The short version of a speakable text: its first line (paragraph, heading, list item) and the last question of
    the text when it is not in there (a question at the end must be heard)."""
    lines = text.split("\n")
    head = sentences(lines[0])
    questions = [s for line in lines for s in sentences(line) if s.endswith("?")]
    if questions and questions[-1] not in head:
        head.append(questions[-1])
    return " ".join(head)


def english(text, articulino=False):
    """text with the words of the list ENGLISH replaced by what Piper should read: phonemes in [[...]] or a German spelling.
    A line of the list: the word as written (case matters), a tab, the replacement; # starts a comment. No list, no change.
    For Articulino a word with phonemes becomes [en]word[/en] (it reads letters, the English ones in English). Only for
    German: an English voice reads English words as they are."""
    if LANGUAGE != "de":
        return text
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

    def replace(m):
        word = m.group(1)
        if articulino and words[word].startswith("[["):
            return "[en]%s[/en]" % word
        return words[word]
    return re.sub(pattern, replace, text)


def log(message):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write("%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), message))
    except OSError:
        pass


def is_player(pid):
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as fh:
            return b"speak.py " + RUN_ARG.encode() in fh.read().replace(b"\0", b" ")
    except OSError:
        return False


def player_pid():
    """The pid in speak.pid when that process is our player (the file lies where others can write), else None."""
    try:
        with open(PIDFILE, encoding="ascii") as fh:
            pid = int(fh.read().strip())
    except (OSError, ValueError):
        return None
    return pid if is_player(pid) else None


def stop(pid=None):
    """End the player that reads (pid: that one, found before)."""
    pid = pid or player_pid()
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


def stop_mark():
    """The state of speak-stopped (its inode and mtime): a stop changes it (Termux puts a new file in place, --stop touches it)."""
    try:
        st = os.lstat(STOPPED)
        return "%d-%d" % (st.st_ino, st.st_mtime_ns)
    except OSError:
        return "0"


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


def text_parts(text):
    """The sentences of a speakable text, in order (the player reads and remembers them one by one); without the parts
    that have nothing to say (no letter or digit, like a line of only an emoji: no voice reads them)."""
    return [part for line in text.split("\n") for part in sentences(line) if re.search(r"[^\W_]", part)]


def start(text):
    """Read text in a detached process after what is being read now (the hook and the caller do not wait).
    Returns an error message when Piper or the voice is missing, else None."""
    return launch(text_parts(text))


@contextlib.contextmanager
def queue_lock():
    """The lock of the queue: a new ticket, and a player that starts to read (speak.pid), one at a time. Yields False
    when there is no lock (then there is no ticket either)."""
    try:
        os.makedirs(QUEUE, mode=0o700, exist_ok=True)
        lock = os.open(QUEUE + ".lock", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    except OSError as e:
        log("Warteschlange %s: %s" % (QUEUE, e))
        yield False   # the player reads anyway, maybe at the same time as another
        return
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield True
    finally:
        os.close(lock)


def launch(parts, first=0, end=None, replace=None):
    """Read the sentences parts[first:end] (as start); the player remembers all of them in speak-last, and where it is.
    replace: the pid of the player whose text this is (repeat, go on; 0 when it is unknown): this one goes before all
    texts that wait, in place of that player, which ends. When another one reads already (it began after that one), the
    new one waits for it."""
    end = len(parts) if end is None else end
    if first >= end:
        return None
    for what, path in (("Piper", PIPER_PYTHON), ("die Stimme", VOICE)):
        if not os.path.exists(path):
            error = "%s fehlt: %s (bash install.sh --setup in Termux)" % (what, path)
            log(error)
            return error
    # The player reads when no older ticket of a live player is left; a stop after the start changes speak-stopped
    # (wait_turn compares stop_mark). The stamp, the start and the ticket under the lock of the queue: a start at the same
    # time gets a newer stamp only after this ticket is in the queue, and no player begins to read meanwhile.
    after = 0
    with queue_lock() as locked:
        since = time.time_ns()
        ticket = "%020d" % since
        if replace is not None:
            older = [stamp for stamp, _, pid in (name.partition(".") for name in os.listdir(QUEUE))
                     if stamp.isdigit() and pid.isdigit() and is_player(int(pid))]
            if older:
                ticket = "%020d" % (int(min(older)) - 1)
            after = player_pid() or 0
            if after and after == replace:
                stop(after)
        proc = subprocess.Popen([sys.executable, "-I", os.path.abspath(__file__), RUN_ARG, ticket, stop_mark(),
                                 PAUSES_ARG],
                                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True)
        if locked:
            try:
                os.close(os.open(os.path.join(QUEUE, "%s.%d" % (ticket, proc.pid)),
                                 os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600))
            except OSError as e:
                log("Warteschlange %s: %s" % (QUEUE, e))
    proc.stdin.write(json.dumps({"parts": parts, "first": first, "end": end, "since": since, "after": after})
                     .encode("utf-8"))
    proc.stdin.close()
    return None


def write_pidfile(pid):
    tmp = "%s.%d" % (PIDFILE, pid)
    with open(tmp, "w", encoding="ascii") as fh:
        fh.write("%d\n" % pid)
    os.replace(tmp, PIDFILE)


def pulse_env():
    env = dict(os.environ)
    env.setdefault("PULSE_SERVER", "127.0.0.1")
    # a short buffer in PulseAudio (libpulse reads it for every stream): a pause is heard at once
    env.setdefault("PULSE_LATENCY_MSEC", str(PULSE_LATENCY_MS))
    if "PULSE_COOKIE" not in env and os.access(PULSE_COOKIE, os.R_OK):
        env["PULSE_COOKIE"] = PULSE_COOKIE
    return env


def play_command(rate):
    # --buffer: SoX holds no more than one piece of pump(), so a pause is heard at once
    return [PLAY, "-q", "--buffer", str(CHUNK), "-t", "raw", "-r", str(rate), "-e", "signed", "-b", "16", "-c", "1", "-",
            "-t", "pulseaudio"]


def connect():
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        conn.connect(SOCKET)
        return conn
    except OSError:
        conn.close()
        return None


def server_connection():
    """A connection to speak-server.py (Articulino with your voice), which is started when none answers. None without
    Articulino or the voice, or when the server does not come up within SERVER_START_SECONDS: then Piper reads."""
    python = os.path.join(ARTICULINO, "bin", "python3")
    model = os.path.join(ARTICULINO, "model")
    if not (os.path.exists(python) and os.path.isdir(model) and os.path.exists(VOICE_SAMPLE) and os.path.exists(SERVER)):
        return None
    conn = connect()
    if conn:
        return conn
    try:
        os.makedirs(os.path.dirname(SOCKET), exist_ok=True)
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        deadline = time.time() + SERVER_START_SECONDS
        with open(SOCKET + ".lock", "a") as lock:
            while True:   # one start at a time; the lock is held by a starting server, which ends within the deadline
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.time() >= deadline:
                        log("Articulino startet noch immer, es liest Piper")
                        return None
                    time.sleep(0.1)
            conn = connect()
            if conn:
                return conn
            with open(LOG, "a") as err:
                # its own session: a stop ends the player's process group, not the server; the server holds the lock
                # (the same open file) until it listens, also when a stop ends this process while it loads
                server = subprocess.Popen([python, "-I", SERVER, SOCKET, model, VOICE_SAMPLE, str(lock.fileno())],
                                          stdin=subprocess.DEVNULL, stdout=err, stderr=err, start_new_session=True,
                                          pass_fds=(lock.fileno(),))
            deadline = time.time() + SERVER_START_SECONDS
            while time.time() < deadline and server.poll() is None:
                conn = connect()
                if conn:
                    return conn
                time.sleep(0.1)
            if server.poll() is None:   # it hangs: it must not keep the lock (and 500 MB)
                server.kill()
            log("Articulino startete nicht (Exit %s), es liest Piper" % server.wait())
    except OSError as e:
        log("Articulino: %s, es liest Piper" % e)
    return None


def focus_allows():
    """Whether the player may play: it waits up to FOCUS_WAIT_SECONDS for the answer of the Termux daemon (which asks
    Android for the audio focus, so music turns down) and plays unless it says "call" (a phone call is going on).
    Without a running daemon (no fresh heartbeat) or without an answer in time it plays."""
    try:
        if time.time() - os.stat(ALIVE).st_mtime > 3:
            return True
    except OSError:
        return True
    me = str(os.getpid())   # start() registered it in speak.pid, which the daemon answers
    deadline = time.time() + FOCUS_WAIT_SECONDS
    while True:
        try:
            with open(FOCUS, encoding="ascii", errors="replace") as fh:
                pid, _, answer = fh.read(64).partition(" ")
            if pid == me:
                if answer.split()[:1] == ["call"]:
                    log("Telefonat: es wird nicht vorgelesen")
                    return False
                return True
        except OSError:
            pass
        if time.time() >= deadline:
            return True
        time.sleep(0.05)


def read_all(conn):
    data = []
    while True:
        chunk = conn.recv(65536)
        if not chunk:
            return b"".join(data)
        data.append(chunk)


def articulino(conn, text):
    """The audio of one sentence from speak-server.py (b"" when none came)."""
    with conn:
        # a language other than German goes first, on a line of its own after \x01 (speak-server.py)
        head = b"" if LANGUAGE == "de" else b"\x01" + LANGUAGE.encode() + b"\n"
        conn.sendall(head + english(text, articulino=True).encode("utf-8"))
        conn.shutdown(socket.SHUT_WR)
        return read_all(conn)


def read_exact(fh, size):
    data = fh.read(size)
    if len(data) < size:
        raise OSError("Piper endete mitten im Satz")
    return data


def piper_audio(worker, text):
    """The audio of one sentence from --piper-worker."""
    worker.stdin.write(english(text).encode("utf-8") + b"\n")
    worker.stdin.flush()
    size, = FRAME.unpack(read_exact(worker.stdout, FRAME.size))
    return read_exact(worker.stdout, size)


def piper_worker(voice):
    """Runs with the Python of Piper: loads the voice once, then for each line of stdin its audio (raw, 16 bit, mono) on
    stdout, after its length (FRAME). Piper's own --output-raw writes the audio of all lines as one stream."""
    from piper import PiperVoice   # only in the venv of Piper
    model = PiperVoice.load(voice)
    out = sys.stdout.buffer
    for line in sys.stdin.buffer:
        text = line.decode("utf-8", "replace").strip()
        audio = b"".join(chunk.audio_int16_bytes for chunk in model.synthesize(text)) if text else b""
        out.write(FRAME.pack(len(audio)) + audio)
        out.flush()
    return 0


def remember(parts, index, heard):
    """speak-last: the sentences of the text, the index where going on starts (the one that is read now; len(parts): all
    were read), that of the sentence heard last (the one to repeat) and the pid of the player."""
    tmp = "%s.%d" % (LAST, os.getpid())
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump({"parts": parts, "index": index, "heard": heard, "player": os.getpid()}, fh)
        os.replace(tmp, LAST)
    except OSError as e:
        log("%s: %s" % (LAST, e))


def last_read():
    """The sentences of the last text read, the index where going on starts, that of the sentence heard last and the pid
    of its player, from
    speak-last; None when there is none (the file lies where others can write: a regular file, not too big, of the right
    form)."""
    try:
        fd = os.open(LAST, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        with os.fdopen(fd, "rb") as fh:
            if not stat.S_ISREG(os.fstat(fh.fileno()).st_mode):
                return None
            last = json.loads(fh.read(LAST_MAX + 1)[:LAST_MAX].decode("utf-8"))
        parts, index, heard, player = last["parts"], last["index"], last["heard"], last.get("player", 0)
    except (OSError, ValueError, KeyError, TypeError):
        return None
    if not (isinstance(parts, list) and parts and all(isinstance(p, str) for p in parts)
            and isinstance(index, int) and 0 <= index <= len(parts) and isinstance(heard, int) and 0 <= heard < len(parts)
            and isinstance(player, int)):
        return None
    return parts, index, heard, player


def paused():
    """True while the microphone is on or about to be: Claude Code records for /voice, or ptt announced a recording less
    than HOLD_SECONDS ago (before its key, so nothing is read into the start of the recording)."""
    try:
        if time.time() - os.lstat(HOLD).st_mtime < HOLD_SECONDS:
            return True
    except OSError:
        pass
    return recording()


def produce(items, parts, first, end, audio, worker, mark):
    """The audio of the sentences parts[first:end] into items, one sentence ahead of the one that plays (audio: that of
    the first one, when it came already); None at the end. worker: --piper-worker, else Articulino. A sentence that
    Articulino has no audio for (a quotation in another script) is left out; when it does not answer, or Piper fails,
    the reading ends there: (that index, None)."""
    index = first
    try:
        for index in range(first, end):
            if index > first or not audio:
                if worker:
                    audio = piper_audio(worker, parts[index])
                else:
                    conn = server_connection()
                    if not conn:
                        raise OSError("Articulino antwortet nicht mehr")
                    audio = articulino(conn, parts[index])
                    if not audio:
                        log("Articulino lieferte für Satz %d kein Audio, er wird übersprungen" % (index + 1))
            items.put((index, audio))
    except OSError as e:
        if stop_mark() == mark:   # a stop ends Piper as well: no failure
            log("Vorlesen abgebrochen: %s" % e)
        items.put((index, None))
    items.put(None)


def play_parts(items, parts, rate, err, env):
    """Plays the sentences from items in pieces of CHUNK and notes in speak-last which one plays (after the last one, when
    play has played all of it: the text is done) and which one was heard last. While paused() nothing more goes: play has only what is in its small
    pipe left and then waits in silence, and the reading goes on where it stopped (a stop signal does not hold a process
    under proot, so the player holds itself). Returns the exit code of play."""
    item = items.get()
    if item is None:
        return 0
    play = subprocess.Popen(play_command(rate), stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=err, env=env,
                            bufsize=0)
    try:
        fcntl.fcntl(play.stdin, fcntl.F_SETPIPE_SZ, CHUNK)
    except (OSError, AttributeError):
        pass
    # what is on its way to the speaker when a piece goes to play: the pipe, SoX and PulseAudio; a sentence counts as heard
    # (and going on starts with it) once that much of it went, so the end of the one before was heard
    lag = 2 * CHUNK + rate * 2 * PULSE_LATENCY_MS // 1000
    done, heard = False, None
    try:
        while item is not None:
            index, audio = item
            if heard is None or audio is None:   # the first one, or no audio for this one: going on starts with it
                remember(parts, index, index if heard is None else heard)
            if audio is None:
                break
            for at in range(0, len(audio), CHUNK):
                while paused():
                    time.sleep(0.1)
                play.stdin.write(audio[at:at + CHUNK])
                if heard != index and at + CHUNK >= min(lag, len(audio)):
                    heard = index
                    remember(parts, index, heard)
            item = items.get()
        else:
            done = True
        play.stdin.close()
    except BrokenPipeError:
        pass
    code = play.wait()
    if done and code == 0:
        remember(parts, index + 1, heard)
    return code


def ahead_of(ticket, after):
    """Whether a live player has an older ticket than this one, or the player after still reads (tickets of dead players
    go)."""
    try:
        names = os.listdir(QUEUE)
    except OSError:
        return False
    ahead = after > 0 and is_player(after)
    for name in names:
        stamp, _, pid = name.partition(".")
        if stamp >= ticket or not pid.isdigit():
            continue
        if is_player(int(pid)):
            ahead = True
        else:
            try:
                os.remove(os.path.join(QUEUE, name))
            except OSError:
                pass
    return ahead


def wait_turn(ticket, mark, since, after=0):
    """Waits until no older ticket of a live player is in the queue and nobody records for /voice (a text that waited must
    not play into the microphone), then takes the turn: speak.pid, under the lock of the queue (a repeat that goes ahead
    sees who reads). False when a stop came after the start (speak-stopped is no longer as it was then, mark) or the text
    waited longer than MAX_WAIT since it came (since): then the player does not read. after: a player that reads until
    it ends (repeat and go on take its place)."""
    while stop_mark() == mark:
        if time.time_ns() - since > MAX_WAIT * 10**9:
            log("Text verworfen: wartete länger als %g s" % MAX_WAIT)
            return False
        if not ahead_of(ticket, after) and not paused():
            with queue_lock():
                if stop_mark() != mark:
                    return False
                if not ahead_of(ticket, after):
                    write_pidfile(os.getpid())   # for a stop and for the daemon's audio focus
                    return True
        time.sleep(0.1)
    return False


def run(ticket, mark):
    """The player: waits for its turn, then reads sentence by sentence with speak-server.py or --piper-worker into play, in
    its own process group (the group id is in speak.pid while it reads)."""
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))   # a stop still removes speak.pid and the ticket (finally below)
    env = pulse_env()
    me = str(os.getpid())
    try:
        job = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
        parts, first, end, since, after = job["parts"], job["first"], job["end"], int(job["since"]), int(job["after"])
        if not wait_turn(ticket, mark, since, after):
            return
        if stop_mark() != mark:   # a stop between the check and speak.pid missed this player
            return
        if not focus_allows():
            return
        with tempfile.TemporaryFile() as err:   # what Piper and play say, into the log only on a failure
            engine, rate, worker, audio = "Articulino", SERVER_RATE, None, b""
            conn = server_connection()
            if conn:
                audio = articulino(conn, parts[first])
                if not audio:
                    log("Articulino lieferte kein Audio (siehe oben), es liest Piper")
            if not audio:
                engine, rate = "piper", sample_rate()
                worker = subprocess.Popen([PIPER_PYTHON, "-I", os.path.abspath(__file__), PIPER_WORKER_ARG, VOICE],
                                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err, env=env)
            items = queue.Queue(maxsize=2)
            threading.Thread(target=produce, args=(items, parts, first, end, audio, worker, mark), daemon=True).start()
            played = play_parts(items, parts, rate, err, env)
            made = 0
            if worker:
                worker.stdin.close()
                try:
                    made = worker.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    worker.kill()
                    made = worker.wait()
            if (made, played) != (0, 0):
                err.seek(0)
                log("%s Exit %d, play Exit %d: %s" % (engine, made, played,
                                                     err.read()[-2000:].decode("utf-8", "replace").strip()))
    except (OSError, ValueError, KeyError, TypeError) as e:
        log("Abspielen ging nicht: %s" % e)
    finally:
        try:
            with open(PIDFILE, encoding="ascii") as fh:
                if fh.read().strip() == me:
                    os.remove(PIDFILE)
        except OSError:
            pass
        try:
            os.remove(os.path.join(QUEUE, "%s.%s" % (ticket, me)))
        except OSError:
            pass


def record():
    """--record: your voice for Articulino, RECORD_SECONDS from the microphone; silence at both ends cut, the level
    evened out. The old recording stays when the new one is shorter than MIN_VOICE_SECONDS. Without dictation (reading
    aloud only) PulseAudio has no microphone: a note instead."""
    if os.path.exists(NO_MICROPHONE):
        print("Ohne Spracheingabe gibt es kein Mikrofon für die Aufnahme. In Termux einschalten: bash install.sh --voice",
              file=sys.stderr)
        return 1
    mark_stopped()   # the waiting texts too: none may play into the microphone
    stop()
    os.makedirs(os.path.dirname(VOICE_SAMPLE), exist_ok=True)
    tmp = VOICE_SAMPLE + ".new.wav"
    print("Aufnahme läuft %d Sekunden: sprich jetzt ruhig ein paar Sätze." % RECORD_SECONDS, flush=True)
    rc = subprocess.call([REC, "-q", "-t", "pulseaudio", "default", "-r", str(SERVER_RATE), "-c", "1", "-b", "16", tmp,
                          "trim", "0", str(RECORD_SECONDS), "silence", "1", "0.1", "1%", "reverse",
                          "silence", "1", "0.3", "1%", "reverse", "gain", "-n", "-3"], env=pulse_env())
    try:
        with wave.open(tmp) as w:
            seconds = w.getnframes() / w.getframerate()
    except (OSError, EOFError, wave.Error):
        seconds = 0
    if rc != 0 or seconds < MIN_VOICE_SECONDS:
        try:
            os.remove(tmp)
        except OSError:
            pass
        print("Zu wenig Sprache aufgenommen (%.1f s, rec Exit %d); die alte Aufnahme bleibt." % (seconds, rc),
              file=sys.stderr)
        return 1
    os.replace(tmp, VOICE_SAMPLE)
    print("Gespeichert: %s (%.1f s). Ab dem nächsten Vorlesen spricht Articulino mit dieser Stimme." % (VOICE_SAMPLE, seconds))
    return 0


def offer_record():
    """--offer-record: after a new installation Articulino is there but the voice is not; ask for it before Claude Code
    starts. Silent without a terminal, with a voice, without Articulino or a microphone, or after "nie"; never fails the
    start."""
    if (os.path.exists(VOICE_SAMPLE) or os.path.exists(NEVER_RECORD) or os.path.exists(NO_MICROPHONE)
            or not os.path.isdir(os.path.join(ARTICULINO, "model")) or not sys.stdin.isatty()):
        return 0
    print("Articulino ist installiert, aber deine Stimme fehlt noch; bis dahin liest Piper vor.")
    print("Jetzt aufnehmen (etwa 10 s ruhig sprechen)? j = ja / Enter = nein, beim nächsten Start / nie: ", end="", flush=True)
    try:
        # nobody may be watching (Termux:Boot, rootbridge start --no-attach): Claude Code starts after OFFER_SECONDS
        if not select.select([sys.stdin], [], [], OFFER_SECONDS)[0]:
            print("\nKeine Antwort, Claude Code startet ohne Aufnahme.")
            return 0
        answer = sys.stdin.readline()
    except KeyboardInterrupt:
        answer = ""
    if not answer:   # Ctrl+D or Ctrl+C: no recording
        print()
        return 0
    answer = answer.strip().lower()
    if answer == "nie":
        os.makedirs(os.path.dirname(NEVER_RECORD), exist_ok=True)
        open(NEVER_RECORD, "w").close()
        print("Ich frage nicht mehr. Später aufnehmen: rootbridge-speak --record")
    elif answer in ("j", "ja", "y", "yes"):   # only an explicit yes opens the microphone
        try:
            record()
        except KeyboardInterrupt:
            print()
    return 0


def hook_input():
    """The hook JSON on stdin, or None when it is not an object or the switch is off."""
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return None
    if os.path.exists(OFF) or not isinstance(data, dict):
        return None
    return data


def proc_start(pid):
    """The start time of a process (field 22 of /proc/<pid>/stat, after the name in parentheses), or None."""
    try:
        with open(os.path.join(PROC, pid, "stat"), "rb") as fh:   # bytes: the name may be cut inside a UTF-8 character
            return fh.read().rpartition(b") ")[2].split()[19].decode("ascii")
    except (OSError, IndexError, UnicodeDecodeError):
        return None


def recording():
    """True while Claude Code records for /voice: its recorder is SoX `rec ... --buffer 1024 -t raw ...` (the same test as
    rb_find_recorders in rootbridge-lib.sh). The microphone would take what is read into the prompt. A recorder in
    rec-stale (left running, rb_fresh_recorders) does not count."""
    try:
        pids = [p for p in os.listdir(PROC) if p.isdigit()]
    except OSError:
        return False
    stale = set()
    try:   # a regular file only, not through a link, and not much of it (the bridge directory is shared)
        fd = os.open(REC_STALE, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            if stat.S_ISREG(os.fstat(fd).st_mode):
                stale = {tuple(w.decode("ascii") for w in line.split()) for line in os.read(fd, 4096).split(b"\n")
                         if len(line.split()) == 2 and line.replace(b" ", b"").isdigit()}
        finally:
            os.close(fd)
    except OSError:
        pass
    stale_pids = {pid for pid, _ in stale}
    for pid in pids:
        if pid in stale_pids and (pid, proc_start(pid)) in stale:   # only the listed pids: their stat, nobody else's
            continue
        try:
            with open(os.path.join(PROC, pid, "cmdline"), "rb") as fh:
                args = fh.read().split(b"\0")
        except OSError:
            continue
        if args[0].endswith(b"rec") and b" --buffer 1024 -t raw " in b" " + b" ".join(args) + b" ":
            return True
    return False


def speak_answer(message, session):
    """Keep the whole speakable text (speak-answer of the session) and read it, or its short version, unless reading is
    off."""
    text = speakable(message)
    save_answer(text, session)
    if os.path.exists(OFF):
        return
    if os.path.exists(FIRST):
        text = summary(text)
    start(text)   # the hooks stay silent towards Claude Code: a failure is in the log


def answer_file(session):
    """speak-answer.<session id of Claude Code>: each window reads its own newest answer again."""
    if not (isinstance(session, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,64}", session)):
        session = "unbekannt"
    return "%s.%s" % (ANSWER, session)


def save_answer(text, session):
    """speak-answer of the session: the whole speakable text, for "Lies mir alles vor" after its short version was read.
    Those of sessions that wrote none for ANSWER_DAYS go."""
    path = answer_file(session)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    try:
        for name in os.listdir(BRIDGE_DIR):
            old = os.path.join(BRIDGE_DIR, name)
            if name.startswith("speak-answer.") and time.time() - os.lstat(old).st_mtime > ANSWER_DAYS * 86400:
                os.remove(old)
    except OSError as e:
        log("%s: %s" % (ANSWER, e))
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except OSError as e:
        log("%s: %s" % (path, e))


def saved_answer(session):
    """The text in speak-answer of the session, or "" (the file lies where others can write: a regular file, not too
    big)."""
    path = answer_file(session)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as fh:
            if not stat.S_ISREG(os.fstat(fh.fileno()).st_mode):
                raise OSError("keine reguläre Datei")
            return fh.read(LAST_MAX).decode("utf-8", "replace")
    except FileNotFoundError:
        return ""
    except OSError as e:
        log("%s: %s" % (path, e))
        return ""


def clear_prompt(prompt):
    """Ask Termux to empty the input line: Claude Code puts a blocked prompt back there. Termux (rb_prompt_clear) empties
    it only while it still holds just this prompt."""
    tmp = "%s.%d" % (PROMPT_CLEAR, os.getpid())
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(prompt.strip())
        os.replace(tmp, PROMPT_CLEAR)
    except OSError as e:
        log("%s: %s" % (PROMPT_CLEAR, e))


def command():
    """A prompt that is one of our sentences: stop at once (never through the queue), switch reading off or on, go on with
    the last text where it stopped or read it (or its sentence) again, and keep it from Claude. Also when reading is off
    (the sentence to switch it on must work then)."""
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    prompt = isinstance(data, dict) and data.get("prompt")
    if not isinstance(prompt, str):
        return
    sentence = said(prompt)
    halt = False                                  # this sentence also ends what is being read
    replay = None                                 # what of the last text is read again: (parts, first, end, player)
    high = True                                   # the beep: high = on, done; low = stopped, off, nothing to do
    try:
        if sentence in STOP_PHRASES:
            halt, high, reason = True, False, "Vorlesen gestoppt."
        elif sentence in OFF_PHRASES:
            switch(OFF, True)   # as `rootbridge voice speak off`
            halt, high, reason = True, False, "Vorlesen ausgeschaltet (wieder an: „Schalte die Sprachausgabe ein“)."
        elif sentence in ON_PHRASES:
            switch(OFF, False)
            reason = "Vorlesen eingeschaltet."
        elif sentence in WHOLE_PHRASES:
            parts = text_parts(saved_answer(data.get("session_id")))
            if parts:   # in place of what is read now; whether the next answers are read whole stays as it is
                replay, reason = (parts, 0, None, player_pid() or 0), "Ich lese die letzte Antwort ganz vor."
            else:
                high, reason = False, "Es gibt keine Antwort, die ich vorlesen könnte."
        elif sentence in ALL_PHRASES:
            switch(FIRST, False)   # as `rootbridge voice speak all`
            reason = "Ab jetzt lese ich immer ganze Antworten vor (ohne Code)."
        elif sentence in SHORT_PHRASES:
            switch(FIRST, True)    # as `rootbridge voice speak first`
            reason = "Ab jetzt lese ich nur noch die Kurzfassung vor."
        elif sentence in HELP_PHRASES:
            reason = help_text()
        elif sentence in RESUME_PHRASES | REPEAT_SENTENCE_PHRASES | REPEAT_TEXT_PHRASES:
            replay, reason = again(sentence)   # in place of what is read now: the texts that wait come afterwards
            high = replay is not None
        else:
            return
    except OSError as e:
        log("Schalter: %s" % e)
        halt, high, reason = False, False, "Vorlesen ließ sich nicht umschalten: %s" % e
    clear_prompt(prompt)
    if halt:
        mark_stopped()
        stop()
    if replay:
        error = launch(*replay)
        if error:
            high, reason = False, error
    beep(high)
    print(json.dumps({"decision": "block", "reason": reason}))


def switch(path, on):
    """A switch file in the bridge directory (speak-off, speak-first): there or not, not through a link."""
    if on:
        os.close(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600))
    elif os.path.lexists(path):
        os.remove(path)


def beep(high):
    """Two short beeps for a sentence of --command, through play in the background (the hook does not wait): high when it
    was done, low when it stopped or switched off, or there was nothing to do. The tones of ptt (800 and 400 Hz), twice,
    so they are not taken for its start and end. RB_SPEAK_BEEP=off: none."""
    if os.environ.get("RB_SPEAK_BEEP", "on") == "off":
        return
    rate, hz = 8000, 800 if high else 400
    tone = b"".join(struct.pack("<h", int(8000 * math.sin(2 * math.pi * hz * n / rate))) for n in range(rate * 8 // 100))
    audio = tone + bytes(rate * 2 * 6 // 100) + tone      # 80 ms, 60 ms quiet, 80 ms
    # a shell in the background waits for play: what play says and its exit code go to the log
    script = '"$@" 2>> "$0" || echo "$(date "+%Y-%m-%d %H:%M:%S") Ton nicht abgespielt: play Exit $?" >> "$0"'
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        play = subprocess.Popen(["sh", "-c", script, LOG, PLAY, "-q", "-t", "raw", "-r", str(rate), "-e", "signed", "-b",
                                 "16", "-c", "1", "-", "-t", "pulseaudio"], stdin=subprocess.PIPE,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=pulse_env(),
                                start_new_session=True)
        play.stdin.write(audio)   # 3.5 KiB: fits the pipe, the hook goes on at once
        play.stdin.close()
    except OSError as e:
        log("Ton nicht abgespielt: %s" % e)


def help_text():
    """All sentences, by what they do (what Claude Code shows for "Welche Sprachbefehle gibt es")."""
    groups = (("Stoppen", STOP_SENTENCES), ("Weiterlesen", RESUME_SENTENCES),
              ("Letzten Satz wiederholen", REPEAT_SENTENCE_SENTENCES), ("Ganzen Text wiederholen", REPEAT_TEXT_SENTENCES),
              ("Dauerhaft aus", OFF_SENTENCES), ("Wieder ein", ON_SENTENCES),
              ("Letzte Antwort einmal ganz vorlesen", WHOLE_SENTENCES),
              ("Ab jetzt immer ganze Antworten (ohne Code)", ALL_SENTENCES), ("Ab jetzt nur die Kurzfassung", SHORT_SENTENCES),
              ("Diese Liste", HELP_SENTENCES))
    return "Sprachbefehle fürs Vorlesen:\n" + "\n".join(
        "%s: %s" % (title, ", ".join("„%s“" % sentence for sentence in sentences)) for title, sentences in groups)


def again(sentence):
    """What a sentence to go on or to repeat reads of the last text (speak-last), and what Claude Code shows."""
    last = last_read()
    if not last:
        return None, "Es gibt keinen Text, der vorgelesen wurde."
    parts, index, heard, player = last
    if sentence in RESUME_PHRASES:
        if index >= len(parts):
            return None, "Der letzte Text ist zu Ende gelesen."
        return (parts, index, None, player), "Ich lese weiter."
    if sentence in REPEAT_SENTENCE_PHRASES:
        return (parts, heard, heard + 1, player), "Ich wiederhole den letzten Satz."
    return (parts, 0, None, player), "Ich wiederhole den Text."


def hook():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    message = isinstance(data, dict) and data.get("last_assistant_message")
    if isinstance(message, str):
        speak_answer(message, data.get("session_id"))   # kept also when off: "Lies mir alles vor" reads the newest one


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
    if note:
        read_note(note, begun, data.get("session_id"))
    # a plan (ExitPlanMode) is read whole after the note, also with speak-first: the user decides on all of it
    plan = data and data.get("tool_name") == "ExitPlanMode" and (data.get("tool_input") or {}).get("plan")
    if isinstance(plan, str) and not os.path.exists(OFF) and not stopped_since(begun):
        start(speakable(plan))
        if os.path.exists(OFF) or stopped_since(begun):
            mark_stopped()
            stop()


def read_note(note, begun, session):
    """Read the note (uuid, text) unless it was read already."""
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
                speak_answer(note[1], session)
                # a stop between that check and the ticket missed the player: a new stop ends it before the first sound
                if os.path.exists(OFF) or stopped_since(begun):
                    mark_stopped()
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
    elif argv[:1] == ["--command"]:
        command()
    elif argv[:1] == [RUN_ARG] and len(argv) == 4 and argv[1].isdigit() and argv[3] == PAUSES_ARG:
        run(argv[1], argv[2])
    elif argv[:1] == [PIPER_WORKER_ARG] and len(argv) == 2:
        return piper_worker(argv[1])
    elif argv[:1] == ["--record"]:
        return record()
    elif argv[:1] == ["--offer-record"]:
        return offer_record()
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
