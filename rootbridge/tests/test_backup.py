"""Tests for termux/lib/rootbridge-backup.py: rootbridge backup and restore (run: python3 -I -m unittest).

A fake Termux home and guest root in a temp dir; BKPW is the password, RB_GUEST_ROOT the guest.
"""
import io
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "..", "termux", "lib", "rootbridge-backup.py")


class TestBackup(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = self.tmp.name
        self.home = self.make_home("home")
        self.guest = os.path.join(self.d, "guest")
        self.write(self.guest, "root/.claude/settings.json", '{"a": 1}')
        self.write(self.guest, "root/.claude/projects/p1/memory/n.md", "note")
        self.write(self.guest, "root/.codex/auth.json", "secret")
        self.write(self.guest, "root/keys/a", "k1")
        self.write(self.guest, "root/keys/skip", "k2")
        self.write(self.home, ".termux/termux.properties", "x=1")
        self.write(self.home, ".config/termux-rootbridge/device.conf", "SIDEKEY_CODE=115\n")
        self.write(self.home, "real-ssh-keys", "ssh-ed25519 AAAA")
        os.makedirs(os.path.join(self.home, ".ssh"))
        os.symlink(os.path.join(self.home, "real-ssh-keys"), os.path.join(self.home, ".ssh/authorized_keys"))
        self.write(self.home, ".config/termux-rootbridge/backup.list",
                   "secret guest root/keys   # own lines\nexclude guest root/keys/skip\n")
        self.out = os.path.join(self.d, "out")

    def tearDown(self):
        self.tmp.cleanup()

    def make_home(self, name):
        home = os.path.join(self.d, name)
        self.write(home, ".config/termux-rootbridge/config", "DISTRO=ubuntu\n")
        own = os.path.join(self.d, "home", ".config/termux-rootbridge/backup.list")
        if name != "home" and os.path.isfile(own):   # the same own list on the new installation
            shutil.copy(own, os.path.join(home, ".config/termux-rootbridge/backup.list"))
        return home

    def write(self, root, rel, text):
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write(text)

    def run_tool(self, args, home, guest, stdin="", **extra):
        env = dict(os.environ, HOME=home, ROOTBRIDGE_CONFIG=os.path.join(home, ".config/termux-rootbridge/config"),
                   RB_GUEST_ROOT=guest, BKPW="test")
        env.update(extra)
        return subprocess.run([sys.executable, "-I", TOOL] + args, input=stdin, env=env, capture_output=True, text=True,
                              timeout=60)

    def backup(self):
        r = self.run_tool(["backup", self.out], self.home, self.guest)
        self.assertEqual(r.returncode, 0, r.stderr)

    def fresh(self):
        """A new installation: a Termux home without the checksums of a backup, an empty guest."""
        home, guest = self.make_home("home2"), os.path.join(self.d, "guest2")
        os.makedirs(os.path.join(guest, "root"))
        return home, guest

    def test_back_and_restored(self):
        self.backup()
        self.assertEqual(sorted(os.listdir(self.out)), ["a.tgz", "h", "k.enc", "m"])
        home, guest = self.fresh()
        r = self.run_tool(["restore", self.out, "--yes"], home, guest)
        self.assertEqual(r.returncode, 0, r.stderr)
        for root, rel in ((guest, "root/.claude/settings.json"), (guest, "root/.claude/projects/p1/memory/n.md"),
                          (guest, "root/.codex/auth.json"), (guest, "root/keys/a"), (home, ".termux/termux.properties"),
                          (home, ".config/termux-rootbridge/device.conf")):
            self.assertTrue(os.path.isfile(os.path.join(root, rel)), rel)
        self.assertFalse(os.path.exists(os.path.join(guest, "root/keys/skip")), "exclude")
        self.assertFalse(os.path.lexists(os.path.join(home, ".ssh/authorized_keys")), "a link is not followed")
        self.assertIn("Siegel: stimmt", r.stdout)

    def test_secrets_are_encrypted(self):
        self.backup()
        with open(os.path.join(self.out, "k.enc"), "rb") as fh:
            self.assertNotIn(b"secret", fh.read())
        with tarfile.open(os.path.join(self.out, "a.tgz")) as tar:
            self.assertNotIn("g/root/.codex/auth.json", tar.getnames())

    def test_ssh_keys_of_the_guest_are_secrets_and_keep_their_rights(self):
        for name, mode in (("root/.ssh/id_test", 0o600), ("root/.ssh/id_test.pub", 0o644), ("root/.ssh/config", 0o600)):
            self.write(self.guest, name, "KEY-MARKER " + name)
            os.chmod(os.path.join(self.guest, name), mode)
        os.chmod(os.path.join(self.guest, "root/.ssh"), 0o700)
        self.backup()
        with open(os.path.join(self.out, "k.enc"), "rb") as fh:
            self.assertNotIn(b"KEY-MARKER", fh.read())
        with tarfile.open(os.path.join(self.out, "a.tgz")) as tar:
            self.assertFalse([n for n in tar.getnames() if ".ssh" in n and n.startswith("g/")], "not in the settings")
        home, guest = self.fresh()
        r = self.run_tool(["restore", self.out, "--yes"], home, guest)
        self.assertEqual(r.returncode, 0, r.stderr)
        for name, mode in (("id_test", 0o600), ("id_test.pub", 0o644), ("config", 0o600)):
            path = os.path.join(guest, "root/.ssh", name)
            with open(path) as fh:
                self.assertEqual(fh.read(), "KEY-MARKER root/.ssh/" + name)
            self.assertEqual(os.stat(path).st_mode & 0o777, mode, name)
        self.assertEqual(os.stat(os.path.join(guest, "root/.ssh")).st_mode & 0o777, 0o700)

    def test_plugins_come_back_with_their_files_but_not_the_marketplaces(self):
        for rel in ("installed_plugins.json", "known_marketplaces.json", "cache/m/p/1.0/.mcp.json", "data/p-m/state/x",
                    "store/b.json", "marketplaces/m/big.txt"):
            self.write(self.guest, "root/.claude/plugins/" + rel, "PLUGIN-MARKER " + rel)
        self.backup()
        with open(os.path.join(self.out, "k.enc"), "rb") as fh:
            self.assertNotIn(b"PLUGIN-MARKER", fh.read())
        with tarfile.open(os.path.join(self.out, "a.tgz")) as tar:
            self.assertFalse([n for n in tar.getnames() if "plugins" in n], "not in the settings")
        home, guest = self.fresh()
        r = self.run_tool(["restore", self.out, "--yes"], home, guest)
        self.assertEqual(r.returncode, 0, r.stderr)
        for rel in ("installed_plugins.json", "known_marketplaces.json", "cache/m/p/1.0/.mcp.json", "data/p-m/state/x",
                    "store/b.json"):
            with open(os.path.join(guest, "root/.claude/plugins", rel)) as fh:
                self.assertEqual(fh.read(), "PLUGIN-MARKER " + rel)
        self.assertFalse(os.path.exists(os.path.join(guest, "root/.claude/plugins/marketplaces")))

    def test_the_checksums_of_the_own_backup_count(self):
        self.backup()
        r = self.run_tool(["restore", self.out, "--yes"], self.home, self.guest)
        self.assertIn("Das ist deine letzte Sicherung von hier", r.stdout)

    def test_a_damaged_backup_is_refused(self):
        self.backup()
        with open(os.path.join(self.out, "a.tgz"), "ab") as fh:
            fh.write(b"x")
        home, guest = self.fresh()
        r = self.run_tool(["restore", self.out, "--yes"], home, guest)
        self.assertEqual(r.returncode, 1)
        self.assertIn("Prüfsumme von a.tgz stimmt nicht", r.stderr)
        self.assertFalse(os.path.exists(os.path.join(guest, "root/.claude")))

    def test_a_planted_backup_fails_the_seal(self):
        self.backup()
        # another app put a backup of its own there, with matching checksums in h, on a fresh installation
        self.plant(tarfile.TarInfo("g/root/.bashrc"), b"evil")
        home, guest = self.fresh()
        r = self.run_tool(["restore", self.out, "--yes"], home, guest)
        self.assertEqual(r.returncode, 1)
        self.assertIn("die Sicherung wurde verändert", r.stderr)
        self.assertFalse(os.path.exists(os.path.join(guest, "root/.bashrc")))

    def test_without_a_seal_only_after_ja(self):
        self.backup()
        os.remove(os.path.join(self.out, "m"))   # a backup of the earlier script
        home, guest = self.fresh()
        r = self.run_tool(["restore", self.out, "--yes"], home, guest, stdin="ja\n")
        self.assertEqual(r.returncode, 1)
        self.assertIn("kein Siegel", r.stderr)   # without --legacy: refused
        r = self.run_tool(["restore", self.out, "--yes", "--legacy"], home, guest, stdin="j\n")
        self.assertEqual(r.returncode, 1)
        self.assertIn("kein Siegel", r.stdout)
        self.assertFalse(os.path.exists(os.path.join(guest, "root/.claude")))
        r = self.run_tool(["restore", self.out, "--yes", "--legacy"], home, guest, stdin="ja\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.isfile(os.path.join(guest, "root/.codex/auth.json")))   # from k.enc
        self.assertFalse(os.path.exists(os.path.join(home, ".termux/termux.properties")))   # a.tgz: not without a seal

    def test_secrets_inside_a_settings_folder_stay_secret(self):
        self.write(self.home, ".config/termux-rootbridge/backup.list", "settings guest root/.codex\n")
        self.backup()
        with tarfile.open(os.path.join(self.out, "a.tgz")) as tar:
            names = tar.getnames()
        self.assertIn("g/root/.codex", names)
        self.assertNotIn("g/root/.codex/auth.json", names)

    def test_a_link_to_a_secret_stays_out_of_the_settings(self):
        os.symlink(os.path.join(self.guest, "root/.codex/auth.json"), os.path.join(self.guest, "root/.claude/token"))
        self.write(self.home, ".config/termux-rootbridge/backup.list", "settings guest root/.claude\n")
        self.backup()
        with tarfile.open(os.path.join(self.out, "a.tgz")) as tar:
            names = tar.getnames()
        self.assertNotIn("g/root/.claude/token", names)
        self.assertNotIn("g/root/.claude/settings.json", names)   # a secret line names it

    def test_a_link_out_of_the_root_is_not_followed(self):
        self.write(self.d, "private/id", "termux secret")
        self.write(self.guest, "root/notes/n.md", "note")
        os.symlink(os.path.join(self.d, "private"), os.path.join(self.guest, "root/notes/out"))
        self.write(self.home, ".config/termux-rootbridge/backup.list", "settings guest root/notes\n")
        self.backup()
        with tarfile.open(os.path.join(self.out, "a.tgz")) as tar:
            names = tar.getnames()
        self.assertIn("g/root/notes/n.md", names)
        self.assertFalse([n for n in names if n.endswith("/out") or n.endswith("/id")])

    def test_another_password_keeps_the_old_backup(self):
        self.backup()
        with open(os.path.join(self.out, "h")) as fh:
            first = fh.read()
        r = self.run_tool(["backup", self.out], self.home, self.guest, BKPW="neu")
        self.assertEqual(r.returncode, 0, r.stderr)
        kept = [d for d in os.listdir(self.out) if d.startswith("kept-")]
        self.assertEqual(len(kept), 1)
        with open(os.path.join(self.out, kept[0], "h")) as fh:
            self.assertEqual(fh.read(), first)

    def test_a_trailing_slash_names_the_folder(self):
        self.write(self.guest, "root/.gnupg/key", "key")   # a folder the base list does not name
        self.write(self.home, ".config/termux-rootbridge/backup.list", "secret guest root/.gnupg/\n")
        self.backup()
        home, guest = self.fresh()
        r = self.run_tool(["restore", self.out, "--yes"], home, guest)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.isfile(os.path.join(guest, "root/.gnupg/key")))

    def extract_from(self, info, data=b"x"):
        """The extract step of restore on a hand-made archive (a.tgz without a seal is not read at all, so the archive
        checks are tested on the step itself, as k.enc reaches it)."""
        import importlib.util
        spec = importlib.util.spec_from_file_location("rbbackup", TOOL)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w:gz") as tar:
            info.size = len(data) if info.isfile() else 0
            tar.addfile(info, io.BytesIO(data) if info.isfile() else None)
        out = os.path.join(self.d, "extracted")
        os.makedirs(out, exist_ok=True)
        entries = [("secret", "guest", "root/.claude/projects/*/memory")]
        try:
            mod.extract(buf.getvalue(), entries, out)
            return 0, out
        except SystemExit as e:
            return e.code, out

    def test_a_link_in_the_archive_is_skipped(self):
        info = tarfile.TarInfo("g/root/.claude/projects/p1/memory/x")
        info.type, info.linkname = tarfile.SYMTYPE, "../../../outside"
        code, out = self.extract_from(info)
        self.assertEqual(code, 0)
        self.assertFalse(os.path.lexists(os.path.join(out, "g/root/.claude/projects/p1/memory/x")))

    def test_a_path_out_of_the_targets_is_refused(self):
        code, out = self.extract_from(tarfile.TarInfo("g/../../escaped"))
        self.assertEqual(code, 1)
        self.assertFalse(os.path.exists(os.path.join(self.d, "escaped")))

    def test_dotdot_cannot_reach_an_unlisted_file(self):
        code, out = self.extract_from(tarfile.TarInfo("g/root/.claude/projects/p1/memory/../../../../.profile"))
        self.assertEqual(code, 1)
        self.assertFalse(os.path.exists(os.path.join(out, "g/root/.profile")))

    def test_a_foreign_previous_folder_is_not_deleted(self):
        self.backup()
        self.write(self.out, "previous/photo.jpg", "mine")
        r = self.run_tool(["backup", self.out], self.home, self.guest)
        self.assertEqual(r.returncode, 1)
        self.assertIn("enthält Fremdes", r.stderr)
        self.assertTrue(os.path.isfile(os.path.join(self.out, "previous/photo.jpg")))

    def test_a_link_in_the_backup_folder_stops_the_backup(self):
        self.backup()
        secret = os.path.join(self.d, "private-file")
        self.write(self.d, "private-file", "termux secret")
        os.remove(os.path.join(self.out, "m"))
        os.symlink(secret, os.path.join(self.out, "m"))
        with open(os.path.join(self.out, "h")) as fh:
            before = fh.read()
        r = self.run_tool(["backup", self.out], self.home, self.guest)
        self.assertEqual(r.returncode, 1)
        with open(os.path.join(self.out, "h")) as fh:   # nothing replaced
            self.assertEqual(fh.read(), before)
        for d in os.listdir(self.out):
            if d.startswith("kept-"):
                self.assertFalse(os.path.exists(os.path.join(self.out, d, "m")))

    def test_a_secret_is_judged_by_its_line_not_by_a_list_made_first(self):
        # a login that appears inside a settings folder (also during a run) stays out of the settings
        self.write(self.home, ".config/termux-rootbridge/backup.list", "settings guest root/.codex\n")
        os.remove(os.path.join(self.guest, "root/.codex/auth.json"))
        self.backup()
        self.write(self.guest, "root/.codex/auth.json", "new login")
        self.backup()
        with tarfile.open(os.path.join(self.out, "a.tgz")) as tar:
            self.assertNotIn("g/root/.codex/auth.json", tar.getnames())

    def test_the_config_keeps_the_guest_that_received_the_files(self):
        self.write(self.home, ".config/termux-rootbridge/config", "DISTRO=debian\nVOICE=on\n")
        self.backup()
        home, guest = self.fresh()
        r = self.run_tool(["restore", self.out, "--yes"], home, guest)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(os.path.join(home, ".config/termux-rootbridge/config")) as fh:
            config = fh.read()
        self.assertIn("DISTRO=ubuntu", config)
        self.assertNotIn("DISTRO=debian", config)
        self.assertIn("VOICE=on", config)   # the rest of the backup's config came back

    def test_decrypted_files_are_staged_in_the_private_folder(self):
        self.backup()
        home, guest = self.fresh()
        elsewhere = os.path.join(self.d, "shared-tmp")
        os.makedirs(elsewhere)
        r = self.run_tool(["restore", self.out, "--yes"], home, guest, TMPDIR=elsewhere)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(os.listdir(elsewhere), [])

    def test_a_failure_while_replacing_puts_the_originals_back(self):
        self.backup()
        home, guest = self.fresh()
        self.write(guest, "root/.claude/CLAUDE.md", "mine")
        self.write(guest, "root/.claude/keybindings.json", "mine too")
        # a folder where the backup has a file, found late (in a later folder): nothing may have been replaced
        os.makedirs(os.path.join(guest, "root/.claude/themes"), exist_ok=True)
        self.write(guest, "root/.claude/projects/p1/memory/n.md", "old")
        os.chmod(os.path.join(guest, "root/.claude/projects/p1/memory"), 0o500)   # cannot be written
        try:
            r = self.run_tool(["restore", self.out, "--yes"], home, guest)
        finally:
            os.chmod(os.path.join(guest, "root/.claude/projects/p1/memory"), 0o700)
        if os.geteuid() != 0:   # as root nothing is unwritable
            self.assertEqual(r.returncode, 1)
            with open(os.path.join(guest, "root/.claude/CLAUDE.md")) as fh:
                self.assertEqual(fh.read(), "mine")
            self.assertFalse(os.path.exists(os.path.join(guest, "root/.claude/CLAUDE.md.rootbridge-alt")))

    def test_the_guest_config_is_encrypted(self):
        self.write(self.guest, "etc/termux-rootbridge.conf", 'CLAUDE_ARGS="--mcp-config {token:abc}"\n')
        self.backup()
        with open(os.path.join(self.out, "a.tgz"), "rb") as fh:
            import gzip
            self.assertNotIn(b"abc", gzip.decompress(fh.read()))
        home, guest = self.fresh()
        r = self.run_tool(["restore", self.out, "--yes"], home, guest)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.isfile(os.path.join(guest, "etc/termux-rootbridge.conf")))

    def test_a_restore_during_a_backup_is_refused(self):
        import fcntl
        self.backup()
        home, guest = self.fresh()
        with open(os.path.join(home, ".config/termux-rootbridge/backup.lock"), "w") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX)
            r = self.run_tool(["restore", self.out, "--yes"], home, guest)
        self.assertEqual(r.returncode, 1)
        self.assertIn("läuft gerade", r.stderr)
        self.assertFalse(os.path.exists(os.path.join(guest, "root/.claude")))

    def test_the_config_named_by_the_environment_is_saved_and_restored(self):
        other = os.path.join(self.home, "elsewhere/rb-config")
        self.write(self.home, "elsewhere/rb-config", "DISTRO=ubuntu\nCUSTOM=1\n")
        r = self.run_tool(["backup", self.out], self.home, self.guest, ROOTBRIDGE_CONFIG=other)
        self.assertEqual(r.returncode, 0, r.stderr)
        home = os.path.join(self.d, "home5")
        home_config = os.path.join(home, "elsewhere/rb-config")
        os.makedirs(os.path.dirname(home_config))
        with open(home_config, "w") as fh:
            fh.write("DISTRO=ubuntu\n")
        guest = os.path.join(self.d, "guest5")
        os.makedirs(os.path.join(guest, "root"))
        r = self.run_tool(["restore", self.out, "--yes"], home, guest, ROOTBRIDGE_CONFIG=home_config)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(home_config) as fh:
            self.assertIn("CUSTOM=1", fh.read())

    def test_a_settings_line_naming_the_config_does_not_put_it_in_the_settings(self):
        self.write(self.home, ".config/termux-rootbridge/backup.list", "settings termux .config/termux-rootbridge\n")
        self.backup()
        with tarfile.open(os.path.join(self.out, "a.tgz")) as tar:
            self.assertNotIn("t/.config/termux-rootbridge/config", tar.getnames())

    def test_the_staging_folder_is_in_the_home_not_beside_the_config(self):
        self.backup()
        home, guest = self.fresh()
        shared_config = os.path.join(self.d, "shared/config")
        self.write(self.d, "shared/config", "DISTRO=ubuntu\n")
        r = self.run_tool(["restore", self.out, "--yes"], home, guest, ROOTBRIDGE_CONFIG=shared_config, stdin="")
        self.assertFalse([n for n in os.listdir(os.path.join(self.d, "shared")) if n.startswith(".stage-")])

    def test_a_config_that_is_a_link_is_refused(self):
        self.backup()
        home, guest = self.fresh()
        target = os.path.join(self.d, "real-config")
        self.write(self.d, "real-config", "DISTRO=ubuntu\nKEEP=1\n")
        os.remove(os.path.join(home, ".config/termux-rootbridge/config"))
        os.symlink(target, os.path.join(home, ".config/termux-rootbridge/config"))
        other = os.path.join(home, ".config/termux-rootbridge/config")
        r = self.run_tool(["restore", self.out, "--yes"], home, guest, ROOTBRIDGE_CONFIG=other)
        with open(target) as fh:
            self.assertEqual(fh.read(), "DISTRO=ubuntu\nKEEP=1\n")

    def test_installer_copies_of_secret_files_stay_out_of_the_settings(self):
        self.write(self.guest, "root/.claude/settings.json.bak-20261123", '{"env": {"TOKEN": "old"}}')
        self.write(self.home, ".config/termux-rootbridge/backup.list", "settings guest root/.claude\n")
        self.backup()
        with tarfile.open(os.path.join(self.out, "a.tgz")) as tar:
            names = tar.getnames()
        self.assertFalse([n for n in names if ".bak" in n])

    def test_leftovers_of_a_restore_stay_out_of_the_settings(self):
        self.write(self.guest, "root/.codex/auth.json.rootbridge-123-alt", "old login")
        self.write(self.home, ".config/termux-rootbridge/backup.list", "settings guest root/.codex\n")
        self.backup()
        with tarfile.open(os.path.join(self.out, "a.tgz")) as tar:
            self.assertFalse([n for n in tar.getnames() if "rootbridge-" in n])

    def test_an_excluded_config_is_not_touched(self):
        self.backup()
        home, guest = self.fresh()
        self.write(home, ".config/termux-rootbridge/backup.list", "exclude termux @config\n")
        with open(os.path.join(home, ".config/termux-rootbridge/config"), "w") as fh:
            fh.write("DISTRO=ubuntu\nMINE=1\n")
        r = self.run_tool(["restore", self.out, "--yes"], home, guest)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(os.path.join(home, ".config/termux-rootbridge/config")) as fh:
            self.assertEqual(fh.read(), "DISTRO=ubuntu\nMINE=1\n")

    def test_an_exclude_for_the_real_config_path_holds(self):
        other = os.path.join(self.home, "elsewhere/rb-config")
        self.write(self.home, "elsewhere/rb-config", "DISTRO=ubuntu\nCUSTOM=1\n")
        r = self.run_tool(["backup", self.out], self.home, self.guest, ROOTBRIDGE_CONFIG=other)
        self.assertEqual(r.returncode, 0, r.stderr)
        home = os.path.join(self.d, "home6")
        home_config = os.path.join(home, "elsewhere/rb-config")
        self.write(home, "elsewhere/rb-config", "DISTRO=ubuntu\nMINE=1\n")
        os.makedirs(os.path.join(home, ".config/termux-rootbridge"), exist_ok=True)
        guest = os.path.join(self.d, "guest6")
        os.makedirs(os.path.join(guest, "root"))
        self.write(home, ".config/termux-rootbridge/backup.list", "exclude termux elsewhere/rb-config\n")
        r = self.run_tool(["restore", self.out, "--yes"], home, guest, ROOTBRIDGE_CONFIG=home_config)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(home_config) as fh:
            self.assertEqual(fh.read(), "DISTRO=ubuntu\nMINE=1\n")

    def test_the_default_config_cannot_take_the_name_of_the_active_one(self):
        other = os.path.join(self.home, "elsewhere/rb-config")
        self.write(self.home, "elsewhere/rb-config", "DISTRO=ubuntu\nCUSTOM=1\n")
        self.write(self.home, ".config/termux-rootbridge/config", "DISTRO=ubuntu\nOLD=1\n")
        self.write(self.home, ".config/termux-rootbridge/backup.list", "settings termux .config/termux-rootbridge\n")
        r = self.run_tool(["backup", self.out], self.home, self.guest, ROOTBRIDGE_CONFIG=other)
        self.assertEqual(r.returncode, 0, r.stderr)
        with tarfile.open(os.path.join(self.out, "a.tgz")) as tar:
            self.assertNotIn("t/.config/termux-rootbridge/config", tar.getnames())

    def test_the_bridge_folder_of_this_installation_stays(self):
        self.write(self.guest, "etc/termux-rootbridge.conf", "BRIDGE_DIR=/old/place/.rootbridge\nCLAUDE_ARGS=x\n")
        self.backup()
        home, guest = self.fresh()
        self.write(guest, "etc/termux-rootbridge.conf", "BRIDGE_DIR=/data/here/.rootbridge\n")
        r = self.run_tool(["restore", self.out, "--yes"], home, guest)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(os.path.join(guest, "etc/termux-rootbridge.conf")) as fh:
            conf = fh.read()
        self.assertIn("BRIDGE_DIR=/data/here/.rootbridge", conf)
        self.assertNotIn("/old/place", conf)
        self.assertIn("CLAUDE_ARGS=x", conf)

    def test_a_plain_archive_cannot_bring_a_secret_path(self):
        self.backup()
        self.plant(tarfile.TarInfo("g/root/.claude/settings.json"), b'{"hooks": "evil"}')
        home, guest = self.fresh()
        r = self.run_tool(["restore", self.out, "--yes", "--legacy"], home, guest, stdin="ja\n")
        self.assertFalse(os.path.exists(os.path.join(guest, "root/.claude/settings.json.evil")))
        self.assertFalse(os.path.exists(os.path.join(home, ".ssh/authorized_keys")))

    def test_the_staging_folder_never_goes_into_a_backup(self):
        self.write(self.home, ".cache/rootbridge-backup/.stage-x/g/root/.codex/auth.json", "decrypted")
        self.write(self.home, ".config/termux-rootbridge/backup.list", "settings termux .cache\n")
        self.backup()
        with tarfile.open(os.path.join(self.out, "a.tgz")) as tar:
            self.assertFalse([n for n in tar.getnames() if "rootbridge-backup" in n])

    def test_a_distro_that_is_a_path_is_refused(self):
        self.backup()
        home = self.make_home("home7")
        self.write(home, ".config/termux-rootbridge/config", "DISTRO=../../../tmp/x\n")
        env = dict(os.environ, HOME=home, ROOTBRIDGE_CONFIG=os.path.join(home, ".config/termux-rootbridge/config"),
                   PREFIX=os.path.join(self.d, "prefix"), BKPW="test")
        env.pop("RB_GUEST_ROOT", None)
        r = subprocess.run([sys.executable, "-I", TOOL, "restore", self.out, "--yes"], env=env, capture_output=True,
                           text=True, timeout=60)
        self.assertEqual(r.returncode, 1)
        self.assertIn("kein gültiger Name", r.stderr)

    def test_the_own_list_of_the_backup_brings_back_everything_on_a_new_installation(self):
        # the own list (setUp) names root/keys; the new installation has no own list yet
        self.backup()
        home, guest = self.fresh()
        own = os.path.join(home, ".config/termux-rootbridge/backup.list")
        if os.path.exists(own):   # fresh() copies it for the other tests: this installation has none
            os.remove(own)
        r = self.run_tool(["restore", self.out, "--yes"], home, guest)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("eigene Liste der Sicherung", r.stdout)
        self.assertTrue(os.path.isfile(os.path.join(guest, "root/keys/a")))   # only the own list names it
        self.assertFalse(os.path.exists(os.path.join(guest, "root/keys/skip")))   # its exclude holds too
        with open(own) as fh:
            self.assertIn("secret guest root/keys", fh.read())   # kept for the next backup

    def test_an_existing_own_list_gets_the_missing_lines(self):
        self.backup()
        home, guest = self.fresh()
        own = os.path.join(home, ".config/termux-rootbridge/backup.list")
        self.write(home, ".config/termux-rootbridge/backup.list", "secret guest root/other\n")
        r = self.run_tool(["restore", self.out, "--yes"], home, guest)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(own) as fh:   # the local lines stay, the backup's lines are added: a restored login stays secret
            text = fh.read()
        self.assertIn("secret guest root/other", text)
        self.assertIn("secret guest root/keys", text)
        self.assertIn("exclude guest root/keys/skip", text)
        self.assertTrue(os.path.isfile(os.path.join(guest, "root/keys/a")))

    def test_the_own_list_is_not_a_file_of_the_archives(self):
        # a rule that covers the config folder must not archive backup.list (it travels on its own, merged on restore)
        self.write(self.home, ".config/termux-rootbridge/backup.list",
                   "settings termux .config/termux-rootbridge\nsecret guest root/keys\nexclude guest root/keys/skip\n")
        self.backup()
        with tarfile.open(os.path.join(self.out, "a.tgz")) as tar:
            self.assertFalse([n for n in tar.getnames() if n.endswith("backup.list")])
        home, guest = self.fresh()
        own = os.path.join(home, ".config/termux-rootbridge/backup.list")
        self.write(home, ".config/termux-rootbridge/backup.list", "secret guest root/other\n")
        r = self.run_tool(["restore", self.out, "--yes"], home, guest)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(own) as fh:
            text = fh.read()
        self.assertIn("secret guest root/other", text)   # the local rule is still there
        self.assertIn("exclude guest root/keys/skip", text)

    def test_hidden_files_are_matched_by_a_wildcard_in_both_passes(self):
        self.write(self.home, ".cfg/.hidden", "h")
        self.write(self.home, ".cfg/shown", "s")
        self.write(self.home, ".config/termux-rootbridge/backup.list", "settings termux .cfg\nsecret termux .cfg/*\n")
        self.backup()
        with tarfile.open(os.path.join(self.out, "a.tgz")) as tar:
            self.assertFalse([n for n in tar.getnames() if n.startswith("t/.cfg/")])   # a secret line names both
        home, guest = self.fresh()
        r = self.run_tool(["restore", self.out, "--yes"], home, guest)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.isfile(os.path.join(home, ".cfg/.hidden")))   # not lost: it is in k.enc
        self.assertTrue(os.path.isfile(os.path.join(home, ".cfg/shown")))

    def test_the_older_previous_stays_until_the_new_backup_is_in_place(self):
        if os.geteuid() == 0:   # as root nothing is unwritable
            self.skipTest("needs a normal user")
        self.backup()
        self.backup()
        with open(os.path.join(self.out, "previous/h")) as fh:
            before = fh.read()
        # a run that cannot publish (a file of the new generation is missing in the folder) keeps previous/ as it was
        os.chmod(self.out, 0o500)
        try:
            r = self.run_tool(["backup", self.out], self.home, self.guest)
        finally:
            os.chmod(self.out, 0o700)
        with open(os.path.join(self.out, "previous/h")) as fh:
            self.assertEqual(fh.read(), before)

    def test_an_unreadable_folder_in_a_wildcard_stops_the_backup(self):
        if os.geteuid() == 0:
            self.skipTest("needs a normal user")
        self.write(self.guest, "root/.claude/projects/p2/memory/x.md", "x")
        os.chmod(os.path.join(self.guest, "root/.claude/projects"), 0o000)
        try:
            r = self.run_tool(["backup", self.out], self.home, self.guest)
        finally:
            os.chmod(os.path.join(self.guest, "root/.claude/projects"), 0o700)
        self.assertEqual(r.returncode, 1)
        self.assertIn("nicht lesbar", r.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.out, "a.tgz")))

    def test_the_list_is_read_from_the_home_not_from_the_config_folder(self):
        # ROOTBRIDGE_CONFIG on shared storage: a backup.list put beside it must not decide what goes into a.tgz
        shared = os.path.join(self.d, "shared")
        self.write(shared, "config", "DISTRO=ubuntu\n")
        self.write(shared, "backup.list", "settings guest root/.codex\n")
        r = self.run_tool(["backup", self.out], self.home, self.guest, ROOTBRIDGE_CONFIG=os.path.join(shared, "config"))
        self.assertEqual(r.returncode, 0, r.stderr)
        with tarfile.open(os.path.join(self.out, "a.tgz")) as tar:
            self.assertFalse([n for n in tar.getnames() if ".codex" in n])

    def test_the_lock_is_not_a_way_to_erase_a_file(self):
        target = os.path.join(self.d, "precious")
        self.write(self.d, "precious", "keep me")
        priv = os.path.join(self.home, ".config/termux-rootbridge")
        os.symlink(target, os.path.join(priv, "backup.lock"))
        r = self.run_tool(["backup", self.out], self.home, self.guest)
        self.assertEqual(r.returncode, 1)
        with open(target) as fh:
            self.assertEqual(fh.read(), "keep me")

    def test_an_unreadable_selected_file_stops_the_backup(self):
        if os.geteuid() == 0:
            self.skipTest("needs a normal user")
        os.chmod(os.path.join(self.guest, "root/.codex/auth.json"), 0o000)
        try:
            r = self.run_tool(["backup", self.out], self.home, self.guest)
        finally:
            os.chmod(os.path.join(self.guest, "root/.codex/auth.json"), 0o600)
        self.assertEqual(r.returncode, 1)
        self.assertIn("nicht lesbar", r.stderr)

    def test_a_failed_restore_leaves_the_own_list_as_it_was(self):
        self.backup()
        home, guest = self.fresh()
        self.write(home, ".config/termux-rootbridge/backup.list", "secret guest root/other\n")
        os.makedirs(os.path.join(guest, "root/keys/a"))   # a folder where the backup has a file: the restore stops
        r = self.run_tool(["restore", self.out, "--yes"], home, guest)
        self.assertEqual(r.returncode, 1)
        with open(os.path.join(home, ".config/termux-rootbridge/backup.list")) as fh:
            self.assertEqual(fh.read(), "secret guest root/other\n")

    def test_a_half_written_installer_copy_stays_out_of_the_settings(self):
        self.write(self.guest, "root/.claude/settings.json.new.4711", '{"env": {"TOKEN": "x"}}')
        self.write(self.home, ".config/termux-rootbridge/backup.list", "settings guest root/.claude\n")
        self.backup()
        with tarfile.open(os.path.join(self.out, "a.tgz")) as tar:
            self.assertFalse([n for n in tar.getnames() if ".new." in n])

    def test_a_config_behind_a_link_stays_out_of_the_settings(self):
        real = os.path.join(self.d, "real-config")
        self.write(self.d, "real-config", "DISTRO=ubuntu\nTOKEN=secret\n")
        link = os.path.join(self.home, "linked-config")
        os.symlink(real, link)
        self.write(self.home, ".config/termux-rootbridge/backup.list", "settings termux linked-config\n")
        r = self.run_tool(["backup", self.out], self.home, self.guest, ROOTBRIDGE_CONFIG=link)
        self.assertEqual(r.returncode, 0, r.stderr)
        with tarfile.open(os.path.join(self.out, "a.tgz")) as tar:
            self.assertFalse([n for n in tar.getnames() if "linked-config" in n])

    def test_a_copy_that_does_not_check_out_is_not_used_for_previous(self):
        self.backup()
        import importlib.util
        spec = importlib.util.spec_from_file_location("rbbackup2", TOOL)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        real = mod.copy_nofollow

        def changing_copy(src, dst, names):
            real(src, dst, names)
            fd = os.open("a.tgz", os.O_WRONLY | os.O_APPEND, dir_fd=dst)   # changed while it was being copied
            os.write(fd, b"x")
            os.close(fd)
        mod.copy_nofollow = changing_copy
        mod.HOME = self.home
        mod.PRIVATE = os.path.join(self.home, ".config/termux-rootbridge")
        mod.OWN_LIST = os.path.join(mod.PRIVATE, "backup.list")
        mod.CONFIG = os.path.join(mod.PRIVATE, "config")
        mod.TRUSTED = os.path.join(mod.PRIVATE, "backup.sha256")
        os.environ["BKPW"] = "test"
        os.environ["RB_GUEST_ROOT"] = self.guest
        with open(os.path.join(self.out, "h")) as fh:
            before = fh.read()
        with self.assertRaises(SystemExit):
            mod.backup(self.out)
        with open(os.path.join(self.out, "h")) as fh:   # nothing replaced
            self.assertEqual(fh.read(), before)
        self.assertFalse(os.path.exists(os.path.join(self.out, "previous")))

    def test_an_unreadable_folder_on_the_way_to_a_secret_stops_the_backup(self):
        if os.geteuid() == 0:
            self.skipTest("needs a normal user")
        os.chmod(os.path.join(self.guest, "root/.codex"), 0o000)
        try:
            r = self.run_tool(["backup", self.out], self.home, self.guest)
        finally:
            os.chmod(os.path.join(self.guest, "root/.codex"), 0o700)
        self.assertEqual(r.returncode, 1)
        self.assertIn("nicht lesbar", r.stderr)

    def test_a_guest_with_another_home(self):
        guest = os.path.join(self.d, "guest8")
        self.write(guest, "home/tester/.codex/auth.json", "login")
        self.write(guest, "home/tester/.claude/CLAUDE.md", "rules")
        r = self.run_tool(["backup", self.out], self.home, guest, ROOTBRIDGE_GUEST_HOME="/home/tester")
        self.assertEqual(r.returncode, 0, r.stderr)
        with tarfile.open(os.path.join(self.out, "a.tgz")) as tar:
            self.assertIn("g/home/tester/.claude/CLAUDE.md", tar.getnames())
        home = self.make_home("home8")
        guest2 = os.path.join(self.d, "guest9")
        os.makedirs(os.path.join(guest2, "home/tester"))
        r = self.run_tool(["restore", self.out, "--yes"], home, guest2, ROOTBRIDGE_GUEST_HOME="/home/tester")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.isfile(os.path.join(guest2, "home/tester/.codex/auth.json")))
        self.assertTrue(os.path.isfile(os.path.join(guest2, "home/tester/.claude/CLAUDE.md")))

    def test_a_backup_of_another_guest_home_is_refused(self):
        guest = os.path.join(self.d, "guest10")
        self.write(guest, "home/alice/.codex/auth.json", "login")
        r = self.run_tool(["backup", self.out], self.home, guest, ROOTBRIDGE_GUEST_HOME="/home/alice")
        self.assertEqual(r.returncode, 0, r.stderr)
        home = self.make_home("home10")
        guest2 = os.path.join(self.d, "guest11")
        os.makedirs(os.path.join(guest2, "home/bob"))
        r = self.run_tool(["restore", self.out, "--yes"], home, guest2, ROOTBRIDGE_GUEST_HOME="/home/bob")
        self.assertEqual(r.returncode, 1)
        self.assertIn("unter anderem Pfad", r.stderr)
        self.assertFalse(os.path.exists(os.path.join(guest2, "home/bob/.codex")))
        r = self.run_tool(["restore", self.out, "--yes"], home, guest2, ROOTBRIDGE_GUEST_HOME="/home/alice")
        os.makedirs(os.path.join(guest2, "home/alice"), exist_ok=True)
        r = self.run_tool(["restore", self.out, "--yes"], home, guest2, ROOTBRIDGE_GUEST_HOME="/home/alice")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.isfile(os.path.join(guest2, "home/alice/.codex/auth.json")))

    def test_the_default_home_and_a_custom_home_do_not_collide(self):
        guest = os.path.join(self.d, "guest18")
        self.write(guest, "root/.codex/auth.json", "root login")
        self.write(guest, "home/alice/.codex/auth.json", "alice login")
        self.write(self.home, ".config/termux-rootbridge/backup.list", "secret guest root\nsecret guest home/alice\n")
        r = self.run_tool(["backup", self.out], self.home, guest, ROOTBRIDGE_GUEST_HOME="/home/alice")
        self.assertEqual(r.returncode, 0, r.stderr)
        home = self.make_home("home18")
        guest2 = os.path.join(self.d, "guest19")
        os.makedirs(os.path.join(guest2, "home/alice"))
        os.makedirs(os.path.join(guest2, "root"))
        r = self.run_tool(["restore", self.out, "--yes"], home, guest2, ROOTBRIDGE_GUEST_HOME="/home/alice")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.isfile(os.path.join(guest2, "root/.codex/auth.json")))   # both survive
        self.assertTrue(os.path.isfile(os.path.join(guest2, "home/alice/.codex/auth.json")))

    def test_a_cache_folder_that_is_a_link_is_refused(self):
        self.backup()
        home, guest = self.fresh()
        shared = os.path.join(self.d, "shared-cache")
        os.makedirs(shared)
        os.symlink(shared, os.path.join(home, ".cache"))
        r = self.run_tool(["restore", self.out, "--yes"], home, guest)
        self.assertEqual(r.returncode, 1)
        self.assertIn("kein eigener Ordner", r.stderr)
        self.assertEqual(os.listdir(shared), [])

    def test_a_config_folder_that_is_a_link_is_refused(self):
        shared = os.path.join(self.d, "shared-config")
        os.makedirs(shared)
        home = self.make_home("home20")
        import shutil as sh
        sh.rmtree(os.path.join(home, ".config"))
        os.symlink(shared, os.path.join(home, ".config"))
        r = self.run_tool(["backup", self.out], home, self.guest, ROOTBRIDGE_CONFIG=os.path.join(self.d, "any-config"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("kein eigener Ordner", r.stderr)

    def test_a_guest_without_its_home_still_gets_the_files(self):
        self.backup()
        home = self.make_home("home21")
        guest = os.path.join(self.d, "guest21")
        os.makedirs(os.path.join(guest, "etc"))   # an installed guest whose home folder is missing
        r = self.run_tool(["restore", self.out, "--yes"], home, guest)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.isfile(os.path.join(guest, "root/.codex/auth.json")))

    def test_a_linked_own_list_is_refused(self):
        real = os.path.join(self.d, "real-list")
        self.write(self.d, "real-list", "secret guest root/keys\n")
        own = os.path.join(self.home, ".config/termux-rootbridge/backup.list")
        os.remove(own)
        os.symlink(real, own)
        r = self.run_tool(["backup", self.out], self.home, self.guest)
        self.assertEqual(r.returncode, 1)
        self.assertIn("ist ein Link", r.stderr)

    def test_ctrl_c_while_publishing_puts_the_previous_generation_back(self):
        self.backup()
        import importlib.util
        spec = importlib.util.spec_from_file_location("rbbackup3", TOOL)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        mod.HOME = self.home
        mod.PRIVATE = os.path.join(self.home, ".config/termux-rootbridge")
        mod.OWN_LIST = os.path.join(mod.PRIVATE, "backup.list")
        mod.CONFIG = os.path.join(mod.PRIVATE, "config")
        mod.TRUSTED = os.path.join(mod.PRIVATE, "backup.sha256")
        os.environ["BKPW"] = "test"
        os.environ["RB_GUEST_ROOT"] = self.guest
        with open(os.path.join(self.out, "h")) as fh:
            before = fh.read()
        real_replace, calls = os.replace, []

        def replace(src, dst, *a, **k):
            if str(src) == "k.enc" and str(dst) == "k.enc" and not calls:   # publishing, after a.tgz was replaced
                calls.append(1)
                raise KeyboardInterrupt
            return real_replace(src, dst, *a, **k)
        mod.os.replace = replace
        try:
            with self.assertRaises(KeyboardInterrupt):
                mod.backup(self.out)
        finally:
            mod.os.replace = real_replace
        with open(os.path.join(self.out, "h")) as fh:
            self.assertEqual(fh.read(), before)
        r = self.run_tool(["restore", self.out, "--yes"], *self.fresh())   # the folder is whole: it restores
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_ctrl_c_keeps_both_older_generations(self):
        self.backup()
        self.backup()
        with open(os.path.join(self.out, "previous/h")) as fh:
            older = fh.read()
        import importlib.util
        spec = importlib.util.spec_from_file_location("rbbackup4", TOOL)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        mod.HOME = self.home
        mod.PRIVATE = os.path.join(self.home, ".config/termux-rootbridge")
        mod.OWN_LIST = os.path.join(mod.PRIVATE, "backup.list")
        mod.CONFIG = os.path.join(mod.PRIVATE, "config")
        mod.TRUSTED = os.path.join(mod.PRIVATE, "backup.sha256")
        os.environ["BKPW"] = "test"
        os.environ["RB_GUEST_ROOT"] = self.guest
        with open(os.path.join(self.out, "h")) as fh:
            current = fh.read()
        real_replace, fired = os.replace, []

        def replace(src, dst, *a, **k):
            if str(src) == "k.enc" and str(dst) == "k.enc" and not fired:
                fired.append(1)
                raise KeyboardInterrupt   # once, after a.tgz was replaced; the rollback must work
            return real_replace(src, dst, *a, **k)
        mod.os.replace = replace
        try:
            with self.assertRaises(KeyboardInterrupt):
                mod.backup(self.out)
        finally:
            mod.os.replace = real_replace
        with open(os.path.join(self.out, "h")) as fh:
            self.assertEqual(fh.read(), current)
        with open(os.path.join(self.out, "previous/h")) as fh:
            self.assertEqual(fh.read(), older)

    def test_restore_works_where_python_has_no_os_link(self):
        # Python on Android (Termux) has no os.link: the original is then kept as a copy
        self.backup()
        home, guest = self.fresh()
        self.write(guest, "root/.codex/auth.json", "old login")   # an original to keep
        env = dict(os.environ, HOME=home, ROOTBRIDGE_CONFIG=os.path.join(home, ".config/termux-rootbridge/config"),
                   RB_GUEST_ROOT=guest, BKPW="test")
        code = ("import os, runpy, sys; hasattr(os, 'link') and delattr(os, 'link'); sys.argv = [%r, 'restore', %r, '--yes']; "
                "runpy.run_path(%r, run_name='__main__')" % (TOOL, self.out, TOOL))
        r = subprocess.run([sys.executable, "-I", "-c", code], env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(os.path.join(guest, "root/.codex/auth.json")) as fh:
            self.assertEqual(fh.read(), "secret")
        self.assertFalse([n for n in os.listdir(os.path.join(guest, "root/.codex")) if "rootbridge-" in n])

    def test_two_backups_at_once_are_refused(self):
        import fcntl
        priv = os.path.join(self.home, ".config/termux-rootbridge")
        with open(os.path.join(priv, "backup.lock"), "w") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX)
            r = self.run_tool(["backup", self.out], self.home, self.guest)
        self.assertEqual(r.returncode, 1)
        self.assertIn("läuft gerade", r.stderr)

    def test_an_empty_or_unreadable_seal_is_refused(self):
        self.backup()
        home, guest = self.fresh()
        for content in (b"", b"unsinn"):
            with open(os.path.join(self.out, "m"), "wb") as fh:
                fh.write(content)
            r = self.run_tool(["restore", self.out, "--yes", "--legacy"], home, guest, stdin="ja\n")
            self.assertEqual(r.returncode, 1)
            self.assertIn("leer oder unlesbar", r.stderr)
        self.assertFalse(os.path.exists(os.path.join(guest, "root/.claude")))

    def test_exclude_holds_for_restore(self):
        self.backup()
        home, guest = self.fresh()
        self.write(home, ".config/termux-rootbridge/backup.list", "secret guest root/keys\nexclude guest root/keys/a\n")
        r = self.run_tool(["restore", self.out, "--yes"], home, guest)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(os.path.exists(os.path.join(guest, "root/keys/a")))

    def test_no_writing_through_a_link(self):
        self.backup()
        home, guest = self.fresh()
        outside = os.path.join(self.d, "outside")
        os.makedirs(outside)
        os.symlink(outside, os.path.join(guest, "root/.claude"))
        r = self.run_tool(["restore", self.out, "--yes"], home, guest)
        self.assertEqual(r.returncode, 1)
        self.assertIn("ein Link auf dem Weg", r.stderr)
        self.assertEqual(os.listdir(outside), [])

    def test_the_previous_backup_is_kept(self):
        self.backup()
        with open(os.path.join(self.out, "h")) as fh:
            first = fh.read()
        self.backup()
        with open(os.path.join(self.out, "previous/h")) as fh:
            self.assertEqual(fh.read(), first)

    def plant(self, info, data):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w:gz") as tar:
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
        with open(os.path.join(self.out, "a.tgz"), "wb") as fh:
            fh.write(buf.getvalue())
        r = subprocess.run(["sha256sum", "a.tgz", "k.enc"], cwd=self.out, capture_output=True, text=True)
        with open(os.path.join(self.out, "h"), "w") as fh:
            fh.write(r.stdout)

    def test_restore_shows_and_asks(self):
        self.backup()
        home, guest = self.fresh()
        r = self.run_tool(["restore", self.out], home, guest, stdin="n\n")
        self.assertEqual(r.returncode, 1)
        self.assertIn("root/.claude/settings.json ->", r.stdout)
        self.assertFalse(os.path.exists(os.path.join(guest, "root/.claude")))

    def test_without_a_guest_first_termux(self):
        self.backup()
        home = self.make_home("home3")
        r = self.run_tool(["restore", self.out, "--yes"], home, os.path.join(self.d, "noguest"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.isfile(os.path.join(home, ".termux/termux.properties")))
        self.assertIn("Der Gast fehlt noch", r.stdout)

    def test_termux_secrets_without_a_guest(self):
        self.write(self.home, ".config/termux-rootbridge/backup.list", "secret termux .termux/termux.properties\n")
        self.backup()
        home = self.make_home("home4")
        r = self.run_tool(["restore", self.out, "--yes"], home, os.path.join(self.d, "noguest"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.isfile(os.path.join(home, ".termux/termux.properties")))

    def test_an_interrupted_backup_keeps_the_whole_previous(self):
        self.backup()
        self.backup()
        with open(os.path.join(self.out, "previous/h")) as fh:
            first = fh.read()
        with open(os.path.join(self.out, "a.tgz"), "ab") as fh:   # half written, h already new: the seal is old
            fh.write(b"x")
        subprocess.run("sha256sum a.tgz k.enc > h", shell=True, cwd=self.out, check=True)
        self.backup()
        with open(os.path.join(self.out, "previous/h")) as fh:
            self.assertEqual(fh.read(), first)

    def test_a_wrong_password(self):
        self.backup()
        home, guest = self.fresh()
        r = self.run_tool(["restore", self.out, "--yes"], home, guest, BKPW="falsch")
        self.assertEqual(r.returncode, 1)
        self.assertIn("Passwort falsch", r.stderr)


if __name__ == "__main__":
    unittest.main()
