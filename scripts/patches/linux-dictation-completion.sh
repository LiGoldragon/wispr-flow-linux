#!/usr/bin/env bash
# Serialize dictation completion in the Electron main bundle.
#
# Upstream guards recording completion (xt, onRecordingDone) with one boolean
# latch, cleared only in the outer finally after paste, history and telemetry.
# Status returns to Idle before that finally, so a next dictation can record
# and finish while the latch is still held; its completion is then dropped as
# a "duplicate" and the dictation times out into Error.
#
# The latch becomes an owner {uuid, done}. A completion for a different,
# current session waits for the owner to release, then runs the unchanged
# body. Same-session duplicates, Testing and missing-uuid completions keep
# upstream's drop. A waiter whose session is no longer current falls through
# to upstream's stale-session drop. Every anchor is exact and counted.
set -uo pipefail

BUNDLE="${1:-}"
[[ -n "$BUNDLE" && -f "$BUNDLE" ]] || { echo "ERROR: main bundle required" >&2; exit 1; }
MARKER="WISPR_LINUX_DICTATION_COMPLETION_SERIAL"
if grep -q "$MARKER" "$BUNDLE"; then
  grep -qF 'const __wlOwner=Lt=globalThis.__wisprDictationOwner={uuid:n,done:new Promise(e=>{__wlRelease=e})};try{yt=!1;' "$BUNDLE" \
    && grep -qF 'globalThis.__wisprDictationOwner===__wlOwner&&(globalThis.__wisprDictationOwner=null),__wlRelease()}}else s().warn("Dropping recording-done from a stale session"' "$BUNDLE" \
    && grep -qF '/*WISPR_LINUX_DICTATION_TAIL_OWNED*/if(c.ZZ.uuid!==i&&""!==c.ZZ.uuid)' "$BUNDLE" \
    && grep -qF '(0,a.yZ)(S,k,W,U,e,j,n,Q)}}c.ZZ.uuid===i||""===c.ZZ.uuid?(0,c.f4)()' "$BUNDLE" \
    && node --check "$BUNDLE" \
    && { echo "Already patched ($MARKER)"; exit 0; }
  echo 'ERROR: partial dictation completion marker set' >&2
  exit 1
fi
BEFORE="$BUNDLE.dictation-completion-before"
cp -p "$BUNDLE" "$BEFORE" || exit 1

python3 - "$BUNDLE" <<'PY'
import io, sys
path = sys.argv[1]
with io.open(path, encoding="utf-8", errors="surrogateescape") as f: data = f.read()

def replace_once(anchor, replacement, label):
    count = data.count(anchor)
    if count != 1:
        raise SystemExit(f"ERROR: expected one {label} anchor, found {count}.")
    return data.replace(anchor, replacement, 1)

if data.count("let Lt=!1,") != 1:
    raise SystemExit("ERROR: expected one completion latch declaration.")

head = 'const xt=async e=>{const t=e,{transcriptionEntityUuid:n}=e;if(c.ZZ.status===Le._W.Testing||void 0===n||n===c.ZZ.uuid)if(Lt)s().warn('
data = replace_once(head,
    'const xt=async e=>{const t=e,{transcriptionEntityUuid:n}=e;/*WISPR_LINUX_DICTATION_COMPLETION_SERIAL*/'
    'for(;Lt&&void 0!==n&&Lt.uuid!==n&&n===c.ZZ.uuid&&c.ZZ.status!==Le._W.Testing;)'
    's().info(`Recording done for ${n} waits for dictation ${Lt.uuid} to finish`),await Lt.done;'
    'if(c.ZZ.status===Le._W.Testing||void 0===n||n===c.ZZ.uuid)if(Lt)s().warn(',
    "completion guard")

data = replace_once('else{Lt=!0;try{yt=!1;',
    'else{let __wlRelease;const __wlOwner=Lt=globalThis.__wisprDictationOwner={uuid:n,done:new Promise(e=>{__wlRelease=e})};try{yt=!1;',
    "completion latch acquisition")

data = replace_once('}}finally{Lt=!1}}else s().warn("Dropping recording-done from a stale session"',
    '}}finally{Lt===__wlOwner&&(Lt=!1),globalThis.__wisprDictationOwner===__wlOwner&&(globalThis.__wisprDictationOwner=null),__wlRelease()}}else s().warn("Dropping recording-done from a stale session"',
    "completion latch release")

# The inner finally runs after the last await of the pipeline, when a next
# session may already be recording. Its end-of-dictation metrics and PasteText
# telemetry read and write the live session's globals (timingInformation,
# basetenNetworkMetrics, appContext, status). A superseded dictation skips
# them; upstream's own uuid check already guards resetTranscriptState.
data = replace_once('finally{null!==H&&(H(),H=null),null!==V&&(clearTimeout(V),V=null),null===c.ZZ.timingInformation.endTime&&(',
    'finally{null!==H&&(H(),H=null),null!==V&&(clearTimeout(V),V=null);/*WISPR_LINUX_DICTATION_TAIL_OWNED*/'
    'if(c.ZZ.uuid!==i&&""!==c.ZZ.uuid)s().info(`Dictation ${i} was superseded by ${c.ZZ.uuid}; its end-of-dictation metrics are skipped`);'
    'else{null===c.ZZ.timingInformation.endTime&&(',
    "tail metrics entry")
data = replace_once('(0,a.yZ)(S,k,W,U,e,j,n,Q)}c.ZZ.uuid===i||""===c.ZZ.uuid?(0,c.f4)()',
    '(0,a.yZ)(S,k,W,U,e,j,n,Q)}}c.ZZ.uuid===i||""===c.ZZ.uuid?(0,c.f4)()',
    "tail metrics exit")

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f: f.write(data)
PY
status=$?
if [[ $status -ne 0 ]] || ! node --check "$BUNDLE"; then
  cp -p "$BEFORE" "$BUNDLE"; rm -f "$BEFORE"
  echo "ERROR: dictation completion patch failed; bundle restored" >&2
  exit 1
fi
rm -f "$BEFORE"
echo "Patched dictation completion: a finished recording waits for the previous dictation"
