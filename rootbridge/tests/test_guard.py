"""Tests for guest/claude/android-root-guard.py (run: python3 -I -m unittest)."""
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.path.join(HERE, "..", "guest", "claude", "android-root-guard.py")

spec = importlib.util.spec_from_file_location("guard", GUARD)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class GuardCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bridge = os.path.join(self.tmp.name, "bridge")
        os.makedirs(self.bridge)
        self.conf = {"BRIDGE_DIR": self.bridge, "TICKET_TTL": "1800",
                     "PROTECTED_PATHS": ""}

    def bash(self, command, **extra):
        data = {"tool_name": "Bash", "tool_input": {"command": command},
                "cwd": self.tmp.name}
        data.update(extra)
        return guard.decide(data, self.conf)

    def kind(self, res):
        return None if res is None else \
            res["hookSpecificOutput"]["permissionDecision"]

    def assertFree(self, command):
        res = self.bash(command)
        self.assertIsNone(res, "sollte frei sein: %r -> %r" % (command, res))

    def assertAsk(self, command):
        res = self.bash(command)
        self.assertEqual(self.kind(res), "ask", "ask erwartet: %r" % command)
        return res

    def assertDeny(self, command):
        res = self.bash(command)
        self.assertEqual(self.kind(res), "deny", "deny erwartet: %r" % command)
        return res

    def ticket_lines(self, tid):
        with open(os.path.join(self.bridge, "tickets", tid),
                  encoding="utf-8") as fh:
            return fh.read().split("\n")

    def tickets(self):
        tdir = os.path.join(self.bridge, "tickets")
        return sorted(f for f in os.listdir(tdir) if not f.startswith(".")) \
            if os.path.isdir(tdir) else []


class TestAndroidsu(GuardCase):
    def test_literal_gets_ticket(self):
        res = self.assertAsk("androidsu 'id'")
        new = res["hookSpecificOutput"]["updatedInput"]["command"]
        tid = new.split()[0].split("=", 1)[1]
        self.assertTrue(new.startswith("ROOTBRIDGE_TICKET="))
        self.assertTrue(new.endswith("androidsu 'id'"))
        self.assertEqual(self.tickets(), [tid])
        lines = self.ticket_lines(tid)
        self.assertEqual(lines[1], hashlib.sha256(b"id").hexdigest())
        self.assertGreater(int(lines[0]), 0)

    def test_hash_is_of_joined_arguments(self):
        res = self.assertAsk("androidsu getprop ro.build.version.sdk")
        tid = res["hookSpecificOutput"]["updatedInput"]["command"] \
            .split()[0].split("=", 1)[1]
        digest = self.ticket_lines(tid)[1]
        self.assertEqual(digest, hashlib.sha256(
            b"getprop ro.build.version.sdk").hexdigest())

    def test_quoted_with_spaces_and_dollar_in_single_quotes(self):
        res = self.assertAsk("androidsu 'echo $HOME; ls -la /data'")
        self.assertIn("ROOTBRIDGE_TICKET=", res["hookSpecificOutput"]
                      ["updatedInput"]["command"])

    def test_variable_is_denied(self):
        self.assertDeny('androidsu "echo $HOME"')
        self.assertDeny("androidsu $CMD")
        self.assertDeny("androidsu $(cat cmd.txt)")
        self.assertDeny("androidsu `cat cmd.txt`")
        self.assertDeny("androidsu ls /sdcard/*")
        self.assertDeny("androidsu ls ~/x")
        self.assertDeny("androidsu echo {a,b}")
        self.assertEqual(self.tickets(), [])

    def test_no_arguments_is_free(self):
        self.assertFree("androidsu")

    def test_redirects_are_not_arguments(self):
        res = self.assertAsk("androidsu 'id' 2>&1 >/tmp/out")
        new = res["hookSpecificOutput"]["updatedInput"]["command"]
        tid = new.split()[0].split("=", 1)[1]
        digest = self.ticket_lines(tid)[1]
        self.assertEqual(digest, hashlib.sha256(b"id").hexdigest())

    def test_pipeline_and_chain_get_one_ticket_each(self):
        res = self.assertAsk("androidsu 'id' | head -1; androidsu 'ls /' && echo ok")
        new = res["hookSpecificOutput"]["updatedInput"]["command"]
        self.assertEqual(new.count("ROOTBRIDGE_TICKET="), 2)
        self.assertEqual(len(self.tickets()), 2)

    def test_command_substitution_inside_assignment(self):
        res = self.assertAsk('out=$(androidsu "id"); echo "$out"')
        new = res["hookSpecificOutput"]["updatedInput"]["command"]
        self.assertIn("$(ROOTBRIDGE_TICKET=", new)
        self.assertEqual(len(self.tickets()), 1)

    def test_substitution_in_double_quotes(self):
        res = self.assertAsk('echo "uid: $(androidsu \'id\')"')
        self.assertIn("$(ROOTBRIDGE_TICKET=", res["hookSpecificOutput"]
                      ["updatedInput"]["command"])

    def test_backtick_substitution_has_no_ticket(self):
        res = self.assertAsk("x=`androidsu 'id'`")
        self.assertNotIn("updatedInput", res["hookSpecificOutput"])

    def test_wrappers_keep_ticket_in_front(self):
        for cmd in ("timeout 60 androidsu 'id'", "nohup androidsu 'id'",
                    "env FOO=1 androidsu 'id'", "FOO=1 androidsu 'id'",
                    "/data/data/com.termux/files/home/bin/androidsu 'id'",
                    "! androidsu 'id'", "if androidsu 'id'; then echo y; fi"):
            res = self.assertAsk(cmd)
            new = res["hookSpecificOutput"]["updatedInput"]["command"]
            self.assertEqual(new.count("ROOTBRIDGE_TICKET="), 1, cmd)

    def test_env_clearing_wrapper_gives_no_ticket(self):
        res = self.assertAsk("env -i androidsu 'id'")
        self.assertNotIn("updatedInput", res["hookSpecificOutput"])

    def test_lookup_is_free(self):
        self.assertFree("command -v androidsu")
        self.assertFree("which androidsu")
        self.assertFree("echo androidsu")

    def test_indirect_runners_ask_without_ticket(self):
        for cmd in ("bash -c 'androidsu id'", "sh -c \"su -c id\"",
                    "xargs androidsu < list.txt", "find / -exec su -c id \\;",
                    "python3 -c \"import os; os.system('su')\"",
                    "eval 'androidsu id'", "sudo androidsu id"):
            res = self.assertAsk(cmd)
            self.assertNotIn("updatedInput", res["hookSpecificOutput"], cmd)
        self.assertEqual(self.tickets(), [])

    def test_script_file_content_is_scanned(self):
        path = os.path.join(self.tmp.name, "dump.sh")
        with open(path, "w") as fh:
            fh.write("#!/bin/bash\nandroidsu 'dd if=/dev/zero of=/x'\n")
        self.assertAsk("bash dump.sh")
        self.assertAsk("./dump.sh")
        clean = os.path.join(self.tmp.name, "clean.sh")
        with open(clean, "w") as fh:
            fh.write("#!/bin/bash\necho hello\n")
        self.assertFree("bash clean.sh")

    def test_heredoc_falls_back(self):
        self.assertAsk("cat <<EOF | bash\nandroidsu id\nEOF")
        self.assertFree("cat > notes.txt <<EOF\nhello\nEOF")

    def test_same_command_twice_needs_two_tickets(self):
        res = self.assertAsk("androidsu 'id'; androidsu 'id'")
        new = res["hookSpecificOutput"]["updatedInput"]["command"]
        self.assertEqual(new.count("ROOTBRIDGE_TICKET="), 2)
        self.assertEqual(len(self.tickets()), 2)

    def test_deny_creates_no_ticket_even_if_other_call_is_valid(self):
        self.assertDeny("androidsu 'id'; androidsu $X")
        self.assertEqual(self.tickets(), [])

    def test_ticket_text_is_not_confused_by_quoted_lookalike(self):
        res = self.assertAsk("echo 'androidsu x'; androidsu 'id'")
        new = res["hookSpecificOutput"]["updatedInput"]["command"]
        self.assertTrue(new.startswith("echo 'androidsu x'; ROOTBRIDGE_TICKET="))

    def test_multiline_command(self):
        res = self.assertAsk("cd /tmp\nandroidsu 'id'\necho done")
        new = res["hookSpecificOutput"]["updatedInput"]["command"]
        self.assertEqual(new.count("ROOTBRIDGE_TICKET="), 1)
        self.assertTrue(new.endswith("echo done"))

    def test_unbalanced_quotes_fall_back(self):
        self.assertAsk("echo 'androidsu id")
        self.assertFree("echo 'hello")


class TestRootTools(GuardCase):
    def test_always_ask(self):
        for cmd in ("su -c id", "/system/xbin/su", "magisk --sqlite 'select 1'",
                    "resetprop ro.debuggable 1", "setprop x y",
                    "fastboot flash boot boot.img", "fastboot reboot"):
            self.assertAsk(cmd)

    def test_adb(self):
        for cmd in ("adb shell su -c id", "adb root", "adb push a /sdcard/",
                    "adb -s ABC reboot", "adb install x.apk",
                    "adb connect 192.168.1.2:5555", "adb pair 1.2.3.4:4000"):
            self.assertAsk(cmd)
        for cmd in ("adb devices", "adb version", "adb --version",
                    "adb -s ABC get-state", "adb help", "adb"):
            self.assertFree(cmd)

    def test_fastboot_safe(self):
        self.assertFree("fastboot devices")
        self.assertFree("fastboot --version")

    def test_android_paths_without_root_are_free(self):
        for cmd in ("ls /sdcard", "cat /storage/emulated/0/x.txt",
                    "cp a.txt /sdcard/Download/", "getprop ro.product.model",
                    "ls /data/data/com.termux/files/home", "mkdir -p /sdcard/git",
                    "echo hi > /sdcard/test.txt", "git status", "ls -la /root"):
            self.assertFree(cmd)

    def test_chain_mixed(self):
        res = self.assertAsk("ls /sdcard && adb shell id")
        self.assertIn("adb shell", res["hookSpecificOutput"]
                      ["permissionDecisionReason"])


class TestTamper(GuardCase):
    def test_bash_writes_to_protected(self):
        for cmd in ("rm -rf /etc/claude-code",
                    "echo {} > /etc/claude-code/managed-settings.json",
                    "mv /usr/local/bin/androidsu /tmp/x",
                    "sed -i 's/ask/allow/' /etc/claude-code/managed-settings.json",
                    "rm /data/data/com.termux/files/home/.rootbridge/audit.log",
                    "cp x /usr/local/lib/termux-rootbridge/android-root-guard.py",
                    "chmod 000 /usr/local/bin/androidsu",
                    "tee /etc/termux-rootbridge.conf < x"):
            self.assertAsk(cmd)

    def test_reading_protected_is_free(self):
        for cmd in ("cat /etc/claude-code/managed-settings.json",
                    "ls -la /data/data/com.termux/files/home/.rootbridge",
                    "tail -n 20 /data/data/com.termux/files/home/.rootbridge/audit.log",
                    "grep ask /etc/claude-code/managed-settings.json",
                    "find /etc/claude-code -name '*.json'"):
            self.assertFree(cmd)

    def test_find_with_delete_asks(self):
        self.assertAsk("find /etc/claude-code -delete")

    def test_bridge_cli(self):
        self.assertAsk("rootbridge guard-off")
        self.assertAsk("rootbridge stop")
        self.assertFree("rootbridge status")

    def test_file_tools(self):
        for tool, key in (("Write", "file_path"), ("Edit", "file_path"),
                          ("NotebookEdit", "notebook_path")):
            res = guard.decide({"tool_name": tool, "tool_input": {
                key: "/etc/claude-code/managed-settings.json"}}, self.conf)
            self.assertEqual(self.kind(res), "ask", tool)
        self.assertIsNone(guard.decide({"tool_name": "Write", "tool_input": {
            "file_path": "/sdcard/notes.txt"}}, self.conf))
        self.assertIsNone(guard.decide({"tool_name": "Edit", "tool_input": {
            "file_path": "/root/workspace/x.py"}}, self.conf))

    def test_symlink_into_protected_is_caught(self):
        link = os.path.join(self.tmp.name, "lnk")
        target = os.path.join(self.tmp.name, "prot")
        os.makedirs(target)
        self.conf["PROTECTED_PATHS"] = target
        os.symlink(target, link)
        res = guard.decide({"tool_name": "Write", "tool_input": {
            "file_path": os.path.join(link, "x")}}, self.conf)
        self.assertEqual(self.kind(res), "ask")

    def test_other_tools_ignored(self):
        self.assertIsNone(guard.decide({"tool_name": "Read", "tool_input": {
            "file_path": "/etc/claude-code/managed-settings.json"}}, self.conf))


class TestEntryPoint(unittest.TestCase):
    def run_guard(self, stdin, env=None):
        e = dict(os.environ)
        e.update(env or {})
        return subprocess.run([sys.executable, "-I", GUARD], input=stdin,
                              capture_output=True, text=True, env=e)

    def test_broken_json_asks(self):
        r = self.run_guard("{not json")
        self.assertEqual(r.returncode, 0)
        out = json.loads(r.stdout)
        self.assertEqual(out["hookSpecificOutput"]["permissionDecision"], "ask")
        self.assertIn("Guard-Fehler", out["hookSpecificOutput"]
                      ["permissionDecisionReason"])

    def test_non_object_asks(self):
        r = self.run_guard("[1,2]")
        self.assertEqual(json.loads(r.stdout)["hookSpecificOutput"]
                         ["permissionDecision"], "ask")

    def test_harmless_command_prints_nothing(self):
        r = self.run_guard(json.dumps({"tool_name": "Bash",
                                       "tool_input": {"command": "ls /sdcard"}}))
        self.assertEqual((r.returncode, r.stdout), (0, ""))

    def test_end_to_end_ticket(self):
        with tempfile.TemporaryDirectory() as tmp:
            conf = os.path.join(tmp, "conf")
            with open(conf, "w") as fh:
                fh.write("BRIDGE_DIR=%s\nTICKET_TTL=60\n" % tmp)
            r = self.run_guard(json.dumps({
                "tool_name": "Bash",
                "tool_input": {"command": "androidsu 'id'", "description": "x"}}),
                env={"ROOTBRIDGE_CONF": conf})
            out = json.loads(r.stdout)["hookSpecificOutput"]
            self.assertEqual(out["permissionDecision"], "ask")
            self.assertEqual(out["updatedInput"]["description"], "x")
            tid = out["updatedInput"]["command"].split()[0].split("=", 1)[1]
            self.assertTrue(os.path.isfile(os.path.join(tmp, "tickets", tid)))


class TestTokenizer(unittest.TestCase):
    def words(self, s):
        return [[w.text for w in sc.words] for sc in guard.tokenize(s)]

    def test_basic(self):
        self.assertEqual(self.words("a b 'c d' \"e f\" g\\ h"),
                         [["a", "b", "c d", "e f", "g h"]])

    def test_separators(self):
        self.assertEqual(self.words("a;b&&c||d|e&f\ng"),
                         [["a"], ["b"], ["c"], ["d"], ["e"], ["f"], ["g"]])

    def test_comment(self):
        self.assertEqual(self.words("a # b c\nd"), [["a"], ["d"]])

    def test_redirects(self):
        scs = guard.tokenize("cmd 2>&1 >out <in &>all x")
        self.assertEqual([w.text for w in scs[0].words], ["cmd", "x"])
        self.assertEqual([w.text for _, w in scs[0].redirs],
                         ["1", "out", "in", "all"])

    def test_quotes_literal(self):
        sc = guard.tokenize("x '$HOME' \"$HOME\" $HOME \"a\" '*'")[0]
        self.assertEqual([w.lit for w in sc.words],
                         [True, True, False, False, True, True])

    def test_unterminated(self):
        for s in ("echo 'x", 'echo "x', "echo $(x", "echo `x"):
            with self.assertRaises(guard.Unparsable):
                guard.tokenize(s)


if __name__ == "__main__":
    unittest.main()
