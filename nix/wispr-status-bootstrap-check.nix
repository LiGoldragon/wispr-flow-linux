{
  runCommand,
  nodejs,
  wispr-flow,
}:
runCommand "wispr-flow-status-bootstrap"
  {
    nativeBuildInputs = [ nodejs ];
  }
  ''
    export XDG_RUNTIME_DIR="$TMPDIR/runtime"
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 0700 "$XDG_RUNTIME_DIR"
    export WISPR_STATUS_RESOURCES='${wispr-flow}/lib/wispr-flow/electron/resources'

    node - <<'NODE'
    const assert = require("node:assert/strict");
    const fs = require("node:fs");
    const path = require("node:path");

    process.resourcesPath = process.env.WISPR_STATUS_RESOURCES;
    const bridge = require(require("node:path").resolve(
      process.resourcesPath, "wispr-status-bridge.cjs"))
      .startStatusBridge({ snapshot: () => ({ state: "idle", hands_free: false }) });

    (async () => {
      await bridge.ready;
      for (const socketPath of [bridge.statusPath, bridge.controlPath]) {
        const stat = fs.lstatSync(socketPath);
        assert.equal(stat.isSocket(), true);
        assert.equal(stat.mode & 0o777, 0o600);
      }
      await bridge.close();
    })().catch(error => { console.error(error); process.exitCode = 1; });
    NODE

    touch "$out"
  ''
