#!/usr/bin/env node
/*
 * Codex OmniRoute -- MCP stdio shield.
 *
 * Optional thin wrapper for inherited MCP server commands. Codex talks to a
 * stdio MCP server using JSON-RPC framing on the child's stdout; any
 * non-JSON line on that pipe makes the host log
 *
 *   "Failed to parse MCP message"
 *
 * and corrupts the transport. On Windows we have observed lines like
 *
 *   SUCCESS: The process with PID 12345 has been terminated.
 *
 * leaking onto MCP stdout when child wrappers (cmd.exe, npx.cmd, certain
 * powershell -Command pipelines) tear down subordinate processes via
 * taskkill and forget to redirect its output. The shield is a passthrough
 * pipe with one job: drop lines on stdout that obviously cannot be JSON-RPC
 * frames.
 *
 * Usage:
 *   node mcp-stdio-shield.mjs <child-cmd> [args...]
 *
 * - Spawns the child with the same args, inherits its stderr unchanged
 *   (so diagnostic logs still flow), and pipes child stdout through a line
 *   filter into the parent's stdout (the MCP transport).
 * - A line is considered "JSON-RPC-eligible" if its first non-whitespace
 *   character is "{" or "[" (Codex always sends/receives JSON objects, but
 *   we accept arrays defensively in case of batched frames). Empty lines
 *   are dropped silently.
 * - All other lines are written to the SHIELD's stderr with a tag, so they
 *   are still observable but never enter the JSON-RPC channel.
 *
 * This is OPT-IN. The launcher only wraps MCP servers with this shield when
 * -SanitizeMcpStdout is passed. Default behavior is to leave inherited MCP
 * commands untouched for maximum upstream compatibility.
 */
import { spawn } from "node:child_process";
import { Buffer } from "node:buffer";
import process from "node:process";

const argv = process.argv.slice(2);
if (argv.length === 0) {
  process.stderr.write("[mcp-stdio-shield] missing child command\n");
  process.exit(64);
}

const [cmd, ...rest] = argv;

// On Windows, .cmd / .bat wrappers must be invoked through cmd.exe; spawn
// with shell:true does that automatically. .exe and .js targets are spawned
// directly. We don't try to be too clever here -- the launcher passes us
// fully-resolved, absolute commands.
const isShellTarget = /\.(cmd|bat)$/i.test(cmd);

const child = spawn(cmd, rest, {
  stdio: ["inherit", "pipe", "inherit"],
  shell: isShellTarget,
  windowsHide: true,
});

let buf = "";
function flushLine(line) {
  const trimmed = line.replace(/\r$/, "");
  if (trimmed.length === 0) return;
  const firstNonWs = trimmed.replace(/^\s+/, "");
  if (firstNonWs.length === 0) return;
  const c0 = firstNonWs[0];
  if (c0 === "{" || c0 === "[") {
    // JSON-RPC frame. Pass through.
    try {
      process.stdout.write(trimmed + "\n");
    } catch {
      /* ignore EPIPE: parent host disconnected */
    }
    return;
  }
  // Non-JSON line. Surface on stderr so it's still observable in logs but
  // does NOT enter the MCP transport.
  try {
    process.stderr.write(`[mcp-stdio-shield] dropped non-JSON stdout line: ${trimmed}\n`);
  } catch {
    /* ignore */
  }
}

child.stdout.on("data", (chunk) => {
  buf += Buffer.isBuffer(chunk) ? chunk.toString("utf8") : String(chunk);
  let idx;
  while ((idx = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, idx);
    buf = buf.slice(idx + 1);
    flushLine(line);
  }
});

child.stdout.on("end", () => {
  if (buf.length > 0) {
    flushLine(buf);
    buf = "";
  }
});

child.on("error", (err) => {
  process.stderr.write(`[mcp-stdio-shield] spawn error: ${err?.message || err}\n`);
  process.exit(127);
});

child.on("exit", (code, signal) => {
  if (signal) {
    process.stderr.write(`[mcp-stdio-shield] child exited via signal ${signal}\n`);
    process.exit(143);
  }
  process.exit(code ?? 0);
});

// Forward parent termination signals to the child so Codex's normal MCP
// shutdown still works.
for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(sig, () => {
    try { child.kill(sig); } catch { /* ignore */ }
  });
}

// Swallow EPIPE on stdout so the shield does not crash if the parent host
// closes the transport before the child finishes writing.
process.stdout.on("error", () => {});
process.stderr.on("error", () => {});
