#!/usr/bin/env bats

@test "signed 1.6.774 payload accepts complete Linux patch suite" {
	[[ -n ${WISPR_FLOW_AUDIT_APP:-} && -f "$WISPR_FLOW_AUDIT_APP/.webpack/main/index.js" ]] || skip 'set WISPR_FLOW_AUDIT_APP to verified extracted 1.6.774 app'
	local copy="$BATS_TEST_TMPDIR/app"
	cp -a "$WISPR_FLOW_AUDIT_APP" "$copy"
	local main="$copy/.webpack/main/index.js"
	[[ ! -f "$WISPR_FLOW_AUDIT_APP/.webpack/main/index.js.orig" ]] \
		|| cp "$WISPR_FLOW_AUDIT_APP/.webpack/main/index.js.orig" "$main"
	for patch in helper-resolver.sh mac-gates.sh helper-env.sh linux-window-frame.sh linux-hub-viewport.sh linux-deeplink.sh linux-status-bridge.sh; do
		bash "$BATS_TEST_DIRNAME/../scripts/patches/$patch" "$main"
	done
	for renderer in "$copy"/.webpack/renderer/*/index.js; do
		[[ -f $renderer ]] && grep -qF 'platform?.isWindows' "$renderer" && bash "$BATS_TEST_DIRNAME/../scripts/patches/linux-renderer-treat-as-windows.sh" "$renderer"
	done
	bash "$BATS_TEST_DIRNAME/../scripts/patches/linux-renderer-chrome.sh" "$copy/.webpack/renderer/hub/index.js"
	node --check "$main"
	bash "$BATS_TEST_DIRNAME/../scripts/patches/linux-status-bridge.sh" "$main"
}

@test "fixture control hook covers the state matrix and lock publication splice" {
	local fixture="$BATS_TEST_TMPDIR/status-control.js"
	local driver="$BATS_TEST_TMPDIR/run-status-control.js"
	cat > "$fixture" <<'JS'
let qe;
qe=(e,t=!0,n={})=>{};
e.app.whenReady().then(()=>(async()=>{})()).catch(e=>{n().warn("Local dev auto sign-in failed",{customAttributes:{error:String(e)}})});
function publish(e){const i=p.ZZ.status;p.ZZ.status=e,p.ZZ.statusLastUpdatedTime=Date.now();}
globalThis.setLocked=e=>{S.ZZ.isLocked=e;};
const Q=()=>{try{const e=S.ZZ.status;}catch(_){}};
const ordinaryStatusShow=()=>{y.H8&&!J&&F.setEnabled(!0),e.showInactive(),y.H8&&noop()};
globalThis.recover=r=(e=y.H8)=>{const t=ie.RA.statusWindow;if(!t||t.isDestroyed())return n().error("Status window is not available or destroyed. Recreating.");t.showInactive()};
JS
	cat > "$driver" <<'JS'
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const source = fs.readFileSync(process.argv[2], "utf8");

const calls = [], publications = [];
let toggle;
const context = {
  e: { app: { whenReady: () => Promise.resolve() }, showInactive: () => {} },
  n: () => ({ error: () => {}, warn: () => {} }),
  p: { ZZ: { status: "Idle" } },
  S: { ZZ: { status: "Idle", isLocked: false } },
  c: { _W: { Idle: "Idle", Dismissed: "Dismissed", Listening: "Listening", Processing: "Processing", Error: "Error" }, B8: ["Listening", "Processing"] , SB: { Deeplink: "wispr-flow:" } },
  z: { Qw: async () => calls.push("start"), US: async () => calls.push("stop") },
  y: { H8: true }, J: false, F: { setEnabled: () => {} }, ie: { RA: { statusWindow: { isDestroyed: () => false, showInactive: () => {} } } }, noop: () => {},
  globalThis: {
    __wisprStatusSnapshot: state => ({ state: state.toLowerCase(), hands_free: context.S.ZZ.isLocked }),
    __wisprStatusBridge: { setToggleHandsFree: fn => { toggle = fn; }, publish: value => publications.push(value) },
  },
  process: { platform: "darwin", resourcesPath: "/unused" },
};
vm.createContext(context);
vm.runInContext(source, context);
(async () => {
  assert.equal(typeof toggle, "function");
  for (const [state, locked, expected, mode] of [
    ["Idle", false, "start", true],
    ["Dismissed", false, "start", true],
    ["Listening", true, "stop", false],
  ]) {
    calls.length = 0;
    context.S.ZZ.status = state;
    context.S.ZZ.isLocked = locked;
    assert.deepEqual({ ...await toggle() }, { hands_free: mode });
    assert.deepEqual(calls, [expected]);
  }
  for (const [state, locked] of [["Listening", false], ["Processing", true], ["Error", true]]) {
    calls.length = 0;
    context.S.ZZ.status = state;
    context.S.ZZ.isLocked = locked;
    assert.deepEqual({ ...await toggle() }, { ok: false, error: "not_toggleable" });
    assert.deepEqual(calls, []);
  }
  context.globalThis.setLocked(true);
  assert.deepEqual({ ...publications.pop() }, { state: "error", hands_free: true });
})().catch(error => { console.error(error); process.exitCode = 1; });
JS
	run bash "$BATS_TEST_DIRNAME/../scripts/patches/linux-status-bridge.sh" "$fixture"
	[[ $status -eq 0 ]]
	run node "$driver" "$fixture"
	[[ $status -eq 0 ]]
}

@test "status patch rejects a one-line bundle containing every marker" {
	local fake="$BATS_TEST_TMPDIR/all-markers.js"
	printf '%s\n' '/*WISPR_LINUX_STATUS_BRIDGE WISPR_LINUX_STATUS_BOOTSTRAP WISPR_LINUX_STATUS_LIFECYCLE WISPR_LINUX_STATUS_PUBLICATION WISPR_LINUX_STATUS_CONTROL WISPR_LINUX_STATUS_WINDOW_SUPPRESSED WISPR_LINUX_STATUS_DICTATION_RESHOW_SUPPRESSED*/' > "$fake"
	run bash "$BATS_TEST_DIRNAME/../scripts/patches/linux-status-bridge.sh" "$fake"
	[[ $status -ne 0 ]]
}

@test "status patch leaves its current input intact when a later anchor fails" {
	[[ -n ${WISPR_FLOW_AUDIT_APP:-} && -f "$WISPR_FLOW_AUDIT_APP/.webpack/main/index.js" ]] || skip 'set WISPR_FLOW_AUDIT_APP to verified extracted 1.6.774 app'
	local fake="$BATS_TEST_TMPDIR/rollback.js"
	cp "$WISPR_FLOW_AUDIT_APP/.webpack/main/index.js" "$fake"
	[[ ! -f "$WISPR_FLOW_AUDIT_APP/.webpack/main/index.js.orig" ]] || cp "$WISPR_FLOW_AUDIT_APP/.webpack/main/index.js.orig" "$fake"
	sed -i 's/y.H8&&!J&&F.setEnabled(!0),e.showInactive(),y.H8&&/missing-status-window-anchor/' "$fake"
	local before
	before=$(sha256sum "$fake")
	run bash "$BATS_TEST_DIRNAME/../scripts/patches/linux-status-bridge.sh" "$fake"
	[[ $status -ne 0 ]]
	[[ "$before" == "$(sha256sum "$fake")" ]]
}
