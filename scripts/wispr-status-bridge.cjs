"use strict";
const crypto = require("node:crypto");
const fs = require("node:fs");
const net = require("node:net");
const path = require("node:path");
const CONTRACT = "com.criomos.wispr.status.v1";
const STATES = new Set(["idle", "recording", "transcribing", "error"]);

function mapWisprState(value) {
  switch (value) {
    case "idle": case "dismissed": return { state: "idle" };
    case "initializing": case "listening": return { state: "recording" };
    case "stopping": case "processing": case "retrying": return { state: "transcribing" };
    case "error": return { state: "error" };
    default: return { state: "error", error: "unknown_lifecycle_state" };
  }
}
function identity(socketPath) { const stat = fs.lstatSync(socketPath); if (!stat.isSocket()) throw new Error("refusing non-socket path"); return `${stat.dev}:${stat.ino}`; }
async function reclaim(socketPath) {
  try {
    await new Promise((resolve, reject) => { const client = net.connect(socketPath); client.once("connect", () => { client.destroy(); reject(new Error("live status bridge already owns socket")); }); client.once("error", error => { client.destroy(); error.code === "ECONNREFUSED" || error.code === "ENOENT" ? resolve() : reject(error); }); });
    const before = identity(socketPath); if (before === identity(socketPath)) fs.unlinkSync(socketPath);
  } catch (error) { if (error.code !== "ENOENT") throw error; }
}
function sanitize(input) { const state = STATES.has(input?.state) ? input.state : "error"; const result = { state, hands_free: input?.hands_free === true }; if (state === "error" && /^[a-z0-9_.-]{1,64}$/.test(input?.error || "")) result.error = input.error; return result; }

function defaultRuntimeDir() {
  const configured = process.env.XDG_RUNTIME_DIR;
  if (path.isAbsolute(configured || "")) return configured;
  if (process.platform !== "linux" || typeof process.getuid !== "function") return configured;
  const uid = process.getuid(), candidate = path.join("/run/user", String(uid));
  try { const stat = fs.statSync(candidate); return stat.isDirectory() && stat.uid === uid && (stat.mode & 0o077) === 0 ? candidate : configured; }
  catch { return configured; }
}

function startStatusBridge({ runtimeDir = defaultRuntimeDir(), snapshot = () => ({}), controlTimeoutMs = 3000, heartbeatMs = 1000 } = {}) {
  if (!path.isAbsolute(runtimeDir || "")) throw new Error("XDG_RUNTIME_DIR is required");
  const statusPath = path.join(runtimeDir, "wispr-flow-status-v1.sock"), controlPath = path.join(runtimeDir, "wispr-flow-control-v1.sock"), sessionId = crypto.randomUUID();
  let sequence = 0, current = sanitize(snapshot()), action = null, queue = Promise.resolve();
  const clients = new Set(), controlClients = new Set(), watchers = new Set(), owned = new Map();
  const packet = () => ({ contract: CONTRACT, type: "snapshot", session_id: sessionId, sequence, ...current });
  const write = (socket, value) => { if (!socket.destroyed) socket.write(`${JSON.stringify(value)}\n`); };
  const publish = next => { current = sanitize(next); sequence += 1; const value = packet(); for (const socket of clients) write(socket, value); for (const watcher of watchers) watcher(); };
  const waitFor = (target, baseline) => { if (sequence > baseline && current.hands_free === target) return Promise.resolve(true); return new Promise(resolve => { const watcher = () => { if (sequence > baseline && current.hands_free === target) { clearTimeout(timer); watchers.delete(watcher); resolve(true); } }; const timer = setTimeout(() => { watchers.delete(watcher); resolve(false); }, controlTimeoutMs); watchers.add(watcher); }); };
  const statusServer = net.createServer(socket => { clients.add(socket); socket.on("close", () => clients.delete(socket)); socket.on("error", () => socket.destroy()); write(socket, packet()); });
  const controlServer = net.createServer(socket => { controlClients.add(socket); socket.on("close", () => controlClients.delete(socket)); let buffer = ""; socket.on("error", () => socket.destroy()); socket.on("data", chunk => { buffer += chunk; const end = buffer.indexOf("\n"); if (end < 0) return buffer.length > 4096 && socket.destroy(); let request; try { request = JSON.parse(buffer.slice(0, end)); } catch { socket.end(`${JSON.stringify({ contract: CONTRACT, type: "control_result", ok: false, error: "invalid_request" })}\n`); return; }
    queue = queue.then(async () => { if (socket.destroyed) return; const reply = { contract: CONTRACT, type: "control_result", id: typeof request.id === "string" ? request.id : "", ok: false }; if (request.contract !== CONTRACT || request.type !== "control" || request.command !== "toggle_hands_free") reply.error = "invalid_request"; else if (!action) reply.error = "unavailable"; else try { const baseline = sequence; const result = await action(); if (typeof result?.hands_free !== "boolean") reply.error = result?.error === "not_toggleable" ? "not_toggleable" : "action_failed"; else if (await waitFor(result.hands_free, baseline)) { reply.ok = true; reply.hands_free = result.hands_free; } else reply.error = "state_timeout"; } catch { reply.error = "action_failed"; } socket.end(`${JSON.stringify(reply)}\n`); }); }); });
  const listen = async (server, socketPath) => { const bind = () => new Promise((resolve, reject) => { server.once("error", reject); server.listen(socketPath, () => { server.removeListener("error", reject); resolve(); }); }); try { await bind(); } catch (error) { if (error.code !== "EADDRINUSE") throw error; await reclaim(socketPath); await bind(); } fs.chmodSync(socketPath, 0o600); owned.set(socketPath, identity(socketPath)); };
  let heartbeat, closed = false;
  const ready = Promise.all([listen(statusServer, statusPath), listen(controlServer, controlPath)]).then(() => { if (!closed) heartbeat = setInterval(() => publish(current), heartbeatMs); });
  return { statusPath, controlPath, ready, publish, setToggleHandsFree(fn) { action = typeof fn === "function" ? fn : null; }, async close() { closed = true; if (heartbeat) clearInterval(heartbeat); for (const socket of clients) socket.destroy(); for (const socket of controlClients) socket.destroy(); await Promise.all([statusServer, controlServer].map(server => new Promise(resolve => server.close(resolve)))); for (const socketPath of [statusPath, controlPath]) try { if (owned.get(socketPath) === identity(socketPath)) fs.unlinkSync(socketPath); } catch (error) { if (error.code !== "ENOENT") throw error; } } };
}
module.exports = { CONTRACT, mapWisprState, startStatusBridge };
