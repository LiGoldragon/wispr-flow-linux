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
    const net = require("node:net");
    const path = require("node:path");
    const vm = require("node:vm");

    let bridge;
    const requestControl = (id) => new Promise((resolve, reject) => {
      const socket = net.connect(bridge.controlPath);
      let buffer = "";
      const timer = setTimeout(() => {
        socket.destroy();
        reject(new Error(`control request $${id} timed out`));
      // The bridge's action-to-state confirmation window is 3000ms; the client
      // deadline must exceed it while still bounding a stalled socket.
      }, 5000);
      const finish = callback => value => {
        clearTimeout(timer);
        socket.destroy();
        callback(value);
      };
      socket.on("connect", () => socket.write(JSON.stringify({
        contract: "com.criomos.wispr.status.v2",
        type: "control",
        id,
        command: "toggle_hands_free",
      }) + "\n"));
      socket.on("data", chunk => {
        buffer += chunk;
        const newline = buffer.indexOf("\n");
        if (newline >= 0) finish(resolve)(JSON.parse(buffer.slice(0, newline)));
      });
      socket.on("error", finish(reject));
    });

    (async () => {
      try {
      const mainPath = process.env.WISPR_STATUS_MAIN;
      const source = fs.readFileSync(mainPath, "utf8");
      const start = source.indexOf("e.app.whenReady().then(()=>{");
      const end = source.indexOf(",(0,Hn.xS)()", start);
      assert.ok(start >= 0 && end > start, "missing executable main startup path");

      const controlCalls = [];
      const mainContext = {
        Promise,
        S: { ZZ: { status: "Idle", isLocked: false } },
        c: {
          _W: { Idle: "Idle", Dismissed: "Dismissed", Listening: "Listening" },
          SB: { Deeplink: "wispr-flow:" },
        },
        e: { app: { whenReady: () => Promise.resolve() } },
        n: () => ({ error: () => {}, warn: () => {} }),
        process: { platform: "linux", resourcesPath: process.env.WISPR_STATUS_RESOURCES },
        require: Module.createRequire(mainPath),
      };
      mainContext.z = {
        Qw: async () => {
          controlCalls.push("start");
          mainContext.S.ZZ.isLocked = true;
          mainContext.__wisprStatusBridge.publish(
            mainContext.__wisprStatusSnapshot(mainContext.S.ZZ.status),
          );
        },
        US: async () => {
          controlCalls.push("stop");
          mainContext.S.ZZ.isLocked = false;
          mainContext.__wisprStatusBridge.publish(
            mainContext.__wisprStatusSnapshot(mainContext.S.ZZ.status),
          );
        },
      };
      vm.createContext(mainContext);
      const controlBegin = "/*WISPR_LINUX_STATUS_CONTROL_BEGIN*/";
      const controlEnd = "/*WISPR_LINUX_STATUS_CONTROL_END*/";
      assert.equal(source.split(controlBegin).length - 1, 1,
        "one packaged control registration");
      assert.equal(source.split(controlEnd).length - 1, 1,
        "one packaged control registration end");
      const controlRegistration = source.slice(
        source.indexOf(controlBegin) + controlBegin.length,
        source.indexOf(controlEnd),
      );
      // The application reaches this real hands-free path before Electron
      // readiness. It must retain the action for bootstrap instead of losing it
      // through an optional chain while the bridge does not yet exist.
      vm.runInContext(controlRegistration, mainContext);
      assert.equal(typeof mainContext.__wisprStatusToggleHandsFree, "function",
        "packaged hands-free path did not retain its control action");
      await vm.runInContext(source.slice(start, end), mainContext);
      bridge = mainContext.__wisprStatusBridge;
      assert.ok(bridge, "main initialization did not start the bridge");
      await bridge.ready;
      for (const socketPath of [bridge.statusPath, bridge.controlPath]) {
        const stat = fs.lstatSync(socketPath);
        assert.equal(stat.isSocket(), true);
        assert.equal(stat.mode & 0o777, 0o600);
      }
      const controlReply = await requestControl("packaged-bootstrap-start");
      assert.deepEqual({ ...controlReply }, {
        contract: "com.criomos.wispr.status.v2",
        type: "control_result",
        id: "packaged-bootstrap-start",
        ok: true,
        hands_free: true,
      });
      mainContext.S.ZZ.status = "Listening";
      const stopReply = await requestControl("packaged-bootstrap-stop");
      assert.deepEqual({ ...stopReply }, {
        contract: "com.criomos.wispr.status.v2",
        type: "control_result",
        id: "packaged-bootstrap-stop",
        ok: true,
        hands_free: false,
      });
      assert.deepEqual(controlCalls, ["start", "stop"]);

      const workletPath = path.join(
        path.dirname(path.dirname(mainPath)),
        "renderer/dist/recorderWorklet.js",
      );
      const workletSource = fs.readFileSync(workletPath, "utf8");
      const posted = [];
      class AudioWorkletProcessor {
        constructor() { this.port = { postMessage: value => posted.push(value) }; }
      }
      let RecorderProcessor;
      const workletContext = {
        AudioWorkletProcessor,
        Float32Array,
        Uint16Array,
        Set,
        Math,
        Number,
        registerProcessor: (_, processor) => { RecorderProcessor = processor; },
      };
      vm.createContext(workletContext);
      vm.runInContext(workletSource, workletContext);
      const recorder = new RecorderProcessor({ numberOfInputs: 1 });
      recorder.port.onmessage({ data: "start" });
      assert.deepEqual({ ...posted.pop() }, {
        type: "wispr-flow-status-meter-v2", capture: true, rms: 0,
      });
      for (const [samples, expected] of [
        [[0, 1], Math.sqrt(0.5)],
        [[0, 0.5, 0.5, 0.5], Math.sqrt(0.1875)],
        [[-0.5, 0.5], 0.5],
        [[NaN, 0.5], 0],
        [[2], 1],
      ]) {
        posted.length = 0;
        recorder.process([[Float32Array.from({ length: 640 }, (_, index) => samples[index % samples.length])]]);
        const meter = posted.find(value => value?.type === "wispr-flow-status-meter-v2");
        assert.ok(meter, "actual recorder worklet did not emit a scalar meter");
        assert.equal(meter.capture, true);
        assert.ok(Math.abs(meter.rms - expected) < 1e-6, `$${meter.rms} != $${expected}`);
        assert.equal(Object.keys(meter).sort().join(","), "capture,rms,type");
      }
      recorder.port.onmessage({ data: "stop" });
      assert.deepEqual({ ...posted.at(-2) }, {
        type: "wispr-flow-status-meter-v2", capture: false,
      });

      const hubPath = path.join(path.dirname(path.dirname(mainPath)), "renderer/hub/index.js");
      const hubSource = fs.readFileSync(hubPath, "utf8");
      const extract = (source, begin, end, label) => {
        assert.equal(source.split(begin).length - 1, 1, `one $${label} begin marker`);
        assert.equal(source.split(end).length - 1, 1, `one $${label} end marker`);
        return source.slice(source.indexOf(begin) + begin.length, source.indexOf(end));
      };
      const handlerStart = hubSource.indexOf(
        "static async handleRecorderWorkletMessage(e){",
      );
      const handlerEnd = hubSource.indexOf(
        "static async condReloadAudioCxOnStop()",
        handlerStart,
      );
      assert.ok(handlerStart >= 0 && handlerEnd > handlerStart,
        "missing executable recorder worklet handler");
      const handlerSource = hubSource.slice(handlerStart, handlerEnd).replace(
        "static async handleRecorderWorkletMessage",
        "async function handleRecorderWorkletMessage",
      );
      const sent = [];
      const rendererContext = {
        window: { electron: { ipc: { send: (...args) => sent.push(args) } } },
      };
      rendererContext.globalThis = rendererContext;
      vm.createContext(rendererContext);
      const handleRecorderWorkletMessage = vm.runInContext(
        `(''${handlerSource})`, rendererContext,
      );
      for (const [message, expected] of [
        [
          { type: "wispr-flow-status-meter-v2", capture: true, rms: 0.5 },
          { type: "wispr-flow-status-meter-v2", capture: true, rms: 0.5 },
        ],
        [
          { type: "wispr-flow-status-meter-v2", capture: false },
          { type: "wispr-flow-status-meter-v2", capture: false },
        ],
      ]) {
        sent.length = 0;
        await handleRecorderWorkletMessage({ data: message });
        assert.deepEqual(sent.map(args => [args[0], { ...args[1] }]), [
          ["wispr-flow-status-meter-v2", expected],
        ]);
      }
      sent.length = 0;
      await handleRecorderWorkletMessage({ data: {
        type: "wispr-flow-status-meter-v2", capture: true, rms: Infinity,
      } });
      assert.deepEqual(sent, [], "invalid meter reached IPC");

      const mainMeter = extract(source,
        "/*WISPR_LINUX_STATUS_METER_MAIN_BEGIN*/",
        "/*WISPR_LINUX_STATUS_METER_MAIN_END*/", "main meter");
      const publishedMeters = [];
      const meterContext = {
        __wisprStatusBridge: { publishMeter: value => { publishedMeters.push(value); return true; } },
      };
      meterContext.globalThis = meterContext;
      vm.createContext(meterContext);
      vm.runInContext(mainMeter, meterContext);
      assert.equal(meterContext.__wisprStatusMeterMessage({
        type: "wispr-flow-status-meter-v2", capture: true, rms: 0.5,
      }), true);
      assert.equal(meterContext.__wisprStatusMeterMessage({
        type: "wispr-flow-status-meter-v2", capture: true, rms: NaN,
      }), false);
      assert.equal(meterContext.__wisprStatusMeterMessage({
        type: "wispr-flow-status-meter-v2", capture: false,
      }), true);
      assert.deepEqual(publishedMeters.map(value => ({ ...value })), [
        { capture: "available", rms: 0.5 },
        { capture: "unavailable" },
      ]);

      const extractMarkedExpression = (begin, end, label) => {
        const count = marker => source.split(marker).length - 1;
        assert.equal(count(begin), 1, `expected one $${label} begin marker`);
        assert.equal(count(end), 1, `expected one $${label} end marker`);
        const first = source.indexOf(begin) + begin.length;
        const last = source.indexOf(end);
        assert.ok(last > first, `empty $${label} payload expression`);
        return source.slice(first, last);
      };
      const controlHook = extractMarkedExpression(
        "/*WISPR_LINUX_STATUS_CONTROL_BEGIN*/",
        "/*WISPR_LINUX_STATUS_CONTROL_END*/",
        "control hook",
      );
      const lockExpression = extractMarkedExpression(
        "/*WISPR_LINUX_STATUS_MODE_PUBLICATION_BEGIN*/",
        "/*WISPR_LINUX_STATUS_MODE_PUBLICATION_END*/",
        "lock-mode publication",
      );

      const calls = [];
      const publications = [];
      let toggle;
      const hookContext = {
        S: { ZZ: { status: "Idle", isLocked: false } },
        c: {
          _W: {
            Idle: "Idle",
            Dismissed: "Dismissed",
            Listening: "Listening",
            Processing: "Processing",
            Error: "Error",
          },
          SB: { Deeplink: "wispr-flow:" },
        },
        z: {
          Qw: async () => calls.push("start"),
          US: async () => calls.push("stop"),
        },
        e: true,
      };
      hookContext.__wisprStatusSnapshot = state => ({
        state,
        hands_free: hookContext.S.ZZ.isLocked,
      });
      hookContext.__wisprStatusBridge = {
        setToggleHandsFree: fn => { toggle = fn; },
        publish: value => publications.push(value),
      };
      vm.createContext(hookContext);
      vm.runInContext(controlHook, hookContext);
      assert.equal(typeof toggle, "function",
        "signed payload did not register its control hook");

      for (const [state, locked, action, handsFree] of [
        ["Idle", false, "start", true],
        ["Dismissed", false, "start", true],
        ["Listening", true, "stop", false],
      ]) {
        calls.length = 0;
        hookContext.S.ZZ.status = state;
        hookContext.S.ZZ.isLocked = locked;
        assert.deepEqual({ ...await toggle() }, { hands_free: handsFree });
        assert.deepEqual(calls, [action]);
      }
      for (const [state, locked] of [
        ["Listening", false],
        ["Processing", true],
        ["Error", true],
      ]) {
        calls.length = 0;
        hookContext.S.ZZ.status = state;
        hookContext.S.ZZ.isLocked = locked;
        assert.deepEqual({ ...await toggle() }, {
          ok: false,
          error: "not_toggleable",
        });
        assert.deepEqual(calls, []);
      }
      vm.runInContext(lockExpression, hookContext);
      assert.deepEqual({ ...publications.pop() }, {
        state: "Error",
        hands_free: true,
      });
      } finally {
        if (bridge) await bridge.close();
      }
      for (const socketPath of bridge ? [bridge.statusPath, bridge.controlPath] : []) {
        assert.equal(fs.existsSync(socketPath), false);
      }
    })().catch(error => { console.error(error); process.exitCode = 1; });
    NODE

    touch "$out"
  ''
