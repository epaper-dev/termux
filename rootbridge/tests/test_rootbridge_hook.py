"""Tests for guest/claude/rootbridge-hook.py (run: python3 -I -m unittest discover -s tests -p test_rootbridge_hook.py).

The hook hands the notes of the Termux daemon (events/<agent pid>-<ns>) to the agent that asked, as additionalContext.
It runs as a subprocess of the test, so the test process is the "agent" above it in a fake /proc."""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HOOK = os.path.join(HERE, "..", "guest", "claude", "rootbridge-hook.py")
CLAUDE_EXE = "/root/.local/share/claude/versions/2.1.325"
CODEX_EXE = "/root/.codex/packages/standalone/releases/0.169.0/bin/codex"


class HookCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bridge = os.path.join(self.tmp.name, "bridge")
        self.events = os.path.join(self.bridge, "events")
        self.proc = os.path.join(self.tmp.name, "proc")
        os.makedirs(self.events)
        self.conf = os.path.join(self.tmp.name, "rootbridge.conf")
        with open(self.conf, "w") as fh:
            fh.write("BRIDGE_DIR=%s\n" % self.bridge)
        self.agent(CLAUDE_EXE)

    def agent(self, exe, ppid=1):
        """The test process (the parent of the hook) is the agent with this executable."""
        d = os.path.join(self.proc, str(os.getpid()))
        os.makedirs(d, exist_ok=True)
        if os.path.lexists(os.path.join(d, "exe")):
            os.remove(os.path.join(d, "exe"))
        os.symlink(exe, os.path.join(d, "exe"))
        with open(os.path.join(d, "status"), "w") as fh:
            fh.write("Name:\tx\nPPid:\t%d\n" % ppid)

    def note(self, decision, command, pid=None, name=None):
        pid = os.getpid() if pid is None else pid
        path = os.path.join(self.events, name or "%d-1700000000000000001" % pid)
        with open(path, "w") as fh:
            fh.write("%s\n%s\n" % (decision, command))
        return path

    def run_hook(self, event="PostToolUse", stdin=None):
        env = dict(os.environ, ROOTBRIDGE_CONF=self.conf, RB_PROC_DIR=self.proc)
        stdin = json.dumps({"hook_event_name": event}) if stdin is None else stdin
        p = subprocess.run([sys.executable, "-I", HOOK], input=stdin, capture_output=True, text=True, env=env, timeout=30)
        self.assertEqual(p.returncode, 0, p.stderr)
        return json.loads(p.stdout) if p.stdout.strip() else None

    def context(self, out):
        return out["hookSpecificOutput"]["additionalContext"]

    def test_refusal_reaches_its_agent_and_the_note_is_gone(self):
        path = self.note("DENY-USER", "androidsu id")
        for event in ("PostToolUse", "UserPromptSubmit"):
            self.note("DENY-USER", "androidsu id")
            out = self.run_hook(event)
            self.assertEqual(out["hookSpecificOutput"]["hookEventName"], event)
            self.assertIn("`androidsu id` in Termux abgelehnt", self.context(out))
            self.assertIn("Keine Umgehung", self.context(out))
        self.assertFalse(os.path.exists(path))
        self.assertIsNone(self.run_hook(), "the note is delivered once")

    def test_codex_gets_its_notes_too(self):
        self.agent(CODEX_EXE)
        self.note("DENY-USER", "su -c id")
        self.assertIn("`su -c id`", self.context(self.run_hook()))

    def test_agent_is_found_above_the_hook_not_only_directly(self):
        # hook -> test process (a shell) -> agent
        agent_pid = 424242
        os.makedirs(os.path.join(self.proc, str(agent_pid)))
        os.symlink(CLAUDE_EXE, os.path.join(self.proc, str(agent_pid), "exe"))
        with open(os.path.join(self.proc, str(agent_pid), "status"), "w") as fh:
            fh.write("PPid:\t1\n")
        self.agent("/usr/bin/bash", ppid=agent_pid)
        self.note("DENY-USER", "androidsu id", pid=agent_pid)
        self.assertIsNotNone(self.run_hook())

    def test_notes_of_other_agents_stay(self):
        other = self.note("DENY-USER", "androidsu id", pid=999999)
        self.assertIsNone(self.run_hook())
        self.assertTrue(os.path.exists(other))

    def test_no_agent_above_the_hook_means_no_output(self):
        self.agent("/usr/bin/bash", ppid=1)
        path = self.note("DENY-USER", "androidsu id")
        self.assertIsNone(self.run_hook())
        self.assertTrue(os.path.exists(path))

    def test_other_events_leave_the_notes_alone(self):
        path = self.note("DENY-USER", "androidsu id")
        self.assertIsNone(self.run_hook("PreToolUse"))
        self.assertTrue(os.path.exists(path))

    def test_each_decision_has_its_message(self):
        for decision, text in (("ASK-TIMEOUT", "nicht rechtzeitig geantwortet"),
                               ("ASK-FAIL", "Rückfrage in Termux nicht angezeigt")):
            self.note(decision, "androidsu id")
            self.assertIn(text, self.context(self.run_hook()))
        self.note("SOMETHING-ELSE", "androidsu id")
        self.assertIsNone(self.run_hook(), "unknown decisions say nothing")

    def test_two_notes_come_in_order(self):
        self.note("DENY-USER", "androidsu one", name="%d-1700000000000000001" % os.getpid())
        self.note("ASK-FAIL", "androidsu two", name="%d-1700000000000000002" % os.getpid())
        lines = self.context(self.run_hook()).split("\n")
        self.assertEqual(len(lines), 2)
        self.assertIn("androidsu one", lines[0])
        self.assertIn("androidsu two", lines[1])

    def test_the_command_is_cleaned_and_cut(self):
        self.note("DENY-USER", "echo `id`\x1b[31m" + "x" * 500)
        text = self.context(self.run_hook())
        self.assertNotIn("\x1b", text)
        self.assertEqual(text.count("`"), 2, "only the quotes around the command")
        self.assertLess(len(text), 600)

    def test_temp_files_of_the_daemon_are_ignored(self):
        tmp = self.note("DENY-USER", "androidsu id", name="%d-1700000000000000001.tmp.77" % os.getpid())
        self.assertIsNone(self.run_hook())
        self.assertTrue(os.path.exists(tmp))

    def test_silent_on_garbage_and_missing_directories(self):
        for bad in ("kein json", "[]", "", "{}"):
            self.assertIsNone(self.run_hook(stdin=bad), repr(bad))
        os.rmdir(self.events)
        self.assertIsNone(self.run_hook())

    def test_bridge_directory_default_without_a_config(self):
        env = dict(os.environ, ROOTBRIDGE_CONF=os.path.join(self.tmp.name, "gibt-es-nicht"), RB_PROC_DIR=self.proc)
        p = subprocess.run([sys.executable, "-I", HOOK], input=json.dumps({"hook_event_name": "PostToolUse"}),
                           capture_output=True, text=True, env=env, timeout=30)
        self.assertEqual((p.returncode, p.stdout), (0, ""))


if __name__ == "__main__":
    unittest.main()
