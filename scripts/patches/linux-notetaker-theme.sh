#!/usr/bin/env bash
# Give the Meeting Recorder (Notetaker) an accessible contrast floor and make
# its otherwise light-only renderer honor Electron's system color preference.
set -euo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" || ! -f "$BUNDLE" ]]; then
  echo "usage: $0 <path-to-.webpack/main/index.js>" >&2
  exit 2
fi

MARKER="WISPR_LINUX_NOTETAKER_THEME"
if grep -q "$MARKER" "$BUNDLE"; then
  echo "Already patched ($MARKER present in $BUNDLE) - nothing to do."
  exit 0
fi

if [[ ! -f "$BUNDLE.orig" ]]; then
  cp -p "$BUNDLE" "$BUNDLE.orig"
fi

python3 - "$BUNDLE" "$MARKER" <<'PY'
import io
import re
import sys

path, marker = sys.argv[1:]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as handle:
    data = handle.read()

# The stable product title and preload path identify the Meeting Recorder's
# BrowserWindow.  Keep the patch local to that window: Hub, dictation, and
# overlays retain their upstream appearance.
anchor = re.compile(
    r'(title:"Meeting Recorder",[\s\S]{0,1200}?'
    r'const (?P<window>[\w$]+)=new (?P<electron>[\w$]+)\.BrowserWindow\([\w$]+\);'
    r'let [\w$]+;\(0,[\w$]+\.c\)\((?P=window)\),)'
    r'(?P<next>[\w$]+\.webContents\.on\("render-process-gone")'
)
matches = list(anchor.finditer(data))
if len(matches) != 1:
    sys.exit(
        "ERROR: expected exactly one Meeting Recorder BrowserWindow anchor, "
        f"found {len(matches)}. Re-audit the payload before applying a theme patch."
    )

match = matches[0]
window = match.group("window")
css = (
    'html{filter:contrast(1.14)}'
    '@media (prefers-color-scheme: dark){'
    'html{background:#fff;filter:invert(1) hue-rotate(180deg) contrast(1.1)}'
    'img,video,canvas{filter:invert(1) hue-rotate(180deg)}'
    '}'
)
injection = (
    f'{window}.webContents.once("dom-ready",()=>{{'
    f'{window}.webContents.insertCSS("{css}").catch(()=>{{}})'
    f'}})/*{marker}*/,'
)
data = data[:match.end(1)] + injection + data[match.end(1):]

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as handle:
    handle.write(data)
PY

grep -q "$MARKER" "$BUNDLE" || { echo "ERROR: marker missing after patch" >&2; exit 1; }
node --check "$BUNDLE"
echo "OK: Meeting Recorder now follows system dark preference with raised contrast"
