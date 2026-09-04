{
  runCommand,
  nodejs,
  asar,
  wispr-flow,
}:
runCommand "wispr-flow-status-bootstrap"
  {
    nativeBuildInputs = [ nodejs asar ];
  }
  ''
    export XDG_RUNTIME_DIR="$TMPDIR/runtime"
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 0700 "$XDG_RUNTIME_DIR"
    export WISPR_STATUS_RESOURCES='${wispr-flow}/lib/wispr-flow/electron/resources'
    asar extract "$WISPR_STATUS_RESOURCES/app.asar" app
    export WISPR_STATUS_MAIN="$PWD/app/.webpack/main/index.js"

    node - <<'NODE'
    const assert = require("node:assert/strict");
    const fs = require("node:fs");
    const Module = require("node:module");
    const path = require("node:path");
    const vm = require("node:vm");

    (async () => {
      const mainPath = process.env.WISPR_STATUS_MAIN;
      const source = fs.readFileSync(mainPath, "utf8");
      const start = source.indexOf("e.app.whenReady().then(()=>{");
      const end = source.indexOf(",(0,Hn.xS)()", start);
      assert.ok(start >= 0 && end > start, "missing executable main startup path");

      const mainContext = {
        Promise,
        S: { ZZ: { status: "Idle", isLocked: false } },
        e: { app: { whenReady: () => Promise.resolve() } },
        n: () => ({ error: () => {}, warn: () => {} }),
        process: { platform: "linux", resourcesPath: process.env.WISPR_STATUS_RESOURCES },
        require: Module.createRequire(mainPath),
      };
      vm.createContext(mainContext);
      await vm.runInContext(source.slice(start, end), mainContext);
      const bridge = mainContext.__wisprStatusBridge;
      assert.ok(bridge, "main initialization did not start the bridge");
      await bridge.ready;
      for (const socketPath of [bridge.statusPath, bridge.controlPath]) {
        const stat = fs.lstatSync(socketPath);
        assert.equal(stat.isSocket(), true);
        assert.equal(stat.mode & 0o777, 0o600);
      }
      await bridge.close();
      for (const socketPath of [bridge.statusPath, bridge.controlPath]) {
        assert.equal(fs.existsSync(socketPath), false);
      }
    })().catch(error => { console.error(error); process.exitCode = 1; });
    NODE

    touch "$out"
  ''
