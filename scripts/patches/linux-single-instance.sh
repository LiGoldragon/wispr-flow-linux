#!/usr/bin/env bash
#===============================================================================
# linux-single-instance.sh -- make a second Wispr Flow launch on Linux stop at
# the single-instance check instead of starting a second app.
#
# The main bundle checks the Electron single-instance lock while the module is
# still being evaluated, before the app is ready:
#
#   if(...,!e.app.requestSingleInstanceLock())
#     return n().warn("App is already running, quitting"),void e.app.quit();
#
# The `return` leaves only the enclosing startup closure; the rest of the main
# bundle still registers its whenReady handlers, and app.quit() is
# asynchronous, so the losing instance goes on to open the SQLite database,
# run migrations and claim the status-bridge socket. On Linux that second app
# dies in a node-addon-api fatal (SIGABRT, exit 134) or fails the bridge
# reclaim guard.
#
# requestSingleInstanceLock() has already handed this launch's argv to the
# running instance (its second-instance event), so nothing is left to do.
# The patch replaces the quit with app.exit(0) on Linux: before the main
# message loop runs, Electron exits the process at once with status 0, so no
# later startup code runs. Other platforms keep app.quit().
#
# Anchor: the developer string "App is already running, quitting" (unique)
# together with the requestSingleInstanceLock() guard; the minified app and
# logger names are read back out of the match.
#
# Usage: linux-single-instance.sh <path-to-.webpack/main/index.js>
#===============================================================================
set -uo pipefail

BUNDLE="${1:-}"
[[ -n "$BUNDLE" && -f "$BUNDLE" ]] || { echo "ERROR: main bundle required" >&2; exit 1; }
MARKER="WISPR_LINUX_SINGLE_INSTANCE_EXIT"
if grep -q "$MARKER" "$BUNDLE"; then
  grep -qF '"linux"===process.platform?' "$BUNDLE" \
    && node --check "$BUNDLE" \
    && { echo "Already patched ($MARKER)"; exit 0; }
  echo 'ERROR: partial single-instance marker set' >&2
  exit 1
fi
BEFORE="$BUNDLE.single-instance-before"
cp -p "$BUNDLE" "$BEFORE" || exit 1

python3 - "$BUNDLE" "$MARKER" <<'PY'
import io, re, sys
path, marker = sys.argv[1:]
with io.open(path, encoding="utf-8", errors="surrogateescape") as f: data = f.read()

guard = re.compile(
    r'!(?P<app>[\w$]+)\.app\.requestSingleInstanceLock\(\)\)'
    r'return (?P<log>[\w$]+\(\)\.warn\("App is already running, quitting"\)),'
    r'void (?P=app)\.app\.quit\(\);'
)
matches = list(guard.finditer(data))
if len(matches) != 1:
    raise SystemExit(
        "ERROR: expected one single-instance quit guard, "
        f"found {len(matches)}."
    )
data = guard.sub(
    lambda m: '!' + m.group("app") + '.app.requestSingleInstanceLock())'
    + 'return ' + m.group("log") + ','
    + 'void("linux"===process.platform?' + m.group("app") + '.app.exit(0):'
    + m.group("app") + '.app.quit())/*' + marker + '*/;',
    data,
    count=1,
)
with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f: f.write(data)
PY
status=$?

if [[ $status -ne 0 ]] \
  || ! grep -q "$MARKER" "$BUNDLE" \
  || ! grep -qF '"linux"===process.platform?' "$BUNDLE" \
  || ! node --check "$BUNDLE"; then
  cp -p "$BEFORE" "$BUNDLE"
  rm -f "$BEFORE"
  echo 'ERROR: single-instance exit patch failed; original bundle restored' >&2
  exit 1
fi
rm -f "$BEFORE"
echo "OK: second launch exits at the single-instance check on Linux ($MARKER)"
