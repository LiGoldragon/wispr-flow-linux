#!/usr/bin/env node
"use strict";

const crypto = require("node:crypto");
const net = require("node:net");
const path = require("node:path");
const CONTRACT = "com.criomos.wispr.status.v1";

if (process.argv[2] !== "toggle-hands-free" || !path.isAbsolute(process.env.XDG_RUNTIME_DIR || "")) {
  console.error("usage: wispr-flow-status toggle-hands-free (requires XDG_RUNTIME_DIR)");
  process.exitCode = 2;
} else {
  const socketPath = path.join(process.env.XDG_RUNTIME_DIR, "wispr-flow-control-v1.sock");
  const socket = net.connect(socketPath);
  let buffer = "";
  socket.on("connect", () => socket.write(`${JSON.stringify({ contract: CONTRACT, type: "control", id: crypto.randomUUID(), command: "toggle_hands_free" })}\n`));
  socket.on("data", (chunk) => { buffer += chunk; const end = buffer.indexOf("\n"); if (end < 0) return; try { const reply = JSON.parse(buffer.slice(0, end)); console.log(JSON.stringify(reply)); process.exitCode = reply.ok === true ? 0 : 1; } catch { console.error("invalid control reply"); process.exitCode = 1; } socket.end(); });
  socket.on("error", () => { console.error("Wispr Flow control endpoint unavailable"); process.exitCode = 1; });
}
