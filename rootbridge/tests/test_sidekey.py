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
import struct, sys, time
out = sys.stdout.buffer
for item in sys.argv[1:]:
    code, value, pause = item.split(":")
    out.write(struct.pack("<qqHHi", 0, 0, 1, int(code), int(value)) + struct.pack("<qqHHi", 0, 0, 0, 0, 0))
    out.flush()
    time.sleep(float(pause))
time.sleep(0.1)
"""

SIDE, HEADSET, VOLUME = 766, 226, 115


class TestKeys(unittest.TestCase):
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


class TestRootCommand(unittest.TestCase):
    def setUp(self):
        self.shell = subprocess.run([sys.executable, "-I", "-c",
                                     "import runpy; m = runpy.run_path(%r, run_name='x'); print(m['CMD'][2])" % READER],
                                    capture_output=True, text=True, check=True).stdout.strip()

    def test_reads_the_side_key_and_the_headset_buttons(self):
        self.assertIn("r /dev/input/event2 &", self.shell)
        self.assertIn('*"Button Jack"*) r "/dev/input/${d##*/}" &', self.shell)
        self.assertTrue(self.shell.endswith("wait"))

    def test_when_one_reader_ends_the_others_end_too(self):
        # a reader of /dev/null ends at once; a second one (sleep) must not keep the stream open
        shell = self.shell.replace("r /dev/input/event2 &", "sleep 30 & r /dev/null &")
        start = time.monotonic()
        subprocess.run(["sh", "-c", shell], start_new_session=True, capture_output=True, timeout=20)   # until EOF
        self.assertLess(time.monotonic() - start, 5)


if __name__ == "__main__":
    unittest.main()
