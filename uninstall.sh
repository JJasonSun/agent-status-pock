#!/bin/bash
# Removes Agent Touch Bar: LaunchAgent, bridge files, widget, and agent hook
# entries added by install.sh (Claude Code / Codex / opencode).
set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/com.touchbar.agentbridge.plist"

echo "==> Stopping AgentBridge"
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
rm -f "$PLIST"

echo "==> Removing Pock widget"
rm -rf "$HOME/Library/Application Support/Pock/Widgets/AgentTouchBar.pock"

echo "==> Removing opencode plugin"
OPENCODE_PLUGIN="$HOME/.config/opencode/plugins/agentbridge.js"
rm -f "$OPENCODE_PLUGIN"
if [[ -f "$OPENCODE_PLUGIN.bak-agentbridge" ]]; then
    mv "$OPENCODE_PLUGIN.bak-agentbridge" "$OPENCODE_PLUGIN"
    echo "    restored the previous opencode plugin"
fi

echo "==> Removing Claude Code hooks"
python3 - "$HOME/.claude/settings.json" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(0)
try:
    with open(path) as f:
        settings = json.load(f)
except (OSError, ValueError) as err:
    print("    warning: could not read/parse %s (%s); leaving it untouched" % (path, err))
    sys.exit(0)
if not isinstance(settings, dict):
    print("    warning: %s is not a JSON object; leaving it untouched" % path)
    sys.exit(0)
hooks = settings.get("hooks")
if not isinstance(hooks, dict):
    hooks = {}
removed = 0
for event in list(hooks):
    entries = hooks[event]
    if not isinstance(entries, list):
        continue
    kept = [e for e in entries if "agentbridge-hook" not in json.dumps(e)]
    removed += len(entries) - len(kept)
    if kept:
        hooks[event] = kept
    else:
        del hooks[event]
if not removed:
    print("    no AgentBridge hook entries")
    sys.exit(0)
if not hooks:
    settings.pop("hooks", None)
temp_path = path + ".tmp-agentbridge"
with open(temp_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
try:
    os.chmod(temp_path, os.stat(path).st_mode & 0o777)
except OSError:
    pass
os.replace(temp_path, path)
backup = path + ".bak-agentbridge"
if os.path.exists(backup):
    os.remove(backup)
print("    removed %d AgentBridge hook entries" % removed)
PYEOF

echo "==> Removing Codex hooks"
python3 - "$HOME/.codex/hooks.json" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(0)
try:
    with open(path) as f:
        document = json.load(f)
except (OSError, ValueError) as err:
    print("    warning: could not read/parse %s (%s); leaving it untouched" % (path, err))
    sys.exit(0)
if not isinstance(document, dict):
    print("    warning: %s is not a JSON object; leaving it untouched" % path)
    sys.exit(0)
hooks = document.get("hooks")
if not isinstance(hooks, dict):
    print("    no AgentBridge hook entries")
    sys.exit(0)
removed = 0
for event in list(hooks):
    entries = hooks[event]
    if not isinstance(entries, list):
        continue
    kept = [e for e in entries if "agentbridge-hook" not in json.dumps(e)]
    removed += len(entries) - len(kept)
    if kept:
        hooks[event] = kept
    else:
        del hooks[event]
if not removed:
    print("    no AgentBridge hook entries")
    sys.exit(0)
if not hooks and set(document) == {"hooks"}:
    os.remove(path)
    print("    removed ~/.codex/hooks.json")
else:
    if not hooks:
        document.pop("hooks", None)
    temp_path = path + ".tmp-agentbridge"
    with open(temp_path, "w") as f:
        json.dump(document, f, indent=2)
        f.write("\n")
    try:
        os.chmod(temp_path, os.stat(path).st_mode & 0o777)
    except OSError:
        pass
    os.replace(temp_path, path)
    print("    removed %d AgentBridge hook entries" % removed)
PYEOF

echo "==> Removing AgentBridge hooks from Codex config.toml"
python3 - "$HOME/.codex/config.toml" <<'PYEOF'
import os, shutil, sys
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(0)
try:
    with open(path) as f:
        lines = f.readlines()
except OSError as err:
    print("    warning: could not read %s (%s); leaving it untouched" % (path, err))
    sys.exit(0)
blocks = []
header = None
current = []
for line in lines:
    if line.lstrip().startswith("["):
        if current:
            blocks.append((header, current))
        header = line.strip()
        current = [line]
    else:
        current.append(line)
if current:
    blocks.append((header, current))
kept = []
removed = 0
removed_parents = set()
parsed = []
for table_header, block in blocks:
    name = ""
    if table_header:
        name = table_header.lstrip("[").split("]", 1)[0].strip()
    text = "".join(block)
    remove = (name.startswith("hooks.")
              and not name.startswith("hooks.state")
              and "agentbridge-hook" in text)
    if remove:
        removed += 1
        if name.endswith(".hooks"):
            removed_parents.add(name[:-len(".hooks")])
    parsed.append((name, block, remove))
for name, block, remove in parsed:
    if remove:
        continue
    if name in removed_parents and not any("=" in line for line in block):
        continue
    kept.extend(block)
if not removed:
    print("    no AgentBridge hook tables")
    sys.exit(0)
backup = path + ".bak-agentbridge"
if not os.path.exists(backup):
    try:
        shutil.copy2(path, backup)
    except OSError as err:
        print("    warning: could not back up %s (%s); leaving it untouched" % (path, err))
        sys.exit(0)
temp_path = path + ".tmp-agentbridge"
with open(temp_path, "w") as f:
    f.writelines(kept)
try:
    os.chmod(temp_path, os.stat(path).st_mode & 0o777)
except OSError:
    pass
os.replace(temp_path, path)
print("    removed %d AgentBridge hook table(s) from config.toml" % removed)
PYEOF

echo "==> Removing bridge files"
rm -rf "$HOME/.agentbridge"

echo "Done."
