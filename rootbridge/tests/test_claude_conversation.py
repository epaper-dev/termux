import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[1] / "guest/claude/claude-conversation.py"
spec = importlib.util.spec_from_file_location("claude_conversation", HELPER)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
SID = "12345678-1234-1234-1234-123456789abc"


class ConversationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.config = Path(self.temp.name) / "custom-claude"
        self.work = Path(self.temp.name) / "work"
        self.work.mkdir()
        self.project = self.config / "projects/encoded-project"
        self.project.mkdir(parents=True)
        self.transcript = self.project / (SID + ".jsonl")

    def message(self, **overrides):
        entry = dict(type="user", sessionId=SID, cwd=str(self.work),
                     message=dict(role="user", content="hello"))
        entry.update(overrides)
        return entry

    def write(self, entries):
        self.transcript.write_text("\n".join(json.dumps(entry) for entry in entries)+"\n")

    def exists(self):
        return module.has_conversation(self.config, self.work)

    def test_no_transcript(self):
        self.assertFalse(self.exists())

    def test_empty_or_metadata_only(self):
        self.transcript.touch()
        self.assertFalse(self.exists())
        self.write([dict(type="queue-operation", sessionId=SID, cwd=str(self.work))])
        self.assertFalse(self.exists())

    def test_valid_custom_config(self):
        self.write([self.message()])
        self.assertTrue(self.exists())

    def test_other_working_directory(self):
        self.write([self.message(cwd=str(self.work.parent))])
        self.assertFalse(self.exists())

    def test_symlink_working_directory(self):
        alias = self.work.parent / "alias"
        alias.symlink_to(self.work, target_is_directory=True)
        self.write([self.message(cwd=str(alias))])
        self.assertTrue(self.exists())

    def test_sidechain_does_not_count(self):
        self.write([self.message(isSidechain=True)])
        self.assertFalse(self.exists())

    def test_nested_subagent_does_not_count(self):
        self.write([self.message()])
        nested = self.project / "session/subagents"
        nested.mkdir(parents=True)
        self.transcript.rename(nested / self.transcript.name)
        self.assertFalse(self.exists())

    def test_bad_session_id(self):
        self.write([self.message(sessionId="different")])
        self.assertFalse(self.exists())

    def test_empty_message(self):
        self.write([self.message(message=dict(role="user", content=[]))])
        self.assertFalse(self.exists())

    def test_malformed_record_before_valid_message(self):
        self.transcript.write_text('broken\n[]\n'+json.dumps(self.message())+'\n')
        self.assertTrue(self.exists())

    def test_invalid_filename_does_not_count(self):
        self.write([self.message()])
        self.transcript.rename(self.project / "settings.jsonl")
        self.assertFalse(self.exists())


if __name__ == "__main__":
    unittest.main()
