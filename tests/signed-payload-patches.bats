#!/usr/bin/env bats

@test "signed 1.6.774 payload accepts complete Linux patch suite" {
	[[ -n ${WISPR_FLOW_AUDIT_APP:-} && -f "$WISPR_FLOW_AUDIT_APP/.webpack/main/index.js" ]] || skip 'set WISPR_FLOW_AUDIT_APP to verified extracted 1.6.774 app'
	local copy="$BATS_TEST_TMPDIR/app"
	cp -a "$WISPR_FLOW_AUDIT_APP" "$copy"
	local main="$copy/.webpack/main/index.js"
	[[ ! -f "$WISPR_FLOW_AUDIT_APP/.webpack/main/index.js.orig" ]] \
		|| cp "$WISPR_FLOW_AUDIT_APP/.webpack/main/index.js.orig" "$main"
	for patch in helper-resolver.sh mac-gates.sh helper-env.sh linux-window-frame.sh linux-hub-viewport.sh linux-deeplink.sh linux-status-bridge.sh linux-dictation-completion.sh; do
		bash "$BATS_TEST_DIRNAME/../scripts/patches/$patch" "$main"
	done
	for renderer in "$copy"/.webpack/renderer/*/index.js; do
		[[ -f $renderer ]] && grep -qF 'platform?.isWindows' "$renderer" && bash "$BATS_TEST_DIRNAME/../scripts/patches/linux-renderer-treat-as-windows.sh" "$renderer"
	done
	bash "$BATS_TEST_DIRNAME/../scripts/patches/linux-renderer-chrome.sh" "$copy/.webpack/renderer/hub/index.js"
	bash "$BATS_TEST_DIRNAME/../scripts/patches/linux-status-meter-worklet.sh" "$copy/.webpack/renderer/dist/recorderWorklet.js"
	bash "$BATS_TEST_DIRNAME/../scripts/patches/linux-status-meter-renderer.sh" "$copy/.webpack/renderer/hub/index.js"
	node --check "$main"
	node --check "$copy/.webpack/renderer/dist/recorderWorklet.js"
	node --check "$copy/.webpack/renderer/hub/index.js"
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
const dismissExport={US:()=>ot,a1:()=>nt,t3:()=>Xe},escapeReason=e=>{e.UserActionEscape="user_action_escape"},bindings=s=>{const z=s(63205),c=s(89424)};
JS
	cat > "$driver" <<'JS'
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const source = fs.readFileSync(process.argv[2], "utf8");

const calls = [], publications = [], fail = {}, sentinel = { value: null };
let toggle;
const context = {
  e: { app: { whenReady: () => Promise.resolve() }, showInactive: () => {} },
  n: () => ({ error: () => {}, warn: () => {} }),
  p: { ZZ: { status: "Idle" } },
  S: { ZZ: { status: "Idle", isLocked: false } },
  c: { _W: { Idle: "Idle", Dismissed: "Dismissed", Listening: "Listening", Processing: "Processing", Error: "Error" }, W5: { UserActionEscape: "user_action_escape" }, B8: ["Listening", "Processing"] , SB: { Deeplink: "wispr-flow:" } },
  z: {
    Qw: async () => { calls.push("start"); if (fail.start) throw new Error("start rejected"); context.S.ZZ.status = "Listening"; context.S.ZZ.isLocked = true; },
    US: async () => { calls.push("stop"); context.S.ZZ.status = "Idle"; context.S.ZZ.isLocked = false; },
    t3: reason => { calls.push(`dismiss:${reason}`); if (fail.dismiss === "throw") throw new Error("dismiss threw"); if (fail.dismiss === "inert") return; sentinel.value = null; context.S.ZZ.status = "Dismissed"; context.S.ZZ.isLocked = false; },
  },
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
  const run = async (state, locked, owner = null) => {
    calls.length = 0;
    context.S.ZZ.status = state;
    context.S.ZZ.isLocked = locked;
    context.globalThis.__wisprDictationOwner = owner;
    return { ...await toggle() };
  };
  for (const [state, locked, expected, mode] of [
    ["Idle", false, "start", true],
    ["Dismissed", false, "start", true],
    ["Listening", true, "stop", false],
  ]) {
    assert.deepEqual(await run(state, locked), { hands_free: mode });
    assert.deepEqual(calls, [expected]);
  }
  // Error leaves through the real dismiss, then starts: final state recording, sentinel cleared.
  sentinel.value = "stale-session";
  assert.deepEqual(await run("Error", false), { hands_free: true });
  assert.deepEqual(calls, ["dismiss:user_action_escape", "start"]);
  assert.equal(context.S.ZZ.status, "Listening");
  assert.equal(context.S.ZZ.isLocked, true);
  assert.equal(sentinel.value, null);
  // Repeated toggle after recovery stops the recording it started.
  calls.length = 0;
  assert.deepEqual({ ...await toggle() }, { hands_free: false });
  assert.deepEqual(calls, ["stop"]);
  assert.equal(context.S.ZZ.status, "Idle");
  // Dismiss throws: no start, the error propagates to the bridge as action_failed.
  fail.dismiss = "throw";
  await assert.rejects(run("Error", false), /dismiss threw/);
  assert.deepEqual(calls, ["dismiss:user_action_escape"]);
  assert.equal(context.S.ZZ.status, "Error");
  // Dismiss leaves the status in Error: no start, explicit refusal.
  fail.dismiss = "inert";
  assert.deepEqual(await run("Error", false), { ok: false, error: "not_dismissed" });
  assert.deepEqual(calls, ["dismiss:user_action_escape"]);
  delete fail.dismiss;
  // Start rejects after a real dismiss: Dismissed, not Error, and the next toggle starts.
  fail.start = true;
  await assert.rejects(run("Error", false), /start rejected/);
  assert.deepEqual(calls, ["dismiss:user_action_escape", "start"]);
  assert.equal(context.S.ZZ.status, "Dismissed");
  delete fail.start;
  assert.deepEqual(await run("Dismissed", false), { hands_free: true });
  assert.deepEqual(calls, ["start"]);
  // A pipeline still owning completion refuses Error and Dismissed starts, touching nothing.
  for (const state of ["Error", "Dismissed"]) {
    assert.deepEqual(await run(state, false, { uuid: "A" }), { ok: false, error: "busy" });
    assert.deepEqual(calls, []);
    assert.equal(context.S.ZZ.status, state);
  }
  // From Idle the owner is in its tail: a new capture starts.
  assert.deepEqual(await run("Idle", false, { uuid: "A" }), { hands_free: true });
  assert.deepEqual(calls, ["start"]);
  // A locked recording stops even while an older pipeline owns completion.
  assert.deepEqual(await run("Listening", true, { uuid: "A" }), { hands_free: false });
  assert.deepEqual(calls, ["stop"]);
  for (const [state, locked] of [["Listening", false], ["Processing", true]]) {
    assert.deepEqual(await run(state, locked), { ok: false, error: "not_toggleable" });
    assert.deepEqual(calls, []);
  }
  context.S.ZZ.status = "Error";
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
	printf '%s\n' '/*WISPR_LINUX_STATUS_BRIDGE WISPR_LINUX_STATUS_BOOTSTRAP WISPR_LINUX_STATUS_LIFECYCLE WISPR_LINUX_STATUS_PUBLICATION WISPR_LINUX_STATUS_CONTROL WISPR_LINUX_STATUS_METER_MAIN WISPR_LINUX_STATUS_WINDOW_SUPPRESSED WISPR_LINUX_STATUS_DICTATION_RESHOW_SUPPRESSED*/' > "$fake"
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
