#!/usr/bin/env python3
import contextlib
import io
import json
import os
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import merge_agent_hooks as hooks


def quiet(function, *args):
    with contextlib.redirect_stdout(io.StringIO()):
        return function(*args)


class InstallerTests(unittest.TestCase):

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = self.directory.name

    def path(self, name):
        return os.path.join(self.root, name)

    def write_json(self, name, value, mode=0o600):
        path = self.path(name)
        with open(path, "w") as f:
            json.dump(value, f)
        os.chmod(path, mode)
        return path

    def write_text(self, name, value, mode=0o600):
        path = self.path(name)
        with open(path, "w") as f:
            f.write(value)
        os.chmod(path, mode)
        return path

    def read_text(self, path):
        with open(path) as f:
            return f.read()

    def read_json(self, path):
        with open(path) as f:
            return json.load(f)

    def claude_snippet(self):
        return self.write_json("snippet.json", {
            "hooks": {
                "PreToolUse": [{
                    "hooks": [{"type": "command", "command": "new-hook claude"}]
                }]
            }
        })

    def test_wrong_typed_event_is_replaced(self):
        path = self.write_json("settings.json", {"hooks": {"PreToolUse": {"foo": 1}}})
        quiet(hooks.install_claude, path, self.claude_snippet())
        settings = self.read_json(path)
        entries = settings["hooks"]["PreToolUse"]
        self.assertIsInstance(entries, list)
        self.assertNotIn("foo", entries)
        self.assertEqual(entries[0]["hooks"][0]["command"], "new-hook claude")

    def test_existing_mode_is_preserved(self):
        path = self.write_json("settings.json", {}, mode=0o600)
        quiet(hooks.install_claude, path, self.claude_snippet())
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)

    def test_unreadable_settings_are_not_overwritten(self):
        if os.geteuid() == 0:
            self.skipTest("root can read chmod 000 files")
        path = self.write_json("settings.json", {"permissions": {"allow": ["x"]}})
        os.chmod(path, 0o000)
        quiet(hooks.install_claude, path, self.claude_snippet())
        os.chmod(path, 0o600)
        with open(path) as f:
            self.assertEqual(json.load(f), {"permissions": {"allow": ["x"]}})
        self.assertFalse(os.path.exists(path + ".bak-agentbridge"))

    def test_codex_upgrade_removes_python_and_stale_swift_entries(self):
        path = self.write_json("hooks.json", {
            "hooks": {
                "Stop": [
                    {"hooks": [{"type": "command",
                                "command": "/usr/bin/python3 ~/.agentbridge/hooks/agentbridge-hook.py codex"}]},
                    {"hooks": [{"type": "command",
                                "command": "old/agentbridge-hook codex"}]},
                    {"hooks": [{"type": "command", "command": "user-hook"}]},
                ]
            }
        })
        template = self.write_text("template.json", json.dumps({
            "hooks": {
                "Stop": [{"hooks": [{"type": "command", "command": "@@HOOK_PATH@@ codex"}]}]
            }
        }))
        quiet(hooks.install_codex, path, template, "new/agentbridge-hook")
        entries = self.read_json(path)["hooks"]["Stop"]
        commands = [entry["hooks"][0]["command"] for entry in entries]
        self.assertNotIn("/usr/bin/python3 ~/.agentbridge/hooks/agentbridge-hook.py codex", commands)
        self.assertNotIn("old/agentbridge-hook codex", commands)
        self.assertIn("user-hook", commands)
        self.assertIn("new/agentbridge-hook codex", commands)

    def test_config_migration_backs_up_and_rewrites(self):
        original = ('[[hooks.Stop]]\n'
                    '[[hooks.Stop.hooks]]\n'
                    'type = "command"\n'
                    'command = "/usr/bin/python3 $HOME/.agentbridge/hooks/agentbridge-hook.py codex"\n')
        path = self.write_text("config.toml", original)
        quiet(hooks.migrate_codex_config_toml, path, "new/agentbridge-hook")
        rewritten = self.read_text(path)
        self.assertIn("new/agentbridge-hook codex", rewritten)
        self.assertNotIn("agentbridge-hook.py", rewritten)
        self.assertTrue(os.path.exists(path + ".bak-agentbridge"))
        self.assertEqual(self.read_text(path + ".bak-agentbridge"), original)
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)

    def test_remove_hooks_json_keeps_user_entries(self):
        path = self.write_json("hooks.json", {
            "hooks": {
                "Stop": [
                    {"hooks": [{"type": "command", "command": "agentbridge-hook codex"}]},
                    {"hooks": [{"type": "command", "command": "user-hook"}]},
                ]
            }
        })
        quiet(hooks.remove_codex_hooks, path)
        entries = self.read_json(path)["hooks"]["Stop"]
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["hooks"][0]["command"], "user-hook")


if __name__ == "__main__":
    unittest.main()
