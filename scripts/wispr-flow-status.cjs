#!/usr/bin/env node
"use strict";
const crypto = require("node:crypto"), net = require("node:net"), path = require("node:path");
const CONTRACT = "com.criomos.wispr.status.v1", timeoutMs = Number(process.env.WISPR_FLOW_STATUS_TIMEOUT_MS || 3000);
if (process.argv[2] !== "toggle-hands-free" || !path.isAbsolute(process.env.XDG_RUNTIME_DIR || "") || !Number.isFinite(timeoutMs) || timeoutMs < 1) { console.error("usage: wispr-flow-status toggle-hands-free (requires XDG_RUNTIME_DIR)"); process.exitCode = 2; }
else {
  const socket = net.connect(path.join(process.env.XDG_RUNTIME_DIR, "wispr-flow-control-v1.sock")); let done = false, buffer = "";
  const finish = (code, message) => { if (done) return; done = true; clearTimeout(timer); if (message) console.error(message); process.exitCode = code; socket.destroy(); };
  const timer = setTimeout(() => finish(1, "Wispr Flow control endpoint timed out"), timeoutMs);
  socket.on("connect", () => socket.write(`${JSON.stringify({ contract: CONTRACT, type: "control", id: crypto.randomUUID(), command: "toggle_hands_free" })}\n`));
  socket.on("data", chunk => { buffer += chunk; const end = buffer.indexOf("\n"); if (end < 0) return; try { const reply = JSON.parse(buffer.slice(0, end)); console.log(JSON.stringify(reply)); finish(reply.ok === true ? 0 : 1); } catch { finish(1, "invalid control reply"); } });
  socket.on("end", () => { if (!done) finish(1, "Wispr Flow control endpoint closed without a reply"); });
  socket.on("close", () => { if (!done) finish(1, "Wispr Flow control endpoint closed without a reply"); });
  socket.on("error", () => finish(1, "Wispr Flow control endpoint unavailable"));
}
