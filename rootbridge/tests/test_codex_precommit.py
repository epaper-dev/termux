"""Tests for guest/claude/codex-precommit-review.py, the PreToolUse hook that lets Codex review every `git commit`.

The Codex plugin is faked: a stub `node` prints the reply the test wants, so nothing leaves the machine. Real git
repositories (in a temp dir, with HOME pointing there) are used for the diffs. What is pinned down:

  * only a `git commit` that is RUN is reviewed (text in quotes or heredocs is not), and CODEX_PRECOMMIT=off (the
    user's emergency switch) skips the review
  * the strict loop: ALLOW lets the commit through and remembers the diff; BLOCK blocks with Codex's findings and
    remembers NOTHING, so the same commit is blocked again until the diff changed and Codex says ALLOW
  * fail closed: no node / no plugin / a crashing or empty Codex blocks the commit (exit 2), and so does a git that
    fails or cannot be run; a binary change is reviewed, not skipped
  * files that only a `git add` in the same command brings in (they are in no diff) are reviewed too, and Codex is
    told which they are
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "guest", "claude", "codex-precommit-review.py")


def tool(name):
    path = shutil.which(name)
    if not path:
        raise unittest.SkipTest(f"{name} fehlt")
    return path


FAKE_NODE = """#!/bin/bash
# stub node: logs the call, answers with $FAKE_REPLY like codex-companion's `task --json`
echo "node $1 $2" >> "$FAKE_LOG"
printf '%s' "${@: -1}" > "${FAKE_PROMPT:-/dev/null}"
printf '%s\n' "${@:2:$(($# - 2))}" > "${FAKE_PROMPT:-/dev/null}.args"
[ -z "${FAKE_FAIL:-}" ] || { echo "boom" >&2; exit 1; }
PYTHON_BIN -I -c 'import json, os; print(json.dumps({"rawOutput": os.environ.get("FAKE_REPLY", "")}))'
"""


class HookTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="codex-precommit-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home = os.path.join(self.tmp, "home")
        self.bin = os.path.join(self.tmp, "bin")
        self.log = os.path.join(self.tmp, "node.log")
        self.prompt_file = os.path.join(self.tmp, "prompt.txt")
        os.makedirs(self.bin)
        plugin = os.path.join(self.home, ".claude/plugins/cache/openai-codex/codex/1.0.6/scripts")
        os.makedirs(plugin)
        open(os.path.join(plugin, "codex-companion.mjs"), "w").close()
        with open(os.path.join(self.bin, "node"), "w") as fh:
            fh.write(FAKE_NODE.replace("PYTHON_BIN", sys.executable))
        os.chmod(os.path.join(self.bin, "node"), 0o755)
        # PATH of the hook: the stub node plus git and which, nothing else
        self.bare = os.path.join(self.tmp, "bare")
        os.makedirs(self.bare)
        for name in ("git", "which"):
            os.symlink(tool(name), os.path.join(self.bare, name))
        self.repo = self.new_repo("repo")

    def new_repo(self, name, content="x = 1\n"):
        repo = os.path.join(self.tmp, name)
        os.makedirs(repo)
        subprocess.run([tool("git"), "init", "-q"], cwd=repo, check=True)
        self.write(repo, "a.py", content)
        return repo

    def write(self, repo, name, content):
        with open(os.path.join(repo, name), "w") as fh:
            fh.write(content)
        subprocess.run([tool("git"), "add", name], cwd=repo, check=True)

    def run_hook(self, command="git commit -m x", cwd=None, reply="ALLOW: ok", with_node=True, path=None, **extra):
        env = {
            "HOME": self.home,
            "PATH": path or (self.bin + os.pathsep if with_node else "") + self.bare,
            "FAKE_LOG": self.log,
            "FAKE_PROMPT": self.prompt_file,
            "FAKE_REPLY": reply,
        }
        env.update(extra)
        data = {"tool_input": {"command": command}, "cwd": cwd or self.repo}
        return subprocess.run([sys.executable, "-I", SCRIPT], input=json.dumps(data), env=env,
                              capture_output=True, text=True, timeout=120)

    def node_calls(self):
        try:
            with open(self.log) as fh:
                return len(fh.read().splitlines())
        except OSError:
            return 0

    def state_files(self):
        d = os.path.join(self.home, ".claude", "codex-precommit")
        try:
            return [f for f in os.listdir(d) if f != "hook.log"]
        except OSError:
            return []

    # ------------------------------------------------------------------ what is reviewed
    def test_other_commands_are_not_reviewed(self):
        r = self.run_hook(command="ls -la")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self.node_calls(), 0)

    def test_emergency_switch_skips_the_review(self):
        r = self.run_hook(reply="BLOCK: no", CODEX_PRECOMMIT="off")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self.node_calls(), 0)

    def test_nothing_to_review_without_a_diff(self):
        empty = os.path.join(self.tmp, "empty")
        os.makedirs(empty)
        subprocess.run([tool("git"), "init", "-q"], cwd=empty, check=True)
        r = self.run_hook(cwd=empty)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self.node_calls(), 0)

    def test_not_a_git_repository_is_left_alone(self):
        plain = os.path.join(self.tmp, "plain")
        os.makedirs(plain)
        r = self.run_hook(cwd=plain)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self.node_calls(), 0)

    def test_git_C_and_cd_find_the_repository(self):
        elsewhere = os.path.join(self.tmp, "elsewhere")
        os.makedirs(elsewhere)
        for command in (f"git -C {self.repo} commit -m x", f"cd {self.repo} && git commit -m x"):
            r = self.run_hook(command=command, cwd=elsewhere, reply="BLOCK: bad")
            self.assertEqual(r.returncode, 2, command)
            self.assertIn("BLOCK: bad", r.stderr, command)

    def test_subshell_context_blocks_instead_of_reviewing_the_wrong_repository(self):
        plain = os.path.join(self.tmp, "plain")
        os.makedirs(plain)
        for command, cwd in (
            ("(git commit -m x)", self.repo),
            (f"(cd {plain} && pwd); git commit -m x", self.repo),
            (f"(cd {self.repo} && git commit -m x)", plain),
            (f"(cd {plain} && pwd); git \"commit\" -m x", self.repo),
            (f"bash -c '(cd {plain} && pwd); git commit -m x'", self.repo),
            ("(pwd); bash -c 'git commit -m x'", self.repo),
            ('(pwd); echo "$(git commit -m x)"', self.repo),
        ):
            with self.subTest(command=command):
                r = self.run_hook(command=command, cwd=cwd, reply="ALLOW: wrong repository")
                self.assertEqual(r.returncode, 2)
                self.assertIn("Shell-Kontext", r.stderr)
        self.assertEqual(self.node_calls(), 0)
        self.assertEqual(self.state_files(), [])

    def test_grouping_without_a_commit_does_not_block(self):
        r = self.run_hook(command='(echo "git commit"); pwd')
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self.node_calls(), 0)

    def test_text_that_only_mentions_a_commit_is_not_reviewed(self):
        for command in (
            'echo "git commit -m x"',
            "printf '%s' 'git commit'",
            "python3 -I - <<'PYEND'\nprint('git commit')\nPYEND",
            "cat > notes.md <<EOF\ngit commit -m x\nEOF",
            "gh pr create --body 'then run git commit'",
        ):
            r = self.run_hook(command=command, reply="BLOCK: must not be asked")
            self.assertEqual(r.returncode, 0, command)
        self.assertEqual(self.node_calls(), 0)

    def test_a_commit_after_a_heredoc_is_still_reviewed(self):
        r = self.run_hook(command="cat > f <<'EOF'\nhello\nEOF\ngit commit -m x", reply="BLOCK: bad")
        self.assertEqual(r.returncode, 2)

    def test_an_unparsable_command_falls_back_to_the_text_search(self):
        r = self.run_hook(command='git commit -m "unbalanced', reply="BLOCK: bad")
        self.assertEqual(r.returncode, 2)                  # better one review too many than a commit without
        self.assertEqual(self.node_calls(), 1)
        r = self.run_hook(command='echo "unbalanced commit', reply="BLOCK: bad")
        self.assertEqual(r.returncode, 0)                  # no git commit in the text: nothing to review

    # ------------------------------------------------------------------ what is inspected, and when it cannot be
    def fresh_repo(self, name="fresh"):
        """A repository with ONE untracked file and nothing staged: in no diff at all."""
        repo = os.path.join(self.tmp, name)
        os.makedirs(repo)
        subprocess.run([tool("git"), "init", "-q"], cwd=repo, check=True)
        with open(os.path.join(repo, "n.py"), "w") as fh:
            fh.write("y = 1\n")
        return repo

    def prompt(self):
        with open(self.prompt_file) as fh:
            return fh.read()

    def test_a_binary_change_is_reviewed_not_skipped(self):
        with open(os.path.join(self.repo, "blob.bin"), "wb") as fh:
            fh.write(b"\xff\xfe\x00\x80 binary")
        subprocess.run([tool("git"), "add", "blob.bin"], cwd=self.repo, check=True)
        r = self.run_hook(reply="BLOCK: bad")             # a binary diff is not UTF-8: it used to end as "skipped"
        self.assertEqual(r.returncode, 2)
        self.assertEqual(self.node_calls(), 1)

    def test_other_binary_content_is_another_diff(self):
        blob = os.path.join(self.repo, "blob.bin")
        with open(blob, "wb") as fh:
            fh.write(b"\xff\xfe\x00\x80 AAAA")
        subprocess.run([tool("git"), "add", "blob.bin"], cwd=self.repo, check=True)
        self.assertEqual(self.run_hook(reply="ALLOW: ok").returncode, 0)
        with open(blob, "wb") as fh:                       # same size, same "Binary files differ" line in a plain diff
            fh.write(b"\xff\xfe\x00\x80 BBBB")
        subprocess.run([tool("git"), "add", "blob.bin"], cwd=self.repo, check=True)
        self.assertEqual(self.run_hook(reply="BLOCK: new content").returncode, 2)

    def test_a_failing_git_blocks(self):
        real = os.readlink(os.path.join(self.bare, "git"))
        os.remove(os.path.join(self.bare, "git"))
        with open(os.path.join(self.bare, "git"), "w") as fh:
            fh.write(f'#!/bin/bash\n[ "$1" = diff ] && {{ echo boom >&2; exit 3; }}\nexec {real} "$@"\n')
        os.chmod(os.path.join(self.bare, "git"), 0o755)
        r = self.run_hook()
        self.assertEqual(r.returncode, 2)
        self.assertIn("fehlgeschlagen", r.stderr)
        self.assertEqual(self.node_calls(), 0)
        self.assertEqual(self.state_files(), [])

    def test_a_git_that_cannot_be_run_blocks(self):
        r = self.run_hook(path=self.bin)                    # node, but no git on the PATH
        self.assertEqual(r.returncode, 2)
        self.assertIn("erforderlich", r.stderr)

    def test_new_files_staged_by_the_same_command_are_reviewed(self):
        repo = self.fresh_repo()
        r = self.run_hook(command="git add n.py && git commit -m x", cwd=repo, reply="BLOCK: bad")
        self.assertEqual(r.returncode, 2)                   # in no diff, but the commit would contain it
        self.assertEqual(self.node_calls(), 1)
        self.assertIn("n.py", self.prompt())
        self.assertIn("untracked", self.prompt())
        self.assertIn("<compact_output_contract>", self.prompt())

    def test_untracked_files_are_ignored_without_a_git_add(self):
        repo = self.fresh_repo()
        r = self.run_hook(command="git commit -m x", cwd=repo, reply="BLOCK: must not be asked")
        self.assertEqual(r.returncode, 0)                    # nothing staged, nothing to commit: nothing to review
        self.assertEqual(self.node_calls(), 0)

    def test_a_changed_untracked_file_is_reviewed_again(self):
        repo = self.fresh_repo()
        command = "git add -A && git commit -m x"
        self.assertEqual(self.run_hook(command=command, cwd=repo, reply="ALLOW: ok").returncode, 0)
        self.assertEqual(self.run_hook(command=command, cwd=repo, reply="BLOCK: no").returncode, 0)   # same state
        with open(os.path.join(repo, "n.py"), "w") as fh:
            fh.write("y = 2\n")
        self.assertEqual(self.run_hook(command=command, cwd=repo, reply="BLOCK: changed").returncode, 2)

    def test_the_review_runs_with_effort_high(self):
        # Standard der gehärteten Fassung: high (Termux-Original: xhigh, dort ist es nicht einstellbar).
        self.assertEqual(self.run_hook(reply="BLOCK: bad").returncode, 2)
        with open(self.prompt_file + ".args") as fh:
            self.assertEqual(fh.read().split(), ["task", "--json", "--effort", "high"])

    def test_no_untracked_list_when_there_are_none(self):
        self.assertEqual(self.run_hook(command="git add -A && git commit -m x", reply="BLOCK: bad").returncode, 2)
        self.assertNotIn("untracked_files", self.prompt())

    # ------------------------------------------------------------------ the strict loop
    def test_allow_lets_the_commit_through_and_is_remembered(self):
        r = self.run_hook(reply="ALLOW: fine")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self.node_calls(), 1)
        self.assertEqual(len(self.state_files()), 1)
        r = self.run_hook(reply="BLOCK: would be new")      # the same diff: no second review
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self.node_calls(), 1)

    def test_block_stops_the_commit_and_remembers_nothing(self):
        r = self.run_hook(reply="BLOCK: bug\n- [high] a.py:1 - wrong")
        self.assertEqual(r.returncode, 2)
        self.assertIn("a.py:1", r.stderr)
        self.assertEqual(self.state_files(), [])

    def test_the_same_blocked_commit_is_blocked_again(self):
        for _ in range(3):
            r = self.run_hook(reply="BLOCK: still wrong")
            self.assertEqual(r.returncode, 2)
        self.assertEqual(self.node_calls(), 3)               # reviewed every time, never waved through
        self.assertEqual(self.state_files(), [])

    def test_fixing_the_diff_leads_to_a_new_review_and_through(self):
        self.assertEqual(self.run_hook(reply="BLOCK: wrong").returncode, 2)
        self.write(self.repo, "a.py", "x = 2\n")             # Claude's fix: a new diff
        r = self.run_hook(reply="ALLOW: fixed")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self.node_calls(), 2)

    def test_an_unclear_reply_blocks(self):
        r = self.run_hook(reply="Looks fine to me")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(self.state_files(), [])

    def test_a_changed_diff_after_allow_is_reviewed_again(self):
        self.assertEqual(self.run_hook(reply="ALLOW: ok").returncode, 0)
        self.write(self.repo, "a.py", "x = 3\n")
        self.assertEqual(self.run_hook(reply="BLOCK: now bad").returncode, 2)

    def test_each_repository_has_its_own_state(self):
        other = self.new_repo("other")
        self.assertEqual(self.run_hook(reply="ALLOW: ok").returncode, 0)
        r = self.run_hook(cwd=other, reply="BLOCK: other")
        self.assertEqual(r.returncode, 2)

    # ------------------------------------------------------------------ fail closed
    def test_no_node_blocks(self):
        r = self.run_hook(with_node=False)
        self.assertEqual(r.returncode, 2)
        self.assertIn("erforderlich", r.stderr)

    def test_no_plugin_blocks(self):
        shutil.rmtree(os.path.join(self.home, ".claude", "plugins"))
        r = self.run_hook()
        self.assertEqual(r.returncode, 2)
        self.assertIn("erforderlich", r.stderr)

    def test_a_crashing_codex_blocks_after_two_attempts(self):
        r = self.run_hook(FAKE_FAIL="1")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(self.node_calls(), 2)
        self.assertEqual(self.state_files(), [])

    def test_an_empty_reply_blocks(self):
        r = self.run_hook(reply="")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(self.state_files(), [])


def load_hook():
    spec = importlib.util.spec_from_file_location("codex_precommit_review", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DetectionTest(unittest.TestCase):
    """find_commit: what counts as a `git commit` (and where it runs), without starting the hook each time."""
    CWD = "/work/repo"

    @classmethod
    def setUpClass(cls):
        cls.hook = load_hook()

    def find(self, command, cwd=CWD):
        return self.hook.find_commit(command, cwd)

    def test_these_are_commits_in_the_working_directory(self):
        for command in (
            "git commit", "git commit -m x", "git commit -am 'fix: a ; b && c'", "git  commit   -m x",
            "/usr/bin/git commit -m x", "git --no-pager commit", "git -c user.name=x -c user.email=y commit -m z",
            "git --git-dir=/x/.git commit", 'git "commit" -m x', 'git commit -m "it\'s fine"',
            "GIT_AUTHOR_NAME=x git commit -m x", "env GIT_AUTHOR_NAME=x git commit -m x", "env -i HOME=/x git commit",
            "sudo git commit -m x", "sudo -u bob git commit -m x", "time git commit -m x", "command git commit",
            "nohup git commit -m x", "timeout 60 git commit -m x", "xargs -I {} git commit -m {}",
            "git add -A && git commit -m x", "git add -A; git commit -m x", "false || git commit -m x",
            "echo a | git commit -F -", "echo a & git commit", "{ git commit -m x; }",
            "if true; then git commit -m x; fi", "for f in a b; do git commit -m $f; done", "! git commit",
            "echo a\ngit commit -m x", "git \\\n  commit -m x", "git commit -m 'a' # note",
            "cat <<'EOF' > f\nhello\nEOF\ngit commit -m x", "python3 - <<'PY'\nprint(1)\nPY\ngit commit",
            "bash -c 'git commit -m x'", 'sh -c "git commit -m x"', "bash -lc 'git commit -m x'",
            "bash -o pipefail -c 'git commit'", "sudo bash -c 'git commit'", "eval 'git commit -m x'",
            'echo "$(git commit -m x)"', "echo `git commit -m x`", "x=$(git commit -m x)",
            "cat <<EOF\n$(git commit -m x)\nEOF",
        ):
            with self.subTest(command=command):
                self.assertEqual(self.find(command), self.CWD)

    def test_these_are_not_commits(self):
        for command in (
            "git status", "git log --oneline", "git commit-tree HEAD^{tree}", "git commit-graph write",
            "git add commit", 'echo "git commit -m x"', "echo git commit", "printf '%s\\n' 'git commit'",
            'grep -rn "git commit" .', "gh pr create --title t --body 'run git commit first'",
            'git log --grep="git commit"', "cat <<'EOF'\ngit commit -m x\nEOF", "cat <<EOF\ngit commit -m x\nEOF",
            "cat <<-EOF\n\tgit commit -m x\n\tEOF", "python3 -I - <<'PYEND'\ns = 'git commit'\nPYEND",
            "# git commit later", "ls # git commit", "echo ok; # git commit", "man git commit", "which git",
            "ssh host git commit", "echo $(echo git commit)", "bash script.sh", "bash -c 'echo git commit'",
            "echo a | grep commit", 'git diff && echo "done, now git commit"', "/tmp/git-commit-helper", "mygit commit",
            "git",
        ):
            with self.subTest(command=command):
                self.assertIsNone(self.find(command))

    def test_where_the_commit_runs(self):
        for command, expected in (
            ("cd /tmp && git commit", "/tmp"),
            ("cd sub && git commit", "/work/repo/sub"),
            ("git -C /x commit", "/x"),
            ("git -C sub commit", "/work/repo/sub"),
            ("git -C a -C b commit", "/work/repo/a/b"),
            ("cd /a && git -C b commit", "/a/b"),
            ("bash -c 'cd /tmp && git commit'", "/tmp"),
            ("cd -- /tmp && git commit", "/tmp"),
            ("cd ~ && git commit", os.path.expanduser("~")),
        ):
            with self.subTest(command=command):
                self.assertEqual(self.find(command), expected)

    def test_a_git_add_before_the_commit_is_noticed(self):
        for command, adds in (
            ("git commit -m x", False), ("git commit -a -m x", False), ("git add -A && git commit -m x", True),
            ("git add f; git commit", True), ("git stage f && git commit", True),
            ("bash -c 'git add . && git commit -m x'", True), ("git commit -m x && git add y", False),
            ("cd d && git -C e add . && git commit", True), ("echo add && git commit", False),
        ):
            with self.subTest(command=command):
                self.assertEqual(self.hook.analyze(command, self.CWD), (self.CWD, adds) if "cd d" not in command
                                 else ("/work/repo/d", adds))

    def test_a_commit_hidden_behind_broken_quoting_is_an_error_not_a_pass(self):
        for command in ('git commit -m "oops', "git commit -m 'oops", "echo $(git commit"):
            with self.subTest(command=command):
                with self.assertRaises(ValueError):
                    self.find(command)

    def test_plugin_versions_are_compared_as_numbers(self):
        with tempfile.TemporaryDirectory() as home:
            for version in ("1.0.2", "1.0.9", "1.0.10"):
                d = os.path.join(home, ".claude/plugins/cache/openai-codex/codex", version, "scripts")
                os.makedirs(d)
                open(os.path.join(d, "codex-companion.mjs"), "w").close()
            with mock.patch.dict(os.environ, {"HOME": home}):
                self.assertTrue(self.hook.find_companion().endswith("/1.0.10/scripts/codex-companion.mjs"))
            with mock.patch.dict(os.environ, {"HOME": os.path.join(home, "keiner")}):
                self.assertIsNone(self.hook.find_companion())


if __name__ == "__main__":
    unittest.main()
