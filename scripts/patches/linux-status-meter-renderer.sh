#!/usr/bin/env bash
# Divert tagged recorder-meter scalars before the renderer's raw audio path.
set -uo pipefail

BUNDLE="${1:-}"
[[ -n "$BUNDLE" && -f "$BUNDLE" ]] || {
	echo "ERROR: dictation renderer bundle required" >&2
	exit 1
}
MARKER="WISPR_LINUX_STATUS_METER_RENDERER"
if grep -q "$MARKER" "$BUNDLE"; then
	grep -qF 'static async handleRecorderWorkletMessage(e){/*WISPR_LINUX_STATUS_METER_RENDERER_BEGIN*/' "$BUNDLE" \
		&& grep -qF 'window.electron.ipc.send("wispr-flow-status-meter-v2"' "$BUNDLE" \
		&& node --check "$BUNDLE" \
		&& { echo "Already patched ($MARKER)"; exit 0; }
	echo 'ERROR: partial status meter renderer marker set' >&2
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
anchor = 'static async handleRecorderWorkletMessage(e){'
if data.count(anchor) != 1:
    raise SystemExit(
        f"ERROR: expected one recorder worklet handler entry, found {data.count(anchor)}."
    )
replacement = '''static async handleRecorderWorkletMessage(e){/*WISPR_LINUX_STATUS_METER_RENDERER_BEGIN*/globalThis.__wisprStatusMeterRendererMessage??=(s=>{if(!s||"wispr-flow-status-meter-v2"!==s.type)return!1;if("boolean"!=typeof s.capture)return!0;if(s.capture){const e=Number(s.rms);return!Number.isFinite(e)||e<0||e>1||(window.electron.ipc.send("wispr-flow-status-meter-v2",{type:"wispr-flow-status-meter-v2",capture:!0,rms:e}),!0)}return void 0!==s.rms?!0:(window.electron.ipc.send("wispr-flow-status-meter-v2",{type:"wispr-flow-status-meter-v2",capture:!1}),!0)})/*WISPR_LINUX_STATUS_METER_RENDERER_END*/;if(globalThis.__wisprStatusMeterRendererMessage(e.data))return;/*WISPR_LINUX_STATUS_METER_RENDERER*/'''
with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(data.replace(anchor, replacement, 1))
PY

if ! grep -qF 'static async handleRecorderWorkletMessage(e){/*WISPR_LINUX_STATUS_METER_RENDERER_BEGIN*/' "$BUNDLE" \
	|| ! grep -qF 'window.electron.ipc.send("wispr-flow-status-meter-v2"' "$BUNDLE" \
	|| ! node --check "$BUNDLE"; then
	cp -p "$BEFORE" "$BUNDLE"
	rm -f "$BEFORE"
	echo 'ERROR: status meter renderer patch failed' >&2
	exit 1
fi
rm -f "$BEFORE"
echo 'Patched dictation renderer to forward scalar microphone meter only.'
