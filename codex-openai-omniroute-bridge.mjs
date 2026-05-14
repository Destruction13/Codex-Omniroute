#!/usr/bin/env node
/*
 * Codex OmniRoute — local OpenAI-compatible bridge.
 *
 * Narrow waist of the architecture. The official Microsoft Store Codex app
 * (launched via Start-Codex-OmniRoute.ps1, which writes a managed block into
 * the user's normal ~/.codex/config.toml) is pointed at this server via:
 *
 *   [model_providers.omniroute_bridge]
 *   base_url = "http://127.0.0.1:<PORT>/v1"
 *   wire_api = "responses"
 *   requires_openai_auth = true
 *   supports_websockets = false
 *
 * Behavior summary
 *   /healthz                       -> local status
 *   GET  /v1/models                -> local models_cache.json from $CODEX_HOME (NOT OmniRoute)
 *   POST /v1/responses             -> OmniRoute (main reasoning)
 *   POST /v1/chat/completions      -> OmniRoute (main reasoning)
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

const CODEX_HOME = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
const CODEX_AUTH_PATH = path.join(CODEX_HOME, "auth.json");
const CODEX_MODELS_PATH = path.join(CODEX_HOME, "models_cache.json");

const OMNIROUTE_BASE_URL_ENV = stripTrailingSlash(process.env.OMNIROUTE_BASE_URL || "");
const OMNIROUTE_API_KEY_ENV = process.env.OMNIROUTE_API_KEY || "";
const OMNIROUTE_MODEL_PREFIX = process.env.OMNIROUTE_MODEL_PREFIX ?? "cx/";
const OMNIROUTE_PIN_55 = process.env.OMNIROUTE_PIN_55 === "1";
const OMNIROUTE_55_CONNECTION_ID = process.env.OMNIROUTE_55_CONNECTION_ID || "";

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

let PROVIDER = null; // { base_url, api_key, model_prefix, default_model, headers, gpt55_pin }

async function resolveProvider() {
  if (PROVIDER) return PROVIDER;

  // 1. Env wins.
  if (OMNIROUTE_BASE_URL_ENV && OMNIROUTE_API_KEY_ENV) {
    PROVIDER = {
      base_url: OMNIROUTE_BASE_URL_ENV,
      api_key: OMNIROUTE_API_KEY_ENV,
      model_prefix: OMNIROUTE_MODEL_PREFIX,
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

function normalizeModelForOmniRoute(model, provider) {
  if (!model || typeof model !== "string") return model;
  const prefix = provider.model_prefix || "";
  if (!prefix) return model;
  if (model.startsWith(prefix)) return model;
  // Strip a leading "openai/" if present so we don't double-prefix.
  const stripped = model.replace(/^openai\//, "");
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
        gpt55_pin_enabled: Boolean(provider?.gpt55_pin?.enabled && provider?.gpt55_pin?.connection_id),
      },
      official_auth_present: Boolean(extractOfficialBearer(auth)),
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
  const target = new URL(provider.base_url + suffix);
  const headers = buildForwardHeaders(req.headers, "omniroute", provider, null);
  headers["content-type"] = "application/json";
  headers["content-length"] = String(bodyBuf.length);
  log("info", "omniroute ->", target.href, `bytes=${bodyBuf.length}`);
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
    return JSON.parse(buf);
  } catch {
    return null;
  }
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
