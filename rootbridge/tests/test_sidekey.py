"""Tests of sidekey-ptt: a long press of the side key or of the headset key runs `ptt start`, its release `ptt stop`.

The reader gets a made-up event stream (SIDEKEY_CMD) and a stand-in for ptt that logs its argument (SIDEKEY_PTT).
"""
import os
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
READER = os.path.join(HERE, "..", "termux", "bin", "sidekey-ptt")

# writes the events of argv ("code:value:pause", ...) as struct input_event, each followed by a SYN, then waits a bit
EVENTS = r"""
import os, struct, sys, time
out = sys.stdout.buffer
out.write(b"%d\n" % os.getpid())   # like a root reader: its pid first
for item in sys.argv[1:]:
    code, value, pause = item.split(":")
    out.write(struct.pack("<qqHHi", 0, 0, 1, int(code), int(value)) + struct.pack("<qqHHi", 0, 0, 0, 0, 0))
    out.flush()
    time.sleep(float(pause))
time.sleep(0.1)
"""

SIDE, HEADSET, VOLUME = 766, 226, 115


class ReaderTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.log = os.path.join(self.tmp.name, "ptt.log")
        self.events = os.path.join(self.tmp.name, "events.py")
        with open(self.events, "w") as fh:
            fh.write(EVENTS)
        self.ptt = os.path.join(self.tmp.name, "ptt")
        with open(self.ptt, "w") as fh:
            fh.write("#!/bin/sh\necho \"$1\" >> %s\n" % self.log)
        os.chmod(self.ptt, 0o755)


class TestKeys(ReaderTest):
    def press(self, *events):
        """The ptt calls of the reader for these events."""
        cmd = " ".join([sys.executable, "-I", self.events] + list(events))
        env = dict(os.environ, SIDEKEY_CMD=cmd, SIDEKEY_PTT=self.ptt, SIDEKEY_ONCE="1", SIDEKEY_LONG="0.2",
                   SIDEKEY_CACHE=self.tmp.name)
        subprocess.run([sys.executable, "-I", READER], env=env, timeout=30, check=True)
        try:
            with open(self.log) as fh:
                return fh.read().split()
        except FileNotFoundError:
            return []

    def test_long_press_of_the_headset_key(self):
        self.assertEqual(self.press("%d:1:0.5" % HEADSET, "%d:0:0" % HEADSET), ["start", "stop"])

    def test_short_press_of_the_headset_key_stays_with_the_music(self):
        self.assertEqual(self.press("%d:1:0.05" % HEADSET, "%d:0:0" % HEADSET), [])

    def test_long_press_of_the_side_key(self):
        self.assertEqual(self.press("%d:1:0.5" % SIDE, "%d:0:0" % SIDE), ["start", "stop"])

    def test_other_keys_do_nothing(self):
        self.assertEqual(self.press("%d:1:0.5" % VOLUME, "%d:0:0" % VOLUME), [])

    def test_only_the_release_of_the_held_key_stops(self):
        self.assertEqual(self.press("%d:1:0.3" % SIDE, "%d:0:0.3" % HEADSET, "%d:0:0" % SIDE), ["start", "stop"])

    def test_the_stream_ends_while_talking(self):
        self.assertEqual(self.press("%d:1:0.5" % HEADSET), ["start", "stop"])


class TestSources(ReaderTest):
    """Each device has its own reader; the end of one ends the others, and the reader starts over."""

    def run_reader(self, *cmds):
        env = dict(os.environ, SIDEKEY_CMD="\n".join(cmds), SIDEKEY_PTT=self.ptt, SIDEKEY_ONCE="1",
                   SIDEKEY_LONG="0.2", SIDEKEY_CACHE=self.tmp.name)
        start = time.monotonic()
        subprocess.run([sys.executable, "-I", READER], env=env, timeout=30, check=True)
        return time.monotonic() - start

    def event_cmd(self, *events):
        return " ".join([sys.executable, "-I", self.events] + list(events))

    def test_a_key_of_the_second_device(self):
        self.run_reader("sh -c 'echo $$; exec sleep 30'", self.event_cmd("%d:1:0.5" % HEADSET, "%d:0:0" % HEADSET))
        with open(self.log) as fh:
            self.assertEqual(fh.read().split(), ["start", "stop"])

    def test_the_end_of_one_device_ends_the_others(self):
        self.assertLess(self.run_reader(self.event_cmd("%d:1:0.05" % SIDE), "sh -c 'echo $$; exec sleep 30'"), 5)

    def test_the_readers_are_ended_by_their_pid(self):
        # the reader behind the client (like Magisk's root cat behind su) is ended too, not only the client
        pidfile = os.path.join(self.tmp.name, "reader.pid")
        self.run_reader(self.event_cmd("%d:1:0.05" % SIDE),
                        "sh -c 'sleep 30 & echo $! | tee %s; wait'" % pidfile)
        with open(pidfile) as fh:
            pid = int(fh.read())
        self.assertTrue(self.wait_for_end(pid))

    def test_a_reader_whose_pid_comes_late_is_ended_too(self):
        pidfile = os.path.join(self.tmp.name, "reader.pid")
        self.run_reader("true", "sh -c 'sleep 30 & sleep 0.3; echo $! | tee %s; wait'" % pidfile)
        with open(pidfile) as fh:
            pid = int(fh.read())
        self.assertTrue(self.wait_for_end(pid))

    def wait_for_end(self, pid):
        end = time.monotonic() + 5
        while time.monotonic() < end:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return True
            time.sleep(0.05)
        return False

    def test_a_failed_lookup_of_the_headset_starts_over(self):
        bindir = os.path.join(self.tmp.name, "bin")
        os.mkdir(bindir)
        with open(os.path.join(bindir, "su"), "w") as fh:
            fh.write("#!/bin/sh\nexit 1\n")
        os.chmod(os.path.join(bindir, "su"), 0o755)
        env = dict(os.environ, PATH=bindir + os.pathsep + os.environ["PATH"], SIDEKEY_PTT=self.ptt, SIDEKEY_ONCE="1",
                   SIDEKEY_CACHE=self.tmp.name)
        env.pop("SIDEKEY_CMD", None)
        subprocess.run([sys.executable, "-I", READER], env=env, timeout=30, check=True)
        with open(os.path.join(self.tmp.name, "sidekey-ptt.log")) as fh:
            self.assertIn("Headset-Suche fehlgeschlagen: su Exit 1", fh.read())

    def test_the_headset_is_looked_up_as_root(self):
        out = subprocess.run([sys.executable, "-I", "-c",
                              "import runpy; m = runpy.run_path(%r, run_name='x'); print(m['FIND_HEADSET'])" % READER],
                             capture_output=True, text=True, check=True).stdout
        self.assertIn('*"Button Jack"*) echo "/dev/input/${d##*/}"', out)


if __name__ == "__main__":
    unittest.main()
