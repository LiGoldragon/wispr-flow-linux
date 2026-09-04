"use strict";

// Linux-only, same-user IPC for the app's non-sensitive dictation state.
const crypto = require("node:crypto");
const fs = require("node:fs");
const net = require("node:net");
const path = require("node:path");

const CONTRACT = "com.criomos.wispr.status.v1";
const STATES = new Set(["idle", "recording", "transcribing", "error"]);

function runtimePath(runtimeDir, name) {
  if (!path.isAbsolute(runtimeDir)) throw new Error("XDG_RUNTIME_DIR is required");
  return path.join(runtimeDir, name);
}

function removeStaleSocket(socketPath) {
  try {
    const stat = fs.lstatSync(socketPath);
    if (!stat.isSocket()) throw new Error(`refusing non-socket path: ${socketPath}`);
    fs.unlinkSync(socketPath);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
}

function sanitize(input) {
  const state = STATES.has(input?.state) ? input.state : "error";
  const snapshot = { state, hands_free: input?.hands_free === true };
  // Error identifiers are protocol codes only; never relay an exception/message.
  if (state === "error" && typeof input?.error === "string" && /^[a-z0-9_.-]{1,64}$/.test(input.error)) snapshot.error = input.error;
  return snapshot;
}

function startStatusBridge({ runtimeDir = process.env.XDG_RUNTIME_DIR, snapshot = () => ({}) } = {}) {
  const statusPath = runtimePath(runtimeDir, "wispr-flow-status-v1.sock");
  const controlPath = runtimePath(runtimeDir, "wispr-flow-control-v1.sock");
  const sessionId = crypto.randomUUID();
  let sequence = 0;
  let current = sanitize(snapshot());
  let toggleHandsFree = null;
  const statusClients = new Set();

  const packet = () => ({ contract: CONTRACT, type: "snapshot", session_id: sessionId, sequence, ...current });
  const write = (socket, value) => { if (!socket.destroyed) socket.write(`${JSON.stringify(value)}\n`); };
  const statusServer = net.createServer((socket) => {
    statusClients.add(socket);
    socket.on("close", () => statusClients.delete(socket));
    socket.on("error", () => socket.destroy());
    write(socket, packet());
  });
  const controlServer = net.createServer((socket) => {
    let buffer = "";
    socket.on("error", () => socket.destroy());
    socket.on("data", async (chunk) => {
      buffer += chunk;
      const end = buffer.indexOf("\n");
      if (end < 0) { if (buffer.length > 4096) socket.destroy(); return; }
      let request;
      try { request = JSON.parse(buffer.slice(0, end)); } catch { socket.end(`${JSON.stringify({ contract: CONTRACT, type: "control_result", ok: false, error: "invalid_request" })}\n`); return; }
      const reply = { contract: CONTRACT, type: "control_result", id: typeof request.id === "string" ? request.id : "", ok: false };
      if (request.contract !== CONTRACT || request.type !== "control" || request.command !== "toggle_hands_free") reply.error = "invalid_request";
      else if (!toggleHandsFree) reply.error = "unavailable";
      else {
        try {
          const result = await toggleHandsFree();
          if (result?.ok === false) reply.error = result.error === "not_toggleable" ? "not_toggleable" : "action_failed";
          else { reply.ok = true; reply.hands_free = result?.hands_free === true; }
        } catch { reply.error = "action_failed"; }
      }
      socket.end(`${JSON.stringify(reply)}\n`);
    });
  });

  removeStaleSocket(statusPath);
  removeStaleSocket(controlPath);
  const listen = (server, socketPath) => new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, () => { server.removeListener("error", reject); fs.chmodSync(socketPath, 0o600); resolve(); });
  });
  const ready = Promise.all([listen(statusServer, statusPath), listen(controlServer, controlPath)]);
  return {
    statusPath, controlPath, ready,
    publish(next) { current = sanitize(next); sequence += 1; const value = packet(); for (const socket of statusClients) write(socket, value); },
    setToggleHandsFree(action) { toggleHandsFree = typeof action === "function" ? action : null; },
    async close() { for (const socket of statusClients) socket.destroy(); await Promise.all([statusServer, controlServer].map((server) => new Promise((resolve) => server.close(resolve)))); for (const socketPath of [statusPath, controlPath]) { try { fs.unlinkSync(socketPath); } catch (error) { if (error.code !== "ENOENT") throw error; } } },
  };
}

module.exports = { CONTRACT, startStatusBridge };
