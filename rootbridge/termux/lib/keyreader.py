"""keyreader - the part that sidekey-ptt and headset-ptt share: root readers of input devices, the long press, ptt.

Each device gets a root reader of its own, a `su -c 'echo $$; exec <reader> DEV'` (Magisk ends a `su -c` at once when its
shell starts readers in the background); the first line is the pid of the root reader. When one stream ends, the others
are ended (the root readers by that pid) and the reader starts over. One instance per reader (flock).

Which device and key a reader reads comes from the device file (devices/<id>.conf of the repository, installed by
install.sh as device.conf next to the rootbridge config): <P>_DEVICE or <P>_DEVICE_NAME, <P>_CODE and LONG_PRESS. Without
the file a reader takes its own defaults (those of the Hisense A9). `python3 -I keyreader.py --check FILE` prints the valid
lines of a device file and a note on stderr for each other one (install.sh installs that output).

Test hooks (environment, <P> is the prefix of the reader, SIDEKEY or HEADSET): <P>_CMD (event sources instead of su, one
command per line; each prints the pid of its reader on the first line, which is then ended without su), <P>_PTT (ptt
binary), <P>_LONG (seconds), <P>_ONCE=1 (leave at the end of the event stream), <P>_CACHE (log and lock directory);
ROOTBRIDGE_CONFIG (the config, device.conf is read next to it).
"""
import fcntl
import os
import re
import select
import shlex
import signal
import struct
import subprocess
import sys
import time

EVENT = struct.Struct("<qqHHi")                      # struct input_event on 64 bit: time (2 x 8), type, code, value
EV_KEY = 1
# a root reader that is still running (a case pattern): a `cat` of an input device, or a reader's own (`<script> --grab DEV`)
ROOT_READER = '"cat /dev/input/event"*|*" --grab /dev/input/event"*'

# the keys of a device file and the pattern each value has to match (devices/README.md)
_INPUT_DEVICE, _INPUT_NAME, _CODE = r"/dev/input/event[0-9]{1,3}", r"[A-Za-z0-9 ._-]{1,64}", r"[0-9]{1,4}"
DEVICE_KEYS = {
    "LABEL": r"[A-Za-z0-9 ._()+-]{1,64}",
    "NAME": r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}",
    "SIDEKEY_DEVICE": _INPUT_DEVICE, "SIDEKEY_DEVICE_NAME": _INPUT_NAME, "SIDEKEY_CODE": _CODE,
    "SIDEKEY_WAKE": r"yes|no",
    "HEADSET_DEVICE": _INPUT_DEVICE, "HEADSET_DEVICE_NAME": _INPUT_NAME, "HEADSET_CODE": _CODE,
    "HOMEKEY_METHOD": r"assistant|none",
    "LONG_PRESS": r"[0-9](\.[0-9]{1,2})?",
    "APP_FREEZE": r"boox|none",
}


def device_file():
    """The installed device file: device.conf next to the rootbridge config."""
    config = os.environ.get("ROOTBRIDGE_CONFIG") or os.path.join(os.path.expanduser("~"), ".config", "termux-rootbridge",
                                                                  "config")
    return os.path.join(os.path.dirname(config), "device.conf")


def read_device(path):
    """The valid KEY=VALUE lines of a device file as a dict, and a note for each other line (comments and empty lines
    aside). Raises OSError when the file cannot be read."""
    conf, notes = {}, []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for number, line in enumerate(fh, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key, eq, value = line.partition("=")
            key, value = key.strip(), value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            if eq and key in DEVICE_KEYS and re.fullmatch(DEVICE_KEYS[key], value):
                conf[key] = value
            else:
                notes.append("Zeile %d übergangen: %s" % (number, line[:80]))
    return conf, notes


def find_command(name):
    """Shell, run as root: the input devices whose name has NAME (event numbers depend on the kernel; apps may not read
    /sys/class/input). Exit 1 when the list cannot be read at all; a device that is not there finds nothing (exit 0)."""
    return ('ls /sys/class/input/event0 >/dev/null || exit 1; '
            'for d in /sys/class/input/event*; do case "$(cat "$d/device/name" 2>/dev/null)" in '
            '*%s*) echo "/dev/input/${d##*/}" ;; esac; done' % shlex.quote(name))


class Reader:
    """One key read from root readers. A script sets `name`, `prefix`, `key` and its default device (`device_path` or
    `device_name`, used without a device file) and overrides what it needs."""
    name = prefix = ""
    key = 0
    device_path = device_name = None

    def __init__(self):
        env = os.environ
        self.cache = env.get(self.prefix + "_CACHE", os.path.join(os.path.expanduser("~"), ".cache"))
        self.log_file = os.path.join(self.cache, self.name + ".log")
        self.ptt_bin = env.get(self.prefix + "_PTT", "ptt")
        try:
            self.device, _ = read_device(device_file())
        except OSError:
            self.device = None       # no device file: the defaults of the script
        conf = self.device or {}
        if conf.get(self.prefix + "_DEVICE") or conf.get(self.prefix + "_DEVICE_NAME"):
            self.device_path = conf.get(self.prefix + "_DEVICE")
            self.device_name = None if self.device_path else conf[self.prefix + "_DEVICE_NAME"]
        elif self.device is not None:
            self.device_path = self.device_name = None   # the device file knows no such key on this device
        self.key = int(conf.get(self.prefix + "_CODE", self.key))
        # Android's long press timeout (long_press_timeout 400)
        self.long = float(env.get(self.prefix + "_LONG", conf.get("LONG_PRESS", "0.4")))
        self.test_cmds = [shlex.split(line) for line in env.get(self.prefix + "_CMD", "").splitlines() if line.strip()]
        self.once = env.get(self.prefix + "_ONCE") == "1"
        self.procs = []

    # --- what a script overrides
    def devices(self):
        """The devices to read; None when they cannot be known now (the reader starts over)."""
        if self.device_path:
            return [self.device_path]
        if self.device_name:
            return self.lookup(self.device_name)
        self.log("%s beschreibt diese Taste nicht" % device_file())
        return None

    def lookup(self, name):
        """The input devices whose name has NAME, looked up as root; None when there is none or the lookup failed."""
        try:
            r = subprocess.run(["su", "-c", find_command(name)], stdin=subprocess.DEVNULL, capture_output=True,
                               text=True, timeout=20)
        except (OSError, subprocess.TimeoutExpired) as e:
            self.log("Suche nach %r fehlgeschlagen: %s" % (name, e))
            return None
        if r.returncode != 0:
            self.log("Suche nach %r fehlgeschlagen: su Exit %d" % (name, r.returncode))
            return None
        devices = [d for d in r.stdout.split() if d.startswith("/dev/input/event")]
        if not devices:
            self.log("kein Eingabegerät %r gefunden" % name)
            return None
        return devices

    def command(self, dev):
        """The root reader of one device: it prints its pid on the first line, then the events of the device."""
        return ["su", "-c", "echo $$; exec cat " + dev]

    def on_long(self, proc):
        """The key is held for `long` seconds."""

    def on_release(self, proc, was_long):
        """The key is released."""

    def on_other(self, proc, code, value):
        """Another key of a device that is read."""

    def on_end(self):
        """The event streams ended."""

    # --- shared
    def log(self, msg):
        try:
            if os.path.exists(self.log_file) and os.path.getsize(self.log_file) > 200_000:
                os.replace(self.log_file, self.log_file + ".1")
            with open(self.log_file, "a") as f:
                f.write("%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
        except OSError:
            pass

    def ptt(self, action):
        try:
            r = subprocess.run([self.ptt_bin, action], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=5)
            if r.returncode != 0:
                self.log("ptt %s: Exit %d" % (action, r.returncode))
        except (OSError, subprocess.TimeoutExpired) as e:
            self.log("ptt %s: %s" % (action, e))

    def shutdown(self, signum, _frame):
        self.log("beendet (Signal %d)" % signum)
        self.on_end()
        self.stop_all([])
        sys.exit(0)

    def stop_all(self, readers):
        """End the su clients and their root readers (by the pids they printed first)."""
        for p in self.procs:
            try:
                p.kill()
                p.wait(timeout=2)
            except (OSError, subprocess.TimeoutExpired):
                pass
        self.procs.clear()
        if not readers:
            return
        if self.test_cmds:
            for pid in readers:
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass
            return
        # kills only a pid that is still a root reader of an input device (a reader that already ended may have passed
        # its pid on), and prints each one that is still there after its kill
        script = ('for p in %s; do case "$(tr "\\0" " " < /proc/$p/cmdline 2>/dev/null)" in '
                  '%s) kill $p 2>/dev/null || [ ! -d /proc/$p ] || echo $p ;; esac; done'
                  % (" ".join(map(str, readers)), ROOT_READER))
        try:
            r = subprocess.run(["su", "-c", script], stdin=subprocess.DEVNULL, capture_output=True, text=True,
                               timeout=20)
        except (OSError, subprocess.TimeoutExpired) as e:
            self.log("Root-Leser %s nicht beendet: %s" % (readers, e))
            return
        if r.returncode != 0 or r.stdout.strip():
            self.log("Root-Leser nicht beendet: %s (su Exit %d)" % (r.stdout.split() or readers, r.returncode))

    def run_once(self):
        """Read the event streams until one of them ends; returns how many seconds that lasted."""
        t_start = time.monotonic()
        if self.test_cmds:
            cmds = self.test_cmds
        else:
            devices = self.devices()
            if devices is None:
                return 0.0
            cmds = [self.command(d) for d in devices]
        # stdin: what a root reader of its own is to pass on (`cat` ignores it); stderr: its messages go to the log
        with open(self.log_file, "a") as log_fh:
            for cmd in cmds:
                self.procs.append(subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=log_fh, stdin=subprocess.PIPE))
        self.log("liest: %s" % ", ".join(cmd[-1] for cmd in cmds))
        procs = {p.stdout.fileno(): p for p in self.procs}
        bufs = {fd: b"" for fd in procs}
        readers = {}                     # fd: the pid of its root reader, from the first line
        down = None                      # monotonic time of the press that is still held
        long_done = False                # its long press was taken
        while True:
            wait = None
            if down is not None and not long_done:
                wait = max(0.0, down[0] + self.long - time.monotonic())
            ready, _, _ = select.select(list(bufs), [], [], wait)
            if down is not None and not long_done and time.monotonic() >= down[0] + self.long:
                long_done = True
                self.on_long(down[1])
            ended = False
            for fd in ready:
                chunk = os.read(fd, 4096)
                if not chunk:
                    ended = True
                    break
                buf = bufs[fd] + chunk
                if fd not in readers:
                    line, newline, rest = buf.partition(b"\n")
                    if not newline:
                        bufs[fd] = buf
                        continue
                    readers[fd] = int(line) if line.strip().isdigit() else 0
                    buf = rest
                while len(buf) >= EVENT.size:
                    _, _, etype, code, value = EVENT.unpack(buf[:EVENT.size])
                    buf = buf[EVENT.size:]
                    if etype != EV_KEY:
                        continue
                    if code != self.key:
                        self.on_other(procs[fd], code, value)
                    elif value == 1 and down is None:
                        down = (time.monotonic(), procs[fd])
                    elif value == 0 and down is not None and down[1] is procs[fd]:
                        self.on_release(procs[fd], long_done)
                        down, long_done = None, False
                bufs[fd] = buf
            if ended:
                break
        self.on_end()
        # the pids of readers whose first line was not read yet (another stream ended first)
        for fd in set(bufs) - set(readers):
            buf = bufs[fd]
            while b"\n" not in buf and select.select([fd], [], [], 1)[0]:
                chunk = os.read(fd, 4096)
                if not chunk:
                    break
                buf += chunk
            line = buf.partition(b"\n")[0]
            readers[fd] = int(line) if b"\n" in buf and line.strip().isdigit() else 0
        self.stop_all([pid for pid in readers.values() if pid > 1])
        return time.monotonic() - t_start

    def main(self):
        os.makedirs(self.cache, exist_ok=True)
        lock = open(os.path.join(self.cache, self.name + ".lock"), "w")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("%s laeuft schon" % self.name, file=sys.stderr)
            return 0
        signal.signal(signal.SIGTERM, self.shutdown)
        signal.signal(signal.SIGINT, self.shutdown)
        self.log("gestartet")
        delay = 2
        while True:
            lasted = self.run_once()
            if self.once:
                return 0
            self.log("Ereignisstrom endete nach %.0f s (su verweigert, oder Leser beendet), neuer Versuch in %d s"
                     % (lasted, delay))
            time.sleep(delay)
            delay = 2 if lasted > 10 else min(60, delay * 2)


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] != "--check":
        sys.exit("keyreader.py --check FILE")
    try:
        valid, skipped = read_device(sys.argv[2])
    except OSError as e:
        sys.exit("%s: %s" % (sys.argv[2], e))
    for note in skipped:
        print("%s: %s" % (sys.argv[2], note), file=sys.stderr)
    for key, value in valid.items():
        print("%s=%s" % (key, value))
