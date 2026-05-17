#!/usr/bin/env node
/*
 * Codex OmniRoute -- per-server MCP probe.
 *
 * Reads a Codex config.toml, walks [mcp_servers.<name>] entries, and probes
 * each configured stdio or streamable-HTTP MCP server with the real MCP
 * startup sequence:
 *
 *   initialize -> wait for result -> notifications/initialized -> tools/list
 *
 * If the initialize result advertises resources or prompts, the probe also
 * attempts resources/list or prompts/list. A read-only tools/call sample can
 * be enabled explicitly with --allow-sample-call plus --call-server/--call-tool.
 *
 * Result statuses are deliberately layered:
 *
 *   transport_dirty      stdout had non-JSON data on a stdio MCP transport
 *   handshake_failed     initialize or initialized failed
 *   tools_list_failed    initialized but tools/list failed
 *   no_tools             tools/list succeeded with an empty tools array
 *   tools_listed         tools/list succeeded with one or more tools
 *   callable             explicit safe sample tools/call succeeded
 *   call_failed          explicit sample tools/call failed
 *
 * Usage:
 *   node mcp_probe.mjs [--config <path>] [--timeout-ms N] [--server NAME] [--json]
 *                      [--allow-sample-call --call-server NAME --call-tool TOOL
 *                       [--call-args-json '{"query":"docs"}']]
 *
 * Exit code is 0 for probe results (the verifier interprets the JSON) and
 * non-zero only for probe tooling errors such as unreadable config.
 */
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import process from "node:process";

const PROTOCOL_VERSION = "2024-11-05";

const argv = process.argv.slice(2);
const opts = {
  configPath: "",
  timeoutMs: 5000,
  server: null,
  json: false,
  allowSampleCall: false,
  callServer: null,
  callTool: null,
  callArgsJson: "{}",
};

for (let i = 0; i < argv.length; i += 1) {
  const a = argv[i];
  if (a === "--config" || a === "--isolated-config") opts.configPath = argv[++i];
  else if (a === "--timeout-ms") opts.timeoutMs = parseInt(argv[++i], 10) || 5000;
  else if (a === "--server") opts.server = argv[++i];
  else if (a === "--json") opts.json = true;
  else if (a === "--allow-sample-call") opts.allowSampleCall = true;
  else if (a === "--call-server") opts.callServer = argv[++i];
  else if (a === "--call-tool") opts.callTool = argv[++i];
  else if (a === "--call-args-json") opts.callArgsJson = argv[++i];
  else if (a === "-h" || a === "--help") {
    process.stdout.write(
      "Usage: node mcp_probe.mjs [--config <path>] [--timeout-ms N] [--server NAME] [--json]\n" +
      "                      [--allow-sample-call --call-server NAME --call-tool TOOL [--call-args-json JSON]]\n",
    );
    process.exit(0);
  }
}

if (!opts.configPath) {
  opts.configPath = path.join(os.homedir(), ".codex", "config.toml");
}

function preview(value, max = 240) {
  const s = String(value ?? "").replace(/\s+/g, " ").trim();
  return s.length > max ? `${s.slice(0, max)}...` : s;
}

function redactHeaderNames(headers) {
  return Object.keys(headers || {}).sort((a, b) => a.localeCompare(b));
}

class ProbeError extends Error {
  constructor(status, detail, extra = {}) {
    super(detail);
    this.status = status;
    this.detail = detail;
    Object.assign(this, extra);
  }
}

class TransportDirtyError extends ProbeError {
  constructor(line) {
    super("transport_dirty", `non-JSON stdout before/among JSON-RPC frames: "${preview(line)}"`, {
      firstNonJsonStdoutLine: preview(line),
    });
  }
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
    if (t.length < 2) return null;
    if (t.startsWith("'") && t.endsWith("'")) return t.slice(1, -1);
    if (!(t.startsWith('"') && t.endsWith('"'))) return null;
    try {
      return JSON.parse(t);
    } catch {
      const inner = t.slice(1, -1);
      let out = "";
      for (let i = 0; i < inner.length; i += 1) {
        const c = inner[i];
        if (c === "\\" && i + 1 < inner.length) {
          const n = inner[i + 1];
          if (n === "\\") { out += "\\"; i += 1; continue; }
          if (n === '"') { out += '"'; i += 1; continue; }
          if (n === "n") { out += "\n"; i += 1; continue; }
          if (n === "r") { out += "\r"; i += 1; continue; }
          if (n === "t") { out += "\t"; i += 1; continue; }
        }
        out += c;
      }
      return out;
    }
  };

  const splitTopLevel = (raw) => {
    const out = [];
    let cur = "";
    let quote = null;
    let escaped = false;
    let depth = 0;
    for (const ch of raw) {
      if (escaped) {
        cur += ch;
        escaped = false;
        continue;
      }
      if (quote === '"' && ch === "\\") {
        cur += ch;
        escaped = true;
        continue;
      }
      if (quote) {
        cur += ch;
        if (ch === quote) quote = null;
        continue;
      }
      if (ch === '"' || ch === "'") {
        quote = ch;
        cur += ch;
        continue;
      }
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
  };

  const decodeArray = (raw) => {
    if (!raw) return null;
    const t = raw.trim();
    if (!(t.startsWith("[") && t.endsWith("]"))) return null;
    const inner = t.slice(1, -1).trim();
    if (!inner) return [];
    const out = [];
    for (const part of splitTopLevel(inner)) {
      const s = decodeString(part);
      if (s === null) return null;
      out.push(s);
    }
    return out;
  };

  const decodeInlineTable = (raw) => {
    if (!raw) return null;
    const t = raw.trim();
    if (!(t.startsWith("{") && t.endsWith("}"))) return null;
    const inner = t.slice(1, -1).trim();
    const out = {};
    if (!inner) return out;
    for (const part of splitTopLevel(inner)) {
      const eq = part.indexOf("=");
      if (eq <= 0) return null;
      const rawKey = part.slice(0, eq).trim();
      const rawValue = part.slice(eq + 1).trim();
      const key = decodeString(rawKey) ?? rawKey;
      const value = decodeString(rawValue) ?? rawValue;
      out[key] = value;
    }
    return out;
  };

  const splitSection = (sec) => {
    if (!sec.toLowerCase().startsWith("mcp_servers.")) return [null, null];
    let rest = sec.slice("mcp_servers.".length).trim();
    if (!rest) return [null, null];
    let name = "";
    let tail = "";
    if (rest.startsWith('"')) {
      let escaped = false;
      let end = -1;
      for (let i = 1; i < rest.length; i += 1) {
        const ch = rest[i];
        if (escaped) { escaped = false; continue; }
        if (ch === "\\") { escaped = true; continue; }
        if (ch === '"') { end = i; break; }
      }
      if (end < 0) return [null, null];
      name = decodeString(rest.slice(0, end + 1));
      tail = rest.slice(end + 1);
    } else {
      const dot = rest.indexOf(".");
      if (dot < 0) {
        name = rest;
        tail = "";
      } else {
        name = rest.slice(0, dot);
        tail = rest.slice(dot);
      }
    }
    const sub = tail.startsWith(".") ? tail.slice(1).trim() : null;
    return [name, sub || null];
  };

  for (const raw of lines) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const sec = /^\[\s*(.+?)\s*\]\s*(?:#.*)?$/.exec(line);
    if (sec) {
      const [name, sub] = splitSection(sec[1]);
      if (!name) {
        currentServer = null;
        currentSub = null;
        continue;
      }
      if (!servers[name]) {
        servers[name] = {
          command: null,
          args: [],
          env: {},
          http_headers: {},
          raw: {},
        };
      }
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
    const asInlineTable = asString === null && asArray === null ? decodeInlineTable(val) : null;
    if (asString !== null) target[key] = asString;
    else if (asArray !== null) target[key] = asArray;
    else if (asInlineTable !== null) target[key] = asInlineTable;
    else if (/^(true|false)$/i.test(val.trim())) target[key] = /^true$/i.test(val.trim());
    else target[key] = val;
  }
  return servers;
}

// ---------- JSON-RPC clients ----------

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
    this.firstNonJsonStdoutLine = null;
    this.dirtyError = null;
  }

  start() {
    const args = Array.isArray(this.defn.args) ? this.defn.args.slice() : [];
    const env = { ...process.env };
    if (this.defn.env && typeof this.defn.env === "object") {
      for (const [k, v] of Object.entries(this.defn.env)) env[k] = String(v);
    }

    const isShellTarget = /\.(cmd|bat)$/i.test(this.defn.command);
    try {
      this.child = spawn(this.defn.command, args, {
        stdio: ["pipe", "pipe", "pipe"],
        shell: isShellTarget,
        windowsHide: true,
        env,
      });
    } catch (err) {
      throw new ProbeError("spawn_error", err?.message || String(err));
    }

    this.child.on("error", (err) => {
      this.rejectAll(new ProbeError("spawn_error", err?.message || String(err)));
    });

    this.child.on("exit", (code, signal) => {
      if (this.pending.size > 0) {
        this.rejectAll(new ProbeError(
          "handshake_failed",
          `server exited while waiting for JSON-RPC response (code=${code} signal=${signal})`,
        ));
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
        this.handleStdoutLine(line);
      }
    });
  }

  handleStdoutLine(line) {
    const trimmed = line.replace(/\r$/, "").trim();
    if (!trimmed) return;
    if (!(trimmed.startsWith("{") || trimmed.startsWith("["))) {
      if (!this.firstNonJsonStdoutLine) this.firstNonJsonStdoutLine = trimmed;
      this.dirtyError = new TransportDirtyError(trimmed);
      this.rejectAll(this.dirtyError);
      return;
    }

    let parsed;
    try {
      parsed = JSON.parse(trimmed);
    } catch {
      if (!this.firstNonJsonStdoutLine) this.firstNonJsonStdoutLine = trimmed;
      this.dirtyError = new TransportDirtyError(trimmed);
      this.rejectAll(this.dirtyError);
      return;
    }

    for (const msg of Array.isArray(parsed) ? parsed : [parsed]) {
      if (!msg || typeof msg !== "object" || msg.id === undefined) continue;
      const key = String(msg.id);
      const pending = this.pending.get(key);
      if (!pending) continue;
      this.pending.delete(key);
      clearTimeout(pending.timer);
      if (msg.error) {
        pending.reject(new ProbeError(
          pending.failureStatus,
          `${pending.method} returned JSON-RPC error: ${preview(msg.error.message || JSON.stringify(msg.error))}`,
        ));
      } else {
        pending.resolve(msg.result ?? {});
      }
    }
  }

  rejectAll(err) {
    for (const [id, pending] of this.pending.entries()) {
      clearTimeout(pending.timer);
      pending.reject(err);
      this.pending.delete(id);
    }
  }

  request(method, params = {}, failureStatus = "handshake_failed") {
    if (this.dirtyError) return Promise.reject(this.dirtyError);
    const id = this.nextId;
    this.nextId += 1;
    const frame = JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n";
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(String(id));
        reject(new ProbeError(failureStatus, `${method} timed out after ${this.timeoutMs}ms`));
      }, this.timeoutMs);
      try { timer.unref(); } catch {}
      this.pending.set(String(id), { method, failureStatus, resolve, reject, timer });
      try {
        this.child.stdin.write(frame);
      } catch (err) {
        clearTimeout(timer);
        this.pending.delete(String(id));
        reject(new ProbeError(failureStatus, `${method} write failed: ${err?.message || err}`));
      }
    });
  }

  notification(method, params = {}) {
    if (this.dirtyError) throw this.dirtyError;
    const frame = JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n";
    try {
      this.child.stdin.write(frame);
    } catch (err) {
      throw new ProbeError("handshake_failed", `${method} notification write failed: ${err?.message || err}`);
    }
  }

  close() {
    this.rejectAll(new ProbeError("closed", "probe closed transport"));
    if (!this.child) return;
    try { this.child.kill("SIGTERM"); } catch {}
    const killTimer = setTimeout(() => {
      try { this.child.kill("SIGKILL"); } catch {}
    }, 250);
    try { killTimer.unref(); } catch {}
  }

  assertClean() {
    if (this.dirtyError) throw this.dirtyError;
  }
}

class HttpMcpClient {
  constructor(name, defn, timeoutMs) {
    this.name = name;
    this.url = defn.url;
    this.timeoutMs = timeoutMs;
    this.nextId = 1;
    this.sessionId = null;
    this.headers = {};
    if (defn.http_headers && typeof defn.http_headers === "object") {
      for (const [k, v] of Object.entries(defn.http_headers)) this.headers[k] = String(v);
    }
  }

  async request(method, params = {}, failureStatus = "handshake_failed") {
    const id = this.nextId;
    this.nextId += 1;
    const messages = await this.post({ jsonrpc: "2.0", id, method, params }, failureStatus);
    const response = messages.find((msg) => msg && typeof msg === "object" && String(msg.id) === String(id));
    if (!response) {
      throw new ProbeError(failureStatus, `${method} did not return a JSON-RPC response with id=${id}`);
    }
    if (response.error) {
      throw new ProbeError(
        failureStatus,
        `${method} returned JSON-RPC error: ${preview(response.error.message || JSON.stringify(response.error))}`,
      );
    }
    return response.result ?? {};
  }

  async notification(method, params = {}) {
    await this.post({ jsonrpc: "2.0", method, params }, "handshake_failed", true);
  }

  async post(payload, failureStatus, notification = false) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try { timer.unref(); } catch {}
    try {
      const headers = {
        accept: "application/json, text/event-stream",
        "content-type": "application/json",
        "mcp-protocol-version": PROTOCOL_VERSION,
        ...this.headers,
      };
      if (this.sessionId) headers["mcp-session-id"] = this.sessionId;

      const res = await fetch(this.url, {
        method: "POST",
        headers,
        body: JSON.stringify(payload),
        signal: controller.signal,
      });
      const newSessionId = res.headers.get("mcp-session-id");
      if (newSessionId) this.sessionId = newSessionId;

      const text = await res.text();
      if (!res.ok) {
        throw new ProbeError(
          failureStatus,
          `HTTP ${res.status} from ${this.url}: ${preview(text)}`,
          { http_status: res.status, http_header_names: redactHeaderNames(this.headers) },
        );
      }
      if (notification && !text.trim()) return [];
      return parseHttpMcpMessages(text, res.headers.get("content-type") || "", failureStatus);
    } catch (err) {
      if (err instanceof ProbeError) throw err;
      if (err?.name === "AbortError") {
        throw new ProbeError(failureStatus, `HTTP ${payload.method} timed out after ${this.timeoutMs}ms`);
      }
      throw new ProbeError(failureStatus, err?.message || String(err));
    } finally {
      clearTimeout(timer);
    }
  }

  close() {}
}

function parseHttpMcpMessages(text, contentType, failureStatus) {
  const trimmed = text.trim();
  if (!trimmed) return [];

  try {
    const parsed = JSON.parse(trimmed);
    return Array.isArray(parsed) ? parsed : [parsed];
  } catch {}

  if (contentType.toLowerCase().includes("text/event-stream") || /^event:|^data:/m.test(text)) {
    const messages = [];
    let dataLines = [];
    const flush = () => {
      if (dataLines.length === 0) return;
      const data = dataLines.join("\n").trim();
      dataLines = [];
      if (!data || data === "[DONE]") return;
      try {
        const parsed = JSON.parse(data);
        if (Array.isArray(parsed)) messages.push(...parsed);
        else messages.push(parsed);
      } catch {
        throw new ProbeError(failureStatus, `SSE data was not JSON: ${preview(data)}`);
      }
    };
    for (const rawLine of text.split(/\r?\n/)) {
      const line = rawLine.trimEnd();
      if (!line) {
        flush();
        continue;
      }
      if (line.startsWith("data:")) dataLines.push(line.slice(5).trimStart());
    }
    flush();
    return messages;
  }

  const lineMessages = [];
  for (const line of trimmed.split(/\r?\n/)) {
    const t = line.trim();
    if (!t) continue;
    try {
      lineMessages.push(JSON.parse(t));
    } catch {
      throw new ProbeError(failureStatus, `HTTP response was not JSON/SSE: ${preview(text)}`);
    }
  }
  return lineMessages;
}

// ---------- probe flow ----------

function supportsCapability(capabilities, key) {
  return Boolean(capabilities && typeof capabilities === "object" && capabilities[key]);
}

function summarizeTools(tools) {
  return tools
    .map((tool) => (tool && typeof tool.name === "string" ? tool.name : null))
    .filter(Boolean)
    .slice(0, 50);
}

function isReadOnlyToolName(name) {
  const n = String(name || "").toLowerCase();
  const unsafe = /(write|create|update|delete|remove|edit|apply|patch|post|put|send|publish|merge|commit|push|install|execute|exec|run|shell|spawn|kill|drop|truncate|mutate|mutation|set_)/;
  if (unsafe.test(n)) return false;
  return /(^|[_-])(list|search|read|get|fetch|find|lookup|resolve|describe|inspect|query|check|status|health)([_-]|$)/.test(n);
}

function parseSampleArgs() {
  try {
    const parsed = JSON.parse(opts.callArgsJson || "{}");
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new Error("call args must be a JSON object");
    }
    return parsed;
  } catch (err) {
    throw new ProbeError("sample_call_config_error", `--call-args-json is not a JSON object: ${err?.message || err}`);
  }
}

async function completeProbe(client, sampleCall) {
  const init = await client.request("initialize", {
    protocolVersion: PROTOCOL_VERSION,
    capabilities: {},
    clientInfo: { name: "codex-omniroute-mcp-probe", version: "0.2.0" },
  }, "handshake_failed");

  client.notification("notifications/initialized", {});

  const capabilities = init?.capabilities && typeof init.capabilities === "object" ? init.capabilities : {};
  const serverInfo = init?.serverInfo && typeof init.serverInfo === "object" ? init.serverInfo : null;
  const toolsResult = await client.request("tools/list", {}, "tools_list_failed");
  const tools = Array.isArray(toolsResult?.tools) ? toolsResult.tools : null;
  if (!tools) {
    throw new ProbeError("tools_list_failed", "tools/list result did not contain a tools array");
  }

  const extra = {
    protocol_version: init?.protocolVersion || null,
    server_info: serverInfo,
    capabilities: Object.keys(capabilities).sort(),
    tools_count: tools.length,
    tools: summarizeTools(tools),
    resources_status: "not_advertised",
    resources_count: null,
    prompts_status: "not_advertised",
    prompts_count: null,
  };

  if (supportsCapability(capabilities, "resources")) {
    try {
      const resourcesResult = await client.request("resources/list", {}, "resources_list_failed");
      const resources = Array.isArray(resourcesResult?.resources) ? resourcesResult.resources : [];
      extra.resources_status = "listed";
      extra.resources_count = resources.length;
    } catch (err) {
      const probeErr = err instanceof ProbeError
        ? err
        : new ProbeError("resources_list_failed", err?.message || String(err));
      extra.resources_status = probeErr.status || "resources_list_failed";
      extra.resources_detail = probeErr.detail || probeErr.message || String(probeErr);
    }
  }

  if (supportsCapability(capabilities, "prompts")) {
    try {
      const promptsResult = await client.request("prompts/list", {}, "prompts_list_failed");
      const prompts = Array.isArray(promptsResult?.prompts) ? promptsResult.prompts : [];
      extra.prompts_status = "listed";
      extra.prompts_count = prompts.length;
    } catch (err) {
      const probeErr = err instanceof ProbeError
        ? err
        : new ProbeError("prompts_list_failed", err?.message || String(err));
      extra.prompts_status = probeErr.status || "prompts_list_failed";
      extra.prompts_detail = probeErr.detail || probeErr.message || String(probeErr);
    }
  }

  if (sampleCall) {
    extra.call_tool = sampleCall.tool;
    if (!isReadOnlyToolName(sampleCall.tool)) {
      client.assertClean?.();
      return {
        status: "sample_call_rejected",
        detail: `sample tool name does not match read-only allow-list: ${sampleCall.tool}`,
        ...extra,
      };
    }
    if (!tools.some((tool) => tool && tool.name === sampleCall.tool)) {
      client.assertClean?.();
      return {
        status: "call_failed",
        detail: `sample tool not present in tools/list: ${sampleCall.tool}`,
        ...extra,
      };
    }
    try {
      const callResult = await client.request("tools/call", {
        name: sampleCall.tool,
        arguments: sampleCall.args,
      }, "call_failed");
      client.assertClean?.();
      return {
        status: "callable",
        detail: `tools/call succeeded for ${sampleCall.tool}`,
        call_result_keys: callResult && typeof callResult === "object" ? Object.keys(callResult).sort() : [],
        ...extra,
      };
    } catch (err) {
      if (err?.status === "transport_dirty") throw err;
      return {
        status: "call_failed",
        detail: err?.detail || err?.message || String(err),
        ...extra,
      };
    }
  }

  client.assertClean?.();
  return {
    status: tools.length > 0 ? "tools_listed" : "no_tools",
    detail: tools.length > 0
      ? `tools/list returned ${tools.length} tool(s)`
      : "tools/list succeeded but returned no tools",
    ...extra,
  };
}

async function probeServer(name, defn, timeoutMs, sampleCall) {
  if (defn.enabled === false) {
    return { name, status: "skipped_disabled", detail: "server is configured with enabled=false" };
  }
  if (defn.url && !defn.command) {
    const client = new HttpMcpClient(name, defn, timeoutMs);
    try {
      const result = await completeProbe(client, sampleCall);
      return { name, transport: "http", ...result };
    } catch (err) {
      return errorResult(name, "http", err);
    } finally {
      client.close();
    }
  }
  if (!defn.command) {
    return { name, status: "no_transport", detail: "neither command nor url is set" };
  }

  const client = new StdioMcpClient(name, defn, timeoutMs);
  try {
    client.start();
    const result = await completeProbe(client, sampleCall);
    return {
      name,
      transport: "stdio",
      stderr: preview(client.stderrBuf, 600),
      firstNonJsonStdoutLine: client.firstNonJsonStdoutLine,
      ...result,
    };
  } catch (err) {
    return {
      ...errorResult(name, "stdio", err),
      stderr: preview(client.stderrBuf, 600),
      firstNonJsonStdoutLine: client.firstNonJsonStdoutLine || err?.firstNonJsonStdoutLine || null,
    };
  } finally {
    client.close();
  }
}

function errorResult(name, transport, err) {
  if (err instanceof ProbeError) {
    return {
      name,
      transport,
      status: err.status,
      detail: err.detail,
      firstNonJsonStdoutLine: err.firstNonJsonStdoutLine || null,
      http_status: err.http_status || null,
    };
  }
  return {
    name,
    transport,
    status: "handshake_failed",
    detail: err?.message || String(err),
  };
}

function statusTag(status) {
  if (status === "tools_listed" || status === "callable") return "PASS";
  if (status === "no_tools" || status === "skipped_disabled") return "WARN";
  return "FAIL";
}

async function main() {
  const text = fs.readFileSync(opts.configPath, "utf8");
  const servers = parseConfig(text);
  const names = opts.server ? [opts.server] : Object.keys(servers);
  let sampleArgs = null;
  if (opts.allowSampleCall || opts.callServer || opts.callTool || opts.callArgsJson !== "{}") {
    if (!opts.allowSampleCall || !opts.callServer || !opts.callTool) {
      throw new ProbeError(
        "sample_call_config_error",
        "sample calls require --allow-sample-call, --call-server, and --call-tool",
      );
    }
    sampleArgs = parseSampleArgs();
  }

  const results = [];
  for (const n of names) {
    if (!servers[n]) {
      results.push({ name: n, status: "missing", detail: "no [mcp_servers.<name>] entry in config" });
      continue;
    }
    const sampleCall = opts.allowSampleCall && opts.callServer === n
      ? { tool: opts.callTool, args: sampleArgs }
      : null;
    const r = await probeServer(n, servers[n], opts.timeoutMs, sampleCall);
    results.push(r);
  }

  if (opts.json) {
    process.stdout.write(JSON.stringify({
      count: results.length,
      config_path: opts.configPath,
      timeout_ms: opts.timeoutMs,
      sample_call_requested: Boolean(opts.allowSampleCall),
      results,
    }, null, 2) + "\n");
    return;
  }

  let passCount = 0;
  let warnCount = 0;
  let failCount = 0;
  for (const r of results) {
    const tag = statusTag(r.status);
    if (tag === "PASS") passCount += 1;
    else if (tag === "WARN") warnCount += 1;
    else failCount += 1;
    let line = `[${tag}] ${r.name} -- ${r.status}: ${r.detail || ""}`;
    if (r.transport) line += ` | transport=${r.transport}`;
    if (typeof r.tools_count === "number") line += ` | tools=${r.tools_count}`;
    if (r.firstNonJsonStdoutLine) line += ` | non-JSON stdout="${preview(r.firstNonJsonStdoutLine, 120)}"`;
    process.stdout.write(line + "\n");
  }
  process.stdout.write(`\nMCP probe summary: ${passCount} pass, ${warnCount} warn, ${failCount} fail (out of ${results.length}).\n`);
}

main().catch((err) => {
  process.stderr.write(`mcp_probe error: ${err?.stack || err?.message || String(err)}\n`);
  process.exit(1);
});
