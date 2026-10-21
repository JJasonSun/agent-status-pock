#!/usr/bin/env python3
"""Shared hook-installation logic for both Agent Status installers.

One implementation for install.sh (source checkout) and
scripts/install-release.sh (prebuilt bundle): merge Claude Code and Codex
hook registrations into the user's config files, back up every rewrite,
tolerate bad input without overwriting an unrecoverable file, and manage
the Codex config.toml representation.

Usage:
  merge_agent_hooks.py claude <settings.json> <snippet.json>
  merge_agent_hooks.py codex <hooks.json> <template.json> <hook_path>
  merge_agent_hooks.py codex-config-toml <config.toml> <hook_path>
  merge_agent_hooks.py codex-remove-hooks <hooks.json>
"""
import json
import os
import shutil
import sys
from pathlib import Path

RETIRED_PY = "agentbridge-hook.py"
AGENTBRIDGE_HOOK = "agentbridge-hook"


def warn(message):
    print("    warning: %s" % message)


def backup_file(path):
    """Back up a user-owned file once. Never rewrite when this fails."""
    if not os.path.exists(path):
        return True
    backup = path + ".bak-agentbridge"
    if os.path.isfile(backup):
        return True
    try:
        shutil.copy2(path, backup)
        return True
    except OSError as err:
        warn("could not back up %s (%s); leaving it untouched" % (path, err))
        return False


def load_object(path):
    """Read a user-owned JSON file; unreadable files are left untouched.

    A missing file becomes an empty dict. Invalid JSON or wrong top-level
    types become an empty dict after a successful backup, so the rewrite
    is recoverable. If the backup itself fails, return None and let the
    caller skip the file rather than destroying unreadable settings.
    """
    if not os.path.exists(path):
        return {}
    if not backup_file(path):
        return None
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


def file_mode(path):
    try:
        return os.stat(path).st_mode & 0o777
    except OSError:
        return 0o600


def write_temp(path, text):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    temp_path = path + ".tmp-agentbridge"
    mode = file_mode(path)
    fd = os.open(temp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    try:
        os.chmod(temp_path, mode)
    except OSError:
        pass
    with os.fdopen(fd, "w") as f:
        f.write(text)
    return temp_path


def write_atomic(path, data):
    temp_path = write_temp(path, json.dumps(data, indent=2) + "\n")
    os.replace(temp_path, path)


def write_text_atomic(path, text):
    temp_path = write_temp(path, text)
    os.replace(temp_path, path)


def event_list(hooks, event, path):
    entries = hooks.get(event)
    if isinstance(entries, list):
        return entries
    if entries is not None:
        warn("'hooks.%s' in %s is not an array; replacing it" % (event, path))
    return []


def install_claude(settings_path, snippet_path):
    with open(snippet_path) as f:
        snippet = json.load(f)
    settings = load_object(settings_path)
    if settings is None:
        print("    skipped ~/.claude/settings.json (no backup)")
        return
    hooks = ensure_hooks_object(settings, settings_path)
    for event, entries in snippet["hooks"].items():
        current = event_list(hooks, event, settings_path)
        current = [entry for entry in current
                   if AGENTBRIDGE_HOOK not in json.dumps(entry)]
        for entry in entries:
            if entry not in current:
                current.append(entry)
        hooks[event] = current
    write_atomic(settings_path, settings)
    print("    merged into ~/.claude/settings.json")


def install_codex(hooks_path, template_path, hook_path):
    with open(template_path) as f:
        template = json.loads(f.read().replace("@@HOOK_PATH@@", hook_path))
    hooks = load_object(hooks_path)
    if hooks is None:
        print("    skipped ~/.codex/hooks.json (no backup)")
        return
    events = ensure_hooks_object(hooks, hooks_path)
    for event, entries in template["hooks"].items():
        current = event_list(events, event, hooks_path)
        # Drop every older AgentBridge entry so an upgrade leaves exactly
        # one current entry per event.
        current = [entry for entry in current
                   if AGENTBRIDGE_HOOK not in json.dumps(entry)]
        for entry in entries:
            if entry not in current:
                current.append(entry)
        events[event] = current
    write_atomic(hooks_path, hooks)
    print("    wrote ~/.codex/hooks.json (run /hooks in Codex to trust the new hooks)")


def remove_codex_hooks(hooks_path):
    """Drop AgentBridge entries from hooks.json when config.toml is authoritative."""
    if not os.path.exists(hooks_path):
        return
    document = load_object(hooks_path)
    if document is None:
        return
    hooks = document.get("hooks")
    if not isinstance(hooks, dict):
        return
    removed = 0
    for event in list(hooks):
        entries = hooks[event]
        if not isinstance(entries, list):
            warn("'hooks.%s' in %s is not an array; leaving it untouched" % (event, hooks_path))
            continue
        kept = [entry for entry in entries if AGENTBRIDGE_HOOK not in json.dumps(entry)]
        removed += len(entries) - len(kept)
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    if not removed:
        print("    %s has no AgentBridge hook entries" % hooks_path)
        return
    if not hooks and set(document) == {"hooks"}:
        os.remove(hooks_path)
        print("    removed %s" % hooks_path)
    else:
        if not hooks:
            document.pop("hooks", None)
        write_atomic(hooks_path, document)
        print("    removed %d AgentBridge hook entries from %s" % (removed, hooks_path))


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
    if not backup_file(config_path):
        return
    try:
        write_text_atomic(config_path, text)
    except OSError as err:
        warn("could not write %s (%s); the old commands are still active" % (config_path, err))
        return
    print("    rewrote %d hook command(s) in %s" % (changed, config_path))


def main(argv):
    usage = ("usage: merge_agent_hooks.py claude <settings.json> <snippet.json>\n"
             "       merge_agent_hooks.py codex <hooks.json> <template.json> <hook_path>\n"
             "       merge_agent_hooks.py codex-config-toml <config.toml> <hook_path>\n"
             "       merge_agent_hooks.py codex-remove-hooks <hooks.json>")
    args = argv[1:]
    if len(args) == 3 and args[0] == "claude":
        install_claude(args[1], args[2])
    elif len(args) == 4 and args[0] == "codex":
        install_codex(args[1], args[2], args[3])
    elif len(args) == 3 and args[0] == "codex-config-toml":
        migrate_codex_config_toml(args[1], args[2])
    elif len(args) == 2 and args[0] == "codex-remove-hooks":
        remove_codex_hooks(args[1])
    else:
        print(usage, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
