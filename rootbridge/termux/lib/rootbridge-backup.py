#!/usr/bin/env python3
"""rootbridge-backup - back up and restore the settings and secrets of the installation (rootbridge backup | restore).

  rootbridge-backup.py backup  [DIR]          settings and secrets of Termux and the guest into DIR
  rootbridge-backup.py restore [DIR] [--yes] [--no-device]  back from DIR: checks it, shows what goes where, asks what
                                              of it, then copies (--no-device: without the device configuration)
  rootbridge-backup.py restore [DIR] --legacy a backup of the earlier backup script (it has no seal)
  (DIR: default /sdcard/backup/termux)

DIR holds a.tgz (settings), k.enc (secrets: a tar.gz encrypted by openssl with your password, aes-256-cbc, pbkdf2,
200000 rounds), h (their SHA-256 checksums, as sha256sum writes them) and m (a seal: HMAC-SHA256 over both checksums,
with a key derived from your password, pbkdf2 200000 rounds; its salt next to it). In both archives t/ is the Termux home
and g/ the root of the guest. The previous backup stays in DIR/previous until the new one is complete.

DIR lies in Android's shared storage, where other apps can write, so restore runs nothing from it and treats it as data:
- It reads each file once into memory and checks and restores exactly those bytes.
- It checks the checksums (a damaged backup is refused) and the seal with your password, before anything is copied: only
  who knows the password can have made the backup. A seal that is missing, empty or unreadable is refused; a backup of the
  earlier backup script (it has none) is restored only with --legacy and after you typed "ja".
- Lines "exclude" of the lists hold for restore too: what they name does not come back.
- It shows what goes where, numbered, and asks what of it comes back: the device configuration (the device file, the
  Termux keys row, and in the config the device, its keys, the phantom process killer and the Remote Control name: on
  another device you want the logins, not these), and single numbers to leave out. --yes: without asking (the tests);
  --no-device: without the device configuration.
- It unpacks with tarfile's "data" filter (no absolute paths, no "..", no links that point out, no device files) into a
  private temporary folder and copies into the Termux home and the guest only, never through a link on the way there.
A backup also leaves its checksums in backup.sha256 next to the config, where only Termux reads: restore names it when the
backup is the one you made last.

Links are not followed: backup names and skips them. What is saved: the list backup.list next to this file (rootbridge, git, Claude Code, Codex; it must be there), and your
own lines in backup.list next to the config. A line: "settings|secret termux|guest PATH" (PATH relative to the Termux home
or the root of the guest; * ? [] as in the shell), or "exclude termux|guest PATH". # starts a comment. What a secret line
names never goes into the settings, also when a settings line names a folder around it.

Environment: ROOTBRIDGE_CONFIG (the config; the private files next to it), RB_GUEST_ROOT (the root of the guest; else
found under $PREFIX/var/lib/proot-distro like the installer), BKPW (the password; the tests), HOME, PREFIX.
"""
import getpass
import hashlib
import hmac
import errno
import fcntl
import io
import os
import re
import shutil
import subprocess
import termios
import sys
import tarfile
import fnmatch
import tempfile
import time

HERE = os.path.dirname(os.path.realpath(__file__))
HOME = os.environ.get("HOME", "/data/data/com.termux/files/home")
PREFIX = os.environ.get("PREFIX", "/data/data/com.termux/files/usr")
CONFIG = os.environ.get("ROOTBRIDGE_CONFIG", os.path.join(HOME, ".config/termux-rootbridge/config"))
# Everything private lives in the Termux home, whatever ROOTBRIDGE_CONFIG says (the config itself may sit elsewhere, even on
# shared storage): the own list that decides what goes into the plain archive, the lock, the checksums of the last backup.
PRIVATE = os.path.join(HOME, ".config", "termux-rootbridge")
OWN_LIST = os.path.join(PRIVATE, "backup.list")
BASE_LIST = os.path.join(HERE, "backup.list")
TRUSTED = os.path.join(PRIVATE, "backup.sha256")   # the checksums of the last backup, where only Termux can read
DEFAULT_DIR = "/sdcard/backup/termux"
FILES = ("a.tgz", "k.enc")
ALL = FILES + ("h", "m")
ROUNDS = 200000
SUFFIX = ".rootbridge-%d" % os.getpid()
# The guest user's home as the guest installer has it (ROOTBRIDGE_GUEST_HOME, default /root), relative to the guest root.
# The lists say root/...; for a guest with another home that prefix becomes this one. A backup records the home it was made
# from (GUEST_HOME_ARC) and restore refuses another one: its files lie under other paths there.
GUEST_HOME_REL = os.environ.get("ROOTBRIDGE_GUEST_HOME", "/root").strip("/")
if not GUEST_HOME_REL or ".." in GUEST_HOME_REL.split("/") or "." in GUEST_HOME_REL.split("/"):
    print("rootbridge: ROOTBRIDGE_GUEST_HOME ist kein gültiger Pfad", file=sys.stderr)
    sys.exit(1)
OWN_TEXT = None   # the own list as read once (backup archives exactly these bytes)
CONFIG_TOKEN = "@config"   # in the lists: the active Termux config, wherever ROOTBRIDGE_CONFIG puts it
CONFIG_ARC = ".config/termux-rootbridge/config"   # its stable name in the archives
OWN_LIST_ARC = "t/.rootbridge-own-list"   # your own list, carried in k.enc so that a restore on a new installation knows it
OPENSSL = ["openssl", "enc", "-aes-256-cbc", "-pbkdf2", "-iter", str(ROUNDS), "-pass", "env:RB_BACKUP_PW"]


def say(text=""):
    print(text, flush=True)


def die(text):
    print("rootbridge: " + text, file=sys.stderr, flush=True)
    sys.exit(1)


def guest_root():
    """The root of the guest (the distro of the config, as install.sh finds it), or None when there is none yet."""
    if os.environ.get("RB_GUEST_ROOT"):
        return os.environ["RB_GUEST_ROOT"] if os.path.isdir(os.environ["RB_GUEST_ROOT"]) else None
    distro = "ubuntu"
    try:
        with open(CONFIG, encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("DISTRO="):
                    distro = line.split("=", 1)[1].strip().strip("\"'") or distro
    except OSError:
        pass
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", distro) or distro.endswith(".."):
        die("DISTRO=%s in der Konfig ist kein gültiger Name" % distro)
    base = os.path.realpath(os.path.join(PREFIX, "var/lib/proot-distro"))
    for root in (os.path.join(PREFIX, "var/lib/proot-distro/containers", distro, "rootfs"),
                 os.path.join(PREFIX, "var/lib/proot-distro/installed-rootfs", distro)):
        if os.path.isdir(root):   # the rootfs is the guest; a missing home is made when files come back
            if not os.path.realpath(root).startswith(base + os.sep):   # a link out of proot-distro's folder
                die("%s liegt nicht unter %s" % (root, base))
            return root
    return None


def stage_dir():
    """~/.cache/rootbridge-backup, checked: a real folder (no link) of ours that nobody else can enter."""
    path = HOME
    for part in (".cache", "rootbridge-backup"):
        path = os.path.join(path, part)
        try:
            os.mkdir(path, 0o700)
        except FileExistsError:
            pass
        st = os.lstat(path)   # every component: a link (~/.cache pointing to shared storage) is refused
        if not os.path.stat.S_ISDIR(st.st_mode) or st.st_uid != os.geteuid():
            die("%s ist kein eigener Ordner (Link oder fremd); nichts wiederhergestellt" % path)
    os.chmod(path, 0o700)
    return path


def check_private():
    """PRIVATE (~/.config/termux-rootbridge) exists, and every component below the Termux home is a real folder of ours:
    a link (~/.config pointing to shared storage) would let other apps change the lists, the lock and the checksums."""
    path = HOME
    for part in os.path.relpath(PRIVATE, HOME).split(os.sep):
        path = os.path.join(path, part)
        try:
            os.mkdir(path, 0o700)
        except FileExistsError:
            pass
        st = os.lstat(path)
        if not os.path.stat.S_ISDIR(st.st_mode) or st.st_uid != os.geteuid():
            die("%s ist kein eigener Ordner (Link oder fremd)" % path)


def take_lock():
    """One backup or restore at a time (they share rotation, staging and the files they replace). The lock lives as long
    as the returned file is open (until the process ends)."""
    check_private()
    # no truncating, no following a link that someone put in place of the lock file
    fd = os.open(os.path.join(PRIVATE, "backup.lock"), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    lock = os.fdopen(fd, "r+")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        die("eine andere Sicherung oder Wiederherstellung läuft gerade; danach nochmal")
    return lock


def config_value(key, path=None):
    """The line KEY=... of the Termux config (or of the file path), or None."""
    try:
        with open(path or CONFIG, encoding="utf-8") as fh:
            lines = [l.rstrip("\n") for l in fh if l.startswith(key + "=")]
    except OSError:
        return None
    return lines[-1] if lines else None


def pin_line(path, key, line):
    """In the staged file path (our own copy, before it is installed) put this installation's KEY=... line (or drop the
    backup's one when there was none), so that the restored config still names the guest that receives the files."""
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    rest = [l for l in lines if not l.startswith(key + "=")]
    if line is not None:
        rest.append(line)
    if rest != lines:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(rest) + "\n")


def expand(root, pattern):
    """The existing paths of pattern below root, matched part by part with fnmatch (hidden files too, exactly as the
    filters for secret and exclude lines match them: both passes must see the same files)."""
    paths = [root]
    for part in pattern.split("/"):
        nxt = []
        for base in paths:
            if not any(c in part for c in "*?["):
                nxt.append(os.path.join(base, part))
                continue
            try:
                names = sorted(os.listdir(base))
            except (FileNotFoundError, NotADirectoryError):
                continue   # not there: nothing to save
            except OSError as e:   # there, but not readable: a backup without it would be wrong, so it stops
                die("%s nicht lesbar (%s); keine Sicherung gemacht" % (base, e.strerror))
            nxt += [os.path.join(base, n) for n in names if fnmatch.fnmatchcase(n, part)]
        paths = nxt
    found = []
    for p in paths:
        try:
            os.lstat(p)
        except (FileNotFoundError, NotADirectoryError):
            continue   # genuinely not there
        except OSError as e:   # there, but a folder on the way cannot be read: a backup without it would be wrong
            die("%s nicht lesbar (%s); keine Sicherung gemacht" % (p, e.strerror))
        found.append(p)
    return sorted(found)


def parse_list(text, label, remap=False):
    """The lines of a list: (kind, side, pattern). remap: the built-in list says root/... for the guest's home; with another
    home (ROOTBRIDGE_GUEST_HOME) that prefix becomes the real one. Your own list is never remapped: a path in it is literal."""
    entries = []
    for number, line in enumerate(text.splitlines(), 1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split(None, 2)
        if len(parts) == 3:   # one spelling for backup and restore: "root/.ssh/" and "root/./.ssh" are root/.ssh
            parts[2] = "/".join(p for p in parts[2].split("/") if p not in ("", "."))
        if (len(parts) != 3 or not parts[2] or parts[0] not in ("settings", "secret", "exclude")
                or parts[1] not in ("termux", "guest") or parts[2].startswith("/") or ".." in parts[2].split("/")):
            die("%s, Zeile %d: unverständlich: %s" % (label, number, line))
        if remap and parts[1] == "guest" and (parts[2] == "root" or parts[2].startswith("root/")):
            parts[2] = GUEST_HOME_REL + parts[2][4:]   # root/.claude -> <the guest's home>/.claude
        entries.append(tuple(parts))
    return entries


def read_lists():
    """The lines of both lists. The base list must be there, your own is optional."""
    global OWN_TEXT
    check_private()   # the own list is read from there: not through a link
    entries = []
    for path, required in ((BASE_LIST, True), (OWN_LIST, False)):
        try:
            # opened without following a link and read once: what is parsed is what is archived (OWN_TEXT)
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, "r", encoding="utf-8") as fh:
                text = fh.read()
            entries += parse_list(text, path, remap=(path == BASE_LIST))
            if path == OWN_LIST:
                OWN_TEXT = text
        except FileNotFoundError:
            if required:
                die("die Liste %s fehlt (bash install.sh)" % path)
        except OSError as e:
            if e.errno == errno.ELOOP:
                die("%s ist ein Link; die Liste wird nicht durch einen Link hindurch gelesen" % path)
            die("%s nicht lesbar (%s)" % (path, e.strerror))
    return entries


def merged_own_list(saved):
    """The own list as it must be after the restore: the backup's list when this installation has none, else the local
    one plus the lines of the backup's list it lacks (a secret line of the backup must hold for the files it restores).
    None when nothing changes. The caller installs it together with the restored files, in one transaction."""
    if os.path.islink(OWN_LIST):
        die("%s ist ein Link; die Liste der Sicherung wird nicht durch einen Link hindurch gespeichert" % OWN_LIST)
    try:
        with open(OWN_LIST, encoding="utf-8") as fh:
            local = fh.read()
    except FileNotFoundError:
        local = None
    wanted = parse_list(saved, "die Liste in der Sicherung")
    if local is None:
        return "".join("%s %s %s\n" % e for e in wanted) or None
    have = set(parse_list(local, OWN_LIST))
    missing = [e for e in wanted if e not in have]
    if not missing:
        return None
    return local + ("" if local.endswith("\n") or not local else "\n") + "".join("%s %s %s\n" % e for e in missing)


GUEST_HOME_ARC = "t/.rootbridge-guest-home"   # the guest home of the backup's guest, in k.enc


def home_rel_of(secrets):
    """The guest home the backup was made from (member GUEST_HOME_ARC of k.enc), as a relative path, or None."""
    try:
        with tarfile.open(fileobj=io.BytesIO(secrets), mode="r:gz") as tar:
            info = tar.getmember(GUEST_HOME_ARC)
            text = tar.extractfile(info).read(512).decode("utf-8").strip().strip("/") if info.isfile() else ""
    except (KeyError, tarfile.TarError, OSError, EOFError, UnicodeDecodeError):
        return None
    parts = text.split("/")
    return text if text and not any(p in ("", ".", "..") for p in parts) else None


def own_list_of(secrets):
    """The own list a backup carries (member OWN_LIST_ARC of k.enc), as text, or None."""
    try:
        with tarfile.open(fileobj=io.BytesIO(secrets), mode="r:gz") as tar:
            try:
                info = tar.getmember(OWN_LIST_ARC)
            except KeyError:
                return None
            if not info.isfile() or info.size > 1 << 20:
                return None
            return tar.extractfile(info).read().decode("utf-8")
    except (tarfile.TarError, OSError, EOFError, UnicodeDecodeError):
        return None




NOFOLLOW_DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def open_dir(root, parts, create=False):
    """A descriptor of root/parts, opened part by part with O_NOFOLLOW relative to the one before: a link anywhere on the
    way fails (OSError), also one swapped in while we run. create: missing folders are made (0700)."""
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in parts:
            if create:
                try:
                    os.mkdir(part, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
            nxt = os.open(part, NOFOLLOW_DIR, dir_fd=fd)
            os.close(fd)
            fd = nxt
    except OSError:
        os.close(fd)
        raise
    return fd


def pack(entries, kind, roots):
    """A tar.gz (bytes) of the paths of this kind (t/ Termux home, g/ guest). Left out: what is excluded, for the
    settings everything a secret line names, and every link (named, not followed: a running guest cannot point us at a
    Termux file). Every file is opened through descriptors with O_NOFOLLOW from its root down."""
    prefixes = {"termux": "t", "guest": "g"}
    # Decided for each path when it is reached, by the lines' patterns, not from a list made at the start: a file that
    # appears while we run (a login) is still kept out of the settings if a secret line names it.
    # (@config stands for the path of the active config, so that a settings line naming it cannot let it into a.tgz)
    config_rel = os.path.relpath(CONFIG, roots["termux"]) if roots.get("termux") else CONFIG_ARC
    skipping = [(side, (config_rel if pattern == CONFIG_TOKEN else pattern).split("/")) for k, side, pattern in entries
                if k == "exclude" or (k == "secret" and kind == "settings")]
    # the installer's own copies of a secret file (settings.json.bak-DATE) hold the old secrets: they stay out as well
    # (also the half-written NAME.new.PID of an installer run that was interrupted)
    skipping += [(side, parts[:-1] + [parts[-1] + suffix]) for side, parts in skipping[:]
                 if not parts[-1].endswith("*") for suffix in (".bak*", ".new*")]

    real_config = os.path.realpath(CONFIG)

    def keep(path, side, active=False):
        names = os.path.relpath(path, roots[side]).split(os.sep)
        if any(".rootbridge-" in n for n in names):   # what an interrupted restore left beside a target (a plain copy)
            return False
        if side == "termux" and os.path.abspath(path) == os.path.abspath(OWN_LIST):   # carried on its own, in k.enc
            return False
        if kind == "settings" and os.path.realpath(path) == real_config and not active:
            return False   # the config behind a link too: it belongs in k.enc only
        stage = os.path.join(os.path.abspath(HOME), ".cache", "rootbridge-backup")   # decrypted files of a restore
        if os.path.abspath(path) == stage or os.path.abspath(path).startswith(stage + os.sep):
            return False
        return not any(w == side and len(names) >= len(parts) and all(fnmatch.fnmatchcase(a, b) for a, b in zip(names, parts))
                       for w, parts in skipping)

    def add(tar, dfd, name, path, arc, side, active=False):   # (arc is recomputed from the path: always the stable name)
        """Adds name in the folder dfd (path, arc: its path on disk and in the archive), a folder with its content."""
        if not keep(path, side, active):
            return
        if arc == "t/" + CONFIG_ARC and not active:   # that name is reserved for the active config, kept in k.enc
            return
        try:
            st = os.stat(name, dir_fd=dfd, follow_symlinks=False)
            if os.path.stat.S_ISDIR(st.st_mode):
                fd = os.open(name, NOFOLLOW_DIR, dir_fd=dfd)
            elif os.path.stat.S_ISREG(st.st_mode):
                fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dfd)
            else:
                say("  übersprungen (Link oder Sonderdatei): %s" % path)
                return
        except FileNotFoundError:
            return   # gone meanwhile
        except OSError as e:   # there, selected, but not readable: a backup without it would be wrong
            die("%s nicht lesbar (%s); keine Sicherung gemacht" % (path, e.strerror))
        try:
            st = os.fstat(fd)
            info = tarfile.TarInfo(arc)
            info.mode, info.mtime = st.st_mode & 0o7777, int(st.st_mtime)
            if os.path.stat.S_ISDIR(st.st_mode):
                info.type = tarfile.DIRTYPE
                tar.addfile(info)
                for child in sorted(os.listdir(fd)):
                    child_path = os.path.join(path, child)
                    add(tar, fd, child, child_path, arc_name(side, os.path.relpath(child_path, roots[side]).split(os.sep))
                        if side == "guest" else arc + "/" + child, side)
            else:
                info.size = st.st_size
                with os.fdopen(os.dup(fd), "rb") as fh:
                    data = fh.read()
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
        finally:
            os.close(fd)

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for k, side, pattern in entries:
            if k != kind:
                continue
            if not roots.get(side):
                say("  übersprungen (kein Gast): %s" % pattern)
                continue
            root = roots[side]
            if pattern == CONFIG_TOKEN:   # the active config (ROOTBRIDGE_CONFIG), kept under its stable name
                inside = os.path.realpath(CONFIG).startswith(os.path.realpath(root) + os.sep)
                if not inside:
                    say("  übersprungen (die Konfig liegt außerhalb von %s): %s" % (root, CONFIG))
                found = [CONFIG] if inside else []
            else:
                found = expand(root, pattern)
            if not found and pattern != CONFIG_TOKEN:
                say("  fehlt, übersprungen: %s" % pattern)
            for path in found:
                parts = os.path.relpath(path, root).split(os.sep)
                arc_parts = CONFIG_ARC.split("/") if pattern == CONFIG_TOKEN else parts
                try:
                    dfd = open_dir(root, parts[:-1])
                except (FileNotFoundError, NotADirectoryError):
                    continue
                except OSError as e:
                    if e.errno == errno.ELOOP:   # a link on the way: never followed
                        say("  übersprungen (Link auf dem Weg): %s" % path)
                        continue
                    die("%s nicht lesbar (%s); keine Sicherung gemacht" % (path, e.strerror))
                try:
                    add(tar, dfd, parts[-1], os.path.normpath(path), arc_name(side, arc_parts), side,
                        pattern == CONFIG_TOKEN)
                finally:
                    os.close(dfd)
        if kind == "secret":
            info = tarfile.TarInfo(GUEST_HOME_ARC)
            info.size, info.mode = len(GUEST_HOME_REL.encode()), 0o600
            tar.addfile(info, io.BytesIO(GUEST_HOME_REL.encode()))
            content = OWN_TEXT.encode() if OWN_TEXT else None   # read once, with the lists
            if content:
                info = tarfile.TarInfo(OWN_LIST_ARC)
                info.size, info.mode = len(content), 0o600
                tar.addfile(info, io.BytesIO(content))
    return buf.getvalue()


def ask_password(prompt):
    # a key pressed while the installer was busy (Enter during a long download) waits in the terminal: not the answer
    try:
        with open("/dev/tty") as tty:
            termios.tcflush(tty, termios.TCIFLUSH)
    except (OSError, termios.error):
        pass
    return getpass.getpass(prompt)


def password(twice):
    if os.environ.get("BKPW"):
        return os.environ["BKPW"]
    for _ in range(3):
        first = ask_password("Passwort der Sicherung: ")
        if first:
            break
        say("  leer; bitte das Passwort eingeben")
    else:
        die("ohne Passwort keine Sicherung")
    if twice and ask_password("Noch einmal: ") != first:
        die("die beiden Passwörter sind verschieden")
    return first


def seal(pw, salt, digests):
    key = hashlib.pbkdf2_hmac("sha256", pw.encode(), salt, ROUNDS)
    return hmac.new(key, "".join(digests).encode(), hashlib.sha256).hexdigest()


def openssl(args, data, pw):
    if not shutil.which("openssl"):
        die("openssl fehlt (pkg install openssl-tool)")
    r = subprocess.run(OPENSSL + args, input=data, capture_output=True, env=dict(os.environ, RB_BACKUP_PW=pw))
    return r.stdout if r.returncode == 0 else None


def write_synced(path, data):
    with open(path, "wb") as fh:
        fh.write(data)
        fh.flush()
        os.fsync(fh.fileno())


NOFOLLOW_FILE = os.O_RDONLY | os.O_NOFOLLOW


def read_in(dfd, name):
    """The bytes of the file name in the folder dfd (opened without following a link), or None when it is not there. Any
    other error (a link, no right) is raised."""
    try:
        fd = os.open(name, NOFOLLOW_FILE, dir_fd=dfd)
    except FileNotFoundError:
        return None
    with os.fdopen(fd, "rb") as fh:
        return fh.read()


def put(dfd, name, data):
    """Makes the new file name in the folder dfd (exclusively, without following a link), written and synced."""
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
    with os.fdopen(fd, "wb") as fh:
        fh.write(data)
        fh.flush()
        os.fsync(fh.fileno())


def write_synced(path, data):
    with open(path, "wb") as fh:
        fh.write(data)
        fh.flush()
        os.fsync(fh.fileno())


def complete_fd(dfd, pw):
    """True when the backup in the folder dfd is whole and restorable with this password: its checksums in h match a.tgz
    and k.enc, and its seal m matches them. Everything is read through the descriptor."""
    try:
        h, m = read_in(dfd, "h"), read_in(dfd, "m")
        if h is None or m is None:
            return False
        expected = {p[1]: p[0] for p in (line.split() for line in h.decode("utf-8", "replace").splitlines())
                    if len(p) == 2}
        digests = []
        for name in FILES:
            content = read_in(dfd, name)
            if content is None:
                return False
            digests.append(hashlib.sha256(content).hexdigest())
            if digests[-1] != expected.get(name):
                return False
        salt_hex, mac = m.decode().split()
        return hmac.compare_digest(seal(pw, bytes.fromhex(salt_hex), digests), mac)
    except (OSError, ValueError):
        return False


def copy_nofollow(sfd, dfd, names):
    """Copies the files names from the folder sfd into the new folder dfd without following links: a source that is a link
    (in a shared folder anyone can put one) or unreadable stops the backup before anything is replaced, a missing one is
    skipped, the targets are made new (O_EXCL), synced."""
    for name in names:
        content = read_in(sfd, name)   # a missing optional file (m of the earlier script) is skipped, any other error stops
        if content is not None:
            put(dfd, name, content)


def own_backup_dir(ffd, name):
    """name below the folder descriptor ffd is a real folder (no link) holding nothing but the backup's own files."""
    try:
        pfd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=ffd)
    except OSError:
        return False
    try:
        return set(os.listdir(pfd)) <= set(ALL)
    finally:
        os.close(pfd)


def remove_backup_dir(ffd, name):
    """Removes the backup folder name below ffd, through descriptors without following links, only its own file names."""
    pfd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=ffd)
    try:
        for entry in os.listdir(pfd):
            if entry not in ALL:
                raise OSError("%s enthält Fremdes: %s" % (name, entry))
            os.unlink(entry, dir_fd=pfd)
    finally:
        os.close(pfd)
    os.rmdir(name, dir_fd=ffd)


def new_dir(ffd, prefix):
    """A new, private folder below ffd (made exclusively); returns its name and an descriptor opened without following."""
    name = "%s%d-%s" % (prefix, os.getpid(), os.urandom(4).hex())
    os.mkdir(name, 0o700, dir_fd=ffd)
    return name, os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=ffd)


def restore_live_from(ffd, source_name):
    """Puts the files of the folder source_name (the prior generation) back as the live files, through copies made beside
    them and renamed over them: the source stays whole until the very end."""
    sfd = os.open(source_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=ffd)
    try:
        for name in ALL:
            content = read_in(sfd, name)
            if content is None:
                continue
            tmp = ".rb-%d-%s" % (os.getpid(), name)
            put(ffd, tmp, content)
            os.replace(tmp, name, src_dir_fd=ffd, dst_dir_fd=ffd)
    finally:
        os.close(sfd)


def backup(folder):
    lock = take_lock()   # first: a restore must not change the files while they are read   # noqa: F841
    roots = {"termux": HOME, "guest": guest_root()}
    entries = read_lists()
    say("Einstellungen:")
    settings = pack(entries, "settings", roots)
    say("Geheimnisse:")
    secrets = pack(entries, "secret", roots)
    pw = password(True)
    encrypted = openssl(["-salt"], secrets, pw)
    if not encrypted:
        die("Verschlüsseln fehlgeschlagen")
    data = {"a.tgz": settings, "k.enc": encrypted}
    digests = [hashlib.sha256(data[f]).hexdigest() for f in FILES]   # from the bytes made here, not read back
    sums = "".join("%s  %s\n" % (d, f) for d, f in zip(digests, FILES))
    salt = os.urandom(16)
    data["h"] = sums.encode()
    data["m"] = ("%s %s\n" % (salt.hex(), seal(pw, salt, digests))).encode()
    # A generation at a time. Everything below goes through descriptors (opened without following links), so another
    # writer in the shared folder cannot swap a folder for a link between two steps: the new generation is written
    # completely beside the live one; the current one is copied whole beside it and checked; that copy becomes previous/
    # BEFORE any live file is replaced (the older previous/ waits aside until the end); then the live files are replaced.
    try:
        os.makedirs(folder, exist_ok=True)
        ffd = os.open(folder, os.O_RDONLY | os.O_DIRECTORY)
    except OSError as e:
        die("kein Zugriff auf %s (%s); einmal termux-setup-storage" % (folder, e))
    newname = aside = altname = nfd = None
    swapped = False
    try:
        newname, nfd = new_dir(ffd, ".neu-")   # kept open: the files are moved out of it through this descriptor
        for name in ALL:
            put(nfd, name, data[name])
        is_complete = complete_fd(ffd, pw)
        if not is_complete and any(os.path.lexists(os.path.join(folder, f)) for f in FILES):
            # one this password cannot check (another password, the earlier script) is not lost: kept-<time>/
            keptname = time.strftime("kept-%Y%m%d-%H%M%S")
            os.mkdir(keptname, 0o700, dir_fd=ffd)   # new, never an existing folder or link
            kfd = os.open(keptname, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=ffd)
            try:
                copy_nofollow(ffd, kfd, ALL)
            finally:
                os.close(kfd)
            say("  die bisherige Sicherung (mit diesem Passwort nicht prüfbar) liegt jetzt in %s" % os.path.join(folder, keptname))
        elif is_complete:
            if os.path.lexists(os.path.join(folder, "previous")) and not own_backup_dir(ffd, "previous"):
                die("%s enthält Fremdes (nicht von rootbridge backup); bitte selbst aufräumen"
                    % os.path.join(folder, "previous"))
            altname, afd = new_dir(ffd, ".alt-")
            try:
                copy_nofollow(ffd, afd, ALL)
                verified = complete_fd(afd, pw)   # the copy itself is checked: someone may have changed the files meanwhile
            finally:
                os.close(afd)
            if not verified:
                die("die bisherige Sicherung hat sich beim Kopieren verändert; nichts ersetzt, bitte nochmal")
            if os.path.lexists(os.path.join(folder, "previous")):
                aside = ".previous-old-%d" % os.getpid()
                os.rename("previous", aside, src_dir_fd=ffd, dst_dir_fd=ffd)
            os.rename(altname, "previous", src_dir_fd=ffd, dst_dir_fd=ffd)
            altname, swapped = None, True
        try:
            for name in ALL:
                os.replace(name, name, src_dir_fd=nfd, dst_dir_fd=ffd)
        except BaseException:   # also Ctrl-C
            # a half-published folder mixes two generations: the prior one (previous/) goes back as the live files, by
            # copies, so that previous/ stays whole until they are in place; then the older previous/ comes back too
            if swapped:
                try:
                    restore_live_from(ffd, "previous")
                    remove_backup_dir(ffd, "previous")
                    if aside is not None:
                        os.rename(aside, "previous", src_dir_fd=ffd, dst_dir_fd=ffd)
                except OSError:
                    die("Sicherung nicht vollständig veröffentlicht; die vorige ganze liegt in %s/previous%s"
                        % (folder, (", die ältere in %s/%s" % (folder, aside)) if aside else ""))
            raise
        if aside is not None:   # the new backup is in place: the older previous/ gives way
            remove_backup_dir(ffd, aside)
    except (OSError, FileExistsError) as e:
        die("Sicherung nicht geschrieben (%s); die vorige liegt in %s bzw. %s/previous" % (e, folder, folder))
    finally:
        if nfd is not None:
            os.close(nfd)
        for name in (newname, altname):
            if name:
                try:
                    remove_backup_dir(ffd, name)
                except OSError:
                    pass
        os.close(ffd)
    os.makedirs(PRIVATE, exist_ok=True)
    write_synced(TRUSTED, sums.encode())
    say("Gesichert in %s (a.tgz, k.enc, h, m; die vorige in previous/). Wiederherstellen:  rootbridge restore" % folder)


def arc_name(side, parts):
    """The name in the archive: t/... or g/..., the real path below the Termux home or the guest root."""
    return ("g/" if side == "guest" else "t/") + "/".join(parts)


def listed(info, entries, kinds=("settings", "secret")):
    """True when a line of the lists (settings or secret) names this entry or a folder around it; a folder on the way to
    such a path counts too. What an exclude line names or contains never is: an older backup does not bring back what
    you have excluded since."""
    side, _, rest = info.name.partition("/")
    names = rest.split("/")
    # the active config is archived under CONFIG_ARC but lands at CONFIG: exclusions are judged at its destination
    config_rel = os.path.relpath(os.path.abspath(CONFIG), os.path.abspath(HOME))
    dest = config_rel.split("/") if side == "t" and rest == CONFIG_ARC else names
    own_rel = os.path.relpath(os.path.abspath(OWN_LIST), os.path.abspath(HOME))
    if side == "t" and rest in (own_rel, ".config/termux-rootbridge/backup.list"):
        return False   # the own list comes back only through the merge (merged_own_list), never as a file of the archive
    sides = {"termux": "t", "guest": "g"}
    for kind, where, pattern in entries:
        if kind == "exclude" and sides[where] == side:
            parts = (config_rel if pattern == CONFIG_TOKEN else pattern).split("/")
            if len(dest) >= len(parts) and all(fnmatch.fnmatchcase(a, b) for a, b in zip(dest, parts)):
                return False
    for kind, where, pattern in entries:
        if kind not in kinds or sides[where] != side:
            continue
        parts = (CONFIG_ARC if pattern == CONFIG_TOKEN else pattern).split("/")
        n = min(len(parts), len(names))
        if all(fnmatch.fnmatchcase(a, b) for a, b in zip(names[:n], parts[:n])) and (
                len(names) >= len(parts) or info.isdir()):
            return True
    return False


def extract(data, entries, tmp, kinds=("settings", "secret")):
    """Unpacks the entries the lists name with the data filter into tmp; returns the names of the files unpacked. What
    the lists do not name stays in the archive (also in a backup of the earlier script: only what you list comes back)."""
    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
            infos = tar.getmembers()
            # only under t/ or g/, and no "..", "." or empty part: the lists are matched against exactly this path
            bad = [i.name for i in infos if i.name.split("/", 1)[0] not in ("t", "g")
                   or any(p in ("..", ".", "") for p in i.name.rstrip("/").split("/"))]
            if bad:
                die("unsichere oder unerwartete Einträge in der Sicherung, nichts wiederhergestellt: %s"
                    % ", ".join(bad[:5]))
            # only files and folders: backup never stores a link, so a link in the archive is not ours
            for i in infos:
                if i.issym() or i.islnk():
                    say("  Link übersprungen: %s" % i.name)
            chosen = [i for i in infos if "/" in i.name and (i.isfile() or i.isdir()) and listed(i, entries, kinds)]
            for name in sorted({i.name.split("/")[1] if i.name.startswith("t/") else "/".join(i.name.split("/")[1:3])
                                for i in infos if "/" in i.name and i not in chosen and not i.isdir()}):
                say("  nicht in der Liste, bleibt in der Sicherung: %s" % name)
            tar.extractall(tmp, members=chosen, filter="data")
    except tarfile.FilterError as e:   # an absolute path, "..", a link out, a device: nothing is copied
        die("unsicherer Eintrag in der Sicherung, nichts wiederhergestellt: %s" % e)
    except (tarfile.TarError, OSError, EOFError) as e:
        die("die Sicherung ist unlesbar (%s)" % e)
    return [i.name for i in chosen if not i.isdir()]


def summary(names, roots, items):
    """What goes where: each file, a deeper one by its folder at the third level (g/root/.claude/projects), once each,
    numbered after those already in items (a list of (side, short) it extends: what can be left out by its number)."""
    shown = []
    for name in names:
        side, _, rest = name.partition("/")
        parts = rest.split("/")
        short = "/".join(parts[:3]) if len(parts) > 3 else rest
        if rest and (side, short) not in items:
            items.append((side, short))
            shown.append("  %2d  %s -> %s" % (len(items), short, os.path.join(
                roots["termux" if side == "t" else "guest"] or "(Gast fehlt)", short)))
    return shown


# the device configuration: the files of the device and, in the Termux config, the keys that belong to the device
DEVICE_ITEMS = (("t", ".config/termux-rootbridge/device.conf"), ("t", ".termux/termux.properties"))
DEVICE_KEYS = ("DEVICE", "SIDEKEY", "HOMEKEY", "HEADSET", "PHANTOM_KILLER", "REMOTE_NAME")


def choose(items, yes, no_device):
    """What of items stays out of the restore: (the items left out, True when the device configuration stays out)."""
    without_device = no_device
    if not yes and not no_device and any(i in DEVICE_ITEMS or i == ("t", CONFIG_ARC) for i in items):
        try:
            answer = input("Gerätekonfiguration der Sicherung übernehmen (Tasten, Gerätedatei, Termux-Tastenleiste, "
                           "Name in Remote Control)? Für ein anderes Gerät: n [J/n] ").strip().lower()
        except EOFError:
            answer = ""
        without_device = answer in ("n", "nein", "no")
    left_out = [i for i in items if without_device and i in DEVICE_ITEMS]
    if not yes:
        try:
            answer = input("Einzelne Punkte weglassen? Ihre Nummern, durch Leerzeichen getrennt (Enter: keinen) ")
        except EOFError:
            answer = ""
        for word in answer.replace(",", " ").split():
            if not word.isdigit() or not 1 <= int(word) <= len(items):
                die("keine Nummer aus der Liste: %s; nichts wiederhergestellt" % word)
            if items[int(word) - 1] not in left_out:
                left_out.append(items[int(word) - 1])
    for side, short in left_out:
        say("  bleibt in der Sicherung: %s" % short)
    if without_device:
        say("  Gerätekonfiguration bleibt in der Sicherung; die Konfig behält %s dieses Geräts" % ", ".join(DEVICE_KEYS))
    return left_out, without_device


def keep_remote_name(path):
    """In the staged guest config: the Remote Control name in CLAUDE_ARGS becomes the one of this device (REMOTE_NAME of
    the Termux config, else the installer's default android), as the device configuration of the backup stays out."""
    line = config_value("REMOTE_NAME") or ""
    name = line.partition("=")[2].strip().strip("\"'")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", name):
        name = "android"
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    new = [re.sub(r"(--remote-control[ =])[A-Za-z0-9._-]+", lambda m: m.group(1) + name, l)
           if l.startswith("CLAUDE_ARGS=") else l for l in lines]
    if new != lines:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(new) + "\n")


UU_DIR = "usr/lib/cargo/bin/coreutils"   # uutils in the guest (Ubuntu 26.04)
UU_HOLD = "APT_HOLD=rust-coreutils gnu-coreutils coreutils-from-uutils coreutils"   # the default an earlier installer wrote


def drop_uutils_hold(path):
    """In the staged guest config of a guest without uutils (Debian): the default hold of the uutils packages goes (a backup
    of Ubuntu would hold Debian's coreutils back from its security updates); a list of your own stays."""
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    if UU_HOLD in lines:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(l for l in lines if l != UU_HOLD) + "\n")


def leave_out(trees, left_out):
    """Remove what stays out from the unpacked trees, before anything is copied."""
    for tree in trees:
        for side, short in left_out:
            path = os.path.join(tree, side, short)
            if os.path.isdir(path) and not os.path.islink(path):
                shutil.rmtree(path)
            elif os.path.lexists(path):
                os.unlink(path)


def confirm(question, yes, word="j"):
    if yes:
        return True
    try:
        answer = input("%s [%s/N] " % (question, word)).strip().lower()
    except EOFError:
        return False
    return answer in (("j", "ja", "y", "yes") if word == "j" else (word,))


def plan_copy(src, root):
    """The files of the tree src as (root, folder parts, name, source path); every target folder is opened through
    descriptors with O_NOFOLLOW from root down (a link on the way, also one a running guest swaps in, fails), and a
    folder where the backup has a file is refused. Nothing is written."""
    ops = []
    for dirpath, _dirnames, filenames in os.walk(src):
        rel = os.path.relpath(dirpath, src)
        parts = [] if rel == "." else rel.split(os.sep)
        try:
            dfd = open_dir(root, parts)
        except FileNotFoundError:
            dfd = None   # made when copying
        except OSError as e:
            die("%s: kein Ordner oder ein Link auf dem Weg (%s); nichts wiederhergestellt"
                % (os.path.join(root, rel), e.strerror))
        try:
            for name in filenames:
                if dfd is not None:
                    try:
                        if os.path.stat.S_ISDIR(os.stat(name, dir_fd=dfd, follow_symlinks=False).st_mode):
                            die("%s ist ein Ordner, in der Sicherung eine Datei; nichts wiederhergestellt"
                                % os.path.join(root, rel, name))
                    except FileNotFoundError:
                        pass
                ops.append((root, parts, name, os.path.join(dirpath, name)))
        finally:
            if dfd is not None:
                os.close(dfd)
    return ops


def relocate_config(tree, home):
    """The config is archived under its stable name; put it where this installation's config lives (ROOTBRIDGE_CONFIG).
    A config path outside the Termux home cannot be a target of restore: then the file is left out."""
    src = os.path.join(tree, "t", CONFIG_ARC)
    if not os.path.isfile(src):
        return
    top = os.path.abspath(home)
    wanted = os.path.abspath(CONFIG)   # as configured, not resolved: a link there is refused, never followed
    if os.path.islink(wanted):
        die("%s ist ein Link; die Konfig wird nicht durch einen Link hindurch wiederhergestellt" % wanted)
    if wanted == os.path.join(top, CONFIG_ARC):
        return
    if wanted.startswith(top + os.sep):
        dst = os.path.join(tree, "t", os.path.relpath(wanted, top))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        os.replace(src, dst)
    else:
        os.unlink(src)
        say("  übersprungen (die Konfig liegt außerhalb des Termux-Homes): %s" % CONFIG)


def apply_ops(ops):
    """All or nothing: first every file is written beside its target (a full disk stops here, nothing replaced), then
    each original is renamed aside and the new file renamed into place; a failure or an interrupt (Ctrl-C) on the way
    puts the originals back, and what could not be put back is named."""
    neu, alt = SUFFIX + "-neu", SUFFIX + "-alt"   # unique per run: two runs never share a staging name
    staged, done, problems = [], [], []

    def in_folder(op, fn):
        root, parts, name, _source = op
        dfd = open_dir(root, parts)
        try:
            return fn(dfd, name)
        finally:
            os.close(dfd)

    try:
        for op in ops:
            root, parts, name, source = op
            dfd = open_dir(root, parts, create=True)
            try:
                mode = os.stat(source).st_mode & 0o777
                staged.append(op)   # before it exists: the clean-up below tolerates a missing file
                out = os.open(name + neu, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode, dir_fd=dfd)
                with os.fdopen(out, "wb") as fh, open(source, "rb") as inp:
                    shutil.copyfileobj(inp, fh)
                    fh.flush()
                    os.fsync(fh.fileno())
            finally:
                os.close(dfd)
        for op in ops:
            def swap(dfd, name):
                try:
                    os.stat(name, dir_fd=dfd, follow_symlinks=False)
                    had = True
                except FileNotFoundError:
                    had = False
                if had:
                    # the original stays in place until the new file replaces it in one step (rename): a hard link
                    # keeps its content under NAME-alt for the rollback; a kill in between leaves the live file whole
                    try:
                        os.unlink(name + alt, dir_fd=dfd)
                    except FileNotFoundError:
                        pass
                    try:
                        os.link(name, name + alt, src_dir_fd=dfd, dst_dir_fd=dfd, follow_symlinks=False)
                    except (OSError, AttributeError, NotImplementedError):   # no hard links here (Python on Android has no os.link): a copy
                        with open(os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dfd), "rb") as inp:
                            orig_mode = os.fstat(inp.fileno()).st_mode & 0o7777   # a rollback must not strip x bits
                            with os.fdopen(os.open(name + alt, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                                   0o600, dir_fd=dfd), "wb") as out:
                                shutil.copyfileobj(inp, out)
                                out.flush()
                                os.fchmod(out.fileno(), orig_mode)
                done.append((op, had))
                os.replace(name + neu, name, src_dir_fd=dfd, dst_dir_fd=dfd)
            in_folder(op, swap)
    except BaseException as e:   # also KeyboardInterrupt
        def undo(dfd, name, had):
            if had:
                try:
                    os.replace(name + alt, name, src_dir_fd=dfd, dst_dir_fd=dfd)
                except FileNotFoundError:
                    pass   # the original was never moved aside
            else:
                try:
                    os.unlink(name, dir_fd=dfd)
                except FileNotFoundError:
                    pass
        for op, had in reversed(done):
            try:
                in_folder(op, lambda dfd, name, had=had: undo(dfd, name, had))
            except OSError as err:
                problems.append("%s: %s" % (os.path.join(op[0], *op[1], op[2]), err.strerror))
        for op in staged:
            try:
                in_folder(op, lambda dfd, name: os.unlink(name + neu, dir_fd=dfd))
            except FileNotFoundError:
                pass
            except OSError as err:
                problems.append("%s: %s" % (os.path.join(op[0], *op[1], op[2] + neu), err.strerror))
        if problems:
            print("rootbridge: NICHT zurückgesetzt (bitte prüfen; die alte Datei heißt NAME%s):" % alt, file=sys.stderr)
            for line in problems:
                print("  " + line, file=sys.stderr)
        if isinstance(e, (SystemExit, KeyboardInterrupt)):
            raise
        die("Wiederherstellen unterbrochen (%s); %s" % (e, "Teile blieben, siehe oben" if problems
                                                         else "alles ist wieder wie vorher"))
    for op, had in done:
        if had:
            try:
                in_folder(op, lambda dfd, name: os.unlink(name + alt, dir_fd=dfd))
            except OSError:
                pass


def copy_all(trees, roots, distro=None, keep_keys=()):
    """t/ of each unpacked tree into the Termux home, g/ into the guest (when there is one): every target is checked
    first, then all files are replaced together. keep_keys: lines of the config that stay as this installation has them."""
    ops = []
    for tmp in trees:
        relocate_config(tmp, roots["termux"])
        staged = os.path.join(tmp, "t", os.path.relpath(os.path.abspath(CONFIG), os.path.abspath(roots["termux"])))
        if os.path.isfile(staged) and not os.path.islink(staged):   # only when the config is part of this restore
            pin_line(staged, "DISTRO", distro)
            for key in keep_keys:
                pin_line(staged, key, config_value(key))
        guest_conf = os.path.join(tmp, "g", "etc", "termux-rootbridge.conf")
        if roots["guest"] and os.path.isfile(guest_conf) and not os.path.islink(guest_conf):
            # the bridge folder is where THIS Termux keeps it: the guest finds the daemon there (none yet: the guest
            # installer writes it)
            pin_line(guest_conf, "BRIDGE_DIR",
                     config_value("BRIDGE_DIR", os.path.join(roots["guest"], "etc", "termux-rootbridge.conf")))
            if "REMOTE_NAME" in keep_keys:   # without the device configuration: the name Claude uses is this device's
                keep_remote_name(guest_conf)
            if not os.path.isdir(os.path.join(roots["guest"], UU_DIR)):
                drop_uutils_hold(guest_conf)
        for side, key in (("t", "termux"), ("g", "guest")):
            src = os.path.join(tmp, side)
            if os.path.isdir(src) and roots[key]:
                ops += plan_copy(src, roots[key])
    apply_ops(ops)


def read_backup(folder):
    """The files of the backup, each read once; restore checks and uses exactly these bytes."""
    data = {}
    for name in ALL:
        try:
            with open(os.path.join(folder, name), "rb") as fh:
                data[name] = fh.read()
        except FileNotFoundError:
            if name != "m":   # a backup of the earlier script has no seal
                die("in %s fehlt %s" % (folder, name))
            data[name] = None
        except OSError as e:
            die("%s in %s nicht lesbar (%s); nichts wiederhergestellt" % (name, folder, e.strerror))
    return data


def restore(folder, yes, legacy=False, no_device=False):
    lock = take_lock()   # noqa: F841 (held until the end)
    data = read_backup(folder)
    expected = {}
    for line in data["h"].decode("utf-8", "replace").splitlines():
        parts = line.split()
        if len(parts) == 2:
            expected[parts[1]] = parts[0]
    digests = [hashlib.sha256(data[f]).hexdigest() for f in FILES]
    for digest, name in zip(digests, FILES):
        if expected.get(name) != digest:
            die("die Prüfsumme von %s stimmt nicht: die Sicherung ist beschädigt oder unvollständig (eine vorige liegt "
                "vielleicht in %s/previous)" % (name, folder))
    say("Prüfsummen: stimmen, die Sicherung ist vollständig.")
    try:
        with open(TRUSTED, encoding="utf-8") as fh:
            if fh.read() == "".join("%s  %s\n" % (d, f) for d, f in zip(digests, FILES)):
                say("Das ist deine letzte Sicherung von hier.")
    except OSError:
        pass
    # the seal: only who knows the password can have made this backup
    pw = password(False)
    if data["m"] is not None:
        # a seal is there, so it must be right: an empty, damaged or removed one is never the way to the legacy path
        try:
            salt_hex, mac = data["m"].decode().split()
            salt = bytes.fromhex(salt_hex)
        except ValueError:
            die("das Siegel (m) der Sicherung ist leer oder unlesbar; nichts wiederhergestellt")
        if not hmac.compare_digest(seal(pw, salt, digests), mac):
            die("Passwort falsch, oder die Sicherung wurde verändert; nichts wiederhergestellt")
        say("Siegel: stimmt, die Sicherung ist mit deinem Passwort gemacht.")
    elif not legacy:
        die("diese Sicherung hat kein Siegel: entweder ist es eine ältere (vom Skript backup), oder jemand hat es "
            "entfernt. Eine ältere stellt  rootbridge restore --legacy  wieder her; besser aber erst mit  rootbridge "
            "backup  neu sichern")
    else:
        say("ACHTUNG: Diese Sicherung hat kein Siegel (--legacy: gemacht vor rootbridge backup). Ob sie von dir ist, lässt "
            "sich nicht")
        say("prüfen; andere Apps können im Telefonspeicher schreiben. Nur wiederherstellen, wenn du sicher bist.")
        if not confirm("Trotzdem wiederherstellen? Dann \"ja\" tippen", False, "ja"):
            die("abgebrochen")
    secrets = openssl(["-d"], data["k.enc"], pw)
    if secrets is None:
        die("Passwort falsch, oder k.enc ist beschädigt; nichts wiederhergestellt")
    roots = {"termux": HOME, "guest": guest_root()}
    entries = read_lists()
    # the own list of the backup first: on a new installation yours does not exist yet, and the backup must come back
    # whole, with what only your list names (keys, signing key, ...). It is from the sealed backup: only you made it.
    src_home = home_rel_of(secrets) or "root"   # the home of the guest the backup came from (older backups: /root)
    if src_home != GUEST_HOME_REL:
        die("die Sicherung stammt von einem Gast mit dem Home /%s, dieser hat /%s; Dateien liegen dort unter anderem Pfad. "
            "Nichts wiederhergestellt (ROOTBRIDGE_GUEST_HOME=/%s setzen, um sie wiederherzustellen)"
            % (src_home, GUEST_HOME_REL, src_home))
    saved = own_list_of(secrets)
    if saved:
        entries += parse_list(saved, "die Liste in der Sicherung")
        say("Die eigene Liste der Sicherung gilt für diese Wiederherstellung (%d Zeilen)." % len(parse_list(saved, "")))
    # decrypted files are staged only in a private folder of the Termux home, whatever ROOTBRIDGE_CONFIG says (never in
    # TMPDIR or beside the config, which can lie on shared storage)
    stage = stage_dir()
    distro = config_value("DISTRO")
    with tempfile.TemporaryDirectory(dir=stage, prefix=".stage-") as plain, \
            tempfile.TemporaryDirectory(dir=stage, prefix=".stage-") as secret:
        items = []   # what comes back, numbered: (side, short)
        if data["m"] is None:
            # a backup without a seal: its a.tgz (plain text, no password in it) proves nothing, so nothing from it
            # comes back (SSH keys, hooks); k.enc was opened with your password and counts
            say("Einstellungen (a.tgz): bei einer Sicherung ohne Siegel nicht zurückgespielt; nach der Wiederherstellung")
            say("  mit  rootbridge backup  neu sichern und dann ein Mal  rootbridge restore  für die Einstellungen.")
        else:
            say("Einstellungen, die zurückkommen:")
            # a.tgz comes from our own backup (sealed) and holds settings only: a secret line cannot reach it
            for line in summary(extract(data["a.tgz"], entries, plain, ("settings",)), roots, items):
                say(line)
        say("Geheimnisse, die zurückkommen%s:" % ("" if roots["guest"] else " (die des Gasts erst, wenn er da ist)"))
        restored_secrets = extract(secrets, entries, secret)
        for line in summary(restored_secrets, roots, items):
            say(line)
        left_out, without_device = choose(items, yes, no_device)
        leave_out((plain, secret), left_out)
        if not confirm("Wiederherstellen?", yes):
            die("abgebrochen")
        merged = merged_own_list(saved) if saved else None
        if merged is not None:
            # installed in the same transaction as the files: all of it or none (a restored login must be named as secret
            # for the next backup, and a failed restore must leave the old rules as they were)
            staged_list = os.path.join(plain, "t", os.path.relpath(OWN_LIST, HOME))
            os.makedirs(os.path.dirname(staged_list), exist_ok=True)
            with open(staged_list, "w", encoding="utf-8") as fh:
                fh.write(merged)
            say("Die eigene Liste wird mitgespeichert: %s" % OWN_LIST)
        # all or nothing; without a guest only the Termux part
        copy_all((plain, secret), roots, distro, DEVICE_KEYS if without_device else ())

    if not roots["guest"]:
        say("Der Termux-Teil ist wiederhergestellt. Der Gast fehlt noch: erst bash install.sh, dann nochmal "
            "rootbridge restore")
        return
    say("Wiederhergestellt. Nicht gesichert: deine Arbeitsordner (aus Git neu holen), Verläufe, Plugins.")


def main(argv):
    yes, legacy, no_device = "--yes" in argv, "--legacy" in argv, "--no-device" in argv
    argv = [a for a in argv if a not in ("--yes", "--legacy", "--no-device")]
    if not argv or argv[0] not in ("backup", "restore") or len(argv) > 2:
        die("rootbridge backup [ORDNER] | rootbridge restore [ORDNER] [--legacy] [--yes] [--no-device]")
    folder = argv[1] if len(argv) == 2 else DEFAULT_DIR
    if argv[0] == "backup":
        backup(folder)
    else:
        restore(folder, yes, legacy, no_device)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
