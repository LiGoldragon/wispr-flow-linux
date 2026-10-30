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

      const admissionMarker = "/*WISPR_LINUX_DICTATION_ADMISSION*/";
      assert.equal(source.split(admissionMarker).length - 1, 1,
        "one packaged dictation admission implementation");
      for (const snippet of [
        '/*WISPR_LINUX_DICTATION_IDLE_GUARD_BEGIN*/',
        '/*WISPR_LINUX_DICTATION_BUSY_PTT_BEGIN*/',
        '/*WISPR_LINUX_DICTATION_BUSY_LENS_BEGIN*/',
        '/*WISPR_LINUX_DICTATION_BUSY_INSTRUCT_BEGIN*/',
        '/*WISPR_LINUX_DICTATION_BUSY_POPO_BEGIN*/',
        'it=(e,t,n)=>{if(globalThis.__wisprDictationBusy())return{accepted:!1,error:"busy"};const c=crypto.randomUUID();if(!globalThis.__wisprReserveDictationOwner(c))return{accepted:!1,error:"busy"};',
        'catch(e){throw Xe(O.W5.UserActionEscape),e}finally{_wisprAdmissionAccepted||globalThis.__wisprAbortDictationOwner?.(c)}',
        'globalThis.__wisprMarkDictationTail?.(n),Lt=!0',
        'globalThis.__wisprReleaseDictationOwner?.(n),Lt=!1',
        'globalThis.__wisprAbortDictationOwner?.(p.ZZ.uuid)',
        'globalThis.__wisprDictationAdmission?.owner?.uuid===n',
      ]) {
        assert.equal(source.split(snippet).length - 1, 1,
          "one packaged admission anchor: " + snippet.slice(0, 48));
      }
      assert.equal(source.split(
        'if(!Ti.KB.includes(ci.ZZ.status))break;if(globalThis.__wisprDictationBusy()){',
      ).length - 1, 2, "both extension routes refuse before mutation");
      assert.equal(source.split(
        'dictation admission busy`,{customAttributes:{requestType:t.type,error:"busy"}});break}',
      ).length - 1, 2, "both one-way extension routes report a structured busy refusal");
      assert.equal(source.split(
        'R=()=>{if(globalThis.__wisprDictationBusy())return{accepted:!1,error:"busy"};N(),E=!0',
      ).length - 1, 1, "BLE refuses before local capture mutation");
      assert.equal(source.split(
        'q.e.getDictionaryContext().then(e=>{if(p.ZZ.uuid!==c)return;',
      ).length - 1, 2, "both asynchronous dictionary writes are UUID-bound");

      const admissionEnd = source.indexOf(",0),Pe=", source.indexOf(admissionMarker));
      assert.ok(admissionEnd > 0, "packaged admission initializer has an end");
      const admissionExpression = source.slice(
        source.indexOf(admissionMarker) + admissionMarker.length,
        admissionEnd,
      ) + ",0";
      const admissionContext = {};
      admissionContext.globalThis = admissionContext;
      vm.createContext(admissionContext);
      vm.runInContext("(" + admissionExpression + ")", admissionContext);
      assert.equal(admissionContext.__wisprMarkDictationTail(undefined), false,
        "a Testing/missing-UUID completion without an owner is harmless");
      assert.equal(admissionContext.__wisprAbortDictationOwner(undefined), false,
        "a Testing/missing-UUID abort without an owner is harmless");
      assert.equal(admissionContext.__wisprReleaseDictationOwner(undefined), false,
        "a Testing/missing-UUID release without an owner is harmless");
      assert.equal(admissionContext.__wisprReserveDictationOwner("old"), true);
      assert.equal(admissionContext.__wisprDictationBusy(), true);
      assert.equal(admissionContext.__wisprReserveDictationOwner("new"), false,
        "a new recording is refused while the old tail owns shared state");
      assert.equal(admissionContext.__wisprMarkDictationTail("old"), true);
      assert.equal(admissionContext.__wisprAbortDictationOwner("old"), false,
        "dismissal cannot reopen admission while an old completion tail mutates");
      let idlePublications = 0;
      admissionContext.__wisprDictationAdmission.pendingIdle = () => { idlePublications += 1; };
      assert.equal(admissionContext.__wisprReleaseDictationOwner("stale"), false,
        "a stale callback cannot release another recording");
      assert.equal(idlePublications, 0);
      assert.equal(admissionContext.__wisprReleaseDictationOwner("old"), true);
      assert.equal(idlePublications, 1, "deferred Idle publishes after cleanup release");
      assert.equal(admissionContext.__wisprDictationBusy(), false);

      assert.equal(admissionContext.__wisprReserveDictationOwner("aborted-capture"), true);
      assert.equal(admissionContext.__wisprAbortDictationOwner("aborted-capture"), true,
        "a capture that cannot produce RecordingDone releases after dismissal cleanup");
      assert.equal(admissionContext.__wisprDictationBusy(), false);

      assert.equal(admissionContext.__wisprReserveDictationOwner("throws"), true);
      await assert.rejects((async () => {
        try { throw new Error("cleanup"); }
        finally { admissionContext.__wisprReleaseDictationOwner("throws"); }
      })(), /cleanup/);
      assert.equal(admissionContext.__wisprDictationBusy(), false,
        "outer cleanup failure still releases the exact owner");

      assert.equal(admissionContext.__wisprReserveDictationOwner("newer"), true);
      assert.equal(admissionContext.__wisprMarkDictationTail("stale"), false);
      assert.equal(admissionContext.__wisprAbortDictationOwner("stale"), false);
      assert.equal(admissionContext.__wisprReleaseDictationOwner("stale"), false,
        "a stale completion/cancel/finally cannot release a newer owner");
      assert.equal(admissionContext.__wisprDictationAdmission.owner.uuid, "newer");
      assert.equal(admissionContext.__wisprAbortDictationOwner("newer"), true);

      const completionAdmission =
        'c.ZZ.status===Le._W.Testing?!globalThis.__wisprDictationBusy():void 0!==n&&n===c.ZZ.uuid&&globalThis.__wisprDictationAdmission?.owner?.uuid===n';
      assert.equal(source.split(completionAdmission).length - 1, 1,
        "one actual Testing/production completion-admission predicate");
      const completionContext = {
        c: { ZZ: { status: "Testing", uuid: undefined } },
        Le: { _W: { Testing: "Testing" } }, n: undefined,
      };
      completionContext.globalThis = completionContext;
      completionContext.__wisprDictationBusy = () => false;
      completionContext.__wisprDictationAdmission = { owner: null };
      vm.createContext(completionContext);
      assert.equal(vm.runInContext(completionAdmission, completionContext), true,
        "actual Testing/missing-UUID path remains admitted without an owner");
      // Its next patched helper call is safe; the no-owner assertion above
      // executes that exact helper body with undefined.

      const extractMainMarker = (begin, end, label) => {
        assert.equal(source.split(begin).length - 1, 1, "one " + label + " begin marker");
        assert.equal(source.split(end).length - 1, 1, "one " + label + " end marker");
        return source.slice(source.indexOf(begin) + begin.length, source.indexOf(end));
      };
      const idleGuard = extractMainMarker(
        "/*WISPR_LINUX_DICTATION_IDLE_GUARD_BEGIN*/",
        "/*WISPR_LINUX_DICTATION_IDLE_GUARD_END*/", "Idle guard");
      let fakeNow = 0;
      let nextTimer = 1;
      const fakeTimers = new Map();
      const schedule = (after, callback) => {
        const id = nextTimer++;
        fakeTimers.set(id, { at: fakeNow + after, callback });
        return id;
      };
      const cancel = id => fakeTimers.delete(id);
      const advance = milliseconds => {
        fakeNow += milliseconds;
        for (const [id, timer] of [...fakeTimers]) {
          if (timer.at <= fakeNow) {
            fakeTimers.delete(id);
            timer.callback();
          }
        }
      };
      let processingErrors = 0;
      const idlePublicationsActual = [];
      let idleContext;
      const processingTimer = schedule(24000, () => {
        processingErrors += 1;
        idleContext.qe("Error");
      });
      const notificationTimer = schedule(4000, () => idlePublicationsActual.push("processing-notification"));
      idleContext = {
        O: { _W: { Idle: "Idle", Error: "Error", Dismissed: "Dismissed" } },
        R: { W3: cancel },
        Me: notificationTimer,
        Le: () => cancel(processingTimer),
        publications: idlePublicationsActual,
      };
      idleContext.globalThis = idleContext;
      idleContext.__wisprDictationAdmission = { owner: { uuid: "tail", phase: "tail" }, pendingIdle: null };
      vm.createContext(idleContext);
      vm.runInContext(
        `qe=(e,t=!0,n={})=>{''${idleGuard}publications.push(e)}`,
        idleContext,
      );
      idleContext.qe("Idle");
      assert.equal(fakeTimers.has(processingTimer), false, "deferred successful Idle clears the 24s processing timer");
      assert.equal(fakeTimers.has(notificationTimer), false, "deferred successful Idle clears the processing-notification timer");
      assert.deepEqual(idlePublicationsActual, [], "Idle remains private while the tail owns state");
      // Advancing a synthetic clock beyond the observed 73.7s history tail cannot
      // invoke either cleared timer or publish Error.
      advance(73700);
      assert.equal(processingErrors, 0, "a 73.7s successful tail cannot time out after upstream completion");
      assert.equal(idleContext.__wisprDictationAdmission.owner.uuid, "tail",
        "the owner remains held throughout the delayed successful tail");
      idleContext.__wisprDictationAdmission.owner = null;
      const publishIdle = idleContext.__wisprDictationAdmission.pendingIdle;
      idleContext.__wisprDictationAdmission.pendingIdle = null;
      publishIdle();
      assert.deepEqual(idlePublicationsActual, ["Idle"], "release publishes successful Idle exactly once");
      idleContext.__wisprDictationAdmission.owner = { uuid: "error", phase: "tail" };
      idleContext.__wisprDictationAdmission.pendingIdle = () => idlePublicationsActual.push("stale-idle");
      idleContext.qe("Error");
      assert.deepEqual(idlePublicationsActual, ["Idle", "Error"], "genuine Error is published unchanged");
      assert.equal(idleContext.__wisprDictationAdmission.pendingIdle, null,
        "genuine Error cancels a deferred success without releasing its owner");
      assert.equal(idleContext.__wisprDictationAdmission.owner.uuid, "error");

      for (const name of ["PTT", "LENS", "INSTRUCT", "POPO"]) {
        const busyBody = extractMainMarker(
          `/*WISPR_LINUX_DICTATION_BUSY_''${name}_BEGIN*/`,
          `/*WISPR_LINUX_DICTATION_BUSY_''${name}_END*/`, name + " busy guard");
        let notifications = 0;
        const busyContext = {
          o: () => ({ warn: () => {} }), Date: { now: () => 10000 },
          ue: { tL: { lastActionTime: 0 } }, u: { DICTATION_DEBOUNCE_DELAY: 1 },
          be: () => { notifications += 1; }, C: { Eg: { TranscriptCurrentlyProcessing: "busy" } },
        };
        busyContext.globalThis = busyContext;
        busyContext.__wisprDictationBusy = () => true;
        vm.createContext(busyContext);
        const result = vm.runInContext(`(()=>{''${busyBody}})()`, busyContext);
        assert.deepEqual({ ...result }, { accepted: false, error: "busy" });
        assert.equal(notifications, 1, name + " busy refusal notifies once");
      }

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
          W5: { UserActionEscape: "escape" },
        },
        z: {
          Qw: async () => calls.push("start"),
          US: async () => calls.push("stop"),
          t3: () => calls.push("dismiss"),
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
        ["Error", true, "start", true],
      ]) {
        calls.length = 0;
        hookContext.S.ZZ.status = state;
        hookContext.S.ZZ.isLocked = locked;
        assert.deepEqual({ ...await toggle() }, { hands_free: handsFree });
        assert.deepEqual(calls, state === "Error" ? ["dismiss", action] : [action]);
      }
      for (const [state, locked] of [
        ["Listening", false],
        ["Processing", true],
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

      let admissionPhase = "capture";
      hookContext.__wisprDictationBusy = () => admissionPhase !== null;
      hookContext.z.t3 = () => {
        calls.push("dismiss");
        if (admissionPhase === "capture") admissionPhase = null;
      };
      calls.length = 0;
      hookContext.S.ZZ.status = "Error";
      assert.deepEqual({ ...await toggle() }, { hands_free: true });
      assert.deepEqual(calls, ["dismiss", "start"],
        "Error recovery cleans a capture owner before readmission");
      admissionPhase = "tail";
      calls.length = 0;
      assert.deepEqual({ ...await toggle() }, { ok: false, error: "busy" });
      assert.deepEqual(calls, ["dismiss"],
        "Error recovery cannot readmit while a completion tail still owns state");

      hookContext.S.ZZ.status = "Error";
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
