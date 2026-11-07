"""Tests for guest/claude/auth-url-hook.py (run: python3 -I -m unittest)."""
import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HOOK = os.path.join(HERE, "..", "guest", "claude", "auth-url-hook.py")

spec = importlib.util.spec_from_file_location("authhook", HOOK)
authhook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(authhook)

LONG = ("https://mcp.slack.com/oauth/authorize?client_id=1234567890.0987654321"
        "&redirect_uri=http%3A%2F%2Flocalhost%3A38555%2Fcallback&response_type=code"
        "&state=abcDEF123_-xyz&code_challenge=" + "A" * 43 +
        "&code_challenge_method=S256&scope=search%3Aread+chat%3Awrite")


class TestFindUrls(unittest.TestCase):
    def test_plain_string(self):
        self.assertEqual(authhook.find_urls("Öffne %s bitte" % LONG), [LONG])

    def test_mcp_content_list(self):
        resp = [{"type": "text", "text": "Authorize here: " + LONG}]
        self.assertEqual(authhook.find_urls(resp), [LONG])

    def test_nested_dict_and_json_string(self):
        resp = {"content": [{"type": "text",
                             "text": json.dumps({"authorization_url": LONG})}]}
        # json.dumps escapes nothing here, but make sure we still find it
        self.assertIn(LONG, authhook.find_urls(resp))

    def test_escaped_json(self):
        escaped = LONG.replace("&", "\\u0026").replace("/", "\\/")
        self.assertEqual(authhook.find_urls("x " + escaped + " y"), [LONG])

    def test_markdown_and_punctuation(self):
        self.assertEqual(authhook.find_urls("[Link](%s)." % LONG), [LONG])
        self.assertEqual(authhook.find_urls("**%s**" % LONG), [LONG])
        self.assertEqual(authhook.find_urls("(%s)" % LONG), [LONG])

    def test_no_url(self):
        self.assertEqual(authhook.find_urls({"a": ["kein Link", 3, None]}), [])
        self.assertEqual(authhook.find_urls(None), [])

    def test_deep_nesting_does_not_crash(self):
        obj = cur = {}
        for _ in range(50):
            cur["x"] = {}
            cur = cur["x"]
        cur["u"] = LONG
        self.assertEqual(authhook.find_urls(obj), [])   # beyond the depth limit


class TestPick(unittest.TestCase):
    def test_prefers_oauth_url(self):
        urls = ["https://docs.example.com/help", LONG, "https://a.io/x"]
        self.assertEqual(authhook.pick_url(urls), LONG)

    def test_rejects_non_https_and_bad_chars(self):
        self.assertIsNone(authhook.pick_url(["http://example.com/a"]))
        self.assertIsNone(authhook.pick_url(["https://exa mple.com/"]))
        self.assertIsNone(authhook.pick_url(["https://example.com/" + "a" * 9000]))

    def test_host(self):
        self.assertEqual(authhook.host_of(LONG), "mcp.slack.com")
        self.assertEqual(authhook.host_of("https://a.b:8443/x?y#z"), "a.b")


class TestEntryPoint(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.log = os.path.join(self.tmp.name, "calls.log")
        self.fake = os.path.join(self.tmp.name, "fake-open")
        with open(self.fake, "w") as fh:
            fh.write('#!/bin/sh\necho "$@" >> "%s"\nexit ${FAKE_RC:-0}\n' % self.log)
        os.chmod(self.fake, os.stat(self.fake).st_mode | stat.S_IEXEC)

    def run_hook(self, payload, **env):
        e = dict(os.environ)
        e.update({"ROOTBRIDGE_OPEN": self.fake,
                  "ROOTBRIDGE_CONF": os.path.join(self.tmp.name, "none.conf")})
        e.update(env)
        r = subprocess.run([sys.executable, "-I", HOOK],
                           input=json.dumps(payload), capture_output=True,
                           text=True, env=e)
        self.assertEqual(r.returncode, 0)
        return json.loads(r.stdout) if r.stdout.strip() else None

    def calls(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log) as fh:
            return fh.read().splitlines()

    def payload(self, tool="mcp__claude_ai_Slack__authenticate", resp=None):
        return {"hook_event_name": "PostToolUse", "tool_name": tool,
                "tool_input": {},
                "tool_response": resp if resp is not None else
                [{"type": "text", "text": "Authorize: " + LONG}]}

    def test_auto_opens_and_instructs(self):
        out = self.run_hook(self.payload())
        self.assertEqual(self.calls(), [LONG])
        spec_ = out["hookSpecificOutput"]
        self.assertEqual(spec_["hookEventName"], "PostToolUse")
        self.assertIn("NICHT", spec_["additionalContext"])
        self.assertNotIn(LONG, json.dumps(out))
        self.assertNotIn("updatedToolOutput", spec_)
        self.assertIn("mcp.slack.com", out["systemMessage"])

    def test_replace_output_switch(self):
        out = self.run_hook(self.payload(), AUTH_REPLACE_OUTPUT="1")
        self.assertIn("mcp.slack.com", out["hookSpecificOutput"]["updatedToolOutput"])
        self.assertNotIn(LONG, out["hookSpecificOutput"]["updatedToolOutput"])

    def test_copy_mode_only_copies(self):
        self.run_hook(self.payload(), AUTH_OPEN="copy")
        self.assertEqual(self.calls(), ["--copy-only " + LONG])

    def test_off_does_nothing(self):
        self.assertIsNone(self.run_hook(self.payload(), AUTH_OPEN="off"))
        self.assertEqual(self.calls(), [])

    def test_other_tools_ignored(self):
        self.assertIsNone(self.run_hook(self.payload(tool="Bash")))
        self.assertIsNone(self.run_hook(self.payload(tool="mcp__x__search")))
        self.assertEqual(self.calls(), [])

    def test_complete_authentication_without_url_is_silent(self):
        out = self.run_hook(self.payload(
            tool="mcp__x__complete_authentication",
            resp=[{"type": "text", "text": "Authentication successful"}]))
        self.assertIsNone(out)
        self.assertEqual(self.calls(), [])

    def test_failed_open_keeps_url_visible(self):
        out = self.run_hook(self.payload(), FAKE_RC="1", AUTH_REPLACE_OUTPUT="1")
        self.assertNotIn("hookSpecificOutput", out)
        self.assertIn("konnte nicht automatisch", out["systemMessage"])

    def test_http_url_is_not_opened(self):
        out = self.run_hook(self.payload(resp="http://evil.example/login"))
        self.assertIsNone(out)
        self.assertEqual(self.calls(), [])

    def test_garbage_input_is_silent(self):
        r = subprocess.run([sys.executable, "-I", HOOK], input="{kaputt",
                           capture_output=True, text=True)
        self.assertEqual((r.returncode, r.stdout), (0, ""))


if __name__ == "__main__":
    unittest.main()
