"""Tests for guest/claude/speak.py, reading Claude's answers aloud (run: python3 -I -m unittest).

piper and play are stubs (RB_SPEAK_PIPER / RB_SPEAK_PLAY), the bridge directory is a temp dir (RB_SPEAK_DIR).
"""
import fcntl
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SPEAK = os.path.join(HERE, "..", "guest", "claude", "speak.py")

spec = importlib.util.spec_from_file_location("speak", SPEAK)
speak = importlib.util.module_from_spec(spec)
spec.loader.exec_module(speak)


class TestSpeakable(unittest.TestCase):
    def test_markdown_marks_go(self):
        self.assertEqual(speak.speakable("## Ergebnis\n\nDas ist **wichtig** und *betont*, siehe `rootbridge-speak`."),
                         "Ergebnis\nDas ist wichtig und betont, siehe rootbridge-speak.")

    def test_code_blocks_tables_and_rules_go(self):
        text = "Vorher\n```bash\necho geheim\n```\n| a | b |\n|---|---|\n| 1 | 2 |\n---\n~~~\nauch weg\n~~~\nNachher"
        self.assertEqual(speak.speakable(text), "Vorher\nNachher")

    def test_links_keep_their_text_urls_go(self):
        self.assertEqual(speak.speakable("Siehe [die Doku](https://example.com/x) und https://a.b/c?d=1 hier ![bild](x.png)"),
                         "Siehe die Doku und hier")

    def test_list_quote_and_task_marks_go(self):
        self.assertEqual(speak.speakable("- eins\n* zwei\n- [x] erledigt\n> Zitat\n1. nummeriert"),
                         "eins\nzwei\nerledigt\nZitat\n1. nummeriert")

    def test_identifiers_with_underscores_stay(self):
        self.assertEqual(speak.speakable("snake_case_name und file_path:12"), "snake_case_name und file_path:12")

    def test_nothing_left(self):
        self.assertEqual(speak.speakable("```\nnur Code\n```\n"), "")


class TestSummary(unittest.TestCase):
    def test_the_first_paragraph_up_to_three_sentences(self):
        self.assertEqual(speak.summary("PR #47 ist gemergt. Tests grün.\nZweiter Absatz."), "PR #47 ist gemergt. Tests grün.")
        self.assertEqual(speak.summary("Eins. Zwei! Drei. Vier.\nMehr."), "Eins. Zwei! Drei.")

    def test_the_last_question_further_down_is_added(self):
        self.assertEqual(speak.summary("Fertig. Alles grün.\nDetails hier.\nSoll ich A? Oder pushen? Sag Bescheid."),
                         "Fertig. Alles grün. Oder pushen?")

    def test_a_question_in_the_first_paragraph_is_not_repeated(self):
        self.assertEqual(speak.summary("Soll ich mergen? Dann sag ja.\nDetails."), "Soll ich mergen? Dann sag ja.")

    def test_numbers_versions_and_abbreviations_do_not_end_a_sentence(self):
        self.assertEqual(speak.sentences("Am 20. November kam Version 2.1.2, z. B. mit Piper, bzw. ohne. Danach mehr."),
                         ["Am 20. November kam Version 2.1.2, z. B. mit Piper, bzw. ohne.", "Danach mehr."])
        self.assertEqual(speak.sentences("Das gilt z.B. hier. Rest"), ["Das gilt z.B. hier.", "Rest"])

    def test_without_an_end_the_first_line(self):
        self.assertEqual(speak.summary("Ergebnis\nDer Text."), "Ergebnis")
        self.assertEqual(speak.summary("So geht es:\nerstens"), "So geht es:")
        self.assertEqual(speak.summary(""), "")


class TestEnglish(unittest.TestCase):
    """English words of the list go to Piper as phonemes; the rest stays as it is."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.old = speak.ENGLISH
        speak.ENGLISH = os.path.join(self.tmp.name, "english.txt")
        with open(speak.ENGLISH, "w", encoding="utf-8") as fh:
            fh.write("# comment\tx\nPull Request\t[[pˈʊl ɹᵻkwˈɛst]]\nCommit\t[[kəmˈɪt]]\nPre-Commit\t[[pɹˈiːkəmˈɪt]]\n"
                     "Prompt\t[[pɹˈɑːmpt]]\nmain\t[[mˈeɪn]]\ngemergt\tgemörtscht\n")

    def tearDown(self):
        speak.ENGLISH = self.old
        self.tmp.cleanup()

    def test_words_become_phonemes(self):
        self.assertEqual(speak.english("Der Pull Request ist auf main, der Merge-Commit auch."),
                         "Der [[pˈʊl ɹᵻkwˈɛst]] ist auf [[mˈeɪn]], der Merge-[[kəmˈɪt]] auch.")

    def test_german_spelling_of_english_verbs(self):
        self.assertEqual(speak.english("Der Pull Request ist gemergt."), "Der [[pˈʊl ɹᵻkwˈɛst]] ist gemörtscht.")

    def test_longest_word_first(self):
        self.assertEqual(speak.english("Der Pre-Commit prüft."), "Der [[pɹˈiːkəmˈɪt]] prüft.")

    def test_only_whole_words_with_their_case(self):
        text = "Er antwortet prompt, die Commits und Pull Requests, # comment, Commitment, Main."
        self.assertEqual(speak.english(text), text)

    def test_articulino_gets_english_words_in_tags(self):
        self.assertEqual(speak.english("Der Pull Request ist gemergt, der Commit auf main.", articulino=True),
                         "Der [en]Pull Request[/en] ist gemörtscht, der [en]Commit[/en] auf [en]main[/en].")

    def test_no_list_no_change(self):
        speak.ENGLISH = os.path.join(self.tmp.name, "fehlt.txt")
        self.assertEqual(speak.english("Der Pull Request"), "Der Pull Request")

    def test_unreadable_list_is_logged_and_text_stays(self):
        with open(speak.ENGLISH, "wb") as fh:
            fh.write("gemergt\tgem\xf6rtscht\n".encode("cp1252"))
        log = os.path.join(self.tmp.name, "speak.log")
        old_log, speak.LOG = speak.LOG, log
        try:
            self.assertEqual(speak.english("Der Commit"), "Der Commit")
        finally:
            speak.LOG = old_log
        with open(log, encoding="utf-8") as fh:
            self.assertIn("Liste englischer Wörter", fh.read())

    def test_shipped_list_is_well_formed(self):
        speak.ENGLISH = self.old
        with open(self.old, encoding="utf-8") as fh:
            lines = [l.rstrip("\n") for l in fh if l.strip() and not l.startswith("#")]
        self.assertTrue(lines)
        for line in lines:
            word, tab, replacement = line.partition("\t")
            self.assertTrue(tab and word.strip() and replacement.strip(), line)
            if replacement.startswith("["):
                self.assertRegex(replacement, r"^\[\[[^\[\]]+\]\]$", line)
        self.assertEqual(speak.english("Der Pull Request ist gemergt"), "Der [[pˈʊl ɹᵻkwˈɛst]] ist gemörtscht")


STUB_ARTICULINO = r"""
import os


class Audio:   # stands in for a numpy array: the server only clips, scales, converts and takes the bytes
    def __init__(self, data):
        self.data = data

    def clip(self, low, high):
        return self

    def __mul__(self, factor):
        return self

    def astype(self, dtype):
        return self

    def tobytes(self):
        return self.data


class TTS:
    @classmethod
    def from_pretrained(cls, path, precision, threads):
        return cls()

    def set_voice(self, voice):
        with open(voice, encoding="utf-8") as fh:
            self.voice = fh.read().strip()

    def stream(self, text, seed):
        for sentence in text.split(". "):
            yield Audio(("%s:%s|" % (self.voice, sentence)).encode())
"""


class TestServer(unittest.TestCase):
    """speak-server.py with a stub of articulino_onnx."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = self.tmp.name
        os.makedirs(os.path.join(d, "lib", "articulino_onnx"))
        with open(os.path.join(d, "lib", "articulino_onnx", "__init__.py"), "w") as fh:
            fh.write(STUB_ARTICULINO)
        self.voice = os.path.join(d, "voice.wav")
        with open(self.voice, "w") as fh:
            fh.write("A")
        self.sock = os.path.join(d, "s.sock")
        self.lock = self.sock + ".lock"
        server = os.path.join(HERE, "..", "guest", "claude", "speak-server.py")
        with open(self.lock, "a") as lock:   # as speak.py starts it: with its start lock, which the server then holds
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.proc = subprocess.Popen([sys.executable, "-I", "-c", "import runpy, sys; sys.path.insert(0, sys.argv[1]); "
                                          "sys.argv = sys.argv[2:]; runpy.run_path(sys.argv[0], run_name='__main__')",
                                          os.path.join(d, "lib"), server, self.sock, d, self.voice, str(lock.fileno())],
                                         env=dict(os.environ, RB_SPEAK_SERVER_IDLE="2"), stderr=subprocess.PIPE,
                                         pass_fds=(lock.fileno(),))
        end = time.time() + 10
        while not os.path.exists(self.sock) and time.time() < end and self.proc.poll() is None:
            time.sleep(0.05)

    def tearDown(self):
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait()
        self.proc.stderr.close()
        self.tmp.cleanup()

    def say(self, text):
        import socket
        conn = socket.socket(socket.AF_UNIX)
        conn.connect(self.sock)
        conn.sendall(text.encode())
        conn.shutdown(socket.SHUT_WR)
        data = b""
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            data += chunk
        conn.close()
        return data.decode()

    def test_holds_the_start_lock_until_it_listens(self):
        self.assertTrue(os.path.exists(self.sock))
        with open(self.lock, "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)   # raises when the server still held it

    def test_answers_sentence_by_sentence(self):
        self.assertEqual(self.say("Eins. Zwei"), "A:Eins|A:Zwei|")

    def test_a_new_recording_is_used_with_the_next_text(self):
        self.assertEqual(self.say("Eins"), "A:Eins|")
        with open(self.voice, "w") as fh:
            fh.write("B")
        os.utime(self.voice, (time.time() + 5, time.time() + 5))   # a new mtime also on a coarse clock
        self.assertEqual(self.say("Zwei"), "B:Zwei|")

    def test_ends_when_idle_and_takes_its_socket(self):
        self.assertEqual(self.say("Eins"), "A:Eins|")
        self.assertEqual(self.proc.wait(timeout=10), 0)
        self.assertFalse(os.path.exists(self.sock))


STUB_SERVER = r"""
import os, socket, sys
import time
with open(os.path.join(os.environ["OUT"], "server.starts"), "a") as fh:
    fh.write("%d %s\n" % (os.getpid(), " ".join(sys.argv[1:])))
if os.environ.get("STUB_SERVER_FAIL"):
    sys.exit(3)
if os.environ.get("STUB_SERVER_HANG"):
    time.sleep(60)
srv = socket.socket(socket.AF_UNIX)
srv.bind(sys.argv[1])
srv.listen(4)
srv.settimeout(5)
try:
    while True:
        try:
            conn, _ = srv.accept()
        except socket.timeout:
            break
        data = b""
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            data += chunk
        if not os.environ.get("STUB_SERVER_SILENT"):
            conn.sendall(b"PCM:" + data)
        conn.close()
finally:
    os.unlink(sys.argv[1])
"""

STUB_REC = r"""#!/bin/bash
# rec of sox: writes a WAV of STUB_SECONDS to its output file (the argument after "-b 16")
while [ "$1" != "-b" ]; do shift; done
python3 -c 'import sys, wave
w = wave.open(sys.argv[1], "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(24000)
w.writeframes(b"\0\0" * int(24000 * float(sys.argv[2]))); w.close()' "$3" "${STUB_SECONDS:-5}"
"""


class TestPlayer(unittest.TestCase):
    """speak.py as Claude Code runs it, with stubs for piper and play."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = self.tmp.name
        self.bridge = os.path.join(d, "bridge")
        self.out = os.path.join(d, "out")
        os.makedirs(self.bridge)
        os.makedirs(self.out)
        self.log = os.path.join(d, "speak.log")
        self.voice = os.path.join(d, "voice.onnx")
        open(self.voice, "w").close()
        with open(self.voice + ".json", "w") as fh:
            json.dump({"audio": {"sample_rate": 16000}}, fh)
        self.piper = self.stub("piper", 'echo "$@" > "$OUT/piper.args"; cat > "$OUT/piper.in"\n'
                                        '[ -z "${SLOW:-}" ] || sleep 30\nprintf RAW\n')
        self.play = self.stub("play", 'echo "$@" > "$OUT/play.args"; cat > "$OUT/play.in"\n')
        self.pids = []

    def tearDown(self):
        for pid in self.pids:
            try:
                os.killpg(pid, 15)
            except OSError:
                pass
        self.tmp.cleanup()

    def stub(self, name, body):
        path = os.path.join(self.tmp.name, name)
        with open(path, "w") as fh:
            fh.write("#!/bin/bash\n" + body)
        os.chmod(path, 0o755)
        return path

    def env(self, **extra):
        env = dict(os.environ, RB_SPEAK_DIR=self.bridge, RB_SPEAK_PIPER=self.piper, RB_SPEAK_PLAY=self.play,
                   PIPER_VOICE=self.voice, OUT=self.out, RB_SPEAK_LOG=self.log,
                   RB_SPEAK_ENGLISH=os.path.join(self.tmp.name, "keine-liste.txt"),   # the text as it is, unless a test sets one
                   RB_SPEAK_ARTICULINO=os.path.join(self.tmp.name, "kein-articulino"))   # Piper, unless a test sets one
        env.update(extra)
        return env

    def run_speak(self, args, stdin="", **extra):
        return subprocess.run([sys.executable, "-I", SPEAK] + args, input=stdin.encode(), env=self.env(**extra),
                              capture_output=True, timeout=20)

    def wait_for(self, cond, seconds=10):
        end = time.time() + seconds
        while time.time() < end:
            if cond():
                return True
            time.sleep(0.05)
        return False

    def out_file(self, name):
        try:
            with open(os.path.join(self.out, name)) as fh:
                return fh.read()
        except OSError:
            return None

    def read_log(self):
        with open(self.log, encoding="utf-8") as fh:
            return fh.read()

    def pidfile(self):
        return os.path.join(self.bridge, "speak.pid")

    def player_pid(self):
        """The pid in speak.pid once the player wrote it."""
        self.assertTrue(self.wait_for(lambda: os.path.exists(self.pidfile())), "kein speak.pid")
        with open(self.pidfile()) as fh:
            pid = int(fh.read())
        self.pids.append(pid)
        return pid

    def test_hook_reads_the_cleaned_answer(self):
        r = self.run_speak(["--hook"], json.dumps({"last_assistant_message": "Fertig: **alles** gut.\n```\ncode\n```"}))
        self.assertEqual(r.returncode, 0)
        self.assertTrue(self.wait_for(lambda: self.out_file("play.in") == "RAW"))
        self.assertEqual(self.out_file("piper.in"), "Fertig: alles gut.")
        self.assertEqual(self.out_file("piper.args").split(), ["-m", self.voice, "--output-raw"])
        self.assertIn("-r 16000", self.out_file("play.args"))          # the rate of the voice, from its .json
        self.assertIn("-t pulseaudio", self.out_file("play.args"))
        self.assertTrue(self.wait_for(lambda: not os.path.exists(self.pidfile())), "speak.pid bleibt liegen")

    def test_hook_with_speak_first_reads_the_short_version(self):
        open(os.path.join(self.bridge, "speak-first"), "w").close()
        r = self.run_speak(["--hook"], json.dumps({"last_assistant_message":
                                                   "**Alles** gut, z. B. hier. Danach Details.\n\nMehr.\n\n- Soll ich pushen?"}))
        self.assertEqual(r.returncode, 0)
        self.assertTrue(self.wait_for(lambda: self.out_file("play.in") == "RAW"))
        self.assertEqual(self.out_file("piper.in"), "Alles gut, z. B. hier. Danach Details. Soll ich pushen?")

    def test_speak_first_leaves_the_command_line_whole(self):
        open(os.path.join(self.bridge, "speak-first"), "w").close()
        self.run_speak(["Erster Satz. Zweiter Satz."])
        self.assertTrue(self.wait_for(lambda: self.out_file("play.in") == "RAW"))
        self.assertEqual(self.out_file("piper.in"), "Erster Satz. Zweiter Satz.")

    def test_hook_returns_at_once(self):
        start = time.time()
        self.run_speak(["--hook"], json.dumps({"last_assistant_message": "lang"}), SLOW="1")
        self.assertLess(time.time() - start, 5)
        self.player_pid()

    def test_switch_off_reads_nothing(self):
        open(os.path.join(self.bridge, "speak-off"), "w").close()
        r = self.run_speak(["--hook"], json.dumps({"last_assistant_message": "Hallo"}))
        self.assertEqual(r.returncode, 0)
        time.sleep(0.5)
        self.assertIsNone(self.out_file("piper.in"))

    def test_command_line_reads_also_when_off(self):
        open(os.path.join(self.bridge, "speak-off"), "w").close()
        self.run_speak(["Hallo", "Welt"])
        self.assertTrue(self.wait_for(lambda: self.out_file("piper.in") == "Hallo Welt"))

    def test_player_hands_english_words_as_phonemes(self):
        english = os.path.join(self.tmp.name, "english.txt")
        with open(english, "w", encoding="utf-8") as fh:
            fh.write("Commit\t[[kəmˈɪt]]\n")
        self.run_speak(["Der Commit ist grün."], RB_SPEAK_ENGLISH=english)
        self.assertTrue(self.wait_for(lambda: self.out_file("piper.in") == "Der [[kəmˈɪt]] ist grün."))

    def articulino(self, voice=True):
        """Articulino in the temp dir: a venv whose python3 is this one, a model dir, the voice, a stub server."""
        venv = os.path.join(self.tmp.name, "articulino")
        os.makedirs(os.path.join(venv, "bin"), exist_ok=True)
        os.makedirs(os.path.join(venv, "model"), exist_ok=True)
        if not os.path.exists(os.path.join(venv, "bin", "python3")):
            os.symlink(sys.executable, os.path.join(venv, "bin", "python3"))
        sample = os.path.join(self.tmp.name, "voice.wav")
        if voice:
            open(sample, "w").close()
        server = os.path.join(self.tmp.name, "speak-server.py")
        with open(server, "w") as fh:
            fh.write(STUB_SERVER)
        english = os.path.join(self.tmp.name, "english.txt")
        with open(english, "w", encoding="utf-8") as fh:
            fh.write("Commit\t[[kəmˈɪt]]\ngemergt\tgemörtscht\n")
        return dict(RB_SPEAK_ARTICULINO=venv, RB_SPEAK_VOICE_SAMPLE=sample, RB_SPEAK_SERVER=server,
                    RB_SPEAK_SOCKET=os.path.join(self.tmp.name, "s.sock"), RB_SPEAK_ENGLISH=english)

    def test_articulino_reads_through_its_server(self):
        env = self.articulino()
        self.run_speak(["Der Commit ist gemergt."], **env)
        self.assertTrue(self.wait_for(lambda: self.out_file("play.in") == "PCM:Der [en]Commit[/en] ist gemörtscht."))
        self.assertIn("-r 24000", self.out_file("play.args"))
        self.assertIsNone(self.out_file("piper.in"))

    def test_articulino_server_is_started_once(self):
        env = self.articulino()
        self.run_speak(["Eins."], **env)
        self.assertTrue(self.wait_for(lambda: self.out_file("play.in") == "PCM:Eins."))
        self.run_speak(["Zwei."], **env)
        self.assertTrue(self.wait_for(lambda: self.out_file("play.in") == "PCM:Zwei."))
        self.assertEqual(len(self.out_file("server.starts").splitlines()), 1)

    def test_piper_reads_when_the_server_does_not_come_up(self):
        env = self.articulino()
        self.run_speak(["Der Commit."], STUB_SERVER_FAIL="1", **env)
        self.assertTrue(self.wait_for(lambda: self.out_file("piper.in") == "Der [[kəmˈɪt]]."))
        self.assertTrue(self.wait_for(lambda: "Articulino startete nicht" in self.read_log()))

    def test_piper_reads_when_the_server_sends_no_audio(self):
        env = self.articulino()
        self.run_speak(["Hallo."], STUB_SERVER_SILENT="1", **env)
        self.assertTrue(self.wait_for(lambda: self.out_file("piper.in") == "Hallo."))
        self.assertTrue(self.wait_for(lambda: "Articulino lieferte kein Audio" in self.read_log()))

    def test_a_hanging_server_is_ended_and_piper_reads(self):
        env = self.articulino()
        self.run_speak(["Hallo."], STUB_SERVER_HANG="1", RB_SPEAK_SERVER_START="1", **env)
        self.assertTrue(self.wait_for(lambda: self.out_file("piper.in") == "Hallo."))
        pid = int(self.out_file("server.starts").split()[0])
        self.assertTrue(self.wait_for(lambda: not os.path.exists("/proc/%d" % pid) or
                                      open("/proc/%d/stat" % pid).read().split()[2] == "Z"), "der Dienst läuft noch")
        os.remove(os.path.join(self.out, "piper.in"))
        self.run_speak(["Nochmal."], STUB_SERVER_FAIL="1", RB_SPEAK_SERVER_START="1", **env)   # the lock is free again
        self.assertTrue(self.wait_for(lambda: self.out_file("piper.in") == "Nochmal."))
        self.assertEqual(len(self.out_file("server.starts").splitlines()), 2)

    def test_piper_reads_without_a_recorded_voice(self):
        env = self.articulino(voice=False)
        self.run_speak(["Hallo."], **env)
        self.assertTrue(self.wait_for(lambda: self.out_file("piper.in") == "Hallo."))
        self.assertIsNone(self.out_file("server.starts"))

    def test_record_keeps_a_long_enough_voice(self):
        env = self.articulino(voice=False)
        rec = self.stub("rec", STUB_REC.split("\n", 1)[1])
        r = self.run_speak(["--record"], RB_SPEAK_REC=rec, STUB_SECONDS="6", **env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.getsize(env["RB_SPEAK_VOICE_SAMPLE"]) > 24000 * 2 * 5)

    def test_record_too_short_keeps_the_old_voice(self):
        env = self.articulino()
        with open(env["RB_SPEAK_VOICE_SAMPLE"], "w") as fh:
            fh.write("alt")
        rec = self.stub("rec", STUB_REC.split("\n", 1)[1])
        r = self.run_speak(["--record"], RB_SPEAK_REC=rec, STUB_SECONDS="1", **env)
        self.assertEqual(r.returncode, 1)
        with open(env["RB_SPEAK_VOICE_SAMPLE"]) as fh:
            self.assertEqual(fh.read(), "alt")
        self.assertFalse(os.path.exists(env["RB_SPEAK_VOICE_SAMPLE"] + ".new.wav"))

    def daemon_answers(self, answer):
        """The Termux daemon: a fresh heartbeat, and its answer in speak-focus once the player is in speak.pid."""
        open(os.path.join(self.bridge, ".alive"), "w").close()

        def answer_the_player():
            end = time.time() + 10
            while time.time() < end:
                try:
                    with open(self.pidfile()) as fh:
                        pid = fh.read().strip()
                except OSError:
                    pid = ""
                if pid:
                    with open(os.path.join(self.bridge, "speak-focus"), "w") as fh:
                        fh.write("%s %s\n" % (pid, answer))
                    return
                time.sleep(0.02)
        threading.Thread(target=answer_the_player, daemon=True).start()

    def logged(self, text):
        return os.path.exists(self.log) and text in self.read_log()

    def test_no_reading_during_a_call(self):
        self.daemon_answers("call")
        self.run_speak(["Hallo."])
        self.assertTrue(self.wait_for(lambda: self.logged("Telefonat")))
        self.assertIsNone(self.out_file("piper.in"))
        self.assertIsNone(self.out_file("play.in"))

    def test_reads_after_the_answer_of_the_daemon(self):
        self.daemon_answers("granted")
        self.run_speak(["Hallo."])
        self.assertTrue(self.wait_for(lambda: self.out_file("piper.in") == "Hallo."))

    def test_reads_when_the_daemon_does_not_answer(self):
        open(os.path.join(self.bridge, ".alive"), "w").close()
        self.run_speak(["Hallo."])
        self.assertTrue(self.wait_for(lambda: self.out_file("piper.in") == "Hallo."))

    def test_articulino_does_not_read_during_a_call(self):
        env = self.articulino()
        self.daemon_answers("call")
        self.run_speak(["Hallo."], **env)
        self.assertTrue(self.wait_for(lambda: self.logged("Telefonat")))
        self.assertIsNone(self.out_file("play.in"))

    def test_bad_input_is_harmless(self):
        for stdin in ("kein json", "[]", json.dumps({"last_assistant_message": 3}), json.dumps({})):
            self.assertEqual(self.run_speak(["--hook"], stdin).returncode, 0)
        time.sleep(0.5)
        self.assertIsNone(self.out_file("piper.in"))

    def test_without_piper_the_hook_stays_quiet_and_logs(self):
        r = self.run_speak(["--hook"], json.dumps({"last_assistant_message": "Hallo"}),
                           RB_SPEAK_PIPER=os.path.join(self.tmp.name, "gibt-es-nicht"))
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, b"", b""))
        time.sleep(0.5)
        self.assertFalse(os.path.exists(self.pidfile()))
        self.assertIn("Piper fehlt", self.read_log())

    def test_without_the_voice_the_command_line_says_so(self):
        r = self.run_speak(["Hallo"], PIPER_VOICE=os.path.join(self.tmp.name, "keine.onnx"))
        self.assertEqual(r.returncode, 1)
        self.assertIn(b"die Stimme fehlt", r.stderr)

    def test_a_failing_player_is_logged(self):
        self.play = self.stub("play", 'cat > /dev/null; echo "kein PulseAudio" >&2; exit 2\n')
        self.run_speak(["Hallo"])
        self.assertTrue(self.wait_for(lambda: os.path.exists(self.log)), "nichts protokolliert")
        self.assertTrue(self.wait_for(lambda: "kein PulseAudio" in self.read_log()))
        self.assertIn("piper Exit 0, play Exit 2", self.read_log())

    def test_a_stop_is_not_logged_as_a_failure(self):
        self.run_speak(["lang"], SLOW="1")
        pid = self.player_pid()
        self.assertTrue(self.wait_for(lambda: self.out_file("piper.in") == "lang"))
        self.run_speak(["--stop"])
        self.assertTrue(self.wait_for(lambda: not os.path.exists("/proc/%d" % pid)))
        self.assertFalse(os.path.exists(self.log))

    def test_stop_ends_the_player_and_its_children(self):
        self.run_speak(["--hook"], json.dumps({"last_assistant_message": "lang"}), SLOW="1")
        pid = self.player_pid()
        self.assertTrue(self.wait_for(lambda: self.out_file("piper.in") == "lang"))
        self.assertEqual(self.run_speak(["--stop"]).returncode, 0)
        self.assertTrue(self.wait_for(lambda: not os.path.exists("/proc/%d" % pid)), "Abspieler läuft noch")
        self.assertTrue(self.wait_for(lambda: not os.path.exists(self.pidfile())), "speak.pid bleibt liegen")
        out = subprocess.run(["pgrep", "-g", str(pid)], capture_output=True)
        self.assertEqual(out.stdout, b"", "ein Kind des Abspielers läuft noch")

    def test_the_player_is_registered_before_the_hook_returns(self):
        # a stop that comes while the player is still starting (the long press on Home right after an answer) must find it
        self.run_speak(["--hook"], json.dumps({"last_assistant_message": "Hallo"}), SLOW="1")
        self.assertTrue(os.path.exists(self.pidfile()), "speak.pid fehlt, wenn der Hook zurückkehrt")
        with open(self.pidfile()) as fh:
            pid = int(fh.read())
        self.pids.append(pid)
        with open("/proc/%d/cmdline" % pid, "rb") as fh:
            self.assertIn(b"speak.py\0--run", fh.read())

    def test_new_answer_ends_the_old_one(self):
        self.run_speak(["--hook"], json.dumps({"last_assistant_message": "alt"}), SLOW="1")
        old = self.player_pid()
        self.assertTrue(self.wait_for(lambda: self.out_file("piper.in") == "alt"))
        self.run_speak(["--hook"], json.dumps({"last_assistant_message": "neu"}))
        self.assertTrue(self.wait_for(lambda: not os.path.exists("/proc/%d" % old)), "der alte Abspieler läuft noch")
        self.assertTrue(self.wait_for(lambda: self.out_file("piper.in") == "neu"))

    def test_stop_leaves_a_foreign_process_alone(self):
        other = subprocess.Popen(["sleep", "30"], start_new_session=True)
        self.pids.append(other.pid)
        with open(self.pidfile(), "w") as fh:
            fh.write("%d\n" % other.pid)
        self.run_speak(["--stop"])
        time.sleep(0.3)
        self.assertIsNone(other.poll(), "ein fremder Prozess wurde beendet")
        other.kill()
        other.wait()

    def transcript(self, *entries):
        path = os.path.join(self.tmp.name, "session.jsonl")
        with open(path, "w") as fh:
            fh.write('{"kaputt\n')
            for uuid, kind, content in entries:
                fh.write(json.dumps({"type": kind, "uuid": uuid, "message": {"content": content}}) + "\n")
        return json.dumps({"transcript_path": path})

    def test_progress_reads_the_newest_note_once(self):
        data = self.transcript(("u1", "user", "Mach mal"),
                               ("a1", "assistant", [{"type": "text", "text": "Ich lese **zuerst** den Code."}]),
                               ("a2", "assistant", [{"type": "tool_use", "name": "Bash", "input": {}}]),
                               ("t1", "user", [{"type": "tool_result", "content": "ok"}]),
                               ("a3", "assistant", [{"type": "tool_use", "name": "Bash", "input": {}}]))
        self.assertEqual(self.run_speak(["--progress"], data).returncode, 0)
        self.assertTrue(self.wait_for(lambda: self.out_file("play.in") == "RAW"))
        self.assertEqual(self.out_file("piper.in"), "Ich lese zuerst den Code.")
        os.remove(os.path.join(self.out, "piper.in"))
        self.run_speak(["--progress"], data)
        time.sleep(0.5)
        self.assertIsNone(self.out_file("piper.in"), "derselbe Zwischenstand zweimal gelesen")

    def test_parallel_progress_hooks_read_the_note_once(self):
        piper = self.stub("piper-count", 'echo x >> "$OUT/piper.count"; cat > /dev/null\n')
        data = self.transcript(("a1", "assistant", [{"type": "text", "text": "Einmal."}]))
        procs = [subprocess.Popen([sys.executable, "-I", SPEAK, "--progress"], stdin=subprocess.PIPE,
                                  env=self.env(RB_SPEAK_PIPER=piper)) for _ in range(4)]
        for p in procs:
            p.communicate(data.encode(), timeout=20)
        self.assertTrue(self.wait_for(lambda: self.out_file("piper.count") is not None))
        time.sleep(0.5)
        self.assertEqual(self.out_file("piper.count"), "x\n")

    def test_progress_without_its_memory_logs_and_reads_nothing(self):
        os.makedirs(os.path.join(self.bridge, "speak-progress"))
        self.run_speak(["--progress"], self.transcript(("a1", "assistant", [{"type": "text", "text": "Nichts."}])))
        time.sleep(0.5)
        self.assertIsNone(self.out_file("piper.in"))
        self.assertIn("Zwischenstand nicht vorgelesen", self.read_log())

    def test_progress_waits_for_its_tool_call(self):
        path = os.path.join(self.tmp.name, "session.jsonl")
        with open(path, "w") as fh:
            fh.write(json.dumps({"type": "user", "uuid": "u1", "message": {"content": "Mach mal"}}) + "\n")
        proc = subprocess.Popen([sys.executable, "-I", SPEAK, "--progress"], stdin=subprocess.PIPE, env=self.env())
        proc.stdin.write(json.dumps({"transcript_path": path, "tool_use_id": "toolu_9"}).encode())
        proc.stdin.close()
        time.sleep(0.5)   # Claude Code writes the note and the call after the hook started
        with open(path, "a") as fh:
            fh.write(json.dumps({"type": "assistant", "uuid": "a1", "message": {"content": [{"type": "text", "text": "Spät."}]}}) + "\n")
            fh.write(json.dumps({"type": "assistant", "uuid": "a2", "message": {"content": [
                {"type": "tool_use", "id": "toolu_9", "name": "Bash", "input": {}}]}}) + "\n")
        proc.wait(timeout=20)
        self.assertTrue(self.wait_for(lambda: self.out_file("piper.in") == "Spät."))

    def test_a_stop_while_progress_waits_cancels_it(self):
        path = os.path.join(self.tmp.name, "session.jsonl")
        with open(path, "w") as fh:
            fh.write(json.dumps({"type": "assistant", "uuid": "a1", "message": {"content": [{"type": "text", "text": "Zu spät."}]}}) + "\n")
        proc = subprocess.Popen([sys.executable, "-I", SPEAK, "--progress"], stdin=subprocess.PIPE, env=self.env())
        proc.stdin.write(json.dumps({"transcript_path": path, "tool_use_id": "toolu_kommt_nie"}).encode())
        proc.stdin.close()
        time.sleep(0.5)
        self.run_speak(["--stop"])   # push to talk or the widget "Stopp" while the hook waits
        proc.wait(timeout=20)
        time.sleep(0.5)
        self.assertIsNone(self.out_file("piper.in"))
        with open(os.path.join(self.bridge, "speak-progress")) as fh:
            self.assertEqual(fh.read(), "a1\n")

    def test_progress_does_not_write_through_a_link(self):
        target = os.path.join(self.tmp.name, "wertvoll")
        with open(target, "w") as fh:
            fh.write("wertvoll")
        os.symlink(target, os.path.join(self.bridge, "speak-progress"))
        os.symlink(target, os.path.join(self.bridge, "speak-stopped"))
        self.run_speak(["--progress"], self.transcript(("a1", "assistant", [{"type": "text", "text": "Nichts."}])))
        self.run_speak(["--stop"])
        time.sleep(0.5)
        with open(target) as fh:
            self.assertEqual(fh.read(), "wertvoll")
        self.assertIsNone(self.out_file("piper.in"))

    def test_nothing_is_read_while_voice_records(self):
        proc_dir = os.path.join(self.tmp.name, "proc")
        os.makedirs(os.path.join(proc_dir, "4711"))
        with open(os.path.join(proc_dir, "4711", "cmdline"), "wb") as fh:
            fh.write(b"/usr/bin/rec\0-q\0--buffer\0" + b"1024\0-t\0raw\0-")
        self.run_speak(["--progress"], self.transcript(("a1", "assistant", [{"type": "text", "text": "Leise."}])),
                       RB_SPEAK_PROC=proc_dir)
        self.run_speak(["--hook"], json.dumps({"last_assistant_message": "Auch leise."}), RB_SPEAK_PROC=proc_dir)
        time.sleep(0.5)
        self.assertIsNone(self.out_file("piper.in"))

    def test_progress_with_speak_first_reads_the_short_version(self):
        open(os.path.join(self.bridge, "speak-first"), "w").close()
        self.run_speak(["--progress"], self.transcript(("a1", "assistant", [{"type": "text", "text": "Jetzt die Tests.\nDanach mehr."}])))
        self.assertTrue(self.wait_for(lambda: self.out_file("piper.in") == "Jetzt die Tests."))

    def test_progress_says_nothing_before_a_note_in_this_turn(self):
        data = self.transcript(("a1", "assistant", [{"type": "text", "text": "Alte Antwort."}]),
                               ("u1", "user", "Neue Frage"),
                               ("a2", "assistant", [{"type": "tool_use", "name": "Bash", "input": {}}]))
        self.run_speak(["--progress"], data)
        self.run_speak(["--progress"], json.dumps({"transcript_path": "/gibt/es/nicht"}))
        self.run_speak(["--progress"], "kein json")
        time.sleep(0.5)
        self.assertIsNone(self.out_file("piper.in"))
        self.assertIn("Sitzungsprotokoll nicht lesbar", self.read_log())

    def test_progress_switch_off_reads_nothing(self):
        open(os.path.join(self.bridge, "speak-off"), "w").close()
        self.run_speak(["--progress"], self.transcript(("a1", "assistant", [{"type": "text", "text": "Still."}])))
        time.sleep(0.5)
        self.assertIsNone(self.out_file("piper.in"))


if __name__ == "__main__":
    unittest.main()
