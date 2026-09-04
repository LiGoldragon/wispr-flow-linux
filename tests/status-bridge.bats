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
  const initial = await next(bridge.statusPath);
  assert.equal(initial.contract, "com.criomos.wispr.status.v1");
  assert.equal(initial.type, "snapshot");
  assert.equal(initial.state, "idle");
  assert.equal(initial.hands_free, false);
  bridge.publish({ state: "recording", hands_free: true });
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
