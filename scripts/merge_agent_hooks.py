#!/usr/bin/env python3
"""Shared hook-installation logic for both Agent Status installers.

One implementation for install.sh (source checkout) and
scripts/install-release.sh (prebuilt bundle): merge Claude Code and Codex
hook registrations into the user's config files, always back up what was
there so every rewrite is recoverable, tolerate every bad file state
(missing, empty, unparseable, wrong-typed, unreadable) by warning and
continuing, and rewrite retired Python hook commands in Codex config.toml.

Usage:
  merge_agent_hooks.py claude <settings.json> <snippet.json>
  merge_agent_hooks.py codex <hooks.json> <template.json> <hook_path>
  merge_agent_hooks.py codex-config-toml <config.toml> <hook_path>
"""
import json
import os
import shutil
import sys
from pathlib import Path

RETIRED_PY = "agentbridge-hook.py"


def warn(message):
    print("    warning: %s" % message)


def load_object(path):
    """Read a user-owned JSON file; every bad state becomes a fresh dict.

    The previous content is backed up to <path>.bak-agentbridge before
    anything can go wrong, so a rewrite is always recoverable.
    """
    backup = path + ".bak-agentbridge"
    existed = os.path.exists(path)
    if existed and not os.path.exists(backup):
        try:
            shutil.copy2(path, backup)
        except OSError as err:
            warn("could not back up %s (%s); continuing without a backup" % (path, err))
    if not existed:
        return {}
    try:
        with open(path) as f:
            data = json.load(f)
    except ValueError as err:
        warn("could not parse %s (%s); starting from an empty file" % (path, err))
        return {}
    except OSError as err:
        warn("could not read %s (%s); starting from an empty file" % (path, err))
        return {}
    if not isinstance(data, dict):
        warn("%s is not a JSON object; starting from an empty file" % path)
        return {}
    return data


def ensure_hooks_object(data, path):
    if not isinstance(data.get("hooks"), dict):
        if data:
            warn("'hooks' in %s is not an object; replacing it" % path)
        data["hooks"] = {}
    return data["hooks"]


def write_atomic(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    temp_path = path + ".tmp-agentbridge"
    with open(temp_path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(temp_path, path)


def install_claude(settings_path, snippet_path):
    with open(snippet_path) as f:
        snippet = json.load(f)
    settings = load_object(settings_path)
    hooks = ensure_hooks_object(settings, settings_path)
    for event, entries in snippet["hooks"].items():
        hooks.setdefault(event, [])
        # Drop the retired Python hook path so a reinstall does not leave
        # both the .py and the Swift binary registered for the same event.
        hooks[event] = [entry for entry in hooks[event]
                        if RETIRED_PY not in json.dumps(entry)]
        for entry in entries:
            if entry not in hooks[event]:
                hooks[event].append(entry)
    write_atomic(settings_path, settings)
    print("    merged into ~/.claude/settings.json")


def install_codex(hooks_path, template_path, hook_path):
    with open(template_path) as f:
        template = json.loads(f.read().replace("@@HOOK_PATH@@", hook_path))
    hooks = load_object(hooks_path)
    events = ensure_hooks_object(hooks, hooks_path)
    for event, entries in template["hooks"].items():
        events.setdefault(event, [])
        # Replace older AgentBridge entries so stale wildcard matchers/args
        # do not remain active alongside the corrected command.
        events[event] = [entry for entry in events[event]
                         if hook_path not in json.dumps(entry)]
        for entry in entries:
            if entry not in events[event]:
                events[event].append(entry)
    write_atomic(hooks_path, hooks)
    print("    wrote ~/.codex/hooks.json (run /hooks in Codex to trust the new hooks)")


def migrate_codex_config_toml(config_path, hook_path):
    """Rewrite hook commands left by older installs that used the Python hook."""
    cfg = Path(config_path)
    if not cfg.exists():
        return
    try:
        text = cfg.read_text()
    except OSError as err:
        warn("could not read %s (%s); leaving it untouched" % (config_path, err))
        return
    retired = os.path.join(os.path.expanduser("~/.agentbridge/hooks"), RETIRED_PY)
    replacements = [
        ("/usr/bin/python3 $HOME/.agentbridge/hooks/%s codex" % RETIRED_PY, hook_path + " codex"),
        ("/usr/bin/python3 " + retired + " codex", hook_path + " codex"),
        (retired + " codex", hook_path + " codex"),
    ]
    changed = 0
    for old, new in replacements:
        if old in text:
            changed += text.count(old)
            text = text.replace(old, new)
    if not changed:
        print("    %s has no retired %s commands" % (config_path, RETIRED_PY))
        return
    try:
        cfg.write_text(text)
    except OSError as err:
        warn("could not write %s (%s); the old commands are still active" % (config_path, err))
        return
    print("    rewrote %d hook command(s) in %s" % (changed, config_path))


def main(argv):
    usage = ("usage: merge_agent_hooks.py claude <settings.json> <snippet.json>\n"
             "       merge_agent_hooks.py codex <hooks.json> <template.json> <hook_path>\n"
             "       merge_agent_hooks.py codex-config-toml <config.toml> <hook_path>")
    args = argv[1:]
    if len(args) == 3 and args[0] == "claude":
        install_claude(args[1], args[2])
    elif len(args) == 4 and args[0] == "codex":
        install_codex(args[1], args[2], args[3])
    elif len(args) == 3 and args[0] == "codex-config-toml":
        migrate_codex_config_toml(args[1], args[2])
    else:
        print(usage, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
