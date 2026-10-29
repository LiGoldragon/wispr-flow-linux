#!/usr/bin/env bats

PATCH="$BATS_TEST_DIRNAME/../scripts/patches/linux-dictation-completion.sh"

# A fixture xt with upstream's exact anchors and shape: a boolean latch around
# the pipeline, the session uuid captured into i, Idle published before the
# last await (the history save), and an inner finally that writes end-of-
# dictation timing, sends PasteText telemetry and guards its own reset.
write_fixture() {
	cat > "$1" <<'JS'
let Lt=!1,Dt=null;const xt=async e=>{const t=e,{transcriptionEntityUuid:n}=e;if(c.ZZ.status===Le._W.Testing||void 0===n||n===c.ZZ.uuid)if(Lt)s().warn(`onRecordingDone called while already processing (uuid: ${c.ZZ.uuid}). Ignoring duplicate.`);else{Lt=!0;try{yt=!1;const i=c.ZZ.uuid;let S={status:"formatted"},k=1,W="w",U=!1,j=!1,Q=!1,H=null,V=null;try{processed.push(i);c.ZZ.status=Le._W.Idle;await history(i)}catch(t){s().error("pipeline failed")}finally{null!==H&&(H(),H=null),null!==V&&(clearTimeout(V),V=null),null===c.ZZ.timingInformation.endTime&&((0,c.eZ)(c.Fy.EndTime),c.ZZ.basetenNetworkMetrics.endToEndTimeMsecs=I(c.ZZ.timingInformation.recorderTimingInfo.absoluteStopTime));const e=0;(0,He.dR)(e);const n=c.ZZ.status===Le._W.Dismissed;if(!n){(0,a.yZ)(S,k,W,U,e,j,n,Q)}c.ZZ.uuid===i||""===c.ZZ.uuid?(0,c.f4)():s().info(`Skipping resetTranscriptState in finally - new dictation ${c.ZZ.uuid} already started`)}}finally{Lt=!1}}else s().warn("Dropping recording-done from a stale session",{customAttributes:{doneTranscriptionEntityUuid:n,currentUuid:c.ZZ.uuid}})};
JS
}

write_driver() {
	cat > "$1" <<'JS'
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const source = fs.readFileSync(process.argv[2], "utf8") + "\n;globalThis.__xt=xt;";
const scenario = process.argv[3];
const patched = source.includes("WISPR_LINUX_DICTATION_COMPLETION_SERIAL");

const log = [], processed = [], telemetry = [], resets = [], pending = new Map();
const session = uuid => ({ uuid, status: "Listening", timingInformation: { endTime: null, recorderTimingInfo: { absoluteStopTime: 1 } }, basetenNetworkMetrics: { endToEndTimeMsecs: null } });
const c = { ZZ: session("A"), Fy: { EndTime: "end" } };
c.eZ = () => { c.ZZ.timingInformation.endTime = `set-by-${context.current}`; };
c.f4 = () => resets.push(c.ZZ.uuid);
const context = {
  c, Le: { _W: { Testing: "testing", Idle: "idle", Dismissed: "dismissed" } },
  s: () => ({ warn: m => log.push(`warn:${m}`), info: m => log.push(`info:${m}`), error: m => log.push(`error:${m}`) }),
  I: () => 1, He: { dR: () => {} }, a: { yZ: () => telemetry.push({ by: context.current, live: c.ZZ.uuid }) },
  processed, yt: !0, current: null,
  history: uuid => { context.current = uuid; if (scenario === "throw" && uuid === "A") return Promise.reject(new Error("history failed")); return new Promise(resolve => pending.set(uuid, () => { context.current = uuid; resolve(); })); },
};
context.globalThis = context;
vm.createContext(context);
vm.runInContext(source, context);
const xt = context.__xt;
const tick = () => new Promise(resolve => setImmediate(resolve));
const newSession = uuid => { c.ZZ = session(uuid); };

(async () => {
  if (scenario === "throw") {
    await xt({ transcriptionEntityUuid: "A" });
    newSession("B");
    const b = xt({ transcriptionEntityUuid: "B" });
    await tick();
    assert.deepEqual(processed, ["A", "B"]);
    pending.get("B")(); await b;
    assert.equal(context.globalThis.__wisprDictationOwner ?? null, null);
    return;
  }
  // A completes and holds in its tail: Idle already published, history pending.
  const a = xt({ transcriptionEntityUuid: "A" });
  await tick();
  assert.equal(c.ZZ.status, "idle");
  if (patched) assert.equal(context.__wisprDictationOwner?.uuid, "A");
  // Same-session duplicate and Testing completions keep upstream's drop.
  await xt({ transcriptionEntityUuid: "A" });
  c.ZZ.status = "testing"; await xt({}); c.ZZ.status = "idle";
  // B records during A's tail and finishes before A releases; its completion
  // is also delivered twice.
  newSession("B");
  const b = xt({ transcriptionEntityUuid: "B" });
  const bAgain = scenario === "stale" ? Promise.resolve() : xt({ transcriptionEntityUuid: "B" });
  await tick();
  if (scenario === "stale") {
    // A recovery replaces B with C before A releases: B is stale, not processed.
    newSession("C");
    pending.get("A")(); await a; await b;
    assert.deepEqual(processed, ["A"]);
    assert.ok(log.some(l => l.startsWith("warn:Dropping recording-done from a stale session")));
    return;
  }
  assert.deepEqual(processed, ["A"], "B must not run while A owns completion");
  pending.get("A")(); await a;
  await tick(); await bAgain;
  assert.deepEqual(processed, ["A", "B"], "B's completion must run after A releases");
  assert.equal(log.filter(l => l.includes("Ignoring duplicate")).length, 3, "same-session duplicates and Testing completions are dropped");
  // A's tail never touched B: no end time, no PasteText built from B's globals, no reset.
  assert.equal(c.ZZ.timingInformation.endTime, null);
  assert.deepEqual(telemetry, []);
  assert.deepEqual(resets, []);
  assert.equal(context.__wisprDictationOwner?.uuid, "B");
  pending.get("B")(); await b;
  assert.equal(c.ZZ.timingInformation.endTime, "set-by-B");
  assert.deepEqual(telemetry, [{ by: "B", live: "B" }]);
  assert.deepEqual(resets, ["B"]);
  assert.equal(context.__wisprDictationOwner, null);
})().catch(error => { console.error(error); process.exitCode = 1; });
JS
}

setup() {
	FIX="$BATS_TEST_TMPDIR/xt.js"; DRV="$BATS_TEST_TMPDIR/driver.js"
	write_fixture "$FIX"; write_driver "$DRV"
}

@test "second completion during the previous tail is dropped by upstream" {
	run node "$DRV" "$FIX" overlap
	[[ $status -ne 0 ]]
	[[ "$output" == *"B's completion must run after A releases"* ]]
}

@test "second completion waits for the owner and the old tail leaves the live session alone" {
	run bash "$PATCH" "$FIX"
	[[ $status -eq 0 ]]
	run node "$DRV" "$FIX" overlap
	echo "$output"
	[[ $status -eq 0 ]]
}

@test "a waiter whose session was replaced falls through to the stale-session drop" {
	bash "$PATCH" "$FIX"
	run node "$DRV" "$FIX" stale
	echo "$output"
	[[ $status -eq 0 ]]
}

@test "a failing pipeline still releases ownership" {
	bash "$PATCH" "$FIX"
	run node "$DRV" "$FIX" throw
	echo "$output"
	[[ $status -eq 0 ]]
}

@test "completion patch is idempotent and fails closed on a drifted anchor" {
	bash "$PATCH" "$FIX"
	run bash "$PATCH" "$FIX"
	[[ $status -eq 0 && "$output" == *"Already patched"* ]]
	write_fixture "$FIX"
	sed -i 's/else{Lt=!0;try{yt=!1;/else{Lt=!0;try{yt=!0;/' "$FIX"
	cp "$FIX" "$FIX.orig"
	run bash "$PATCH" "$FIX"
	[[ $status -ne 0 ]]
	cmp "$FIX" "$FIX.orig"
}
