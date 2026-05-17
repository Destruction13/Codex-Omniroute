#!/usr/bin/env node
/*
 * Codex OmniRoute — local OpenAI-compatible bridge.
 *
 * Narrow waist of the Variant-3 architecture. The official Microsoft Store
 * Codex app (launched via Start-Codex-OmniRoute.ps1) runs against an
 * isolated CODEX_HOME (".codex-omniroute-home" next to the launcher). The
 * launcher seeds that directory with:
 *   - auth.json         : the user's real OAuth tokens copied verbatim from
 *                         their normal ~/.codex/auth.json (Codex Desktop
 *                         stays logged in as the user; fast mode +
 *                         ChatGPT credits keep working).
 *   - models_cache.json : copied from real ~/.codex if present.
 *   - config.toml       : written fresh by the launcher, selects
 *                         model_provider = "omniroute_bridge" pointing
 *                         at this bridge:
 *
 *                           [model_providers.omniroute_bridge]
 *                           base_url = "http://127.0.0.1:<PORT>/v1"
 *                           wire_api = "responses"
 *                           requires_openai_auth = true
 *                           supports_websockets = false
 *
 * state_5.sqlite is deliberately absent in the isolated dir so Codex
 * Desktop starts with an empty thread store and reads model_provider
 * from the freshly-written config.toml on the first new thread.
 *
 * The bridge reads $CODEX_HOME/auth.json directly to recover the real
 * OAuth bearer for compact + dictation passthrough — no sentinel auth
 * scheme, no CODEX_OFFICIAL_AUTH_PATH redirection. Codex Desktop sends
 * the same real bearer on its requests, so the official-passthrough
 * path forwards it verbatim.
 *
 * Behavior summary
 *   /healthz                       -> local status
 *   GET  /v1/models                -> local models_cache.json from $CODEX_HOME (NOT OmniRoute)
 *   POST /v1/responses             -> OmniRoute (main reasoning, counted)
 *   POST /v1/chat/completions      -> OmniRoute (main reasoning, counted)
 *   POST /v1/responses/compact     -> official upstream
 *   POST /v1/audio/transcriptions  -> official upstream
 *   POST /transcribe               -> official upstream /audio/transcriptions
 *   GET/POST /v1/images/generations-> official upstream (optional parity)
 *   *                              -> official upstream proxy with auth fallback
 *
 * Hard rules
 *   - NEVER log secrets.
 *   - NEVER hardcode connection IDs, account IDs, or API keys.
 *   - NEVER reroute compact or dictation to OmniRoute.
 *   - NEVER fetch /v1/models from OmniRoute (Codex UI compatibility).
 *
 * Dependencies: Node >= 18 stdlib only. zstd is opt-in via dynamic import.
 */

import http from "node:http";
import https from "node:https";
import { URL } from "node:url";
import { Buffer } from "node:buffer";
import fsSync from "node:fs";
import { promises as fs } from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import os from "node:os";
import process from "node:process";

// ----------------------------------------------------------------------------
// Configuration
// ----------------------------------------------------------------------------

const VERSION = "0.1.0";
const STARTED_AT = Date.now();

const HOST = process.env.CODEX_BRIDGE_HOST || "127.0.0.1";
const PORT = parseInt(process.env.CODEX_BRIDGE_PORT || "20333", 10);

const OFFICIAL_UPSTREAM = stripTrailingSlash(
  process.env.CODEX_OFFICIAL_UPSTREAM || "https://chatgpt.com/backend-api/codex",
);

// CODEX_HOME under Variant 3 is the isolated ".codex-omniroute-home"
// directory next to the launcher. The launcher seeds it on every boot:
// auth.json comes from the user's real ~/.codex/auth.json (so Codex
// Desktop stays signed in), models_cache.json is copied if present, and
// config.toml is regenerated with the managed OmniRoute provider plus
// selected MCP/plugin/marketplace/project sections imported from the real
// user config or overlay. The bridge reads auth.json from here for the
// official-passthrough fallback, and models_cache.json for /v1/models. No
// CODEX_OFFICIAL_AUTH_PATH redirection: Codex Desktop sends the real OAuth
// bearer on its requests, so we forward it as-is.
const CODEX_HOME = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
const CODEX_AUTH_PATH = path.join(CODEX_HOME, "auth.json");
const CODEX_MODELS_PATH = path.join(CODEX_HOME, "models_cache.json");
const CODEX_SEED_STAMP_PATH = path.join(CODEX_HOME, ".omniroute-seed.json");
const CODEX_CONFIG_PATH = path.join(CODEX_HOME, "config.toml");
const LAST_REASONING_DIAGNOSTIC_PATH = path.join(CODEX_HOME, ".omniroute-last-reasoning.json");

const OMNIROUTE_BASE_URL_ENV = stripTrailingSlash(process.env.OMNIROUTE_BASE_URL || "");
const OMNIROUTE_API_KEY_ENV = process.env.OMNIROUTE_API_KEY || "";
const OMNIROUTE_MODEL_PREFIX = process.env.OMNIROUTE_MODEL_PREFIX ?? "cx/";
const OMNIROUTE_PIN_55 = process.env.OMNIROUTE_PIN_55 === "1";
const OMNIROUTE_55_CONNECTION_ID = process.env.OMNIROUTE_55_CONNECTION_ID || "";
const OMNIROUTE_MODEL_ALIASES = process.env.OMNIROUTE_MODEL_ALIASES || "";

const PROVIDER_JSON_PATH = path.resolve(
  process.env.OMNIROUTE_PROVIDER_JSON || "./omniroute-provider.json",
);
const OPENCODE_AUTH_PATH = path.join(os.homedir(), ".config", "opencode", "auth.json");
const OPENCODE_PROVIDER_NAMES = ["cloud_omni", "miracloud", "omniroute"];

const REQUEST_TIMEOUT_MS = parseInt(process.env.CODEX_BRIDGE_REQUEST_TIMEOUT_MS || "300000", 10);
const LOG_LEVEL = (process.env.CODEX_BRIDGE_LOG_LEVEL || "info").toLowerCase();

// Header allowlist for inbound -> outbound forwarding.
const HOP_BY_HOP = new Set([
  "host",
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
  "content-length", // we recompute
  "content-encoding", // we decompress and re-send uncompressed
]);

// ----------------------------------------------------------------------------
// Logging
// ----------------------------------------------------------------------------

// Optional persistent log file. The launcher passes BRIDGE_LOG_PATH so the
// bridge can keep a durable record of its activity even when the launcher
// PowerShell process exits and the inherited stdout pipe goes away. Without
// this fallback the bridge dies on first stdout write after the parent shell
// closes (EPIPE / CTRL_CLOSE_EVENT), which leaves Codex Desktop talking to a
// dead loopback port and silently retrying.
const BRIDGE_LOG_PATH = process.env.BRIDGE_LOG_PATH || "";
let BRIDGE_LOG_STREAM = null;
if (BRIDGE_LOG_PATH) {
  try {
    BRIDGE_LOG_STREAM = fsSync.createWriteStream(BRIDGE_LOG_PATH, { flags: "a" });
    BRIDGE_LOG_STREAM.on("error", () => { BRIDGE_LOG_STREAM = null; });
  } catch {
    BRIDGE_LOG_STREAM = null;
  }
}

const LEVELS = { error: 0, warn: 1, info: 2, debug: 3 };
function log(level, ...args) {
  if ((LEVELS[level] ?? 2) > (LEVELS[LOG_LEVEL] ?? 2)) return;
  const ts = new Date().toISOString();
  const line = `[${ts}] [${level.toUpperCase()}] ${args
    .map((a) => (typeof a === "string" ? a : safeStringify(a)))
    .join(" ")}`;
  // Best-effort stdout write -- ignore EPIPE if the launcher's pipe is gone.
  try { process.stdout.write(line + "\n"); } catch {}
  if (BRIDGE_LOG_STREAM) {
    try { BRIDGE_LOG_STREAM.write(line + "\n"); } catch {}
  }
}

// Swallow EPIPE on stdout/stderr so the bridge keeps serving Codex even
// after the parent launcher's pipe is closed. Without this, the next
// `process.stdout.write` from any logger will surface as an uncaught error
// and tear the process down.
process.stdout.on?.("error", () => {});
process.stderr.on?.("error", () => {});
function safeStringify(o) {
  try {
    return JSON.stringify(o, redactReplacer);
  } catch {
    return String(o);
  }
}
function redactReplacer(key, value) {
  if (typeof key !== "string") return value;
  const k = key.toLowerCase();
  if (
    k.includes("authorization") ||
    k.includes("api_key") ||
    k.includes("apikey") ||
    k.includes("access_token") ||
    k.includes("refresh_token") ||
    k.includes("id_token") ||
    k.includes("connection_id") ||
    k.includes("account_id") ||
    k === "cookie" ||
    k === "set-cookie"
  ) {
    return value == null ? value : "[REDACTED]";
  }
  return value;
}

// ----------------------------------------------------------------------------
// Provider resolution (OmniRoute)
// ----------------------------------------------------------------------------

let PROVIDER = null; // { base_url, api_key, model_prefix, model_aliases, default_model, headers, gpt55_pin }

// Counter incremented every time handleOmniRoutePost forwards a request
// to OmniRoute (main reasoning). Exposed on /healthz so the operator can
// confirm via a single curl that Codex Desktop is actually routing
// through the bridge instead of bypassing it. If this stays at 0 after
// the user has sent a chat message, the bridge was bypassed.
let MAIN_REASONING_HITS = 0;
let LAST_REASONING_DIAGNOSTIC = null;

async function resolveProvider() {
  if (PROVIDER) return PROVIDER;

  // 1. Env wins.
  if (OMNIROUTE_BASE_URL_ENV && OMNIROUTE_API_KEY_ENV) {
    PROVIDER = {
      base_url: OMNIROUTE_BASE_URL_ENV,
      api_key: OMNIROUTE_API_KEY_ENV,
      model_prefix: OMNIROUTE_MODEL_PREFIX,
      model_aliases: parseModelAliases(OMNIROUTE_MODEL_ALIASES),
      default_model: "gpt-5.4",
      headers: {},
      gpt55_pin: {
        enabled: OMNIROUTE_PIN_55,
        connection_id: OMNIROUTE_55_CONNECTION_ID,
        aliases: ["gpt-5.5", "gpt-5.5-thinking", "gpt-5.5-mini"],
      },
      source: "env",
    };
    return PROVIDER;
  }

  // 2. Local provider JSON.
  const fromJson = await tryReadJson(PROVIDER_JSON_PATH);
  if (fromJson && fromJson.base_url && fromJson.api_key) {
    PROVIDER = {
      base_url: stripTrailingSlash(fromJson.base_url),
      api_key: fromJson.api_key,
      model_prefix: fromJson.model_prefix ?? OMNIROUTE_MODEL_PREFIX,
      model_aliases: parseModelAliases(fromJson.model_aliases),
      default_model: fromJson.default_model || "gpt-5.4",
      headers: fromJson.headers || {},
      gpt55_pin: fromJson.gpt55_pin || {
        enabled: OMNIROUTE_PIN_55,
        connection_id: OMNIROUTE_55_CONNECTION_ID,
        aliases: ["gpt-5.5", "gpt-5.5-thinking", "gpt-5.5-mini"],
      },
      source: PROVIDER_JSON_PATH,
    };
    return PROVIDER;
  }

  // 3. OpenCode-style auth.json (~/.config/opencode/auth.json).
  const opencode = await tryReadJson(OPENCODE_AUTH_PATH);
  if (opencode && typeof opencode === "object") {
    for (const name of OPENCODE_PROVIDER_NAMES) {
      const entry = opencode[name];
      if (entry && (entry.api_key || entry.access_token || entry.key)) {
        const apiKey = entry.api_key || entry.access_token || entry.key;
        const baseUrl =
          entry.base_url || entry.baseURL || entry.endpoint || entry.url || OMNIROUTE_BASE_URL_ENV;
        if (apiKey && baseUrl) {
          PROVIDER = {
            base_url: stripTrailingSlash(baseUrl),
            api_key: apiKey,
            model_prefix: entry.model_prefix ?? OMNIROUTE_MODEL_PREFIX,
            model_aliases: parseModelAliases(entry.model_aliases),
            default_model: entry.default_model || "gpt-5.4",
            headers: entry.headers || {},
            gpt55_pin: entry.gpt55_pin || {
              enabled: OMNIROUTE_PIN_55,
              connection_id: OMNIROUTE_55_CONNECTION_ID,
              aliases: ["gpt-5.5", "gpt-5.5-thinking", "gpt-5.5-mini"],
            },
            source: `${OPENCODE_AUTH_PATH}#${name}`,
          };
          return PROVIDER;
        }
      }
    }
  }

  return null;
}

// ----------------------------------------------------------------------------
// Official auth fallback (auth.json from $CODEX_HOME)
// ----------------------------------------------------------------------------

let OFFICIAL_AUTH_CACHE = { loadedAt: 0, value: null };

async function loadOfficialAuth() {
  // Refresh at most every 5s.
  if (Date.now() - OFFICIAL_AUTH_CACHE.loadedAt < 5000 && OFFICIAL_AUTH_CACHE.value) {
    return OFFICIAL_AUTH_CACHE.value;
  }
  const auth = await tryReadJson(CODEX_AUTH_PATH);
  OFFICIAL_AUTH_CACHE = { loadedAt: Date.now(), value: auth };
  return auth;
}

function extractOfficialBearer(auth) {
  if (!auth || typeof auth !== "object") return null;
  if (typeof auth.OPENAI_API_KEY === "string" && auth.OPENAI_API_KEY.length > 0) {
    return { bearer: auth.OPENAI_API_KEY, accountId: auth?.tokens?.account_id || null };
  }
  if (auth.tokens && typeof auth.tokens === "object") {
    const t = auth.tokens;
    if (typeof t.access_token === "string" && t.access_token.length > 0) {
      return { bearer: t.access_token, accountId: t.account_id || null };
    }
  }
  return null;
}

// ----------------------------------------------------------------------------
// Body decoding
// ----------------------------------------------------------------------------

async function readRequestBody(req) {
  return await new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

async function decompressBody(buf, encoding) {
  if (!buf || buf.length === 0) return buf;
  const enc = (encoding || "").toLowerCase().trim();
  if (!enc || enc === "identity") return buf;
  // Handle comma-separated chains like "gzip, br" by applying right-to-left.
  const layers = enc
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
    .reverse();
  let out = buf;
  for (const layer of layers) {
    if (layer === "gzip" || layer === "x-gzip") {
      out = await new Promise((resolve, reject) =>
        zlib.gunzip(out, (err, res) => (err ? reject(err) : resolve(res))),
      );
    } else if (layer === "deflate") {
      out = await new Promise((resolve, reject) =>
        zlib.inflate(out, (err, res) => {
          if (err) {
            // Some servers send raw deflate; try inflateRaw.
            zlib.inflateRaw(buf, (err2, res2) => (err2 ? reject(err2) : resolve(res2)));
          } else {
            resolve(res);
          }
        }),
      );
    } else if (layer === "br") {
      out = await new Promise((resolve, reject) =>
        zlib.brotliDecompress(out, (err, res) => (err ? reject(err) : resolve(res))),
      );
    } else if (layer === "zstd") {
      out = await zstdDecompress(out);
    } else {
      throw new Error(`Unsupported content-encoding: ${layer}`);
    }
  }
  return out;
}

let _zstdMod = undefined; // undefined=untried, null=unavailable, object=loaded
async function zstdDecompress(buf) {
  if (_zstdMod === undefined) {
    _zstdMod = null;
    for (const mod of ["@mongodb-js/zstd", "fzstd", "zstd-codec"]) {
      try {
        const m = await import(mod);
        _zstdMod = { name: mod, mod: m };
        log("info", `zstd support via ${mod}`);
        break;
      } catch {
        /* ignore */
      }
    }
  }
  if (!_zstdMod) {
    throw new Error(
      "zstd content-encoding received but no zstd decoder installed. Run: npm i @mongodb-js/zstd",
    );
  }
  const { name, mod } = _zstdMod;
  if (name === "@mongodb-js/zstd") return await mod.decompress(buf);
  if (name === "fzstd") return Buffer.from(mod.decompress(new Uint8Array(buf)));
  if (name === "zstd-codec") {
    return await new Promise((resolve, reject) => {
      mod.ZstdCodec.run((zstd) => {
        try {
          const simple = new zstd.Simple();
          resolve(Buffer.from(simple.decompress(buf)));
        } catch (e) {
          reject(e);
        }
      });
    });
  }
  throw new Error("zstd decoder loaded but unrecognized");
}

function maybeBase64DecodeBody(buf, headers) {
  if (!buf || buf.length === 0) return buf;
  const flag = (headers["x-codex-base64"] || headers["x-codex-base64-multipart"] || "").toString();
  if (flag !== "1" && flag.toLowerCase() !== "true") return buf;
  let asString;
  try {
    asString = buf.toString("utf8").trim();
  } catch {
    return buf;
  }
  try {
    return Buffer.from(asString, "base64");
  } catch {
    return buf;
  }
}

// ----------------------------------------------------------------------------
// Model normalization
// ----------------------------------------------------------------------------

function parseModelAliases(value) {
  if (!value) return {};
  let parsed = value;
  if (typeof value === "string") {
    try {
      parsed = JSON.parse(value);
    } catch {
      log("warn", "ignoring invalid OMNIROUTE_MODEL_ALIASES/model_aliases JSON");
      return {};
    }
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {};
  const aliases = {};
  for (const [from, to] of Object.entries(parsed)) {
    if (typeof from === "string" && typeof to === "string" && from && to) {
      aliases[from] = to;
    }
  }
  return aliases;
}

function stripModelPrefixForAlias(model, provider) {
  if (!model || typeof model !== "string") return model;
  const prefix = provider.model_prefix || "";
  let stripped = model.replace(/^openai\//, "");
  if (prefix && stripped.startsWith(prefix)) stripped = stripped.slice(prefix.length);
  return stripped;
}

function normalizeAliasTargetForOmniRoute(target, provider) {
  if (!target || typeof target !== "string") return target;
  const prefix = provider.model_prefix || "";
  const stripped = target.replace(/^openai\//, "");
  if (!prefix || stripped.startsWith(prefix) || /^[a-z][\w.-]*\//i.test(stripped)) {
    return stripped;
  }
  return `${prefix}${stripped}`;
}

function normalizeModelForOmniRoute(model, provider) {
  if (!model || typeof model !== "string") return model;
  const prefix = provider.model_prefix || "";
  const aliases = provider.model_aliases || {};
  const stripped = stripModelPrefixForAlias(model, provider);
  const aliasTarget = aliases[model] || aliases[stripped];
  if (aliasTarget) return normalizeAliasTargetForOmniRoute(aliasTarget, provider);
  if (!prefix) return model;
  if (model.startsWith(prefix)) return model;
  return `${prefix}${stripped}`;
}

function applyGpt55Pin(jsonBody, provider) {
  if (!provider.gpt55_pin || !provider.gpt55_pin.enabled) return jsonBody;
  const connId = provider.gpt55_pin.connection_id;
  if (!connId) return jsonBody;
  const aliases = provider.gpt55_pin.aliases || [];
  const model = jsonBody.model || "";
  const bare = typeof model === "string" ? model.replace(/^.*\//, "") : "";
  if (!aliases.some((a) => bare === a || bare.startsWith(a))) return jsonBody;
  jsonBody.metadata = { ...(jsonBody.metadata || {}), connection_id: connId };
  jsonBody.connection_id = connId;
  return jsonBody;
}

function normalizeMainRequestBody(buf, provider) {
  if (!buf || buf.length === 0) return buf;
  let parsed;
  try {
    parsed = JSON.parse(buf.toString("utf8"));
  } catch {
    return buf;
  }
  if (parsed && typeof parsed === "object") {
    if (parsed.model) parsed.model = normalizeModelForOmniRoute(parsed.model, provider);
    parsed.store = false;
    parsed = applyGpt55Pin(parsed, provider);
  }
  return Buffer.from(JSON.stringify(parsed), "utf8");
}

// ----------------------------------------------------------------------------
// Live model-request tool diagnostics
// ----------------------------------------------------------------------------

function normalizeToolSignal(value) {
  if (value == null) return "";
  return String(value).toLowerCase().replace(/[^a-z0-9]+/g, "");
}

function stripTomlQuotes(value) {
  const s = String(value || "").trim();
  if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
    try {
      return JSON.parse(s);
    } catch {
      return s.slice(1, -1);
    }
  }
  if (s.length >= 2 && s.startsWith("'") && s.endsWith("'")) return s.slice(1, -1);
  return s;
}

async function readConfiguredMcpServerNames() {
  let text = "";
  try {
    text = await fs.readFile(CODEX_CONFIG_PATH, "utf8");
  } catch {
    return [];
  }

  const names = new Set();
  for (const line of text.split(/\r?\n/)) {
    const m = line.match(/^\s*\[(.+?)\]\s*(?:#.*)?$/);
    if (!m) continue;
    const section = m[1].trim();
    if (!section.toLowerCase().startsWith("mcp_servers.")) continue;
    if (section.toLowerCase().endsWith(".env")) continue;
    const name = stripTomlQuotes(section.slice("mcp_servers.".length));
    if (name) names.add(name);
  }
  return Array.from(names).sort((a, b) => a.localeCompare(b));
}

function pickToolString(tool, paths) {
  for (const pathParts of paths) {
    let cur = tool;
    for (const part of pathParts) {
      if (cur == null || typeof cur !== "object" || !(part in cur)) {
        cur = null;
        break;
      }
      cur = cur[part];
    }
    if (typeof cur === "string" && cur.trim()) return cur.trim();
  }
  return null;
}

function summarizeOneTool(tool) {
  if (tool == null || typeof tool !== "object") {
    return { type: typeof tool, name: String(tool).slice(0, 120) };
  }
  return {
    type: pickToolString(tool, [["type"]]),
    name: pickToolString(tool, [["name"], ["function", "name"]]),
    namespace: pickToolString(tool, [["namespace"]]),
    server_label: pickToolString(tool, [["server_label"], ["serverLabel"]]),
    server_name: pickToolString(tool, [["server_name"], ["serverName"], ["mcp_server"], ["mcpServer"]]),
    connector_id: pickToolString(tool, [["connector_id"], ["connectorId"]]),
  };
}

function compactDefinedObject(obj) {
  const out = {};
  for (const [key, value] of Object.entries(obj || {})) {
    if (value != null && value !== "") out[key] = value;
  }
  return out;
}

function toolLooksLikeToolSearch(tool, summary) {
  const haystack = normalizeToolSignal([
    summary?.type,
    summary?.name,
    summary?.namespace,
    summary?.server_label,
    summary?.server_name,
  ].filter(Boolean).join(" "));
  if (haystack.includes("toolsearch")) return true;
  try {
    return normalizeToolSignal(JSON.stringify(tool, redactReplacer)).includes("toolsearch");
  } catch {
    return false;
  }
}

function toolHasExplicitMcpAttachment(summary) {
  const type = normalizeToolSignal(summary?.type);
  if (type === "mcp" || type === "mcptool" || type === "mcpserver") return true;
  return Boolean(summary?.server_label || summary?.server_name);
}

function explicitConfiguredMcpServerMatches(summary, serverSignals) {
  const matches = [];
  for (const value of [summary?.server_label, summary?.server_name]) {
    const signal = normalizeToolSignal(value);
    if (signal && serverSignals.has(signal)) matches.push(serverSignals.get(signal));
  }
  return matches;
}

function toolLooksLikeMcpHeuristic(tool, summary) {
  if (toolHasExplicitMcpAttachment(summary)) return true;
  const haystack = normalizeToolSignal([
    summary?.type,
    summary?.name,
    summary?.namespace,
    summary?.connector_id,
  ].filter(Boolean).join(" "));
  if (haystack.includes("mcp")) return true;
  try {
    return normalizeToolSignal(JSON.stringify(tool, redactReplacer)).includes("mcp");
  } catch {
    return false;
  }
}

async function summarizeReasoningRequestTools(bodyBuf, suffix, inboundHeaders = {}) {
  const configuredMcpServers = await readConfiguredMcpServerNames();
  const serverSignals = new Map(
    configuredMcpServers
      .map((name) => [normalizeToolSignal(name), name])
      .filter(([signal]) => signal),
  );

  let parsed = null;
  let parseError = null;
  try {
    parsed = JSON.parse(bodyBuf.toString("utf8"));
  } catch (err) {
    parseError = err?.message || String(err);
  }

  const tools = Array.isArray(parsed?.tools) ? parsed.tools : [];
  const summarizedTools = tools.map((tool) => compactDefinedObject(summarizeOneTool(tool)));
  const directMatchedServers = new Set();
  const heuristicMatchedServers = new Set();
  let hasToolSearch = false;
  let directMcpAttachmentCount = 0;
  let heuristicMcpShapedCount = 0;

  for (let i = 0; i < tools.length; i += 1) {
    const tool = tools[i];
    const summary = summarizedTools[i] || {};
    if (toolHasExplicitMcpAttachment(summary)) {
      directMcpAttachmentCount += 1;
      for (const name of explicitConfiguredMcpServerMatches(summary, serverSignals)) {
        directMatchedServers.add(name);
      }
    }
    const searchable = normalizeToolSignal([
      JSON.stringify(summary),
      safeStringify(tool),
    ].join(" "));
    for (const [signal, name] of serverSignals.entries()) {
      if (searchable.includes(signal)) heuristicMatchedServers.add(name);
    }
    if (toolLooksLikeToolSearch(tool, summary)) hasToolSearch = true;
    if (toolLooksLikeMcpHeuristic(tool, summary)) heuristicMcpShapedCount += 1;
  }

  const diagnostic = {
    recorded_at_utc: new Date().toISOString(),
    path: suffix,
    model: typeof parsed?.model === "string" ? parsed.model : null,
    parse_error: parseError,
    inbound_headers: {
      has_authorization: Boolean(inboundHeaders.authorization),
      user_agent: inboundHeaders["user-agent"] || null,
      x_codex_headers: Object.keys(inboundHeaders)
        .filter((name) => name.toLowerCase().startsWith("x-codex"))
        .sort(),
    },
    config_path: CODEX_CONFIG_PATH,
    configured_mcp_servers: configuredMcpServers,
    matched_configured_mcp_servers: Array.from(directMatchedServers).sort((a, b) => a.localeCompare(b)),
    direct_configured_mcp_servers: Array.from(directMatchedServers).sort((a, b) => a.localeCompare(b)),
    has_configured_mcp_tools: directMatchedServers.size > 0,
    has_direct_configured_mcp_tools: directMatchedServers.size > 0,
    has_any_mcp_shaped_tool: directMcpAttachmentCount > 0,
    mcp_shaped_tool_count: directMcpAttachmentCount,
    direct_mcp_attachment_count: directMcpAttachmentCount,
    heuristic_matched_configured_mcp_servers: Array.from(heuristicMatchedServers).sort((a, b) => a.localeCompare(b)),
    has_any_mcp_shaped_tool_heuristic: heuristicMcpShapedCount > 0,
    mcp_shaped_tool_count_heuristic: heuristicMcpShapedCount,
    mcp_heuristics_are_authoritative: false,
    has_tool_search: hasToolSearch,
    tools_total: tools.length,
    tool_types: Array.from(new Set(summarizedTools.map((t) => t.type).filter(Boolean))).sort(),
    tool_names: summarizedTools
      .map((t) => t.name || t.server_label || t.server_name || t.namespace)
      .filter(Boolean)
      .slice(0, 50),
    first_tools: summarizedTools.slice(0, 20),
  };

  LAST_REASONING_DIAGNOSTIC = diagnostic;
  try {
    await fs.writeFile(
      LAST_REASONING_DIAGNOSTIC_PATH,
      JSON.stringify(diagnostic, null, 2),
      "utf8",
    );
  } catch (err) {
    log("warn", "failed to write reasoning tool diagnostic", err?.message);
  }
  return diagnostic;
}

// ----------------------------------------------------------------------------
// Outbound forwarding helpers
// ----------------------------------------------------------------------------

function buildForwardHeaders(inboundHeaders, mode, provider, officialAuth) {
  const out = {};
  for (const [k, v] of Object.entries(inboundHeaders)) {
    if (HOP_BY_HOP.has(k.toLowerCase())) continue;
    if (Array.isArray(v)) out[k] = v.join(", ");
    else if (v != null) out[k] = String(v);
  }
  delete out["accept-encoding"]; // we want uncompressed responses we can stream

  if (mode === "omniroute") {
    delete out["authorization"];
    delete out["openai-organization"];
    delete out["openai-project"];
    delete out["chatgpt-account-id"];
    if (provider.api_key) out["authorization"] = `Bearer ${provider.api_key}`;
    for (const [k, v] of Object.entries(provider.headers || {})) out[k] = String(v);
    out["x-omniroute-client"] = out["x-omniroute-client"] || "codex-omniroute-bridge";
  } else if (mode === "official") {
    // Codex Desktop is sending its real OAuth bearer (loaded from the
    // isolated $CODEX_HOME/auth.json, which the launcher seeded from
    // the user's real ~/.codex/auth.json), so the simple thing is to
    // pass it straight through to chatgpt.com. Only fall back to the
    // auth.json on disk if the inbound request didn't have one, e.g.
    // because something probed /transcribe directly without a bearer.
    if (!out["authorization"] && officialAuth?.bearer) {
      out["authorization"] = `Bearer ${officialAuth.bearer}`;
    }
    if (!out["chatgpt-account-id"] && officialAuth?.accountId) {
      out["chatgpt-account-id"] = officialAuth.accountId;
    }
  }
  return out;
}

function pickHttpModule(target) {
  return target.protocol === "https:" ? https : http;
}

function forwardOutbound({ target, method, headers, bodyBuf, clientRes, isStreaming }) {
  const mod = pickHttpModule(target);
  const upstreamReq = mod.request(
    {
      method,
      hostname: target.hostname,
      port: target.port || (target.protocol === "https:" ? 443 : 80),
      path: target.pathname + (target.search || ""),
      headers,
      timeout: REQUEST_TIMEOUT_MS,
    },
    (upstreamRes) => {
      clientRes.statusCode = upstreamRes.statusCode || 502;
      for (const [k, v] of Object.entries(upstreamRes.headers)) {
        if (HOP_BY_HOP.has(k.toLowerCase())) continue;
        if (v != null) clientRes.setHeader(k, v);
      }
      upstreamRes.on("data", (chunk) => clientRes.write(chunk));
      upstreamRes.on("end", () => clientRes.end());
      upstreamRes.on("error", (err) => {
        log("error", "upstream response error", err?.message);
        if (!clientRes.headersSent) {
          clientRes.statusCode = 502;
          clientRes.setHeader("content-type", "application/json");
          clientRes.end(JSON.stringify({ error: "upstream_error", detail: err?.message }));
        } else {
          clientRes.end();
        }
      });
    },
  );
  upstreamReq.on("timeout", () => {
    log("warn", "upstream request timed out", target.href);
    upstreamReq.destroy(new Error("upstream timeout"));
  });
  upstreamReq.on("error", (err) => {
    log("error", "upstream request error", err?.message);
    if (!clientRes.headersSent) {
      clientRes.statusCode = 502;
      clientRes.setHeader("content-type", "application/json");
      clientRes.end(JSON.stringify({ error: "upstream_error", detail: err?.message }));
    } else {
      clientRes.end();
    }
  });
  if (bodyBuf && bodyBuf.length > 0) upstreamReq.write(bodyBuf);
  upstreamReq.end();
}

// ----------------------------------------------------------------------------
// Route handlers
// ----------------------------------------------------------------------------

async function handleHealth(req, res) {
  const provider = await resolveProvider();
  const auth = await loadOfficialAuth();
  const homeStatus = await inspectIsolatedCodexHome();
  const lastReasoningRequest =
    LAST_REASONING_DIAGNOSTIC || (await tryReadJson(LAST_REASONING_DIAGNOSTIC_PATH));

  res.statusCode = 200;
  res.setHeader("content-type", "application/json");
  res.end(
    JSON.stringify({
      ok: true,
      service: "codex-openai-omniroute-bridge",
      version: VERSION,
      pid: process.pid,
      uptime_ms: Date.now() - STARTED_AT,
      host: HOST,
      port: PORT,
      official_upstream: OFFICIAL_UPSTREAM,
      codex_home: CODEX_HOME,
      omniroute: {
        configured: Boolean(provider),
        source: provider?.source || null,
        base_url: provider?.base_url || null,
        model_prefix: provider?.model_prefix || null,
        model_aliases: provider?.model_aliases || {},
        gpt55_pin_enabled: Boolean(provider?.gpt55_pin?.enabled && provider?.gpt55_pin?.connection_id),
      },
      official_auth_path: CODEX_AUTH_PATH,
      official_auth_present: Boolean(extractOfficialBearer(auth)),
      // Variant-3 diagnostics. The launcher seeds CODEX_HOME with a
      // .omniroute-seed.json stamp listing every file it wrote. We
      // compare that stamp against the current directory contents to
      // tell whether Codex Desktop is actually using CODEX_HOME (it
      // would create state_5.sqlite and rewrite auth.json over time).
      // main_reasoning_hits counts requests rerouted to OmniRoute since
      // boot; if it stays at 0 after the user sends a chat message,
      // Desktop ignored CODEX_HOME and bypassed the bridge.
      main_reasoning_hits: MAIN_REASONING_HITS,
      last_reasoning_request_path: LAST_REASONING_DIAGNOSTIC_PATH,
      last_reasoning_request: lastReasoningRequest,
      desktop_codex_home_honored: homeStatus.honored,
      isolated_home: {
        seed_stamp_path: CODEX_SEED_STAMP_PATH,
        seed_stamp_present: homeStatus.stampPresent,
        new_files: homeStatus.newFiles,
        modified_files: homeStatus.modifiedFiles,
        state_sqlite_present: homeStatus.stateSqlitePresent,
      },
      models_cache_present: await pathExists(CODEX_MODELS_PATH),
    }),
  );
}

async function handleModels(req, res) {
  // ALWAYS serve from local models_cache.json under $CODEX_HOME — never
  // from OmniRoute. This is the same file the official Codex Desktop
  // populates from chatgpt.com/backend-api/codex/models.
  const cache = await tryReadJson(CODEX_MODELS_PATH);
  if (cache) {
    res.statusCode = 200;
    res.setHeader("content-type", "application/json");
    // Codex desktop expects either the raw OpenAI shape ({object:"list",data:[...]})
    // or a Codex-specific cache shape. Pass through unchanged.
    res.end(JSON.stringify(cache));
    return;
  }
  res.statusCode = 503;
  res.setHeader("content-type", "application/json");
  res.end(
    JSON.stringify({
      error: "models_cache_missing",
      detail: `${CODEX_MODELS_PATH} is missing. Launch the official Codex app once so it can populate this file from chatgpt.com.`,
    }),
  );
}

async function handleOmniRoutePost(req, res, suffix) {
  const provider = await resolveProvider();
  if (!provider) {
    res.statusCode = 500;
    res.setHeader("content-type", "application/json");
    res.end(
      JSON.stringify({
        error: "omniroute_not_configured",
        detail:
          "Set OMNIROUTE_BASE_URL + OMNIROUTE_API_KEY, or create omniroute-provider.json (see omniroute-provider.example.json).",
      }),
    );
    return;
  }
  let raw;
  try {
    raw = await readRequestBody(req);
    raw = await decompressBody(raw, req.headers["content-encoding"]);
    raw = maybeBase64DecodeBody(raw, req.headers);
  } catch (err) {
    log("warn", "failed to decode inbound body for", suffix, err?.message);
    res.statusCode = 400;
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ error: "bad_request_encoding", detail: err?.message }));
    return;
  }
  const bodyBuf = normalizeMainRequestBody(raw, provider);
  let toolDiagnostic = null;
  try {
    toolDiagnostic = await summarizeReasoningRequestTools(bodyBuf, suffix, req.headers);
  } catch (err) {
    log("warn", "failed to summarize reasoning request tools", err?.message);
  }
  const target = new URL(provider.base_url + suffix);
  const headers = buildForwardHeaders(req.headers, "omniroute", provider, null);
  headers["content-type"] = "application/json";
  headers["content-length"] = String(bodyBuf.length);
  // Increment BEFORE forwarding: the metric tracks "did Codex Desktop
  // route through us at all", not "did OmniRoute succeed". Even if the
  // upstream returns 502, the fact that the bridge handled the request
  // is enough to prove CODEX_HOME isolation is working.
  MAIN_REASONING_HITS += 1;
  if (toolDiagnostic) {
    const matched = toolDiagnostic.direct_configured_mcp_servers.join(",") || "none";
    const heuristicMatched = toolDiagnostic.heuristic_matched_configured_mcp_servers.join(",") || "none";
    log(
      "info",
      "omniroute ->",
      target.href,
      `bytes=${bodyBuf.length}`,
      `tools=${toolDiagnostic.tools_total}`,
      `mcp_direct=${matched}`,
      `mcp_direct_count=${toolDiagnostic.direct_mcp_attachment_count}`,
      `mcp_heuristic=${heuristicMatched}`,
      `mcp_heuristic_count=${toolDiagnostic.mcp_shaped_tool_count_heuristic}`,
      `tool_search=${toolDiagnostic.has_tool_search}`,
    );
  } else {
    log("info", "omniroute ->", target.href, `bytes=${bodyBuf.length}`);
  }
  forwardOutbound({ target, method: "POST", headers, bodyBuf, clientRes: res, isStreaming: true });
}

async function handleOfficialPassthrough(req, res, suffixOverride) {
  const auth = await loadOfficialAuth();
  const officialBearer = extractOfficialBearer(auth);
  let raw;
  try {
    raw = await readRequestBody(req);
    raw = await decompressBody(raw, req.headers["content-encoding"]);
    raw = maybeBase64DecodeBody(raw, req.headers);
  } catch (err) {
    log("warn", "failed to decode inbound body for official path", err?.message);
    res.statusCode = 400;
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ error: "bad_request_encoding", detail: err?.message }));
    return;
  }
  const url = new URL(req.url, "http://placeholder.local");
  const suffix = suffixOverride ?? url.pathname + (url.search || "");
  const target = new URL(OFFICIAL_UPSTREAM + suffix);
  const headers = buildForwardHeaders(req.headers, "official", null, officialBearer);
  if (raw && raw.length > 0) headers["content-length"] = String(raw.length);
  // Don't claim x-codex-base64 to upstream — we already decoded it.
  delete headers["x-codex-base64"];
  delete headers["x-codex-base64-multipart"];
  log("info", "official ->", target.href, `bytes=${raw?.length || 0}`);
  forwardOutbound({
    target,
    method: req.method,
    headers,
    bodyBuf: raw,
    clientRes: res,
    isStreaming: true,
  });
}

// ----------------------------------------------------------------------------
// Router
// ----------------------------------------------------------------------------

async function router(req, res) {
  // CORS preflight (local app may not need it, but harmless and useful for debugging).
  if (req.method === "OPTIONS") {
    res.statusCode = 204;
    res.setHeader("access-control-allow-origin", req.headers.origin || "*");
    res.setHeader("access-control-allow-methods", "GET, POST, OPTIONS");
    res.setHeader(
      "access-control-allow-headers",
      "authorization, content-type, x-codex-base64, x-codex-base64-multipart",
    );
    res.end();
    return;
  }

  const url = new URL(req.url, "http://placeholder.local");
  const p = url.pathname;
  const m = req.method;

  if (p === "/healthz" || p === "/v1/healthz") return handleHealth(req, res);

  if (m === "GET" && (p === "/v1/models" || p === "/models")) return handleModels(req, res);

  // Main reasoning -> OmniRoute.
  if (m === "POST" && (p === "/v1/responses" || p === "/responses")) {
    return handleOmniRoutePost(req, res, "/responses");
  }
  if (m === "POST" && (p === "/v1/chat/completions" || p === "/chat/completions")) {
    return handleOmniRoutePost(req, res, "/chat/completions");
  }

  // Compact -> official upstream.
  if (m === "POST" && (p === "/v1/responses/compact" || p === "/responses/compact")) {
    return handleOfficialPassthrough(req, res, "/responses/compact");
  }

  // Dictation -> official upstream.
  if (m === "POST" && (p === "/v1/audio/transcriptions" || p === "/audio/transcriptions")) {
    return handleOfficialPassthrough(req, res, "/audio/transcriptions");
  }
  if (m === "POST" && p === "/transcribe") {
    return handleOfficialPassthrough(req, res, "/audio/transcriptions");
  }

  // Image generation parity (optional).
  if (
    (m === "POST" || m === "GET") &&
    (p === "/v1/images/generations" || p === "/images/generations")
  ) {
    return handleOfficialPassthrough(req, res, "/images/generations");
  }

  // Catchall: forward to official upstream (preserves account/MCP/skills/plugins backend calls).
  return handleOfficialPassthrough(req, res);
}

// ----------------------------------------------------------------------------
// Utilities
// ----------------------------------------------------------------------------

function stripTrailingSlash(s) {
  if (!s) return s;
  return s.endsWith("/") ? s.slice(0, -1) : s;
}

async function pathExists(p) {
  try {
    await fs.access(p);
    return true;
  } catch {
    return false;
  }
}

async function tryReadJson(p) {
  try {
    const buf = await fs.readFile(p, "utf8");
    return JSON.parse(buf.replace(/^\uFEFF/, ""));
  } catch {
    return null;
  }
}

// Compare the current $CODEX_HOME directory against the .omniroute-seed.json
// stamp the launcher wrote at boot. Returns:
//   stampPresent          : did the launcher write a seed stamp at all?
//   stateSqlitePresent    : does state_5.sqlite (or any sqlite sidecar) exist
//                            in $CODEX_HOME now? Codex Desktop only creates it
//                            when it boots against this CODEX_HOME.
//   newFiles              : files in $CODEX_HOME that the launcher did NOT
//                            write at seed time. Anything here means a
//                            running Codex Desktop has touched the directory.
//   modifiedFiles         : seeded files whose mtime or size has changed
//                            since the stamp (e.g. Desktop refreshed
//                            auth.json on a token rotation).
//   honored               : convenience boolean. true iff Desktop has
//                            measurably touched the isolated dir (state_5
//                            present || any new/modified file). The operator
//                            can poll /healthz once after sending a chat
//                            message and use this to decide whether to fall
//                            back to a different isolation strategy.
// The function is best-effort: any I/O failure returns honored=false with
// the stamp_present=false so the verifier surfaces it instead of crashing.
async function inspectIsolatedCodexHome() {
  const result = {
    stampPresent: false,
    stateSqlitePresent: false,
    newFiles: [],
    modifiedFiles: [],
    honored: false,
  };
  let stamp = null;
  try {
    stamp = await tryReadJson(CODEX_SEED_STAMP_PATH);
  } catch {
    stamp = null;
  }
  result.stampPresent = Boolean(stamp);

  let entries = [];
  try {
    entries = await fs.readdir(CODEX_HOME, { withFileTypes: true });
  } catch {
    return result;
  }

  const stampedByName = new Map();
  if (stamp && Array.isArray(stamp.files)) {
    for (const f of stamp.files) {
      if (f && typeof f.name === "string") stampedByName.set(f.name, f);
    }
  }

  for (const ent of entries) {
    if (!ent.isFile()) continue;
    const name = ent.name;
    // Skip the stamp itself.
    if (name === ".omniroute-seed.json") continue;
    // state_5.sqlite (and its WAL/journal/shm sidecars) is the single most
    // load-bearing signal that Desktop is using this CODEX_HOME.
    if (/^state_\d+\.sqlite(?:-journal|-wal|-shm)?$/.test(name)) {
      result.stateSqlitePresent = true;
    }
    let stat = null;
    try {
      stat = await fs.stat(path.join(CODEX_HOME, name));
    } catch {
      continue;
    }
    const stamped = stampedByName.get(name);
    if (!stamped) {
      result.newFiles.push(name);
      continue;
    }
    const stampedSize = typeof stamped.size === "number" ? stamped.size : null;
    const stampedMtime = stamped.mtime ? Date.parse(stamped.mtime) : NaN;
    if (stampedSize !== null && stat.size !== stampedSize) {
      result.modifiedFiles.push(name);
    } else if (!Number.isNaN(stampedMtime) && Math.abs(stat.mtimeMs - stampedMtime) > 1000) {
      // Allow ~1s drift to absorb filesystem rounding (FAT, network mounts).
      result.modifiedFiles.push(name);
    }
  }

  result.honored =
    result.stateSqlitePresent || result.newFiles.length > 0 || result.modifiedFiles.length > 0;
  return result;
}

// ----------------------------------------------------------------------------
// Boot
// ----------------------------------------------------------------------------

const server = http.createServer((req, res) => {
  router(req, res).catch((err) => {
    log("error", "router error", err?.stack || err?.message || String(err));
    if (!res.headersSent) {
      res.statusCode = 500;
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify({ error: "internal_error", detail: err?.message || String(err) }));
    } else {
      try {
        res.end();
      } catch {
        /* ignore */
      }
    }
  });
});

server.on("error", (err) => {
  log("error", "server error", err?.message);
  if (err && err.code === "EADDRINUSE") {
    log(
      "error",
      `Bridge port ${PORT} is already in use. Pass CODEX_BRIDGE_PORT=<free port> or let the launcher pick one.`,
    );
    process.exit(2);
  }
  process.exit(1);
});

server.listen(PORT, HOST, async () => {
  await resolveProvider().catch(() => null);
  log(
    "info",
    `bridge listening`,
    {
      host: HOST,
      port: PORT,
      pid: process.pid,
      codex_home: CODEX_HOME,
      official_upstream: OFFICIAL_UPSTREAM,
      omniroute_configured: Boolean(PROVIDER),
      omniroute_source: PROVIDER?.source || null,
    },
  );
});

// Graceful shutdown.
for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, () => {
    log("info", `received ${sig}, shutting down`);
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 2000).unref();
  });
}
