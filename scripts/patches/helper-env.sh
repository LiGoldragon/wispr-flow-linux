#!/usr/bin/env bash
#===============================================================================
# patch-helper-env.sh
#
# Restores the session environment to the native-helper child process in the
# webpack-bundled Electron main process (.webpack/main/index.js).
#
# WHY THIS PATCH EXISTS
# ---------------------
# The shipped main bundle spawns the native helper with a REPLACEMENT env
# object that lists only telemetry keys -- it does NOT spread process.env:
#
#   helper.process = spawn(s, {
#     stdio:["pipe","pipe","pipe","pipe"],
#     env:{ sentryDSN, environment, segmentWriteKey,
#           postHogProjectKey, sentryLocalDebug } })
#
# On macOS/Windows the helper talks to the OS through native APIs and needs no
# session env, so upstream never spread process.env. But the Linux helper's
# backend detection (the helper's src/backend/mod.rs::pick_injector;
# github.com/wispr-flow-linux/helper) gates
# the Wayland/X11 injection + clipboard + active-app backends on the session
# env vars WAYLAND_DISPLAY / DISPLAY (and, to actually connect, XDG_RUNTIME_DIR
# and DBUS_SESSION_BUS_ADDRESS). With the replacement env none of those reach
# the child, so the helper falls through to the no-op `stub` backend:
#
#   WARN  ...backend] injection: stub (no-op) -- OS integration disabled
#
# The mic records and shortcuts fire (keypress capture reads /dev/input
# directly, needing no env), but PasteText returns
#   "PasteText failed: no backend available (stub)"
# and nothing is ever injected into the focused field. This was misdiagnosed in
# helper-resolver.sh PATCH NOTE #3 as "harmless"; it is the cause of the dead
# text injection. See docs/learnings/helper-spawn-env.md.
#
# THE PATCH (surgical, one insertion point)
# -----------------------------------------
# In upstream 1.6.774, the stable four-pipe spawn still calls `env:N()`, but
# the telemetry-only object is now factored into `const N=(...)=>(...)`.
# Anchor on that function's first stable telemetry property rather than
# pretending the old inline object still exists. Insert `...process.env,` at
# the FRONT of its returned object so session variables propagate, while the
# telemetry keys that follow still override anything of the same name. On
# macOS/Windows this only adds the parent env the helper already ignores.
#
#   env:{...process.env,sentryDSN:...}   (marker comment carries the grep token)
#
# stdio / fd-3 / exec-bit notes live in helper-resolver.sh PATCH NOTES.
#===============================================================================
set -euo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" ]]; then
  # default to the in-repo extracted bundle
  BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/extract/app/.webpack/main/index.js"
fi

if [[ ! -f "$BUNDLE" ]]; then
  echo "ERROR: bundle not found: $BUNDLE" >&2
  exit 1
fi

# --- Idempotency guard --------------------------------------------------------
ENV_MARKER="WISPR_LINUX_HELPER_ENV"
if grep -q "$ENV_MARKER" "$BUNDLE"; then
  echo "Already patched ($ENV_MARKER present in $BUNDLE) - nothing to do."
  exit 0
fi

# --- Backup -------------------------------------------------------------------
if [[ ! -f "$BUNDLE.orig" ]]; then
  cp -p "$BUNDLE" "$BUNDLE.orig"
  echo "Backup written: $BUNDLE.orig"
fi

# --- Patch (anchored on stable string/property literals, no minified ids) -----
python3 - "$BUNDLE" "$ENV_MARKER" <<'PY'
import sys, io
path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
    data = f.read()

# The 1.6.774 helper env factory. `sentryDSN` is a retained property name and
# the complete prefix is unique in the audited bundle. If upstream starts
# inheriting the parent env itself, this fails closed for re-audit instead of
# accepting an unknown helper launch shape.
anchor = ',N=(e=a.app.isPackaged)=>({sentryDSN:'
n = data.count(anchor)
if n != 1:
    sys.exit(f"ERROR: expected exactly 1 helper-env factory anchor, found {n}.")

after = data[data.find(anchor) + len(anchor):]
if after.startswith("...process.env") or after.startswith(f"/*{marker}*/"):
    sys.exit(0)  # already spreads the parent env -- nothing to do

# Insert the marker comment + spread at the front of N()'s returned object.
# The `sentryDSN:` prefix remains intact after the inserted comma.
repl = anchor.replace("sentryDSN:", f"/*{marker}*/...process.env,sentryDSN:")
data = data.replace(anchor, repl, 1)

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(data)
print("Patched: spread process.env into the helper-spawn env object (1).")
PY

# --- Verify the result --------------------------------------------------------
if ! grep -q "$ENV_MARKER" "$BUNDLE"; then
  echo "ERROR: post-patch verification failed (marker not found)." >&2
  echo "       Restoring backup." >&2
  cp -p "$BUNDLE.orig" "$BUNDLE"
  exit 1
fi

# Syntax-check: the spread is inside an object literal; catch any edit that
# serializes but doesn't parse before it ever reaches asar.
if command -v node >/dev/null; then
  if ! node --check "$BUNDLE"; then
    echo "ERROR: node --check failed on patched bundle. Restoring backup." >&2
    cp -p "$BUNDLE.orig" "$BUNDLE"
    exit 1
  fi
  echo "node --check OK"
fi
echo "OK: helper-spawn env now inherits the session environment in $BUNDLE"
echo
echo "Patched spawn now does (conceptually):"
echo "  spawn(helper, { stdio:[...x4],"
echo "    env:{ ...process.env, sentryDSN, environment, ... } });"
