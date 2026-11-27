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
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SIDEKEY = os.path.join(HERE, "..", "termux", "bin", "sidekey-ptt")
HEADSET_READER = os.path.join(HERE, "..", "termux", "bin", "headset-ptt")
KEYREADER = os.path.join(HERE, "..", "termux", "lib", "keyreader.py")
A9 = os.path.join(HERE, "..", "devices", "hisense-hlte556n.conf")
BOOX = os.path.join(HERE, "..", "devices", "onyx-maxlumi.conf")
READERS = {"side": (SIDEKEY, "SIDEKEY"), "headset": (HEADSET_READER, "HEADSET")}

# writes the events of argv ("code:value:pause", ...) as struct input_event, each followed by a SYN, then waits a bit;
# what the reader passes on (its stdin) goes to the file PASSED_LOG
EVENTS = r"""
import os, shutil, struct, sys, threading, time
def keep():
    with open(os.environ["PASSED_LOG"], "ab", buffering=0) as fh:
        shutil.copyfileobj(sys.stdin.buffer.raw, fh, 1)
threading.Thread(target=keep, daemon=True).start()
out = sys.stdout.buffer
out.write(b"%d\n" % os.getpid())   # like a root reader: its pid first
for item in sys.argv[1:]:
    code, value, pause = item.split(":")
    out.write(struct.pack("<qqHHi", 0, 0, 1, int(code), int(value)) + struct.pack("<qqHHi", 0, 0, 0, 0, 0))
    out.flush()
    time.sleep(float(pause))
time.sleep(0.2)
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
        self.passed = os.path.join(self.tmp.name, "passed")   # what a reader handed on to Android
        self.ptt = os.path.join(self.tmp.name, "ptt")
        with open(self.ptt, "w") as fh:
            fh.write("#!/bin/sh\necho \"$1\" >> %s\n" % self.log)
        os.chmod(self.ptt, 0o755)
        # the config the readers find device.conf next to (none written: the defaults of the Hisense A9)
        self.config = os.path.join(self.tmp.name, "config")

    def device(self, text):
        """Write device.conf next to the config."""
        with open(os.path.join(self.tmp.name, "device.conf"), "w") as fh:
            fh.write(text)


class TestKeys(ReaderTest):
    def press(self, *events, reader="side"):
        """The ptt calls of the reader for these events."""
        path, p = READERS[reader]
        cmd = " ".join([sys.executable, "-I", self.events] + list(events))
        env = dict(os.environ, **{p + "_CMD": cmd, p + "_PTT": self.ptt, p + "_ONCE": "1", p + "_LONG": "0.2",
                                  p + "_CACHE": self.tmp.name}, PASSED_LOG=self.passed, ROOTBRIDGE_CONFIG=self.config)
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

    def passed_on(self):
        try:
            with open(self.passed) as fh:
                return fh.read().splitlines()
        except FileNotFoundError:
            return []

    def test_a_short_press_of_the_headset_key_goes_to_android_as_one_click(self):
        self.press("%d:1:0.05" % HEADSET, "%d:0:0.1" % HEADSET, "%d:1:0.05" % HEADSET, "%d:0:0" % HEADSET,
                   reader="headset")
        self.assertEqual(self.passed_on(), ["226 1", "226 0", "226 1", "226 0"])

    def test_a_long_press_of_the_headset_key_stays_with_the_reader(self):
        # Android would send each repeat of the held key to the music app (pause, play, pause...)
        self.press("%d:1:0.5" % HEADSET, "%d:0:0" % HEADSET, reader="headset")
        self.assertEqual(self.passed_on(), [])

    def test_the_other_headset_keys_go_to_android_as_they_come(self):
        self.press("%d:1:0.5" % VOLUME, "%d:0:0" % VOLUME, reader="headset")
        self.assertEqual(self.passed_on(), ["115 1", "115 0"])

    def test_the_side_key_reader_passes_nothing_on(self):
        # its `cat` does not take the device: Android reads the keys itself
        self.press("%d:1:0.05" % SIDE, "%d:0:0" % SIDE, "%d:1:0.05" % VOLUME, "%d:0:0" % VOLUME)
        self.assertEqual(self.passed_on(), [])

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

    def test_the_key_code_of_the_device_file(self):
        self.device("SIDEKEY_DEVICE=/dev/input/event5\nSIDEKEY_CODE=%d\n" % VOLUME)
        self.assertEqual(self.press("%d:1:0.5" % SIDE, "%d:0:0.1" % SIDE, "%d:1:0.5" % VOLUME, "%d:0:0" % VOLUME),
                         ["start", "stop"])

    def test_a_short_press_of_the_headset_key_of_the_device_file_goes_to_android(self):
        self.device("HEADSET_DEVICE_NAME=Jack\nHEADSET_CODE=%d\n" % VOLUME)
        self.press("%d:1:0.05" % VOLUME, "%d:0:0" % VOLUME, reader="headset")
        self.assertEqual(self.passed_on(), ["%d 1" % VOLUME, "%d 0" % VOLUME])

    def woken(self, text):
        """The su calls of the side key reader for a long press with this device file."""
        bindir = os.path.join(self.tmp.name, "bin")
        os.makedirs(bindir, exist_ok=True)
        calls = os.path.join(self.tmp.name, "su.log")
        with open(os.path.join(bindir, "su"), "w") as fh:
            fh.write('#!/bin/sh\necho "$2" >> %s\n' % calls)
        os.chmod(os.path.join(bindir, "su"), 0o755)
        self.device(text)
        with mock.patch.dict(os.environ, PATH=bindir + os.pathsep + os.environ["PATH"]):
            self.assertEqual(self.press("158:1:0.5", "158:0:0"), ["start", "stop"])
        try:
            with open(calls) as fh:
                return fh.read().splitlines()
        except FileNotFoundError:
            return []

    def test_a_long_press_wakes_the_device_when_the_device_file_says_so(self):
        self.assertEqual(self.woken("SIDEKEY_CODE=158\nSIDEKEY_WAKE=yes\n"), ["input keyevent KEYCODE_WAKEUP"])

    def test_without_sidekey_wake_nothing_is_woken(self):
        self.assertEqual(self.woken("SIDEKEY_CODE=158\n"), [])

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
                   HEADSET_CACHE=self.tmp.name, ROOTBRIDGE_CONFIG=self.config)
        env.pop("HEADSET_CMD", None)
        subprocess.run([sys.executable, "-I", HEADSET_READER], env=env, timeout=30, check=True)
        with open(os.path.join(self.tmp.name, "headset-ptt.log")) as fh:
            self.assertIn("Suche nach 'Button Jack' fehlgeschlagen: su Exit 1", fh.read())

    def sources(self, reader, path):
        """What the reader reads (its commands, None when it knows no device), with su on PATH stubbed out."""
        return subprocess.run([sys.executable, "-I", "-c",
                               "import runpy; m = runpy.run_path(%r, run_name='x'); r = m[%r](); d = r.devices();"
                               "print(None if d is None else [r.command(x) for x in d])" % (reader, path)],
                              capture_output=True, text=True, check=True,
                              env=dict(os.environ, PATH=self.bindir + os.pathsep + os.environ["PATH"],
                                       ROOTBRIDGE_CONFIG=self.config, SIDEKEY_CACHE=self.tmp.name,
                                       HEADSET_CACHE=self.tmp.name)).stdout.strip()

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
                         "[['su', '-c', 'echo $$; exec %s -I %s --grab /dev/input/event2']]"
                         % (sys.executable, os.path.realpath(HEADSET_READER)))

    def test_the_headset_is_looked_up_as_root(self):
        out = subprocess.run([sys.executable, "-I", "-c",
                              "import runpy; m = runpy.run_path(%r, run_name='x'); print(m['find_command']('Button Jack'))"
                              % KEYREADER], capture_output=True, text=True, check=True).stdout
        self.assertIn("*'Button Jack'*) echo \"/dev/input/${d##*/}\"", out)

    def test_the_side_key_of_the_device_file(self):
        self.stub_su("/dev/input/event9")
        self.device("SIDEKEY_DEVICE=/dev/input/event5\nSIDEKEY_CODE=115\n")
        self.assertEqual(self.sources(SIDEKEY, "SideKey"), "[['su', '-c', 'echo $$; exec cat /dev/input/event5']]")

    def test_the_side_key_found_by_the_name_in_the_device_file(self):
        self.stub_su("/dev/input/event7")
        self.device("SIDEKEY_DEVICE_NAME=gpio-keys\n")
        self.assertEqual(self.sources(SIDEKEY, "SideKey"), "[['su', '-c', 'echo $$; exec cat /dev/input/event7']]")

    def test_a_key_the_device_file_does_not_describe_is_not_read(self):
        self.stub_su("/dev/input/event2")
        self.device("HEADSET_DEVICE_NAME=Button Jack\n")
        self.assertEqual(self.sources(SIDEKEY, "SideKey"), "None")

    def test_the_headset_key_of_the_device_file_is_passed_to_its_root_reader(self):
        self.stub_su("/dev/input/event3")
        self.device("HEADSET_DEVICE_NAME=Jack\nHEADSET_CODE=115\n")
        self.assertEqual(self.sources(HEADSET_READER, "HeadsetKey"),
                         "[['su', '-c', 'echo $$; exec %s -I %s --grab /dev/input/event3 115']]"
                         % (sys.executable, os.path.realpath(HEADSET_READER)))

    def test_the_a9_file_gives_the_defaults(self):
        # the device file of the Hisense A9 says what the readers do without one
        self.stub_su("/dev/input/event2")
        with open(A9) as src:
            self.device(src.read())
        self.assertEqual(self.sources(SIDEKEY, "SideKey"), "[['su', '-c', 'echo $$; exec cat /dev/input/event2']]")
        self.assertEqual(self.sources(HEADSET_READER, "HeadsetKey"),
                         "[['su', '-c', 'echo $$; exec %s -I %s --grab /dev/input/event2']]"
                         % (sys.executable, os.path.realpath(HEADSET_READER)))


class TestDeviceFile(unittest.TestCase):
    def check(self, text):
        with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as fh:
            fh.write(text)
        self.addCleanup(os.unlink, fh.name)
        r = subprocess.run([sys.executable, "-I", KEYREADER, "--check", fh.name], capture_output=True, text=True,
                           check=True)
        return r.stdout.splitlines(), r.stderr

    def test_the_a9_file_is_valid(self):
        with open(A9) as src:
            out, err = self.check(src.read())
        self.assertEqual(err, "")
        self.assertIn("SIDEKEY_CODE=766", out)
        self.assertIn("HEADSET_DEVICE_NAME=Button Jack", out)
        self.assertIn("LABEL=Hisense A9", out)

    def test_the_boox_file_is_valid(self):
        with open(BOOX) as src:
            out, err = self.check(src.read())
        self.assertEqual(err, "")
        self.assertIn("SIDEKEY_WAKE=yes", out)
        self.assertIn("HEADSET_CODE=164", out)

    def test_unknown_keys_and_values_that_do_not_fit_are_left_out(self):
        out, err = self.check("SIDEKEY_CODE=766\nSIDEKEY_DEVICE=/dev/input/../../etc/passwd\nEVIL=$(reboot)\n"
                              "HEADSET_DEVICE_NAME=a'b\nHOMEKEY_METHOD=assistant\n")
        self.assertEqual(out, ["SIDEKEY_CODE=766", "HOMEKEY_METHOD=assistant"])
        self.assertEqual(err.count("übergangen"), 3)


if __name__ == "__main__":
    unittest.main()
