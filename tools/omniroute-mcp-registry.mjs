#!/usr/bin/env node
/*
 * Codex OmniRoute -- MCP registry resource server.
 *
 * This server exists to make configured MCP servers visible through the
 * resources surface even when Codex Desktop defers their callable tools behind
 * tool_search. It reads the active Codex config.toml and publishes a redacted
 * inventory resource plus one resource per configured [mcp_servers.*] entry.
 */
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { spawn, spawnSync } from "node:child_process";

const PROTOCOL_VERSION = "2024-11-05";
const SERVER_NAME = "omniroute-mcp-registry";
const SERVER_VERSION = "0.1.0";
const ROOT_URI = "mcp://omniroute/mcp-registry";
const JSON_URI = "mcp://omniroute/mcp-registry.json";
const SERVER_URI_PREFIX = "mcp://omniroute/mcp-registry/servers/";

let inputBuffer = "";

process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  inputBuffer += chunk;
  let idx;
  while ((idx = inputBuffer.indexOf("\n")) >= 0) {
    const raw = inputBuffer.slice(0, idx);
    inputBuffer = inputBuffer.slice(idx + 1);
    handleLine(raw);
  }
});

process.stdin.on("end", () => process.exit(0));

function handleLine(raw) {
  const line = raw.trim();
  if (!line) return;
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return;
  }
  for (const msg of Array.isArray(message) ? message : [message]) {
    if (!msg || typeof msg !== "object") continue;
    if (msg.id === undefined) continue;
    handleRequest(msg).catch((err) => {
      write({
        jsonrpc: "2.0",
        id: msg.id,
        error: { code: -32603, message: preview(err?.message || err) },
      });
    });
  }
}

async function handleRequest(msg) {
  const method = String(msg.method || "");
  if (method === "initialize") {
    write({
      jsonrpc: "2.0",
      id: msg.id,
      result: {
        protocolVersion: PROTOCOL_VERSION,
        serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
        capabilities: {
          resources: {},
          tools: {},
        },
      },
    });
    return;
  }

  if (method === "resources/list") {
    const inventory = getInventory();
    write({ jsonrpc: "2.0", id: msg.id, result: { resources: buildResources(inventory) } });
    return;
  }

  if (method === "resources/read") {
    const uri = String(msg.params?.uri || "");
    const inventory = getInventory();
    const content = readResource(uri, inventory);
    if (!content) {
      write({
        jsonrpc: "2.0",
        id: msg.id,
        error: { code: -32002, message: `Unknown registry resource: ${uri}` },
      });
      return;
    }
    write({ jsonrpc: "2.0", id: msg.id, result: { contents: [content] } });
    return;
  }

  if (method === "tools/list") {
    write({
      jsonrpc: "2.0",
      id: msg.id,
      result: {
        tools: [
          {
            name: "omniroute_mcp_list",
            description: "List MCP servers configured in the active Codex OmniRoute config, with secrets redacted.",
            inputSchema: {
              type: "object",
              properties: { format: { type: "string", enum: ["json", "markdown"] } },
              additionalProperties: false,
            },
          },
          {
            name: "omniroute_mcp_call",
            description: "Call a tool on a configured Codex OmniRoute stdio MCP server through the local registry dispatcher.",
            inputSchema: {
              type: "object",
              properties: {
                server: { type: "string" },
                tool: { type: "string" },
                arguments: { type: "object" },
                timeout_ms: { type: "number" },
              },
              required: ["server", "tool"],
              additionalProperties: false,
            },
          },
        ],
      },
    });
    return;
  }

  if (method === "tools/call") {
    const name = String(msg.params?.name || "");
    if (name === "omniroute_mcp_list") {
      const format = String(msg.params?.arguments?.format || "json").toLowerCase();
      const inventory = getInventory();
      const text = format === "markdown" ? renderMarkdown(inventory) : JSON.stringify(inventory, null, 2);
      write({ jsonrpc: "2.0", id: msg.id, result: { content: [{ type: "text", text }] } });
      return;
    }
    if (name === "omniroute_mcp_call") {
      const args = msg.params?.arguments || {};
      const result = await callConfiguredMcpTool({
        serverName: String(args.server || ""),
        toolName: String(args.tool || ""),
        toolArgs: args.arguments && typeof args.arguments === "object" && !Array.isArray(args.arguments)
          ? args.arguments
          : {},
        timeoutMs: Number.isFinite(Number(args.timeout_ms)) ? Number(args.timeout_ms) : 60000,
      });
      write({ jsonrpc: "2.0", id: msg.id, result });
      return;
    }
    if (name) {
      write({
        jsonrpc: "2.0",
        id: msg.id,
        error: { code: -32602, message: `Unknown tool: ${name}` },
      });
      return;
    }
    write({
      jsonrpc: "2.0",
      id: msg.id,
      error: { code: -32602, message: "Missing tool name" },
    });
    return;
  }

  write({
    jsonrpc: "2.0",
    id: msg.id,
    error: { code: -32601, message: `Method not found: ${method}` },
  });
}

function write(message) {
  process.stdout.write(JSON.stringify(message) + "\n");
}

function resolveConfigPath() {
  if (process.argv.includes("--config")) {
    const idx = process.argv.indexOf("--config");
    const candidate = process.argv[idx + 1];
    if (candidate) return path.resolve(candidate);
  }
  if (process.env.OMNIROUTE_MCP_REGISTRY_CONFIG) {
    return path.resolve(process.env.OMNIROUTE_MCP_REGISTRY_CONFIG);
  }
  if (process.env.CODEX_HOME) {
    return path.join(process.env.CODEX_HOME, "config.toml");
  }
  return path.join(os.homedir(), ".codex", "config.toml");
}

function getInventory() {
  const configPath = resolveConfigPath();
  const now = new Date().toISOString();
  let configText = "";
  let configError = null;
  try {
    configText = fs.readFileSync(configPath, "utf8");
  } catch (err) {
    configError = err?.message || String(err);
  }

  const parsed = configText ? parseMcpServers(configText) : {};
  const servers = Object.entries(parsed)
    .map(([name, defn]) => summarizeServer(name, defn))
    .sort((a, b) => a.name.localeCompare(b.name));

  const lastReasoning = readLastReasoning(configPath);
  return {
    generated_at_utc: now,
    registry_server: { name: SERVER_NAME, version: SERVER_VERSION },
    config_path: configPath,
    config_error: configError,
    count: servers.length,
    enabled_count: servers.filter((s) => s.enabled).length,
    disabled_count: servers.filter((s) => !s.enabled).length,
    servers,
    live_request: lastReasoning,
    note: "This registry reports configured MCP servers. A server can be configured and callable even when it does not publish MCP resources of its own.",
  };
}

async function callConfiguredMcpTool({ serverName, toolName, toolArgs, timeoutMs }) {
  if (!serverName) throw new Error("server is required");
  if (!toolName) throw new Error("tool is required");

  const configPath = resolveConfigPath();
  const configText = fs.readFileSync(configPath, "utf8");
  const servers = parseMcpServers(configText);
  const defn = servers[serverName];
  if (!defn) throw new Error(`MCP server is not configured: ${serverName}`);
  if (defn.enabled === false) throw new Error(`MCP server is disabled: ${serverName}`);
  if (defn.url) throw new Error(`MCP dispatcher currently supports stdio servers only: ${serverName}`);
  if (!defn.command) throw new Error(`MCP server has no command: ${serverName}`);

  const client = new StdioMcpClient(serverName, defn, Math.max(1000, Math.min(timeoutMs || 60000, 300000)));
  try {
    client.start();
    await client.request("initialize", {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: { name: SERVER_NAME, version: SERVER_VERSION },
    });
    client.notification("notifications/initialized", {});
    const toolsResult = await client.request("tools/list");
    const tools = Array.isArray(toolsResult.tools) ? toolsResult.tools : [];
    if (!tools.some((tool) => tool && tool.name === toolName)) {
      throw new Error(`Tool is not listed by ${serverName}: ${toolName}`);
    }
    const callResult = await client.request("tools/call", {
      name: toolName,
      arguments: toolArgs,
    });
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify({
            server: serverName,
            tool: toolName,
            status: "completed",
            result: callResult,
          }, null, 2),
        },
      ],
    };
  } finally {
    client.close();
  }
}

function readLastReasoning(configPath) {
  const dir = path.dirname(configPath);
  const file = process.env.CODEX_OMNI_LAST_REASONING_PATH ||
    path.join(dir, "omniroute", "diagnostics", "last-reasoning.json");
  try {
    const raw = fs.readFileSync(file, "utf8");
    const parsed = JSON.parse(raw);
    return {
      recorded_at_utc: parsed.recorded_at_utc || null,
      has_tool_search: Boolean(parsed.has_tool_search),
      has_direct_configured_mcp_tools: Boolean(parsed.has_direct_configured_mcp_tools),
      direct_configured_mcp_servers: Array.isArray(parsed.direct_configured_mcp_servers)
        ? parsed.direct_configured_mcp_servers
        : [],
      tools_total: Number.isFinite(Number(parsed.tools_total)) ? Number(parsed.tools_total) : null,
    };
  } catch {
    return null;
  }
}

function buildResources(inventory) {
  const resources = [
    {
      uri: ROOT_URI,
      name: "OmniRoute MCP Registry",
      description: `Configured MCP servers: ${inventory.count}`,
      mimeType: "text/markdown",
    },
    {
      uri: JSON_URI,
      name: "OmniRoute MCP Registry JSON",
      description: "Redacted JSON inventory of configured MCP servers",
      mimeType: "application/json",
    },
  ];

  for (const server of inventory.servers) {
    resources.push({
      uri: `${SERVER_URI_PREFIX}${encodeURIComponent(server.name)}`,
      name: `MCP: ${server.name}`,
      description: `${server.enabled ? "enabled" : "disabled"}, ${server.transport}`,
      mimeType: "text/markdown",
    });
  }

  return resources;
}

function readResource(uri, inventory) {
  if (uri === ROOT_URI) {
    return { uri, mimeType: "text/markdown", text: renderMarkdown(inventory) };
  }
  if (uri === JSON_URI) {
    return { uri, mimeType: "application/json", text: JSON.stringify(inventory, null, 2) };
  }
  if (uri.startsWith(SERVER_URI_PREFIX)) {
    const name = decodeURIComponent(uri.slice(SERVER_URI_PREFIX.length));
    const server = inventory.servers.find((s) => s.name === name);
    if (!server) return null;
    return { uri, mimeType: "text/markdown", text: renderServerMarkdown(server, inventory) };
  }
  return null;
}

function renderMarkdown(inventory) {
  const lines = [
    "# OmniRoute MCP Registry",
    "",
    `Config: ${inventory.config_path}`,
    `Servers: ${inventory.count} configured, ${inventory.enabled_count} enabled, ${inventory.disabled_count} disabled`,
  ];
  if (inventory.config_error) lines.push(`Config error: ${inventory.config_error}`);
  if (inventory.live_request) {
    lines.push(
      "",
      "## Live Request",
      `Recorded: ${inventory.live_request.recorded_at_utc || "unknown"}`,
      `tool_search: ${inventory.live_request.has_tool_search ? "yes" : "no"}`,
      `direct MCP tools: ${inventory.live_request.has_direct_configured_mcp_tools ? "yes" : "no"}`,
      `tools total: ${inventory.live_request.tools_total ?? "unknown"}`,
    );
  }
  lines.push("", "## Servers", "");
  for (const s of inventory.servers) {
    const keys = [...s.env_keys, ...s.http_header_keys];
    const auth = keys.length ? `, keys: ${keys.join(", ")}` : "";
    lines.push(`- ${s.name}: ${s.enabled ? "enabled" : "disabled"}, ${s.transport}${auth}`);
  }
  lines.push("", inventory.note);
  return lines.join("\n");
}

function renderServerMarkdown(server, inventory) {
  const lines = [
    `# MCP: ${server.name}`,
    "",
    `Enabled: ${server.enabled ? "yes" : "no"}`,
    `Transport: ${server.transport}`,
  ];
  if (server.command) lines.push(`Command: ${server.command}`);
  if (server.args_count !== null) lines.push(`Args: ${server.args_count} item(s), redacted`);
  if (server.url_host) lines.push(`URL host: ${server.url_host}`);
  if (server.startup_timeout_sec !== null) lines.push(`Startup timeout: ${server.startup_timeout_sec}s`);
  if (server.env_keys.length) lines.push(`Env keys: ${server.env_keys.join(", ")}`);
  if (server.http_header_keys.length) lines.push(`HTTP header keys: ${server.http_header_keys.join(", ")}`);
  lines.push("", `Registry config: ${inventory.config_path}`);
  return lines.join("\n");
}

function summarizeServer(name, defn) {
  const envKeys = new Set();
  const headerKeys = new Set();
  collectKeys(defn.env, envKeys);
  collectKeys(defn.http_headers, headerKeys);
  collectKeys(defn.httpHeaders, headerKeys);

  const hasUrl = typeof defn.url === "string" && defn.url.length > 0;
  const explicitTransport = typeof defn.transport === "string" && defn.transport.length > 0
    ? defn.transport
    : null;
  const transport = explicitTransport || (hasUrl ? "http" : "stdio");
  let urlHost = null;
  if (hasUrl) {
    try { urlHost = new URL(defn.url).host; } catch { urlHost = "invalid-url"; }
  }

  return {
    name,
    enabled: defn.enabled !== false,
    transport,
    command: defn.command ? path.basename(String(defn.command)) : null,
    args_count: Array.isArray(defn.args) ? defn.args.length : null,
    url_host: urlHost,
    startup_timeout_sec: defn.startup_timeout_sec ?? null,
    env_keys: Array.from(envKeys).sort((a, b) => a.localeCompare(b)),
    http_header_keys: Array.from(headerKeys).sort((a, b) => a.localeCompare(b)),
  };
}

function collectKeys(value, out) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return;
  for (const key of Object.keys(value)) out.add(key);
}

function parseMcpServers(text) {
  const servers = {};
  let currentServer = null;
  let currentSub = null;

  for (const raw of text.split(/\r?\n/)) {
    const line = stripTomlComment(raw).trim();
    if (!line) continue;
    const section = /^\s*\[(.+?)\]\s*$/.exec(line);
    if (section) {
      const [name, sub] = splitMcpSection(section[1]);
      currentServer = name;
      currentSub = sub;
      if (name && !servers[name]) servers[name] = { env: {}, http_headers: {} };
      continue;
    }
    if (!currentServer) continue;
    const kv = /^([A-Za-z0-9_\-]+)\s*=\s*(.+)$/.exec(line);
    if (!kv) continue;
    const target = currentSub
      ? (servers[currentServer][currentSub] = servers[currentServer][currentSub] || {})
      : servers[currentServer];
    target[kv[1]] = decodeTomlValue(kv[2]);
  }

  return servers;
}

function splitMcpSection(section) {
  const trimmed = section.trim();
  if (!trimmed.toLowerCase().startsWith("mcp_servers.")) return [null, null];
  let rest = trimmed.slice("mcp_servers.".length).trim();
  let name = "";
  let tail = "";
  if (rest.startsWith('"')) {
    const end = findClosingQuote(rest);
    if (end < 0) return [null, null];
    name = decodeTomlString(rest.slice(0, end + 1));
    tail = rest.slice(end + 1);
  } else {
    const dot = rest.indexOf(".");
    if (dot < 0) {
      name = rest;
    } else {
      name = rest.slice(0, dot);
      tail = rest.slice(dot);
    }
  }
  const sub = tail.startsWith(".") ? tail.slice(1).trim() : null;
  if (!name || sub === "env" || sub === "http_headers") return [name, sub];
  if (sub) return [name, sub];
  return [name, null];
}

function stripTomlComment(raw) {
  let quote = null;
  let escaped = false;
  let out = "";
  for (const ch of String(raw)) {
    if (escaped) { out += ch; escaped = false; continue; }
    if (quote === '"' && ch === "\\") { out += ch; escaped = true; continue; }
    if (quote) {
      out += ch;
      if (ch === quote) quote = null;
      continue;
    }
    if (ch === '"' || ch === "'") { quote = ch; out += ch; continue; }
    if (ch === "#") break;
    out += ch;
  }
  return out;
}

function decodeTomlValue(raw) {
  const value = raw.trim();
  if (/^(true|false)$/i.test(value)) return /^true$/i.test(value);
  if (value.startsWith('"') || value.startsWith("'")) return decodeTomlString(value);
  if (value.startsWith("[")) return decodeTomlArray(value);
  if (value.startsWith("{")) return decodeTomlInlineTable(value);
  const asNum = Number(value);
  if (Number.isFinite(asNum)) return asNum;
  return value;
}

function decodeTomlString(raw) {
  const value = raw.trim();
  if (value.startsWith("'") && value.endsWith("'")) return value.slice(1, -1);
  if (!value.startsWith('"') || !value.endsWith('"')) return value;
  try { return JSON.parse(value); } catch { return value.slice(1, -1); }
}

function decodeTomlArray(raw) {
  const inner = raw.trim().slice(1, -1).trim();
  if (!inner) return [];
  return splitTopLevel(inner).map(decodeTomlValue);
}

function decodeTomlInlineTable(raw) {
  const inner = raw.trim().slice(1, -1).trim();
  const out = {};
  if (!inner) return out;
  for (const part of splitTopLevel(inner)) {
    const eq = part.indexOf("=");
    if (eq <= 0) continue;
    const key = decodeTomlKey(part.slice(0, eq).trim());
    out[key] = decodeTomlValue(part.slice(eq + 1).trim());
  }
  return out;
}

function decodeTomlKey(raw) {
  if (raw.startsWith('"') || raw.startsWith("'")) return decodeTomlString(raw);
  return raw;
}

function splitTopLevel(raw) {
  const out = [];
  let cur = "";
  let quote = null;
  let escaped = false;
  let depth = 0;
  for (const ch of raw) {
    if (escaped) { cur += ch; escaped = false; continue; }
    if (quote === '"' && ch === "\\") { cur += ch; escaped = true; continue; }
    if (quote) {
      cur += ch;
      if (ch === quote) quote = null;
      continue;
    }
    if (ch === '"' || ch === "'") { quote = ch; cur += ch; continue; }
    if (ch === "[" || ch === "{") depth += 1;
    if (ch === "]" || ch === "}") depth -= 1;
    if (ch === "," && depth === 0) {
      out.push(cur.trim());
      cur = "";
      continue;
    }
    cur += ch;
  }
  if (cur.trim()) out.push(cur.trim());
  return out;
}

function findClosingQuote(value) {
  let escaped = false;
  for (let i = 1; i < value.length; i += 1) {
    const ch = value[i];
    if (escaped) { escaped = false; continue; }
    if (ch === "\\") { escaped = true; continue; }
    if (ch === '"') return i;
  }
  return -1;
}

function preview(value, max = 240) {
  const text = String(value ?? "").replace(/\s+/g, " ").trim();
  return text.length > max ? `${text.slice(0, max)}...` : text;
}

class StdioMcpClient {
  constructor(name, defn, timeoutMs) {
    this.name = name;
    this.defn = defn;
    this.timeoutMs = timeoutMs;
    this.nextId = 1;
    this.pending = new Map();
    this.stdoutBuf = "";
    this.stderrBuf = "";
    this.child = null;
  }

  start() {
    const args = Array.isArray(this.defn.args) ? this.defn.args.slice() : [];
    const env = { ...process.env };
    if (this.defn.env && typeof this.defn.env === "object") {
      for (const [k, v] of Object.entries(this.defn.env)) env[k] = String(v);
    }
    const command = String(this.defn.command || "");
    const isShellTarget = /\.(cmd|bat)$/i.test(command);
    this.child = spawn(command, args, {
      stdio: ["pipe", "pipe", "pipe"],
      shell: isShellTarget,
      windowsHide: true,
      env,
    });
    this.child.on("error", (err) => this.rejectAll(err));
    this.child.on("exit", (code, signal) => {
      if (this.pending.size > 0) {
        this.rejectAll(new Error(`server exited while waiting for JSON-RPC response (code=${code} signal=${signal})`));
      }
    });
    this.child.stderr.on("data", (chunk) => {
      this.stderrBuf += Buffer.isBuffer(chunk) ? chunk.toString("utf8") : String(chunk);
      if (this.stderrBuf.length > 8000) this.stderrBuf = this.stderrBuf.slice(-8000);
    });
    this.child.stdout.on("data", (chunk) => {
      this.stdoutBuf += Buffer.isBuffer(chunk) ? chunk.toString("utf8") : String(chunk);
      let idx;
      while ((idx = this.stdoutBuf.indexOf("\n")) >= 0) {
        const line = this.stdoutBuf.slice(0, idx);
        this.stdoutBuf = this.stdoutBuf.slice(idx + 1);
        this.handleLine(line);
      }
    });
  }

  handleLine(line) {
    const trimmed = line.replace(/\r$/, "").trim();
    if (!trimmed || !(trimmed.startsWith("{") || trimmed.startsWith("["))) return;
    let parsed;
    try { parsed = JSON.parse(trimmed); } catch { return; }
    for (const msg of Array.isArray(parsed) ? parsed : [parsed]) {
      if (!msg || typeof msg !== "object" || msg.id === undefined) continue;
      const id = String(msg.id);
      const pending = this.pending.get(id);
      if (!pending) continue;
      this.pending.delete(id);
      clearTimeout(pending.timer);
      if (msg.error) {
        pending.reject(new Error(`${pending.method} returned JSON-RPC error: ${preview(msg.error.message || JSON.stringify(msg.error))}`));
      } else {
        pending.resolve(msg.result ?? {});
      }
    }
  }

  request(method, params = {}) {
    const id = this.nextId++;
    const frame = JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n";
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(String(id));
        reject(new Error(`${method} timed out after ${this.timeoutMs}ms${this.stderrBuf ? `; stderr=${preview(this.stderrBuf)}` : ""}`));
      }, this.timeoutMs);
      try { timer.unref(); } catch {}
      this.pending.set(String(id), { method, resolve, reject, timer });
      try {
        this.child.stdin.write(frame);
      } catch (err) {
        clearTimeout(timer);
        this.pending.delete(String(id));
        reject(err);
      }
    });
  }

  notification(method, params = {}) {
    this.child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n");
  }

  rejectAll(err) {
    for (const [id, pending] of this.pending.entries()) {
      clearTimeout(pending.timer);
      pending.reject(err);
      this.pending.delete(id);
    }
  }

  close() {
    this.rejectAll(new Error("transport closed"));
    if (!this.child?.pid) return;
    if (process.platform === "win32") {
      try {
        spawnSync("taskkill.exe", ["/PID", String(this.child.pid), "/T", "/F"], {
          stdio: "ignore",
          windowsHide: true,
          timeout: 3000,
        });
        return;
      } catch {}
    }
    try { this.child.kill("SIGTERM"); } catch {}
  }
}
