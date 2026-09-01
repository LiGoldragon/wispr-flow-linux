#!/usr/bin/env bash
# Patch the Flow Hub so setup remains operable on every display work area.
set -euo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" ]]; then
	echo "usage: $0 <path-to-.webpack/main/index.js>" >&2
	exit 2
fi

if [[ ! -f "$BUNDLE" ]]; then
	echo "ERROR: bundle not found: $BUNDLE" >&2
	exit 2
fi

LINUX_MARKER="WISPR_LINUX_HUB_VIEWPORT"
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

# The title and the two sizing calls are stable product literals.  Every
# captured identifier is minifier-owned, so the patch remains tied to the Hub
# without depending on its current module or local-variable names.
site = re.compile(
    r'title:"Flow Hub",width:(?P<prefs>[\w$]+)\.width,height:(?P=prefs)\.height,'
    r'[\s\S]{0,2000}?const (?P<window>[\w$]+)=new '
    r'(?P<electron>[\w$]+)\.BrowserWindow\([\w$]+\);'
    r'(?P<minimum>(?P=window)\.setMinimumSize\('
    r'(?P<minimum_config>[\w$]+)\.eh\.width,'
    r'(?P=minimum_config)\.eh\.height\))'
)
matches = list(site.finditer(data))
if len(matches) != 1:
    sys.exit(
        "ERROR: expected exactly 1 Flow Hub size site, found "
        f"{len(matches)}. Bundle layout may have changed; re-audit the "
        "Flow Hub BrowserWindow and setMinimumSize calls before patching."
    )

match = matches[0]
window = match.group("window")
electron = match.group("electron")
minimum_config = match.group("minimum_config")
minimum = match.group("minimum")

# Electron receives outer-window dimensions.  Clamp both the restored size and
# its minimum to the display work area, then make the onboarding page scroll
# and its CTA sticky.  This is Hub-local and Linux-only; all other products and
# platforms preserve their shipped behavior.
linux_safe_minimum = (
    '"linux"===process.platform?(()=>{'
    f'const e={electron}.screen.getDisplayMatching({window}.getBounds()).workArea,'
    f't={window}.getBounds(),r=Math.min(t.width,e.width),a=Math.min(t.height,e.height);'
    f'{window}.setBounds({{x:Math.max(e.x,Math.min(t.x,e.x+e.width-r)),'
    'y:Math.max(e.y,Math.min(t.y,e.y+e.height-a)),width:r,height:a}),'
    f'{window}.setMinimumSize(Math.min({minimum_config}.eh.width,e.width),'
    f'Math.min({minimum_config}.eh.height,e.height)),'
    f'{window}.webContents.once("dom-ready",()=>{{{window}.webContents.insertCSS('
    '"[data-testid^=\\\"onboarding-page-\\\"]{min-height:0!important;'
    'max-height:100%!important;overflow:auto!important}'
    '[data-testid^=\\\"onboarding-page-\\\"] '
    '[data-testid=\\\"onboarding-cta\\\"]{position:sticky!important;'
    'bottom:0;z-index:1;background:inherit;padding:16px 0}"'
    ').catch(()=>{})})'
    f'/*{marker}*/}})():{minimum}'
)
data = data[:match.start("minimum")] + linux_safe_minimum + data[match.end("minimum"):]

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(data)
PY

if ! grep -q "$LINUX_MARKER" "$BUNDLE"; then
	echo "ERROR: post-patch verification failed (marker not found)." >&2
	cp -p "$BUNDLE.orig" "$BUNDLE"
	exit 1
fi

if command -v node >/dev/null; then
	if ! node --check "$BUNDLE"; then
		echo "ERROR: patched bundle does not parse. Restoring backup." >&2
		cp -p "$BUNDLE.orig" "$BUNDLE"
		exit 1
	fi
	printf '%s\n' 'node --check OK'
fi

printf '%s\n' 'OK: Linux Flow Hub viewport is bounded to its display work area'
