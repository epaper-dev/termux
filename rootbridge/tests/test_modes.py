"""Repository hygiene (run: python3 -I -m unittest discover -s tests).

* every tracked file with a shebang must be executable (100755) in the git index
  - on /sdcard chmod does nothing, so `bash tools/fix-modes.sh` sets it
* no build artifacts (__pycache__, *.pyc) may be tracked
"""
import os
import subprocess
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def git(*args):
    return subprocess.run(["git", "-C", ROOT] + list(args),
                          capture_output=True, text=True)


class TestRepoHygiene(unittest.TestCase):
    def setUp(self):
        try:
            res = git("rev-parse", "--is-inside-work-tree")
        except OSError:
            self.skipTest("git nicht verfügbar")
        if res.returncode != 0 or res.stdout.strip() != "true":
            self.skipTest("kein Git-Arbeitsbaum")

    def tracked(self):
        out = git("ls-files", "-s", "-z").stdout
        entries = []
        for rec in out.split("\0"):
            if rec:
                meta, path = rec.split("\t", 1)
                entries.append((meta.split()[0], path))
        return entries

    def test_shebang_files_are_executable_in_index(self):
        bad = []
        for mode, path in self.tracked():
            if mode == "120000":
                continue
            try:
                with open(os.path.join(ROOT, path), "rb") as fh:
                    head = fh.read(2)
            except OSError:
                continue
            if head == b"#!" and mode != "100755":
                bad.append("%s (%s)" % (path, mode))
        self.assertEqual(bad, [], "Skripte ohne Ausführungsrecht im Index - "
                         "`bash tools/fix-modes.sh` ausführen")

    def test_no_build_artifacts_tracked(self):
        bad = [p for _, p in self.tracked()
               if "__pycache__" in p or p.endswith((".pyc", ".pyo"))]
        self.assertEqual(bad, [], "Build-Artefakte sind versioniert")


if __name__ == "__main__":
    unittest.main()
