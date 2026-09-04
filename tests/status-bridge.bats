#!/usr/bin/env bats

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
BRIDGE="$SCRIPT_DIR/../scripts/wispr-status-bridge.cjs"
CLI="$SCRIPT_DIR/../scripts/wispr-flow-status.cjs"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP BRIDGE CLI
}

teardown() {
	if [[ -n ${TEST_TMP:-} && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "bridge publishes an initial private snapshot and sequenced transitions" {
	run node - <<'NODE'
const assert = require("node:assert/strict");
const fs = require("node:fs");
const net = require("node:net");
const { startStatusBridge } = require(process.env.BRIDGE);

const runtime = `${process.env.TEST_TMP}/runtime`;
fs.mkdirSync(runtime, { mode: 0o700 });
const bridge = startStatusBridge({
  runtimeDir: runtime,
  snapshot: () => ({ state: "idle", hands_free: false }),
});

function next(path) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(path);
    let buffer = "";
    socket.on("data", (chunk) => {
      buffer += chunk;
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;
      socket.destroy();
      resolve(JSON.parse(buffer.slice(0, newline)));
    });
    socket.on("error", reject);
  });
}

(async () => {
  await bridge.ready;
  assert.equal(fs.statSync(bridge.statusPath).mode & 0o777, 0o600);
  const subscriber = net.connect(bridge.statusPath);
  let lines = "";
  const transition = new Promise((resolve, reject) => { subscriber.on("data", chunk => { lines += chunk; const packets = lines.trim().split("\n"); if (packets.length === 2) resolve([JSON.parse(packets[0]), JSON.parse(packets[1])]); }); subscriber.on("error", reject); });
  const initial = await next(bridge.statusPath);
  assert.equal(initial.contract, "com.criomos.wispr.status.v1");
  assert.equal(initial.type, "snapshot");
  assert.equal(initial.state, "idle");
  assert.equal(initial.hands_free, false);
  bridge.publish({ state: "recording", hands_free: true });
  const [subscriberInitial, subscriberTransition] = await transition;
  assert.equal(subscriberInitial.state, "idle");
  assert.equal(subscriberTransition.state, "recording");
  subscriber.destroy();
  const updated = await next(bridge.statusPath);
  assert.equal(updated.state, "recording");
  assert.equal(updated.hands_free, true);
  assert.ok(updated.sequence > initial.sequence);
  assert.equal(updated.session_id, initial.session_id);
  assert.deepEqual(Object.keys(updated).sort(),
    ["contract", "hands_free", "sequence", "session_id", "state", "type"]);
  await bridge.close();
})().catch((error) => { console.error(error); process.exitCode = 1; });
NODE
	[[ $status -eq 0 ]]
}

@test "bridge control replies only after the registered hands-free action" {
	run node - <<'NODE'
const assert = require("node:assert/strict");
const fs = require("node:fs");
const net = require("node:net");
const { startStatusBridge } = require(process.env.BRIDGE);

const runtime = `${process.env.TEST_TMP}/runtime`;
fs.mkdirSync(runtime, { mode: 0o700 });
let actions = 0;
const bridge = startStatusBridge({
  runtimeDir: runtime,
  snapshot: () => ({ state: "idle", hands_free: false }),
});
bridge.setToggleHandsFree(async () => {
  actions += 1;
  setTimeout(() => bridge.publish({ state: "recording", hands_free: true }), 5);
  return { hands_free: true };
});

(async () => {
  await bridge.ready;
  const reply = await new Promise((resolve, reject) => {
    const socket = net.connect(bridge.controlPath);
    let buffer = "";
    socket.on("connect", () => socket.write(JSON.stringify({
      contract: "com.criomos.wispr.status.v1",
      type: "control",
      id: "test-toggle",
      command: "toggle_hands_free",
    }) + "\n"));
    socket.on("data", (chunk) => {
      buffer += chunk;
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;
      socket.destroy();
      resolve(JSON.parse(buffer.slice(0, newline)));
    });
    socket.on("error", reject);
  });
  assert.equal(actions, 1);
  assert.deepEqual(reply, {
    contract: "com.criomos.wispr.status.v1",
    type: "control_result",
    id: "test-toggle",
    ok: true,
    hands_free: true,
  });
  await bridge.close();
})().catch((error) => { console.error(error); process.exitCode = 1; });
NODE
	[[ $status -eq 0 ]]
}

@test "lifecycle mapping makes Listening recording and unknown states errors" {
	run node - <<'NODE'
const assert = require("node:assert/strict");
const { mapWisprState } = require(process.env.BRIDGE);
assert.deepEqual(mapWisprState("listening"), {state:"recording"});
assert.deepEqual(mapWisprState("initializing"), {state:"recording"});
assert.deepEqual(mapWisprState("processing"), {state:"transcribing"});
assert.deepEqual(mapWisprState("testing"), {state:"error",error:"unknown_lifecycle_state"});
NODE
	[[ $status -eq 0 ]]
}

@test "control accepts the authoritative transition published synchronously by its action" {
	run node - <<'NODE'
const assert=require("node:assert/strict"),fs=require("node:fs"),net=require("node:net"),{startStatusBridge}=require(process.env.BRIDGE);
const runtime=`${process.env.TEST_TMP}/runtime`;fs.mkdirSync(runtime,{mode:0o700}); const bridge=startStatusBridge({runtimeDir:runtime,controlTimeoutMs:40,snapshot:()=>({state:"idle",hands_free:false})});
bridge.setToggleHandsFree(async()=>{bridge.publish({state:"recording",hands_free:true});return {hands_free:true}});
(async()=>{await bridge.ready;const reply=await new Promise((resolve,reject)=>{const s=net.connect(bridge.controlPath);let b="";s.on("connect",()=>s.write('{"contract":"com.criomos.wispr.status.v1","type":"control","id":"sync","command":"toggle_hands_free"}\n'));s.on("data",d=>{b+=d;const n=b.indexOf("\n");if(n>=0){s.destroy();resolve(JSON.parse(b.slice(0,n)))}});s.on("error",reject)});assert.equal(reply.ok,true);await bridge.close()})().catch(e=>{console.error(e);process.exitCode=1});
NODE
	[[ $status -eq 0 ]]
}

@test "bridge close destroys incomplete control clients before server shutdown" {
	run node - <<'NODE'
const assert=require("node:assert/strict"),fs=require("node:fs"),net=require("node:net"),{startStatusBridge}=require(process.env.BRIDGE);
const runtime=`${process.env.TEST_TMP}/runtime`;fs.mkdirSync(runtime,{mode:0o700});const bridge=startStatusBridge({runtimeDir:runtime});
(async()=>{await bridge.ready;const client=net.connect(bridge.controlPath);client.on("error",()=>{});await new Promise(r=>client.once("connect",r));client.write('{"contract":');const closed=new Promise(r=>client.once("close",r));await Promise.race([bridge.close(),new Promise((_,reject)=>setTimeout(()=>reject(new Error("close hung")),100))]);await closed;assert.equal(client.destroyed,true)})().catch(e=>{console.error(e);process.exitCode=1});
NODE
	[[ $status -eq 0 ]]
}

@test "control rejects action failure and pre-existing target without a new transition" {
	run node - <<'NODE'
const assert=require("node:assert/strict"),fs=require("node:fs"),net=require("node:net"),{startStatusBridge}=require(process.env.BRIDGE);
const runtime=`${process.env.TEST_TMP}/runtime`;fs.mkdirSync(runtime,{mode:0o700});
const request=(p,id)=>new Promise((resolve,reject)=>{const s=net.connect(p);let b="";s.on("connect",()=>s.write(JSON.stringify({contract:"com.criomos.wispr.status.v1",type:"control",id,command:"toggle_hands_free"})+"\n"));s.on("data",d=>{b+=d;const n=b.indexOf("\n");if(n>=0){s.destroy();resolve(JSON.parse(b.slice(0,n)))}});s.on("error",reject)});
(async()=>{let bridge=startStatusBridge({runtimeDir:runtime,controlTimeoutMs:30,snapshot:()=>({state:"idle",hands_free:false})});bridge.setToggleHandsFree(async()=>{throw new Error("rejected")});await bridge.ready;assert.equal((await request(bridge.controlPath,"reject")).error,"action_failed");await bridge.close();bridge=startStatusBridge({runtimeDir:runtime,controlTimeoutMs:30,snapshot:()=>({state:"recording",hands_free:true})});bridge.setToggleHandsFree(async()=>({hands_free:true}));await bridge.ready;assert.equal((await request(bridge.controlPath,"old")).error,"state_timeout");await bridge.close()})().catch(e=>{console.error(e);process.exitCode=1});
NODE
	[[ $status -eq 0 ]]
}

@test "a second bridge never steals live sockets or unlinks its owner" {
	run node - <<'NODE'
const assert = require("node:assert/strict"), fs=require("node:fs");
const {startStatusBridge}=require(process.env.BRIDGE); const runtime=`${process.env.TEST_TMP}/runtime`; fs.mkdirSync(runtime,{mode:0o700});
(async()=>{const first=startStatusBridge({runtimeDir:runtime}); await first.ready; const second=startStatusBridge({runtimeDir:runtime}); await assert.rejects(second.ready,/live status bridge/); assert.equal(fs.existsSync(first.statusPath),true); await first.close();})().catch(e=>{console.error(e);process.exitCode=1});
NODE
	[[ $status -eq 0 ]]
}

@test "CLI times out and rejects a peer that closes before replying" {
	run node - <<'NODE'
const assert=require("node:assert/strict"),fs=require("node:fs"),net=require("node:net"),{spawn}=require("node:child_process");
const runtime=`${process.env.TEST_TMP}/runtime`;fs.mkdirSync(runtime,{mode:0o700});const p=`${runtime}/wispr-flow-control-v1.sock`;
const server=net.createServer(s=>s.end());server.listen(p,()=>{const child=spawn(process.execPath,[process.env.CLI,"toggle-hands-free"],{env:{...process.env,XDG_RUNTIME_DIR:runtime,WISPR_FLOW_STATUS_TIMEOUT_MS:"50"}});let err="";child.stderr.on("data",d=>err+=d);child.on("close",code=>server.close(()=>{assert.equal(code,1);assert.match(err,/closed without a reply/)}));});
NODE
	[[ $status -eq 0 ]]
}

@test "packaged CLI sends the typed toggle command and prints its reply" {
	run node - <<'NODE'
const assert = require("node:assert/strict");
const fs = require("node:fs");
const net = require("node:net");
const { spawn } = require("node:child_process");

const runtime = `${process.env.TEST_TMP}/runtime`;
fs.mkdirSync(runtime, { mode: 0o700 });
const path = `${runtime}/wispr-flow-control-v1.sock`;
const server = net.createServer((socket) => {
  let buffer = "";
  socket.on("data", (chunk) => {
    buffer += chunk;
    const newline = buffer.indexOf("\n");
    if (newline < 0) return;
    const request = JSON.parse(buffer.slice(0, newline));
    assert.equal(request.contract, "com.criomos.wispr.status.v1");
    assert.equal(request.type, "control");
    assert.equal(request.command, "toggle_hands_free");
    socket.end(JSON.stringify({
      contract: request.contract,
      type: "control_result",
      id: request.id,
      ok: true,
      hands_free: true,
    }) + "\n");
  });
});

server.listen(path, () => {
  const child = spawn(process.execPath, [process.env.CLI, "toggle-hands-free"], {
    env: { ...process.env, XDG_RUNTIME_DIR: runtime },
  });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  child.on("close", (code) => {
    server.close(() => {
      assert.equal(code, 0, stderr);
      assert.equal(JSON.parse(stdout).hands_free, true);
    });
  });
});
NODE
	[[ $status -eq 0 ]]
}
