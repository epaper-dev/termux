"""Tests for guest/claude/speak.py, reading Claude's answers aloud (run: python3 -I -m unittest).

piper and play are stubs (RB_SPEAK_PIPER / RB_SPEAK_PLAY), the bridge directory is a temp dir (RB_SPEAK_DIR).
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
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


class TestFirstSentence(unittest.TestCase):
    def test_up_to_the_first_end(self):
        self.assertEqual(speak.first_sentence("PR #47 ist gemergt. Der Rest folgt.\nZweiter Absatz."), "PR #47 ist gemergt.")

    def test_question_and_exclamation_end_it(self):
        self.assertEqual(speak.first_sentence("Soll ich mergen? Dann sag ja."), "Soll ich mergen?")
        self.assertEqual(speak.first_sentence("Fertig! Alles grün."), "Fertig!")

    def test_numbers_versions_and_abbreviations_do_not(self):
        self.assertEqual(speak.first_sentence("Am 20. November kam Version 2.1.2, z. B. mit Piper, bzw. ohne. Danach mehr."),
                         "Am 20. November kam Version 2.1.2, z. B. mit Piper, bzw. ohne.")
        self.assertEqual(speak.first_sentence("Das gilt z.B. hier. Rest."), "Das gilt z.B. hier.")

    def test_without_an_end_the_first_line(self):
        self.assertEqual(speak.first_sentence("Ergebnis\nDer Text."), "Ergebnis")
        self.assertEqual(speak.first_sentence("So geht es:\nerstens"), "So geht es:")
        self.assertEqual(speak.first_sentence(""), "")


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
                   PIPER_VOICE=self.voice, OUT=self.out, RB_SPEAK_LOG=self.log)
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

    def test_hook_with_speak_first_reads_the_first_sentence(self):
        open(os.path.join(self.bridge, "speak-first"), "w").close()
        r = self.run_speak(["--hook"], json.dumps({"last_assistant_message": "**Alles** gut, z. B. hier. Danach Details.\n\nMehr."}))
        self.assertEqual(r.returncode, 0)
        self.assertTrue(self.wait_for(lambda: self.out_file("play.in") == "RAW"))
        self.assertEqual(self.out_file("piper.in"), "Alles gut, z. B. hier.")

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

    def test_progress_with_speak_first_reads_the_first_sentence(self):
        open(os.path.join(self.bridge, "speak-first"), "w").close()
        self.run_speak(["--progress"], self.transcript(("a1", "assistant", [{"type": "text", "text": "Jetzt die Tests. Danach mehr."}])))
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
