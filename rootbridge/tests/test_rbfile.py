"""Tests for guest/lib/rbfile.py: replace, remove and look beside the marked block of a text file
(run: python3 -I -m unittest)."""
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "guest", "lib", "rbfile.py")

spec = importlib.util.spec_from_file_location("rbfile", SCRIPT)
rbfile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rbfile)

BEGIN = "# >>> termux-rootbridge >>>"
END = "# <<< termux-rootbridge <<<"


class BlockText(unittest.TestCase):
    def test_set_appends_a_new_block_after_an_empty_line(self):
        self.assertEqual(rbfile.set_block("export A=1\n", BEGIN, END, "alias x=y\n"),
                         f"export A=1\n\n{BEGIN}\nalias x=y\n{END}\n")

    def test_set_in_an_empty_file_starts_with_the_block(self):
        self.assertEqual(rbfile.set_block("", BEGIN, END, "alias x=y"), f"{BEGIN}\nalias x=y\n{END}\n")

    def test_set_replaces_the_old_block_and_keeps_the_rest(self):
        old = f"top\n{BEGIN}\nold 1\nold 2\n{END}\nbottom\n"
        self.assertEqual(rbfile.set_block(old, BEGIN, END, "new\n"), f"top\nbottom\n\n{BEGIN}\nnew\n{END}\n")

    def test_set_twice_gives_the_same_file(self):
        once = rbfile.set_block("a\n", BEGIN, END, "x\n")
        self.assertEqual(rbfile.set_block(once, BEGIN, END, "x\n"), once)

    def test_marker_lines_may_carry_whitespace(self):
        text = f"a\n  {BEGIN}  \nx\n\t{END}\nb\n"
        self.assertEqual(rbfile.drop_block(text, BEGIN, END), "a\nb\n")

    def test_drop_removes_the_block_and_normalises_the_last_newline(self):
        self.assertEqual(rbfile.drop_block(f"a\n{BEGIN}\nx\n{END}\nb\n\n\n", BEGIN, END), "a\nb\n")
        self.assertEqual(rbfile.drop_block("a\nb", BEGIN, END), "a\nb\n")

    def test_drop_without_a_block_changes_nothing_but_the_ending(self):
        self.assertEqual(rbfile.drop_block("a\nb\n", BEGIN, END), "a\nb\n")

    def test_a_block_without_end_runs_to_the_end_of_the_file(self):
        self.assertEqual(rbfile.drop_block(f"a\n{BEGIN}\nx\ny\n", BEGIN, END), "a\n")

    def test_has_line_outside_ignores_the_block(self):
        pattern = r"\s*extra-keys\s*[=:]"
        inside = f"a\n{BEGIN}\nextra-keys = [[]]\n{END}\n"
        self.assertFalse(rbfile.has_line_outside(inside, BEGIN, END, pattern))
        self.assertTrue(rbfile.has_line_outside(inside + "  extra-keys: x\n", BEGIN, END, pattern))
        self.assertFalse(rbfile.has_line_outside("# extra-keys = x\n", BEGIN, END, pattern))


class CommandLine(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def path(self, name, text=None):
        p = os.path.join(self.tmp.name, name)
        if text is not None:
            with open(p, "w", encoding="utf-8") as fh:
                fh.write(text)
        return p

    def run_cli(self, *args):
        return subprocess.run([sys.executable, "-I", SCRIPT, *args], capture_output=True, text=True, timeout=30)

    def test_set_writes_the_output_file_and_leaves_the_source(self):
        src, content, out = self.path("src", "keep\n"), self.path("content", "mine\n"), self.path("out")
        r = self.run_cli("set", src, out, BEGIN, END, content)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(out, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), f"keep\n\n{BEGIN}\nmine\n{END}\n")
        with open(src, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), "keep\n")

    def test_drop_works_in_place(self):
        f = self.path("f", f"a\n{BEGIN}\nx\n{END}\n")
        self.assertEqual(self.run_cli("drop", f, BEGIN, END).returncode, 0)
        with open(f, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), "a\n")

    def test_other_reports_through_the_exit_code(self):
        f = self.path("f", f"{BEGIN}\nextra-keys = 1\n{END}\n")
        self.assertEqual(self.run_cli("other", f, BEGIN, END, r"\s*extra-keys\s*[=:]").returncode, 1)
        g = self.path("g", f"extra-keys = 2\n{BEGIN}\nx\n{END}\n")
        self.assertEqual(self.run_cli("other", g, BEGIN, END, r"\s*extra-keys\s*[=:]").returncode, 0)

    def test_wrong_usage_is_an_error_with_the_help_text(self):
        for args in ([], ["frobnicate"], ["drop", "only-one"]):
            with self.subTest(args=args):
                r = self.run_cli(*args)
                self.assertEqual(r.returncode, 2)
                self.assertIn("rbfile.py set", r.stderr)


if __name__ == "__main__":
    unittest.main()
