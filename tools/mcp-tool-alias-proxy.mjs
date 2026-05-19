#!/usr/bin/env node
/*
 * Codex OmniRoute -- MCP tool alias proxy.
 *
 * Some MCP servers publish tool names that are legal MCP names but are not
 * reliably exposed by Codex as direct function namespaces. This proxy keeps the
 * upstream server unchanged while publishing Codex-friendly aliases in
 * tools/list and mapping tools/call back to the original upstream name.
 *
 * Usage:
 *   node mcp-tool-alias-proxy.mjs --map public_name=upstream-name -- <cmd> [args...]
 */
import { spawn } from "node:child_process";
import { Buffer } from "node:buffer";
import process from "node:process";

const argv = process.argv.slice(2);
const publicToUpstream = new Map();
const upstreamToPublic = new Map();
const envFallbacks = new Map();
const descriptionOverrides = new Map();
let serverNameOverride = "";
let toolsOnlyCapability = false;
let hideUnmappedTools = false;

let childArgStart = -1;
for (let i = 0; i < argv.length; i += 1) {
  const arg = argv[i];
  if (arg === "--") {
    childArgStart = i + 1;
    break;
  }
  if (arg === "--map") {
    const spec = argv[++i] || "";
    const eq = spec.indexOf("=");
    if (eq <= 0 || eq === spec.length - 1) {
      process.stderr.write(`[mcp-tool-alias-proxy] invalid --map value: ${spec}\n`);
      process.exit(64);
    }
    const publicName = spec.slice(0, eq).trim();
    const upstreamName = spec.slice(eq + 1).trim();
    if (!publicName || !upstreamName) {
      process.stderr.write(`[mcp-tool-alias-proxy] invalid --map value: ${spec}\n`);
      process.exit(64);
    }
    publicToUpstream.set(publicName, upstreamName);
    upstreamToPublic.set(upstreamName, publicName);
    continue;
  }
  if (arg === "--env-fallback") {
    const spec = argv[++i] || "";
    const eq = spec.indexOf("=");
    if (eq <= 0 || eq === spec.length - 1) {
      process.stderr.write(`[mcp-tool-alias-proxy] invalid --env-fallback value: ${spec}\n`);
      process.exit(64);
    }
    const target = spec.slice(0, eq).trim();
    const source = spec.slice(eq + 1).trim();
    if (!target || !source) {
      process.stderr.write(`[mcp-tool-alias-proxy] invalid --env-fallback value: ${spec}\n`);
      process.exit(64);
    }
    envFallbacks.set(target, source);
    continue;
  }
  if (arg === "--description") {
    const spec = argv[++i] || "";
    const eq = spec.indexOf("=");
    if (eq <= 0 || eq === spec.length - 1) {
      process.stderr.write(`[mcp-tool-alias-proxy] invalid --description value: ${spec}\n`);
      process.exit(64);
    }
    const publicName = spec.slice(0, eq).trim();
    const description = spec.slice(eq + 1).trim();
    if (!publicName || !description) {
      process.stderr.write(`[mcp-tool-alias-proxy] invalid --description value: ${spec}\n`);
      process.exit(64);
    }
    descriptionOverrides.set(publicName, description);
    continue;
  }
  if (arg === "--server-name") {
    serverNameOverride = (argv[++i] || "").trim();
    if (!serverNameOverride) {
      process.stderr.write("[mcp-tool-alias-proxy] --server-name requires a value\n");
      process.exit(64);
    }
    continue;
  }
  if (arg === "--tools-only-capability") {
    toolsOnlyCapability = true;
    continue;
  }
  if (arg === "--hide-unmapped-tools") {
    hideUnmappedTools = true;
    continue;
  }
  process.stderr.write(`[mcp-tool-alias-proxy] unknown argument before --: ${arg}\n`);
  process.exit(64);
}

if (childArgStart < 0 || childArgStart >= argv.length) {
  process.stderr.write("[mcp-tool-alias-proxy] missing child command after --\n");
  process.exit(64);
}
if (publicToUpstream.size === 0) {
  process.stderr.write("[mcp-tool-alias-proxy] at least one --map is required\n");
  process.exit(64);
}

const [cmd, ...rest] = argv.slice(childArgStart);
const isShellTarget = /\.(cmd|bat)$/i.test(cmd);
const childEnv = { ...process.env };
for (const [target, source] of envFallbacks) {
  if (!childEnv[target] && childEnv[source]) childEnv[target] = childEnv[source];
}

const child = spawn(cmd, rest, {
  stdio: ["pipe", "pipe", "inherit"],
  shell: isShellTarget,
  env: childEnv,
  windowsHide: true,
});

function rewriteParentMessage(message) {
  if (message && message.method === "tools/call" && message.params && typeof message.params.name === "string") {
    const upstreamName = publicToUpstream.get(message.params.name);
    if (upstreamName) {
      message = {
        ...message,
        params: {
          ...message.params,
          name: upstreamName,
        },
      };
    }
  }
  return message;
}

function rewriteChildMessage(message) {
  if (message?.result && (serverNameOverride || toolsOnlyCapability)) {
    const result = { ...message.result };
    if (serverNameOverride && result.serverInfo && typeof result.serverInfo === "object") {
      result.serverInfo = { ...result.serverInfo, name: serverNameOverride };
    }
    if (toolsOnlyCapability && result.capabilities && typeof result.capabilities === "object") {
      result.capabilities = { tools: result.capabilities.tools || {} };
    }
    message = { ...message, result };
  }

  const tools = message?.result?.tools;
  if (Array.isArray(tools)) {
    message = {
      ...message,
      result: {
        ...message.result,
        tools: tools.flatMap((tool) => {
          if (!tool || typeof tool.name !== "string") return tool;
          const publicName = upstreamToPublic.get(tool.name);
          if (!publicName) return hideUnmappedTools ? [] : [tool];
          const description = descriptionOverrides.get(publicName);
          const next = description ? { ...tool, name: publicName, description } : { ...tool, name: publicName };
          return [next];
        }),
      },
    };
  }
  return message;
}

function writeJsonLine(stream, message) {
  try {
    stream.write(JSON.stringify(message) + "\n");
  } catch {
    /* ignore EPIPE: the other side closed */
  }
}

let parentBuf = "";
process.stdin.on("data", (chunk) => {
  parentBuf += Buffer.isBuffer(chunk) ? chunk.toString("utf8") : String(chunk);
  let idx;
  while ((idx = parentBuf.indexOf("\n")) >= 0) {
    const line = parentBuf.slice(0, idx).trim();
    parentBuf = parentBuf.slice(idx + 1);
    if (!line) continue;
    try {
      writeJsonLine(child.stdin, rewriteParentMessage(JSON.parse(line)));
    } catch {
      try { child.stdin.write(line + "\n"); } catch { /* ignore */ }
    }
  }
});

process.stdin.on("end", () => {
  if (parentBuf.trim()) {
    try {
      writeJsonLine(child.stdin, rewriteParentMessage(JSON.parse(parentBuf.trim())));
    } catch {
      try { child.stdin.write(parentBuf.trim() + "\n"); } catch { /* ignore */ }
    }
  }
  try { child.stdin.end(); } catch { /* ignore */ }
});

let childBuf = "";
function flushChildLine(line) {
  const trimmed = line.replace(/\r$/, "").trim();
  if (!trimmed) return;
  const first = trimmed.replace(/^\s+/, "")[0];
  if (first !== "{" && first !== "[") {
    try {
      process.stderr.write(`[mcp-tool-alias-proxy] dropped non-JSON stdout line: ${trimmed}\n`);
    } catch {
      /* ignore */
    }
    return;
  }
  try {
    writeJsonLine(process.stdout, rewriteChildMessage(JSON.parse(trimmed)));
  } catch {
    try { process.stdout.write(trimmed + "\n"); } catch { /* ignore */ }
  }
}

child.stdout.on("data", (chunk) => {
  childBuf += Buffer.isBuffer(chunk) ? chunk.toString("utf8") : String(chunk);
  let idx;
  while ((idx = childBuf.indexOf("\n")) >= 0) {
    const line = childBuf.slice(0, idx);
    childBuf = childBuf.slice(idx + 1);
    flushChildLine(line);
  }
});

child.stdout.on("end", () => {
  if (childBuf.length > 0) {
    flushChildLine(childBuf);
    childBuf = "";
  }
});

child.on("error", (err) => {
  process.stderr.write(`[mcp-tool-alias-proxy] spawn error: ${err?.message || err}\n`);
  process.exit(127);
});

child.on("exit", (code, signal) => {
  if (signal) {
    process.stderr.write(`[mcp-tool-alias-proxy] child exited via signal ${signal}\n`);
    process.exit(143);
  }
  process.exit(code ?? 0);
});

for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(sig, () => {
    try { child.kill(sig); } catch { /* ignore */ }
  });
}

process.stdout.on("error", () => {});
process.stderr.on("error", () => {});
