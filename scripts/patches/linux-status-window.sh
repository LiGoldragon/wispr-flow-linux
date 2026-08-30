#!/usr/bin/env bash
#===============================================================================
# linux-status-window.sh -- give the transparent Status BrowserWindow an ARGB
# background in the Wispr Flow main bundle.
#
# The v1.6.7 Status BrowserWindow is a transparent, frameless, always-on-top
# Wayland overlay, but unlike the other transparent overlays it omits
# `backgroundColor:"#00000000"`. Electron can then expose Chromium's opaque,
# tiled fallback before the renderer paints. Add the explicit transparent ARGB
# colour at this Status-only config site, preserving its transparency and every
# unrelated BrowserWindow configuration.
#
# The anchor combines the preserved status preload path, the transparent window
# options, and the Status title. It must occur exactly once. A changed upstream
# bundle therefore fails loudly for re-audit instead of patching another overlay.
#===============================================================================
set -euo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" ]]; then
	BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	BUNDLE="$BUNDLE/extract/app/.webpack/main/index.js"
fi

if [[ ! -f "$BUNDLE" ]]; then
	echo "ERROR: bundle not found: $BUNDLE" >&2
	exit 1
fi

LINUX_MARKER="WISPR_LINUX_STATUS_ARGB_BACKGROUND"
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

# The Status preload path and title are preserved app literals. Keeping the
# transparent option in the same anchor prevents a similarly named renderer or
# unrelated BrowserWindow from being modified.
site = re.compile(
    r'(?P<prefix>preload:require\("path"\)\.resolve\('
    r'__dirname,"\.\./renderer","status","preload\.js"\),'
    r'backgroundThrottling:!1\},transparent:!0)'
    r'(?P<suffix>,hasShadow:!1,roundedCorners:!1,type:'
    r'[\s\S]{0,120}?title:"Flow Status Indicator")'
)
matches = list(site.finditer(data))
if len(matches) != 1:
    sys.exit(
        f"ERROR: expected exactly 1 transparent Status BrowserWindow, found "
        f"{len(matches)}. Bundle layout may have changed; re-audit the status "
        "window before patching."
    )

def add_argb_background(match):
    return (
        match.group("prefix")
        + ',backgroundColor:"#00000000"/*' + marker + '*/'
        + match.group("suffix")
    )

data, count = site.subn(add_argb_background, data, count=1)
if count != 1:
    sys.exit(f"ERROR: substitution applied {count} times (expected 1).")

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(data)
print("Patched: added explicit transparent ARGB background to the Status "
      "BrowserWindow (1 site).")
PY

if ! grep -q "$LINUX_MARKER" "$BUNDLE"; then
	echo "ERROR: post-patch verification failed (marker not found)." >&2
	cp -p "$BUNDLE.orig" "$BUNDLE"
	exit 1
fi

if ! grep -q \
	'transparent:!0,backgroundColor:"#00000000"/\*'"$LINUX_MARKER"'\*/,hasShadow:!1' \
	"$BUNDLE"; then
	echo "ERROR: Status ARGB background is not in the expected form." >&2
	cp -p "$BUNDLE.orig" "$BUNDLE"
	exit 1
fi

if command -v node >/dev/null; then
	if ! node --check "$BUNDLE"; then
		echo "ERROR: node --check failed on patched bundle. Restoring backup." >&2
		cp -p "$BUNDLE.orig" "$BUNDLE"
		exit 1
	fi
	echo "node --check OK"
fi

echo "OK: transparent ARGB background added to the Status BrowserWindow"
