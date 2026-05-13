#!/usr/bin/env node
/*
 * Codex OmniRoute -- per-server MCP probe.
 *
 * Reads an isolated runtime config.toml, walks every [mcp_servers.<name>]
 * entry, spawns it the way Codex would (`command` + `args`, plus the
 * sub-table [mcp_servers.<name>.env] merged into the child env), sends a
 * single JSON-RPC `initialize` frame on the child's stdin, waits up to a
 * configurable timeout for a JSON-RPC response on the child's stdout, and
 * reports per-server status:
 *
 *   ok            -- responded with a parseable JSON-RPC frame
 *   no_response   -- exited or timed out without sending a JSON frame
 *   spawn_error   -- spawn failed before stdio could be set up
 *   transport_dirty -- got non-JSON output before any JSON frame
 *
 * This is exactly the failure mode Codex's MCP host hits when the JSON-RPC
 * stdio transport is corrupted by Windows process-management noise. It
 * also catches dead servers (missing env vars, missing node modules,
 * crash on init) which the smoke test cannot.
 *
 * Usage:
 *   node mcp_probe.mjs --isolated-config <path-to-config.toml>
 *                      [--timeout-ms 5000]
 *                      [--server <name>]
 *                      [--json]
 *
 * Exit code is 0 always (this is observability, not enforcement). The
 * verifier interprets the output and decides whether to PASS / WARN / FAIL.
 */
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import process from "node:process";

const argv = process.argv.slice(2);
const opts = { isolatedConfig: "", timeoutMs: 5000, server: null, json: false };
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--isolated-config") opts.isolatedConfig = argv[++i];
  else if (a === "--timeout-ms") opts.timeoutMs = parseInt(argv[++i], 10) || 5000;
  else if (a === "--server") opts.server = argv[++i];
  else if (a === "--json") opts.json = true;
  else if (a === "-h" || a === "--help") {
    process.stdout.write(
      "Usage: node mcp_probe.mjs --isolated-config <path> [--timeout-ms N] [--server NAME] [--json]\n",
    );
    process.exit(0);
  }
}
if (!opts.isolatedConfig) {
  process.stderr.write("error: --isolated-config is required\n");
  process.exit(64);
}

// ---------- minimal TOML parser, scoped to mcp_servers.* sections ----------

function parseConfig(text) {
  const lines = text.split(/\r?\n/);
  const servers = {};
  let currentServer = null;
  let currentSub = null;

  const decodeString = (raw) => {
    if (!raw) return null;
    const t = raw.trim();
    if (!(t.startsWith('"') && t.endsWith('"'))) return null;
    const inner = t.slice(1, -1);
    let out = "";
    for (let i = 0; i < inner.length; i++) {
      const c = inner[i];
      if (c === "\\" && i + 1 < inner.length) {
        const n = inner[i + 1];
        if (n === "\\") { out += "\\"; i++; continue; }
        if (n === '"')  { out += '"';  i++; continue; }
        if (n === "n")  { out += "\n"; i++; continue; }
        if (n === "r")  { out += "\r"; i++; continue; }
        if (n === "t")  { out += "\t"; i++; continue; }
      }
      out += c;
    }
    return out;
  };

  const decodeArray = (raw) => {
    if (!raw) return null;
    const t = raw.trim();
    if (!(t.startsWith("[") && t.endsWith("]"))) return null;
    const inner = t.slice(1, -1).trim();
    if (inner.length === 0) return [];
    const out = [];
    let i = 0;
    while (i < inner.length) {
      while (i < inner.length && /[\s,]/.test(inner[i])) i++;
      if (i >= inner.length) break;
      if (inner[i] !== '"') return null;
      i++;
      let s = "";
      while (i < inner.length && inner[i] !== '"') {
        const c = inner[i];
        if (c === "\\" && i + 1 < inner.length) {
          const n = inner[i + 1];
          if (n === "\\") { s += "\\"; i += 2; continue; }
          if (n === '"')  { s += '"';  i += 2; continue; }
          if (n === "n")  { s += "\n"; i += 2; continue; }
          if (n === "r")  { s += "\r"; i += 2; continue; }
          if (n === "t")  { s += "\t"; i += 2; continue; }
        }
        s += c;
        i++;
      }
      if (i >= inner.length || inner[i] !== '"') return null;
      i++;
      out.push(s);
    }
    return out;
  };

  const splitSection = (sec) => {
    if (!sec.startsWith("mcp_servers.")) return [null, null];
    let rest = sec.slice("mcp_servers.".length);
    if (!rest) return [null, null];
    let name, sub;
    if (rest.startsWith('"')) {
      const end = rest.indexOf('"', 1);
      if (end < 0) return [null, null];
      name = rest.slice(1, end);
      const tail = rest.slice(end + 1);
      sub = tail.startsWith(".") ? tail.slice(1) : (tail || null);
    } else {
      const dot = rest.indexOf(".");
      if (dot < 0) { name = rest; sub = null; }
      else { name = rest.slice(0, dot); sub = rest.slice(dot + 1); }
    }
    return [name, sub || null];
  };

  for (const raw of lines) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const sec = /^\[\s*([A-Za-z0-9_.\-]+(?:\."[^"]*")?(?:\.[A-Za-z0-9_.\-]+)*)\s*\]$/.exec(line);
    if (sec) {
      const [name, sub] = splitSection(sec[1]);
      if (!name) {
        currentServer = null;
        currentSub = null;
        continue;
      }
      if (!servers[name]) servers[name] = { command: null, args: [], env: {}, raw: {} };
      currentServer = name;
      currentSub = sub;
      continue;
    }
    if (!currentServer) continue;
    const kv = /^([A-Za-z0-9_\-]+)\s*=\s*(.+)$/.exec(line);
    if (!kv) continue;
    const key = kv[1];
    const val = kv[2];
    const target = currentSub
      ? (servers[currentServer][currentSub] = servers[currentServer][currentSub] || {})
      : servers[currentServer];
    const asString = decodeString(val);
    const asArray = asString === null ? decodeArray(val) : null;
    if (asString !== null) target[key] = asString;
    else if (asArray !== null) target[key] = asArray;
    else target[key] = val;
  }
  return servers;
}

// ---------- per-server probe ----------

function probeServer(name, defn, timeoutMs) {
  return new Promise((resolve) => {
    if (defn.url && !defn.command) {
      resolve({ name, status: "skipped_url", detail: "url-based MCP, not probed" });
      return;
    }
    if (!defn.command) {
      resolve({ name, status: "no_command", detail: "neither command nor url is set" });
      return;
    }
    const args = Array.isArray(defn.args) ? defn.args.slice() : [];
    const env = { ...process.env };
    if (defn.env && typeof defn.env === "object") {
      for (const [k, v] of Object.entries(defn.env)) env[k] = String(v);
    }

    const isShellTarget = /\.(cmd|bat)$/i.test(defn.command);
    let child;
    try {
      child = spawn(defn.command, args, {
        stdio: ["pipe", "pipe", "pipe"],
        shell: isShellTarget,
        windowsHide: true,
        env,
      });
    } catch (err) {
      resolve({ name, status: "spawn_error", detail: err?.message || String(err) });
      return;
    }

    let stdoutBuf = "";
    let stderrBuf = "";
    let firstNonJsonStdoutLine = null;
    let resolved = false;
    let timer = null;

    const finalize = (status, detail) => {
      if (resolved) return;
      resolved = true;
      try { clearTimeout(timer); } catch {}
      try { child.kill("SIGTERM"); } catch {}
      // Force-kill in 200ms if still alive.
      const killTimer = setTimeout(() => {
        try { child.kill("SIGKILL"); } catch {}
      }, 200);
      try { killTimer.unref(); } catch {}
      resolve({
        name,
        status,
        detail,
        firstNonJsonStdoutLine,
        stderr: stderrBuf.trim().slice(0, 400),
      });
    };

    child.on("error", (err) => {
      finalize("spawn_error", err?.message || String(err));
    });

    child.on("exit", (code, signal) => {
      if (resolved) return;
      finalize("exited_before_response", `exit code=${code} signal=${signal} stdout-bytes=${stdoutBuf.length}`);
    });

    child.stderr.on("data", (chunk) => {
      stderrBuf += Buffer.isBuffer(chunk) ? chunk.toString("utf8") : String(chunk);
      if (stderrBuf.length > 4000) stderrBuf = stderrBuf.slice(-4000);
    });

    const handleStdoutLine = (line) => {
      const trimmed = line.replace(/\r$/, "").trim();
      if (trimmed.length === 0) return;
      if (!(trimmed.startsWith("{") || trimmed.startsWith("["))) {
        if (firstNonJsonStdoutLine === null) firstNonJsonStdoutLine = trimmed;
        return;
      }
      // Try to parse as JSON; if it parses and looks like a JSON-RPC result
      // for our initialize, we're done.
      try {
        const parsed = JSON.parse(trimmed);
        if (parsed && typeof parsed === "object" && (parsed.jsonrpc === "2.0" || parsed.id !== undefined)) {
          finalize("ok", `JSON-RPC frame received (jsonrpc=${parsed.jsonrpc ?? "?"} id=${parsed.id ?? "?"})`);
        }
      } catch {
        // Not JSON; treat as transport noise.
        if (firstNonJsonStdoutLine === null) firstNonJsonStdoutLine = trimmed;
      }
    };

    child.stdout.on("data", (chunk) => {
      stdoutBuf += Buffer.isBuffer(chunk) ? chunk.toString("utf8") : String(chunk);
      let idx;
      while ((idx = stdoutBuf.indexOf("\n")) >= 0) {
        const line = stdoutBuf.slice(0, idx);
        stdoutBuf = stdoutBuf.slice(idx + 1);
        handleStdoutLine(line);
        if (resolved) return;
      }
    });

    // Send a single MCP `initialize` request.
    const initFrame = JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: { name: "codex-omniroute-mcp-probe", version: "0.1.0" },
      },
    }) + "\n";
    try {
      child.stdin.write(initFrame);
    } catch {
      // some servers close stdin instantly; we still wait for stdout.
    }

    timer = setTimeout(() => {
      if (firstNonJsonStdoutLine && !resolved) {
        finalize("transport_dirty",
          `non-JSON stdout before any JSON frame: "${firstNonJsonStdoutLine.slice(0, 200)}"`);
      } else {
        finalize("no_response", `no JSON-RPC frame within ${timeoutMs}ms`);
      }
    }, timeoutMs);
    try { timer.unref(); } catch {}
  });
}

// ---------- main ----------

async function main() {
  const text = fs.readFileSync(opts.isolatedConfig, "utf8");
  const servers = parseConfig(text);
  const names = opts.server ? [opts.server] : Object.keys(servers);
  const results = [];
  for (const n of names) {
    if (!servers[n]) {
      results.push({ name: n, status: "missing", detail: "no [mcp_servers.<name>] entry in config" });
      continue;
    }
    const r = await probeServer(n, servers[n], opts.timeoutMs);
    results.push(r);
  }
  if (opts.json) {
    process.stdout.write(JSON.stringify({ count: results.length, results }, null, 2) + "\n");
  } else {
    let okCount = 0, badCount = 0, skipCount = 0;
    for (const r of results) {
      const tag = r.status === "ok" ? "PASS"
              : (r.status === "skipped_url" ? "SKIP" : "FAIL");
      if (tag === "PASS") okCount++;
      else if (tag === "SKIP") skipCount++;
      else badCount++;
      let line = `[${tag}] ${r.name} -- ${r.status}: ${r.detail || ""}`;
      if (r.firstNonJsonStdoutLine) {
        line += ` | non-JSON stdout: "${r.firstNonJsonStdoutLine.slice(0, 120)}"`;
      }
      process.stdout.write(line + "\n");
    }
    process.stdout.write(`\nMCP probe summary: ${okCount} ok, ${badCount} failing, ${skipCount} skipped (out of ${results.length}).\n`);
  }
}

main().catch((err) => {
  process.stderr.write(`mcp_probe error: ${err?.stack || err?.message || String(err)}\n`);
  process.exit(1);
});
