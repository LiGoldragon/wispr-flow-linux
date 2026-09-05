#!/usr/bin/env bash
# Add a bounded scalar microphone meter to the upstream recorder worklet.
set -uo pipefail

BUNDLE="${1:-}"
[[ -n "$BUNDLE" && -f "$BUNDLE" ]] || {
	echo "ERROR: recorder worklet required" >&2
	exit 1
}
MARKER="WISPR_LINUX_STATUS_METER_WORKLET"
if grep -q "$MARKER" "$BUNDLE"; then
	grep -q 'WISPR_LINUX_STATUS_METER_CAPTURE' "$BUNDLE" \
		&& node --check "$BUNDLE" \
		&& { echo "Already patched ($MARKER)"; exit 0; }
	echo 'ERROR: partial status meter worklet marker set' >&2
	exit 1
fi

BEFORE="$BUNDLE.status-meter-before"
cp -p "$BUNDLE" "$BEFORE" || exit 1
python3 - "$BUNDLE" <<'PY'
import io
import sys

path = sys.argv[1]
with io.open(path, encoding="utf-8", errors="surrogateescape") as f:
    data = f.read()

def replace_once(anchor, replacement, label):
    count = data.count(anchor)
    if count != 1:
        raise SystemExit(f"ERROR: expected one {label} anchor, found {count}.")
    return data.replace(anchor, replacement, 1)

data = replace_once(
    'if("start"===e.data)this.resetBufferIndexOnly(),this.recording=!0;'
    'else if("stop"===e.data){this.recording=!1;',
    'if("start"===e.data)this.resetBufferIndexOnly(),this.recording=!0,'
    'this.port.postMessage({type:"wispr-flow-status-meter-v2",capture:!0,rms:0})'
    '/*WISPR_LINUX_STATUS_METER_CAPTURE*/;else if("stop"===e.data){'
    'this.recording=!1,this.sendCaptureUnavailable();',
    'this.port.onmessage lifecycle',
)
data = replace_once(
    'sendDataAsKeyValue(e){let t={};for(let s=0;s<this.numInputStreams;s++)'
    't[s]=this.buffer[s].slice(0,e),this.bufferIndex[s]=0;this.port.postMessage(t)}',
    'sendMeter(e){let t=0;for(let s=0;s<e.length;s++){const a=e[s];t+=a*a}'
    'let s=e.length?Math.sqrt(t/e.length):0;Number.isFinite(s)||(s=0),'
    'this.port.postMessage({type:"wispr-flow-status-meter-v2",capture:!0,'
    'rms:Math.min(1,Math.max(0,s))})/*WISPR_LINUX_STATUS_METER_WORKLET*/}'
    'sendCaptureUnavailable(){this.port.postMessage({type:"wispr-flow-status-meter-v2",capture:!1})}'
    'sendDataAsKeyValue(e){let t={};this.sendMeter(this.buffer[0].subarray(0,e));for(let s=0;s<this.numInputStreams;s++)'
    't[s]=this.buffer[s].slice(0,e),this.bufferIndex[s]=0;this.port.postMessage(t)}',
    'raw transcription sender',
)
data = replace_once(
    'const e=s[0];this.buffer[t].set(e,this.bufferIndex[t]),this.bufferIndex[t]+=e.length',
    'const e=s[0];this.buffer[t].set(e,this.bufferIndex[t]),'
    'this.bufferIndex[t]+=e.length',
    'first-channel Float32 consumption',
)
with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(data)
PY

if ! grep -q 'WISPR_LINUX_STATUS_METER_WORKLET' "$BUNDLE" \
	|| ! grep -q 'WISPR_LINUX_STATUS_METER_CAPTURE' "$BUNDLE" \
	|| ! node --check "$BUNDLE"; then
	cp -p "$BEFORE" "$BUNDLE"
	rm -f "$BEFORE"
	echo 'ERROR: status meter worklet patch failed' >&2
	exit 1
fi
rm -f "$BEFORE"
echo 'Patched recorder worklet with bounded scalar microphone meter.'
