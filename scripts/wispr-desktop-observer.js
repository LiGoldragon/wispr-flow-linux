"use strict";

/*
 * Owner-operated evidence recorder for Wispr's gRPC client.  This is not a
 * telemetry exporter: payload evidence stays local and OpenTelemetry never
 * receives it.  `install` is intentionally a no-op unless the operator names
 * an output directory with WISPR_DESKTOP_OBSERVER_DIR.
 */
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const OUTPUT_ENV = "WISPR_DESKTOP_OBSERVER_DIR";
const MAX_BYTES = 64 * 1024 * 1024;
const MAX_FILES = 8;
const SECRET_KEY = /(?:authorization|cookie|credential|password|secret|token|api[_-]?key|bearer)/i;
const CORRELATION_KEY = /(?:^|[_-])(uuid|request[_-]?id|session[_-]?id|correlation[_-]?id|stream[_-]?id|id)$/i;

function digest(value) {
  return crypto.createHash("sha256").update(String(value)).digest("hex");
}

function bytes(value) {
  return Buffer.isBuffer(value) || value instanceof Uint8Array;
}

function snapshot(value, state, depth = 0) {
  if (depth > 32) return { "$truncated": "depth" };
  if (bytes(value)) return { "$bytes": Buffer.from(value).toString("base64") };
  if (value === null || typeof value !== "object") return value;
  if (state.seen.has(value)) return { "$cycle": true };
  state.seen.add(value);
  if (Array.isArray(value)) return value.map(item => snapshot(item, state, depth + 1));
  const result = {};
  for (const key of Object.keys(value).sort()) {
    if (SECRET_KEY.test(key)) {
      state.hasSecret = true;
      result[key] = { "$redacted": true };
    } else {
      result[key] = snapshot(value[key], state, depth + 1);
    }
  }
  return result;
}

function structure(value, state, depth = 0) {
  if (depth > 32) return "truncated";
  if (bytes(value)) return { type: "bytes", length: value.byteLength };
  if (value === null) return "null";
  if (typeof value !== "object") return typeof value;
  if (state.seen.has(value)) return "cycle";
  state.seen.add(value);
  if (Array.isArray(value)) return { type: "array", items: value.map(item => structure(item, state, depth + 1)) };
  const fields = {};
  for (const key of Object.keys(value).sort()) {
    fields[key] = SECRET_KEY.test(key) ? "redacted" : structure(value[key], state, depth + 1);
  }
  return { type: "object", fields };
}

function correlations(value, result = {}, depth = 0) {
  if (depth > 32 || value === null || typeof value !== "object" || bytes(value)) return result;
  for (const key of Object.keys(value)) {
    if (SECRET_KEY.test(key)) continue;
    if (CORRELATION_KEY.test(key) && (typeof value[key] === "string" || typeof value[key] === "number")) {
      result[key] = digest(value[key]);
    }
    correlations(value[key], result, depth + 1);
  }
  return result;
}

class EvidenceWriter {
  constructor(root) {
    this.root = root;
    this.session = crypto.randomUUID();
    this.sequence = 0;
    this.segment = 0;
    this.privateBytes = 0;
    this.indexBytes = 0;
    this.failed = false;
    fs.mkdirSync(path.join(root, "private"), { mode: 0o700, recursive: true });
    fs.mkdirSync(path.join(root, "index"), { mode: 0o700, recursive: true });
    fs.chmodSync(root, 0o700);
    this.rotate(true);
  }

  file(kind) {
    return path.join(this.root, kind, `${this.session}-${String(this.segment).padStart(6, "0")}.ndjson`);
  }

  rotate(initial = false) {
    if (!initial) this.segment += 1;
    this.privateFile = this.file("private");
    this.indexFile = this.file("index");
    fs.closeSync(fs.openSync(this.privateFile, "a", 0o600));
    fs.closeSync(fs.openSync(this.indexFile, "a", 0o600));
    fs.chmodSync(this.privateFile, 0o600);
    fs.chmodSync(this.indexFile, 0o600);
    this.privateBytes = fs.statSync(this.privateFile).size;
    this.indexBytes = fs.statSync(this.indexFile).size;
    for (const kind of ["private", "index"]) {
      const directory = path.join(this.root, kind);
      const files = fs.readdirSync(directory)
        .filter(name => /^[0-9a-f-]+-[0-9]{6}\.ndjson$/.test(name))
        .map(name => ({ name, stat: fs.statSync(path.join(directory, name)) }))
        .sort((a, b) => a.stat.mtimeMs - b.stat.mtimeMs);
      for (const old of files.slice(0, Math.max(0, files.length - MAX_FILES))) {
        fs.unlinkSync(path.join(directory, old.name));
      }
    }
  }

  write(record) {
    if (this.failed) return;
    try {
      const privateLine = JSON.stringify(record.private) + "\n";
      const indexLine = JSON.stringify(record.index) + "\n";
      if (this.privateBytes + Buffer.byteLength(privateLine) > MAX_BYTES ||
          this.indexBytes + Buffer.byteLength(indexLine) > MAX_BYTES) this.rotate();
      fs.appendFileSync(this.privateFile, privateLine, { encoding: "utf8", mode: 0o600 });
      fs.appendFileSync(this.indexFile, indexLine, { encoding: "utf8", mode: 0o600 });
      this.privateBytes += Buffer.byteLength(privateLine);
      this.indexBytes += Buffer.byteLength(indexLine);
    } catch (_) {
      this.failed = true;
    }
  }
}

function install(grpc) {
  const root = process.env[OUTPUT_ENV];
  if (!root || !grpc || !grpc.Client || grpc.Client.prototype.__wisprDesktopObserver) return false;
  let writer;
  try {
    writer = new EvidenceWriter(root);
  } catch (_) {
    return false;
  }
  const started = process.hrtime.bigint();
  let callSequence = 0;
  const emit = (direction, method, callId, original, message, raw) => {
    try {
      const privateState = { seen: new WeakSet(), hasSecret: false };
      const body = snapshot(message, privateState);
      const indexState = { seen: new WeakSet() };
      const entry = {
        session: writer.session,
        order: ++writer.sequence,
        monotonicNs: (process.hrtime.bigint() - started).toString(),
        direction,
        rpc: { method, callId },
        correlation: correlations(message),
        kind: message && message.constructor ? message.constructor.name : typeof message,
        structure: structure(message, indexState),
      };
      writer.write({
        private: Object.assign({}, entry, {
          execution: { platform: process.platform, arch: process.arch, node: process.versions.node, electron: process.versions.electron || null },
          message: body,
          rawBytes: privateState.hasSecret || !bytes(raw) ? null : Buffer.from(raw).toString("base64"),
          rawBytesOmitted: privateState.hasSecret,
        }),
        index: entry,
      });
    } catch (_) {
      // Dictation is primary: observer faults must never alter the call.
    }
  };
  const wrap = name => {
    const original = grpc.Client.prototype[name];
    if (typeof original !== "function") return;
    grpc.Client.prototype[name] = function observedRequest(method, serialize, deserialize, ...rest) {
      const callId = `${writer.session}:${++callSequence}`;
      const requestSerialize = typeof serialize === "function" ? value => {
        const raw = serialize(value);
        emit("outgoing", method, callId, original, value, raw);
        return raw;
      } : serialize;
      const responseDeserialize = typeof deserialize === "function" ? raw => {
        const value = deserialize(raw);
        emit("incoming", method, callId, original, value, raw);
        return value;
      } : deserialize;
      return original.call(this, method, requestSerialize, responseDeserialize, ...rest);
    };
  };
  for (const name of ["makeUnaryRequest", "makeClientStreamRequest", "makeServerStreamRequest", "makeBidiStreamRequest"]) wrap(name);
  Object.defineProperty(grpc.Client.prototype, "__wisprDesktopObserver", { value: true });
  return true;
}

module.exports = { install };
