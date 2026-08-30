#!/usr/bin/env bash
#===============================================================================
# linux-ptt-shortcut.sh -- normalize unusable persisted PTT bindings on Linux.
#
# Wispr's main-process shortcut matcher consumes prefs.user.shortcuts as a map
# of `VK+VK` strings to actions. Profiles can carry macOS's unmappable `-1`
# PTT key, which no Linux KeypressEvent can match. At the single startup write
# of that shortcut map, retain any matchable PTT binding unchanged; otherwise
# replace only PTT entries with the live Linux matcher chord Ctrl+Meta (162+91).
#===============================================================================
set -euo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" ]]; then
	BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
	BUNDLE="$BUNDLE/extract/app/.webpack/main/index.js"
fi

if [[ ! -f "$BUNDLE" ]]; then
	echo "ERROR: bundle not found: $BUNDLE" >&2
	exit 1
fi

LINUX_MARKER="WISPR_LINUX_PTT_SHORTCUT"
if grep -q "$LINUX_MARKER" "$BUNDLE"; then
	echo "Already patched ($LINUX_MARKER present in $BUNDLE) - nothing to do."
	exit 0
fi

if [[ ! -f "$BUNDLE.orig" ]]; then
	cp -p "$BUNDLE" "$BUNDLE.orig"
	echo "Backup written: $BUNDLE.orig"
fi

python3 - "$BUNDLE" "$LINUX_MARKER" <<'PY'
import io
import re
import sys

path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
    data = f.read()

# This is the single startup update that writes both shortcuts and the
# preserved scratchpad stash. Both property names are app-owned stable anchors;
# the minified update function and shortcut/stash locals are captured.
site = re.compile(
    r'\(0,(?P<update>[\w$]+)\.xB\)'
    r'\(\{shortcuts:(?P<shortcuts>[\w$]+),'
    r'stashedScratchpadShortcuts:(?P<stash>[\w$]+)\}\)'
)
matches = list(site.finditer(data))
if len(matches) != 1:
    sys.exit(
        "ERROR: expected exactly 1 startup shortcuts update, found "
        f"{len(matches)}. Bundle layout may have changed; re-audit the "
        "shortcut migration before patching."
    )

def normalize(match):
    shortcuts = match.group("shortcuts")
    return (
        "(0," + match.group("update") + ".xB)({shortcuts:"
        "(e=>{const t=Object.entries(e).filter(([e,t])=>\"ptt\"===t),"
        "n=t.filter(([e])=>!e.split(\"+\").includes(\"-1\"));"
        "return n.length?e:{...Object.fromEntries(Object.entries(e).filter("
        "([e,t])=>\"ptt\"!==t)),\"162+91\":\"ptt\"}})(" + shortcuts
        + ")/*" + marker + "*/,stashedScratchpadShortcuts:"
        + match.group("stash") + "})"
    )

data, count = site.subn(normalize, data, count=1)
if count != 1:
    sys.exit(f"ERROR: substitution applied {count} times (expected 1).")

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(data)
print("Patched: Linux startup now normalizes only unusable PTT bindings (1 site).")
PY

if ! grep -q "$LINUX_MARKER" "$BUNDLE"; then
	echo "ERROR: PTT shortcut marker missing after patch. Restoring backup." >&2
	cp -p "$BUNDLE.orig" "$BUNDLE"
	exit 1
fi

if command -v node >/dev/null; then
	if ! node --check "$BUNDLE"; then
		echo "ERROR: node --check failed on patched bundle. Restoring." >&2
		cp -p "$BUNDLE.orig" "$BUNDLE"
		exit 1
	fi
	echo "node --check OK"
fi

echo "OK: unusable Linux PTT bindings normalize to Ctrl+Meta"
