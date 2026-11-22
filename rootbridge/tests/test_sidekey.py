"""Tests of the key readers: a long press of the side key runs `ptt start`, its release `ptt stop` (sidekey-ptt); a long
press of the headset key runs `ptt toggle` (headset-ptt). Both share keyreader.py.

A reader gets a made-up event stream (<P>_CMD) and a stand-in for ptt that logs its argument (<P>_PTT).
"""
import os
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SIDEKEY = os.path.join(HERE, "..", "termux", "bin", "sidekey-ptt")
HEADSET_READER = os.path.join(HERE, "..", "termux", "bin", "headset-ptt")
READERS = {"side": (SIDEKEY, "SIDEKEY"), "headset": (HEADSET_READER, "HEADSET")}

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
    def press(self, *events, reader="side"):
        """The ptt calls of the reader for these events."""
        path, p = READERS[reader]
        cmd = " ".join([sys.executable, "-I", self.events] + list(events))
        env = dict(os.environ, **{p + "_CMD": cmd, p + "_PTT": self.ptt, p + "_ONCE": "1", p + "_LONG": "0.2",
                                  p + "_CACHE": self.tmp.name})
        subprocess.run([sys.executable, "-I", path], env=env, timeout=30, check=True)
        try:
            with open(self.log) as fh:
                return fh.read().split()
        except FileNotFoundError:
            return []

    def test_long_presses_of_the_headset_key_toggle(self):
        # its key shorts the microphone while held: a long press toggles, the release does nothing
        self.assertEqual(self.press("%d:1:0.5" % HEADSET, "%d:0:1" % HEADSET, "%d:1:0.5" % HEADSET, "%d:0:0" % HEADSET,
                                    reader="headset"), ["toggle", "toggle"])

    def test_short_press_of_the_headset_key_stays_with_the_music(self):
        self.assertEqual(self.press("%d:1:0.05" % HEADSET, "%d:0:0" % HEADSET, reader="headset"), [])

    def test_long_press_of_the_side_key(self):
        self.assertEqual(self.press("%d:1:0.5" % SIDE, "%d:0:0" % SIDE), ["start", "stop"])

    def test_other_keys_do_nothing(self):
        self.assertEqual(self.press("%d:1:0.5" % VOLUME, "%d:0:0" % VOLUME), [])
        self.assertEqual(self.press("%d:1:0.5" % VOLUME, "%d:0:0" % VOLUME, reader="headset"), [])

    def test_each_reader_reads_its_own_key(self):
        both = ("%d:1:0.5" % SIDE, "%d:0:0.1" % SIDE, "%d:1:0.5" % HEADSET, "%d:0:0" % HEADSET)
        self.assertEqual(self.press(*both), ["start", "stop"])
        os.remove(self.log)
        self.assertEqual(self.press(*both, reader="headset"), ["toggle"])

    def test_a_headset_recording_is_left_to_its_next_key(self):
        # in tap mode a stop is one more press: it would start a new recording after an Esc
        self.assertEqual(self.press("%d:1:0.5" % HEADSET, "%d:0:0" % HEADSET, reader="headset"), ["toggle"])

    def test_the_stream_ends_while_talking(self):
        self.assertEqual(self.press("%d:1:0.5" % SIDE), ["start", "stop"])


class TestSources(ReaderTest):
    """Each device has its own reader; the end of one ends the others, and the reader starts over."""

    def run_reader(self, *cmds):
        env = dict(os.environ, HEADSET_CMD="\n".join(cmds), HEADSET_PTT=self.ptt, HEADSET_ONCE="1",
                   HEADSET_LONG="0.2", HEADSET_CACHE=self.tmp.name)
        start = time.monotonic()
        subprocess.run([sys.executable, "-I", HEADSET_READER], env=env, timeout=30, check=True)
        return time.monotonic() - start

    def event_cmd(self, *events):
        return " ".join([sys.executable, "-I", self.events] + list(events))

    def test_a_key_of_the_second_device(self):
        self.run_reader("sh -c 'echo $$; exec sleep 30'", self.event_cmd("%d:1:0.5" % HEADSET, "%d:0:0" % HEADSET))
        with open(self.log) as fh:
            self.assertEqual(fh.read().split(), ["toggle"])

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
        env = dict(os.environ, PATH=bindir + os.pathsep + os.environ["PATH"], HEADSET_PTT=self.ptt, HEADSET_ONCE="1",
                   HEADSET_CACHE=self.tmp.name)
        env.pop("HEADSET_CMD", None)
        subprocess.run([sys.executable, "-I", HEADSET_READER], env=env, timeout=30, check=True)
        with open(os.path.join(self.tmp.name, "headset-ptt.log")) as fh:
            self.assertIn("Headset-Suche fehlgeschlagen: su Exit 1", fh.read())

    def sources(self, reader, path):
        """What the reader reads (its commands), with su on PATH stubbed out."""
        return subprocess.run([sys.executable, "-I", "-c",
                               "import runpy; m = runpy.run_path(%r, run_name='x'); r = m[%r]();"
                               "print([r.command(d) for d in r.devices()])" % (reader, path)],
                              capture_output=True, text=True, check=True,
                              env=dict(os.environ, PATH=self.bindir + os.pathsep + os.environ["PATH"])).stdout.strip()

    def stub_su(self, output):
        self.bindir = os.path.join(self.tmp.name, "bin")
        os.makedirs(self.bindir, exist_ok=True)
        with open(os.path.join(self.bindir, "su"), "w") as fh:
            fh.write("#!/bin/sh\necho %s\n" % output)
        os.chmod(os.path.join(self.bindir, "su"), 0o755)

    def test_the_side_key_without_root_lookup(self):
        self.stub_su("/dev/input/event9")
        self.assertEqual(self.sources(SIDEKEY, "SideKey"), "[['su', '-c', 'echo $$; exec cat /dev/input/event2']]")

    def test_a_jack_on_event2_is_read(self):
        # another phone may have its headset buttons at event2
        self.stub_su("/dev/input/event2")
        self.assertEqual(self.sources(HEADSET_READER, "HeadsetKey"),
                         "[['su', '-c', 'echo $$; exec cat /dev/input/event2']]")

    def test_the_headset_is_looked_up_as_root(self):
        out = subprocess.run([sys.executable, "-I", "-c",
                              "import runpy; m = runpy.run_path(%r, run_name='x'); print(m['FIND_HEADSET'])" % HEADSET_READER],
                             capture_output=True, text=True, check=True).stdout
        self.assertIn('*"Button Jack"*) echo "/dev/input/${d##*/}"', out)


if __name__ == "__main__":
    unittest.main()
