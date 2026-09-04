#!/usr/bin/env bash
# Add the Linux-only, app-owned Wispr status/control bridge to the audited
# Electron main bundle. Every anchor is exact and counted: an upstream bundle
# drift is a packaging failure, never a silent partial integration.
set -uo pipefail

BUNDLE="${1:-}"
[[ -n "$BUNDLE" && -f "$BUNDLE" ]] || { echo "ERROR: main bundle required" >&2; exit 1; }
MARKER="WISPR_LINUX_STATUS_BRIDGE"
if grep -q "$MARKER" "$BUNDLE"; then
  grep -q 'WISPR_LINUX_STATUS_LIFECYCLE' "$BUNDLE" \
    && grep -q 'WISPR_LINUX_STATUS_PUBLICATION' "$BUNDLE" \
    && grep -q 'WISPR_LINUX_STATUS_CONTROL' "$BUNDLE" \
    && grep -q 'WISPR_LINUX_STATUS_WINDOW_SUPPRESSED' "$BUNDLE" \
    && grep -qF 'globalThis.__wisprStatusBridge?.publish(globalThis.__wisprStatusSnapshot(e))' "$BUNDLE" \
    && grep -qF 'globalThis.__wisprStatusBridge?.setToggleHandsFree(async()=>' "$BUNDLE" \
    && grep -qF 'await(0,z.Qw)(c.SB.Deeplink)' "$BUNDLE" \
    && grep -qF 'await(0,z.US)(c.SB.Deeplink)' "$BUNDLE" \
    && grep -qF '"linux"!==process.platform&&e.showInactive()' "$BUNDLE" \
    && node --check "$BUNDLE" \
    && { echo "Already patched ($MARKER)"; exit 0; }
  echo 'ERROR: partial status bridge marker set' >&2
  exit 1
fi
BEFORE="$BUNDLE.status-bridge-before"
cp -p "$BUNDLE" "$BEFORE" || exit 1

python3 - "$BUNDLE" "$MARKER" <<'PY'
import io, sys
path, marker = sys.argv[1:]
with io.open(path, encoding="utf-8", errors="surrogateescape") as f: data = f.read()

def replace_once(anchor, replacement, label):
    count = data.count(anchor)
    if count != 1:
        raise SystemExit(f"ERROR: expected one {label} anchor, found {count}.")
    return data.replace(anchor, replacement, 1)

status_setter = 'qe=(e,t=!0,n={})=>{'
bridge_bootstrap = '''qe=(e,t=!0,n={})=>{globalThis.__wisprStatusSnapshot??=(e=>{const t=String(e).toLowerCase(),n="idle"===t||"dismissed"===t?"idle":"initializing"===t||"listening"===t?"recording":"stopping"===t||"processing"===t||"retrying"===t?"transcribing":"error"===t?"error":"error";return{state:n,hands_free:!!p.ZZ.isLocked,..."error"===n&&"error"!==t?{error:"unknown_lifecycle_state"}:{}}}),globalThis.__wisprStatusBridge??=("linux"===process.platform?(()=>{try{return require(require("path").resolve(process.resourcesPath,"wispr-status-bridge.cjs")).startStatusBridge({snapshot:()=>globalThis.__wisprStatusSnapshot(p.ZZ.status)})}catch(e){return null}})():null);/*WISPR_LINUX_STATUS_BRIDGE WISPR_LINUX_STATUS_LIFECYCLE*/'''
data = replace_once(status_setter, bridge_bootstrap, "authoritative status setter")

status_assignment = 'const i=p.ZZ.status;p.ZZ.status=e,p.ZZ.statusLastUpdatedTime=Date.now();'
data = replace_once(status_assignment, 'const i=p.ZZ.status;p.ZZ.status=e,p.ZZ.statusLastUpdatedTime=Date.now(),globalThis.__wisprStatusBridge?.publish(globalThis.__wisprStatusSnapshot(e))/*WISPR_LINUX_STATUS_PUBLICATION*/;', "status publication")

hands_free = 'const Q=()=>{try{const e=S.ZZ.status;'
control_hook = '''globalThis.__wisprStatusBridge?.setToggleHandsFree(async()=>{const e=S.ZZ.status;if(e===c._W.Idle||e===c._W.Dismissed)return await(0,z.Qw)(c.SB.Deeplink),{hands_free:!0};if(c.B8.includes(e)&&S.ZZ.isLocked)return await(0,z.US)(c.SB.Deeplink),{hands_free:!1};return{ok:!1,error:"not_toggleable"}});/*WISPR_LINUX_STATUS_CONTROL*/const Q=()=>{try{const e=S.ZZ.status;'''
data = replace_once(hands_free, control_hook, "actual hands-free action")

status_show = 'y.H8&&!J&&F.setEnabled(!0),e.showInactive(),y.H8&&'
data = replace_once(status_show, 'y.H8&&!J&&F.setEnabled(!0),"linux"!==process.platform&&e.showInactive(),y.H8&&/*WISPR_LINUX_STATUS_WINDOW_SUPPRESSED*/', "status-window show")

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f: f.write(data)
PY

if ! grep -q "$MARKER" "$BUNDLE" \
  || ! grep -q 'WISPR_LINUX_STATUS_LIFECYCLE' "$BUNDLE" \
  || ! grep -q 'WISPR_LINUX_STATUS_PUBLICATION' "$BUNDLE" \
  || ! grep -q 'WISPR_LINUX_STATUS_CONTROL' "$BUNDLE" \
  || ! grep -q 'WISPR_LINUX_STATUS_WINDOW_SUPPRESSED' "$BUNDLE"; then
  cp -p "$BEFORE" "$BUNDLE"
  rm -f "$BEFORE"
  echo "ERROR: bridge marker missing" >&2
  exit 1
fi
if ! node --check "$BUNDLE"; then
  cp -p "$BEFORE" "$BUNDLE"
  rm -f "$BEFORE"
  exit 1
fi
rm -f "$BEFORE"
echo "Patched Linux authoritative status bridge and suppressed Status window."
