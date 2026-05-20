#!/usr/bin/env node
/*
 * Codex OmniRoute — local OpenAI-compatible bridge.
 *
 * Shared-home gateway architecture. Official Codex and Codex OmniRoute both
 * use the normal Codex home (%USERPROFILE%\.codex on Windows, ~/.codex on
 * macOS). The launcher selects OmniRoute only for its own process by passing
 * runtime -c overrides that point model calls at this local bridge.
 *
 * The bridge reads $CODEX_HOME/auth.json directly to recover the official
 * OAuth bearer for compact + dictation passthrough. Codex Desktop also sends
 * the real bearer on its requests, so the official-passthrough path forwards
 * it as-is.
 *
 * Behavior summary
 *   /healthz                       -> local status
 *   GET  /v1/models                -> local models_cache.json from $CODEX_HOME (NOT OmniRoute)
 *   POST /v1/responses             -> OmniRoute (main reasoning, counted)
 *   POST /v1/chat/completions      -> OmniRoute (main reasoning, counted)
 *   POST /v1/responses/compact     -> official upstream
 *   POST /v1/audio/transcriptions  -> official upstream
 *   POST /transcribe               -> official upstream /audio/transcriptions
 *   GET/POST /v1/images/generations-> OmniRoute image lane
 *   GET/POST /v1/images/edits      -> OmniRoute image lane
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
import { StringDecoder } from "node:string_decoder";

import { createMediaCache } from "./bridge-modules/media-cache.mjs";
import { createToolAdapters } from "./bridge-modules/tool-adapters.mjs";

// ----------------------------------------------------------------------------
// Configuration
// ----------------------------------------------------------------------------

const VERSION = "0.2.0-shared-home";
const STARTED_AT = Date.now();

const HOST = process.env.CODEX_BRIDGE_HOST || "127.0.0.1";
const PORT = parseInt(process.env.CODEX_BRIDGE_PORT || "20333", 10);

const OFFICIAL_UPSTREAM = stripTrailingSlash(
  process.env.CODEX_OFFICIAL_UPSTREAM || "https://chatgpt.com/backend-api/codex",
);

// CODEX_HOME is the normal official Codex home. OmniRoute mode is selected by
// process-level launcher overrides, not by a separate profile.
const CODEX_HOME = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
const CODEX_AUTH_PATH = path.join(CODEX_HOME, "auth.json");
const CODEX_MODELS_PATH = path.join(CODEX_HOME, "models_cache.json");
const CODEX_CONFIG_PATH = path.join(CODEX_HOME, "config.toml");
const OMNIROUTE_DIAGNOSTIC_DIR =
  process.env.CODEX_OMNI_DIAGNOSTIC_DIR || path.join(CODEX_HOME, "omniroute", "diagnostics");
const LAST_REASONING_DIAGNOSTIC_PATH = path.join(OMNIROUTE_DIAGNOSTIC_DIR, "last-reasoning.json");

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
const OMNIROUTE_MAX_BODY_BYTES = parseInt(
  process.env.CODEX_OMNI_OMNIROUTE_MAX_BODY_BYTES || String(10 * 1024 * 1024),
  10,
);
const OMNIROUTE_BODY_HEADROOM_BYTES = parseInt(
  process.env.CODEX_OMNI_OMNIROUTE_BODY_HEADROOM_BYTES || "65536",
  10,
);
const OMNIROUTE_BODY_FALLBACK_THRESHOLD_BYTES = Math.max(
  1024,
  OMNIROUTE_MAX_BODY_BYTES - Math.max(0, OMNIROUTE_BODY_HEADROOM_BYTES || 0),
);
const INLINE_IMAGE_HISTORY_BUDGET_BYTES = Math.max(
  0,
  parseInt(process.env.CODEX_OMNI_INLINE_IMAGE_HISTORY_BUDGET_BYTES || String(6 * 1024 * 1024), 10) ||
    6 * 1024 * 1024,
);
const MEDIA_CACHE_DIR =
  process.env.CODEX_OMNI_MEDIA_CACHE_DIR ||
  path.join(process.env.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local"), "CodexOmniRoute", "media");
const MEDIA_CACHE_MAX_BYTES = Math.max(
  0,
  parseInt(process.env.CODEX_OMNI_MEDIA_CACHE_MAX_BYTES || String(512 * 1024 * 1024), 10) ||
    512 * 1024 * 1024,
);
const MEDIA_CACHE_MAX_AGE_MS = Math.max(
  0,
  parseInt(process.env.CODEX_OMNI_MEDIA_CACHE_MAX_AGE_MS || String(7 * 24 * 60 * 60 * 1000), 10) ||
    7 * 24 * 60 * 60 * 1000,
);

const APPLY_PATCH_TOOL_NAME = "apply_patch";
const APPLY_PATCH_ARGUMENT_KEYS = ["input", "patch", "content", "text", "body", "arguments"];
const TOOL_SEARCH_SHIM_FUNCTION_NAME =
  process.env.CODEX_OMNI_TOOL_SEARCH_SHIM_FUNCTION_NAME || "omniroute_tool_search";
const ENABLE_TOOL_SEARCH_FUNCTION_SHIM = !/^(0|false|no)$/i.test(
  process.env.CODEX_OMNI_ENABLE_TOOL_SEARCH_FUNCTION_SHIM || "1",
);
const ENABLE_TOOL_SEARCH_ALIAS_RERANK = !/^(0|false|no)$/i.test(
  process.env.CODEX_OMNI_ENABLE_TOOL_SEARCH_ALIAS_RERANK || "1",
);
const ENABLE_APPLY_PATCH_FUNCTION_ADAPTER = !/^(0|false|no)$/i.test(
  process.env.CODEX_OMNI_ENABLE_APPLY_PATCH_FUNCTION_ADAPTER || "1",
);
const TOOL_SEARCH_ALIASES_PATH =
  process.env.CODEX_OMNI_TOOL_SEARCH_ALIASES ||
  path.join(CODEX_HOME, "plugins", "cache", "omniroute-local", "omniroute-productivity", "0.1.2", "routing", "tool-search-aliases.json");
const IMAGE_GENERATIONS_PATH = "/v1/images/generations";
const IMAGE_EDITS_PATH = "/v1/images/edits";
const DEFAULT_OMNIROUTE_IMAGE_MODEL =
  process.env.CODEX_OMNI_OMNIROUTE_IMAGE_MODEL || "chatgpt-web/gpt-5.3-instant";
const DEFAULT_OMNIROUTE_IMAGE_COMPAT_MODEL =
  process.env.CODEX_OMNI_OMNIROUTE_IMAGE_COMPAT_MODEL || "cgpt-web/gpt-5.3-instant";
const OPENAI_COMPAT_IMAGE_MODELS = new Set([
  DEFAULT_OMNIROUTE_IMAGE_MODEL,
  DEFAULT_OMNIROUTE_IMAGE_COMPAT_MODEL,
  "gpt-5.3-instant",
  "gpt-image-2",
  "gpt-image-1.5",
  "gpt-image-1",
  "gpt-image-1-mini",
]);

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
      image_api_key: fromJson.image_api_key || fromJson.imageApiKey || "",
      gpt55_pin: fromJson.gpt55_pin || {
        enabled: OMNIROUTE_PIN_55,
        connection_id: OMNIROUTE_55_CONNECTION_ID,
        aliases: ["gpt-5.5", "gpt-5.5-thinking", "gpt-5.5-mini"],
      },
      source: PROVIDER_JSON_PATH,
    };
    return PROVIDER;
  }
  const superProvider = fromJson?.models?.providers?.omniroute;
  if (superProvider?.baseUrl && (superProvider?.apiKey || OMNIROUTE_API_KEY_ENV)) {
    PROVIDER = {
      base_url: stripTrailingSlash(superProvider.baseUrl),
      api_key: superProvider.apiKey || OMNIROUTE_API_KEY_ENV,
      model_prefix: superProvider.model_prefix ?? OMNIROUTE_MODEL_PREFIX,
      model_aliases: parseModelAliases(superProvider.model_aliases),
      default_model: "gpt-5.5",
      headers: fromJson.headers || {},
      gpt55_pin: {
        enabled: OMNIROUTE_PIN_55,
        connection_id: OMNIROUTE_55_CONNECTION_ID,
        aliases: ["gpt-5.5", "gpt-5.5-thinking", "gpt-5.5-mini"],
      },
      image_api_key: superProvider.imageApiKey || fromJson.image_api_key || "",
      source: `${PROVIDER_JSON_PATH}#models.providers.omniroute`,
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

function requestedReasoningEffort(payload) {
  const nested = typeof payload?.reasoning?.effort === "string" ? payload.reasoning.effort : "";
  const direct = typeof payload?.reasoning_effort === "string" ? payload.reasoning_effort : "";
  return (nested || direct).trim().toLowerCase();
}

function selectModelForOmniRoute(model, provider, payload) {
  const normalized = normalizeModelForOmniRoute(model, provider);
  const prefix = provider.model_prefix || "";
  const effort = requestedReasoningEffort(payload);
  const bare = typeof normalized === "string" && prefix && normalized.startsWith(prefix)
    ? normalized.slice(prefix.length)
    : normalized;

  if (bare === "gpt-5.5") {
    if (effort === "low") return `${prefix}gpt-5.5-low`;
    if (effort === "medium") return `${prefix}gpt-5.5`;
    if (effort === "high") return `${prefix}gpt-5.5-high`;
    return `${prefix}gpt-5.5-xhigh`;
  }

  if (bare === "gpt-5.5-low" || bare === "gpt-5.5-high" || bare === "gpt-5.5-xhigh") {
    return `${prefix}${bare}`;
  }

  return normalized;
}

function normalizeModelForOmniRouteImage(model) {
  if (typeof model !== "string") return DEFAULT_OMNIROUTE_IMAGE_MODEL;
  const trimmed = model.trim();
  if (!trimmed || OPENAI_COMPAT_IMAGE_MODELS.has(trimmed)) return DEFAULT_OMNIROUTE_IMAGE_MODEL;
  return trimmed;
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

function formatMegabytes(bytes) {
  return `${(Math.max(0, bytes) / (1024 * 1024)).toFixed(2)} MB`;
}

function formatBytes(bytes) {
  const normalized = Math.max(0, Number(bytes) || 0);
  if (normalized >= 1024 * 1024) return `${(normalized / (1024 * 1024)).toFixed(2)} MB`;
  if (normalized >= 1024) return `${(normalized / 1024).toFixed(2)} KB`;
  return `${normalized} bytes`;
}

function isInlineDataImageUrl(value) {
  return typeof value === "string" && /^data:image\//i.test(value);
}

function inlineImageMime(value) {
  const match = /^data:([^;,]+)[;,]/i.exec(String(value || ""));
  return match?.[1] || "image";
}

function inlineImagePlaceholder(url, mediaRef = null) {
  const mime = mediaRef?.mime || inlineImageMime(url);
  const bytes = mediaRef?.bytes || Buffer.byteLength(url, "utf8");
  const refText = mediaRef?.uri ? `${mediaRef.uri}, ` : "";
  const retention = mediaRef?.uri ? "cached locally with bounded TTL" : "retained in local Codex history";
  return `[inline image omitted: ${refText}${mime}, ${formatMegabytes(bytes)}; ${retention}]`;
}

function replaceKnownImagePartWithPlaceholder(target, url, options = {}) {
  const mediaRef = options.storeOmittedImages === false ? null : storeInlineImageInMediaCache(url, options.requestPath);
  const placeholder = inlineImagePlaceholder(url, mediaRef);
  if (target.type === "input_image") {
    target.type = "input_text";
    target.text = placeholder;
    delete target.image_url;
    delete target.detail;
    return mediaRef;
  }

  if (target.type === "image_url") {
    target.type = "text";
    target.text = placeholder;
    delete target.image_url;
    delete target.detail;
    return mediaRef;
  }

  target.image_url = placeholder;
  return mediaRef;
}

function collectInlineImageRefs(value, refs = []) {
  if (!value || typeof value !== "object") return refs;

  if (Array.isArray(value)) {
    for (const item of value) collectInlineImageRefs(item, refs);
    return refs;
  }

  if ((value.type === "input_image" || value.type === "image_url") && isInlineDataImageUrl(value.image_url)) {
    refs.push({ target: value, url: value.image_url, bytes: Buffer.byteLength(value.image_url, "utf8") });
    return refs;
  }

  if (
    value.type === "image_url" &&
    value.image_url &&
    typeof value.image_url === "object" &&
    isInlineDataImageUrl(value.image_url.url)
  ) {
    refs.push({ target: value, url: value.image_url.url, bytes: Buffer.byteLength(value.image_url.url, "utf8") });
    return refs;
  }

  for (const nested of Object.values(value)) collectInlineImageRefs(nested, refs);
  return refs;
}

function sanitizeInlineImageHistory(payload, options = {}) {
  const budgetBytes = Math.max(
    0,
    Number.isFinite(options.budgetBytes) ? options.budgetBytes : INLINE_IMAGE_HISTORY_BUDGET_BYTES,
  );
  const keepNewest = options.keepNewest !== false;
  if ((budgetBytes <= 0 && keepNewest) || !payload || typeof payload !== "object" || Array.isArray(payload)) {
    return null;
  }

  const refs = collectInlineImageRefs(payload.input);
  if (refs.length === 0) return null;

  const totalInlineImageBytes = refs.reduce((sum, ref) => sum + ref.bytes, 0);
  if (totalInlineImageBytes <= budgetBytes) {
    return {
      totalCount: refs.length,
      omittedCount: 0,
      keptCount: refs.length,
      omittedBytes: 0,
      keptBytes: totalInlineImageBytes,
      totalInlineImageBytes,
      budgetBytes,
    };
  }

  let keptBytes = 0;
  let keptCount = 0;
  let omittedBytes = 0;
  let omittedCount = 0;
  let cachedCount = 0;
  let cachedBytes = 0;

  for (let index = refs.length - 1; index >= 0; index -= 1) {
    const ref = refs[index];
    const keep = (keepNewest && keptCount === 0) || keptBytes + ref.bytes <= budgetBytes;
    if (keep) {
      keptBytes += ref.bytes;
      keptCount += 1;
      continue;
    }

    const mediaRef = replaceKnownImagePartWithPlaceholder(ref.target, ref.url, options);
    if (mediaRef) {
      cachedCount += 1;
      cachedBytes += mediaRef.bytes || 0;
    }
    omittedBytes += ref.bytes;
    omittedCount += 1;
  }

  return {
    totalCount: refs.length,
    omittedCount,
    keptCount,
    omittedBytes,
    keptBytes,
    cachedCount,
    cachedBytes,
    totalInlineImageBytes,
    budgetBytes,
  };
}

function parseMultipartBoundary(contentType) {
  const match = /boundary=(?:"([^"]+)"|([^;]+))/i.exec(String(contentType || ""));
  return (match?.[1] || match?.[2] || "").trim();
}

function splitMultipartBuffer(buffer, contentType) {
  const boundary = parseMultipartBoundary(contentType);
  if (!boundary) return null;
  const raw = buffer.toString("latin1");
  const delimiter = `--${boundary}`;
  return { raw, delimiter, parts: raw.split(delimiter) };
}

function findMultipartFieldPartIndex(parts, fieldName) {
  const marker = `name="${fieldName}"`;
  for (let index = 0; index < parts.length; index += 1) {
    if (parts[index].includes(marker)) return index;
  }
  return -1;
}

function extractMultipartFormFieldValue(buffer, contentType, fieldName) {
  const split = splitMultipartBuffer(buffer, contentType);
  if (!split) return null;
  const index = findMultipartFieldPartIndex(split.parts, fieldName);
  if (index < 0) return null;

  const part = split.parts[index];
  const bodyStart = part.indexOf("\r\n\r\n");
  if (bodyStart < 0) return null;

  const valueStart = bodyStart + 4;
  const valueEnd = part.lastIndexOf("\r\n");
  if (valueEnd < valueStart) return null;
  return part.slice(valueStart, valueEnd);
}

function rewriteMultipartFormFieldValue(buffer, contentType, fieldName, nextValue) {
  const split = splitMultipartBuffer(buffer, contentType);
  if (!split) return null;
  const index = findMultipartFieldPartIndex(split.parts, fieldName);
  if (index < 0) return null;

  const part = split.parts[index];
  const bodyStart = part.indexOf("\r\n\r\n");
  if (bodyStart < 0) return null;

  const valueStart = bodyStart + 4;
  const valueEnd = part.lastIndexOf("\r\n");
  if (valueEnd < valueStart) return null;

  split.parts[index] = `${part.slice(0, valueStart)}${nextValue}${part.slice(valueEnd)}`;
  return Buffer.from(split.parts.join(split.delimiter), "latin1");
}

function appendMultipartFormFieldValue(buffer, contentType, fieldName, nextValue) {
  const boundary = parseMultipartBoundary(contentType);
  if (!boundary) return null;
  const raw = buffer.toString("latin1");
  const closingBoundary = `--${boundary}--`;
  const closingIndex = raw.lastIndexOf(closingBoundary);
  if (closingIndex < 0) return null;

  const insertion = `--${boundary}\r\nContent-Disposition: form-data; name="${fieldName}"\r\n\r\n${nextValue}\r\n`;
  return Buffer.from(`${raw.slice(0, closingIndex)}${insertion}${raw.slice(closingIndex)}`, "latin1");
}

function normalizeImageRequestBody(buffer, contentType, requestPath = IMAGE_GENERATIONS_PATH) {
  if (!buffer || buffer.length === 0) return buffer;

  const pathname = new URL(requestPath, "http://127.0.0.1").pathname;
  const normalizedType = String(contentType || "").toLowerCase();

  if (normalizedType.includes("application/json")) {
    let payload;
    try {
      payload = JSON.parse(buffer.toString("utf8"));
    } catch {
      return buffer;
    }

    if (!payload || typeof payload !== "object" || Array.isArray(payload)) return buffer;
    return Buffer.from(JSON.stringify({ ...payload, model: normalizeModelForOmniRouteImage(payload.model) }));
  }

  if (pathname === IMAGE_EDITS_PATH && normalizedType.includes("multipart/form-data")) {
    const currentModel = extractMultipartFormFieldValue(buffer, contentType, "model");
    const nextModel = normalizeModelForOmniRouteImage(currentModel);
    return (
      rewriteMultipartFormFieldValue(buffer, contentType, "model", nextModel) ||
      appendMultipartFormFieldValue(buffer, contentType, "model", nextModel) ||
      buffer
    );
  }

  return buffer;
}

// ----------------------------------------------------------------------------
// Codex native/freeform apply_patch <-> OmniRoute function adapter
// ----------------------------------------------------------------------------

function createApplyPatchAdapterContext(suffix) {
  return {
    suffix,
    requestHadAdaptedApplyPatch: false,
    requestHadToolSearchShim: false,
    adaptedApplyPatchToolCount: 0,
    originalApplyPatchTools: [],
    applyPatchFunctionCallItemIds: new Set(),
    applyPatchFunctionCallIds: new Set(),
    applyPatchFunctionOutputIndexes: new Set(),
    functionArgumentStateByKey: new Map(),
  };
}

function isRecord(value) {
  return value != null && typeof value === "object" && !Array.isArray(value);
}

function pickStringAtPaths(obj, paths) {
  if (!isRecord(obj)) return null;
  for (const pathParts of paths) {
    let cur = obj;
    for (const part of pathParts) {
      if (!isRecord(cur) || !(part in cur)) {
        cur = null;
        break;
      }
      cur = cur[part];
    }
    if (typeof cur === "string" && cur.length > 0) return cur;
  }
  return null;
}

function getToolName(tool) {
  return pickStringAtPaths(tool, [["name"], ["function", "name"], ["custom", "name"]]);
}

function getToolDescription(tool) {
  return (
    pickStringAtPaths(tool, [["description"], ["function", "description"], ["custom", "description"]]) ||
    "Apply a patch to files in the current workspace."
  );
}

function getToolType(tool) {
  return pickStringAtPaths(tool, [["type"]]) || "";
}

function isApplyPatchCustomTool(tool) {
  if (!isRecord(tool)) return false;
  if (getToolName(tool) !== APPLY_PATCH_TOOL_NAME) return false;
  const type = getToolType(tool).toLowerCase();
  return type === "custom" || type === "custom_tool" || type === "freeform";
}

function makeApplyPatchFunctionParameters() {
  return {
    type: "object",
    properties: {
      input: {
        type: "string",
        description:
          "The exact apply_patch patch text, including *** Begin Patch and *** End Patch.",
      },
    },
    required: ["input"],
    additionalProperties: false,
  };
}

function rememberOriginalApplyPatchTool(ctx, tool, description) {
  if (!ctx) return;
  ctx.originalApplyPatchTools.push({
    type: getToolType(tool),
    name: getToolName(tool),
    description,
    format:
      (isRecord(tool) && (tool.format || tool.input_format || tool.inputFormat)) ||
      (isRecord(tool?.custom) && (tool.custom.format || tool.custom.input_format || tool.custom.inputFormat)) ||
      null,
  });
}

function rewriteApplyPatchToolForOmniRoute(tool, suffix, ctx) {
  if (!isApplyPatchCustomTool(tool)) return tool;

  const description = getToolDescription(tool);
  const parameters = makeApplyPatchFunctionParameters();
  const isChatCompletions = suffix.includes("chat/completions");
  rememberOriginalApplyPatchTool(ctx, tool, description);
  if (ctx) {
    ctx.requestHadAdaptedApplyPatch = true;
    ctx.adaptedApplyPatchToolCount += 1;
  }

  if (isChatCompletions) {
    return {
      type: "function",
      function: {
        name: APPLY_PATCH_TOOL_NAME,
        description,
        parameters,
        strict: true,
      },
    };
  }

  return {
    type: "function",
    name: APPLY_PATCH_TOOL_NAME,
    description,
    parameters,
    strict: true,
  };
}

function rewriteApplyPatchToolChoiceForOmniRoute(toolChoice, suffix, ctx) {
  if (!ctx?.requestHadAdaptedApplyPatch || !isRecord(toolChoice)) return toolChoice;
  if (getToolName(toolChoice) !== APPLY_PATCH_TOOL_NAME) return toolChoice;

  const type = getToolType(toolChoice).toLowerCase();
  if (type && type !== "custom" && type !== "custom_tool" && type !== "freeform") {
    return toolChoice;
  }

  if (suffix.includes("chat/completions")) {
    return { type: "function", function: { name: APPLY_PATCH_TOOL_NAME } };
  }
  return { type: "function", name: APPLY_PATCH_TOOL_NAME };
}

function rewriteApplyPatchToolsForOmniRoute(parsed, suffix, ctx) {
  if (!isRecord(parsed)) return parsed;
  if (Array.isArray(parsed.tools)) {
    parsed.tools = parsed.tools.map((tool) => rewriteApplyPatchToolForOmniRoute(tool, suffix, ctx));
  }
  if (parsed.tool_choice != null) {
    parsed.tool_choice = rewriteApplyPatchToolChoiceForOmniRoute(parsed.tool_choice, suffix, ctx);
  }
  return parsed;
}

function normalizeMainRequestBody(buf, provider, applyPatchAdapterContext = null, suffix = "") {
  if (!buf || buf.length === 0) return buf;
  let parsed;
  try {
    parsed = JSON.parse(buf.toString("utf8"));
  } catch {
    return buf;
  }
  if (parsed && typeof parsed === "object") {
    if (parsed.model) parsed.model = selectModelForOmniRoute(parsed.model, provider, parsed);
    parsed.store = false;
    parsed = applyGpt55Pin(parsed, provider);
    parsed = rewriteApplyPatchToolsForOmniRoute(parsed, suffix, applyPatchAdapterContext);
    if (toolAdapters.maybeInjectToolSearchFunctionShim(parsed, "omniroute")) {
      if (applyPatchAdapterContext) applyPatchAdapterContext.requestHadToolSearchShim = true;
      log("info", "tool_search function shim injected", { suffix, shim: TOOL_SEARCH_SHIM_FUNCTION_NAME });
    }
    const strippedToolSearchCount = toolAdapters.maybeStripNativeToolSearchTool(parsed, "omniroute");
    if (strippedToolSearchCount > 0) {
      log("info", "native tool_search stripped for OmniRoute upstream", {
        suffix,
        strippedToolSearchCount,
        shim: TOOL_SEARCH_SHIM_FUNCTION_NAME,
      });
    }

    const inlineImageStats = sanitizeInlineImageHistory(parsed, {
      budgetBytes: INLINE_IMAGE_HISTORY_BUDGET_BYTES,
      keepNewest: true,
      requestPath: suffix || "/responses",
    });
    if (inlineImageStats?.omittedCount > 0) {
      log("warn", "inline image history sanitized", {
        suffix,
        kept: inlineImageStats.keptCount,
        omitted: inlineImageStats.omittedCount,
        omittedBytes: inlineImageStats.omittedBytes,
        cached: inlineImageStats.cachedCount || 0,
      });
    }
  }
  let out = Buffer.from(JSON.stringify(parsed), "utf8");

  if (out.length > OMNIROUTE_BODY_FALLBACK_THRESHOLD_BYTES && parsed && typeof parsed === "object") {
    const hardStats = sanitizeInlineImageHistory(parsed, {
      budgetBytes: 0,
      keepNewest: false,
      requestPath: suffix || "/responses",
    });
    const compacted = Buffer.from(JSON.stringify(parsed), "utf8");
    if (compacted.length < out.length) {
      log("warn", "omniroute body hard-compacted for 10MB upstream limit", {
        suffix,
        originalBytes: out.length,
        compactedBytes: compacted.length,
        thresholdBytes: OMNIROUTE_BODY_FALLBACK_THRESHOLD_BYTES,
        maxBytes: OMNIROUTE_MAX_BODY_BYTES,
        omittedImages: hardStats?.omittedCount || 0,
      });
      out = compacted;
    }
  }

  return out;
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
    if (section.toLowerCase().endsWith(".http_headers")) continue;
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
  if (extractMcpNamespaceServerSignal(summary)) return true;
  return Boolean(summary?.server_label || summary?.server_name);
}

const { maybeGcMediaCache, storeInlineImageInMediaCache } = createMediaCache({
  mediaCacheDir: MEDIA_CACHE_DIR,
  mediaCacheMaxBytes: MEDIA_CACHE_MAX_BYTES,
  mediaCacheMaxAgeMs: MEDIA_CACHE_MAX_AGE_MS,
  logBridge: (level, message, details = {}) => log(level, message, details),
});

const toolAdapters = createToolAdapters({
  enableToolSearchFunctionShim: ENABLE_TOOL_SEARCH_FUNCTION_SHIM,
  enableToolSearchAliasRerank: ENABLE_TOOL_SEARCH_ALIAS_RERANK,
  enableApplyPatchFunctionAdapter: false,
  toolSearchShimFunctionName: TOOL_SEARCH_SHIM_FUNCTION_NAME,
  toolSearchAliasesPath: TOOL_SEARCH_ALIASES_PATH,
  logBridge: (level, message, details = {}) => log(level, message, details),
});

function extractMcpNamespaceServerSignal(summary) {
  for (const value of [summary?.name, summary?.namespace]) {
    if (typeof value !== "string") continue;
    const match = value.trim().match(/^mcp__(.+)__$/);
    if (match?.[1]) return normalizeToolSignal(match[1]);
  }
  return "";
}

function explicitConfiguredMcpServerMatches(summary, serverSignals) {
  const matches = [];
  for (const value of [summary?.server_label, summary?.server_name]) {
    const signal = normalizeToolSignal(value);
    if (signal && serverSignals.has(signal)) matches.push(serverSignals.get(signal));
  }
  const namespaceSignal = extractMcpNamespaceServerSignal(summary);
  if (namespaceSignal && serverSignals.has(namespaceSignal)) {
    matches.push(serverSignals.get(namespaceSignal));
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
    await fs.mkdir(path.dirname(LAST_REASONING_DIAGNOSTIC_PATH), { recursive: true });
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
    delete out["x-api-key"];
    delete out["openai-organization"];
    delete out["openai-project"];
    delete out["chatgpt-account-id"];
    if (provider.api_key) out["x-api-key"] = provider.api_key;
    for (const [k, v] of Object.entries(provider.headers || {})) out[k] = String(v);
    out["x-omniroute-client"] = out["x-omniroute-client"] || "codex-omniroute-bridge";
  } else if (mode === "official") {
    // Codex Desktop is sending its real OAuth bearer (loaded from the
    // shared $CODEX_HOME/auth.json), so the simple thing is to
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

function shouldTransformApplyPatchResponse(ctx) {
  return Boolean(ctx?.requestHadAdaptedApplyPatch);
}

function rememberApplyPatchFunctionCall(ctx, obj) {
  if (!ctx || !isRecord(obj)) return;
  if (typeof obj.id === "string" && obj.id) ctx.applyPatchFunctionCallItemIds.add(obj.id);
  if (typeof obj.item_id === "string" && obj.item_id) {
    ctx.applyPatchFunctionCallItemIds.add(obj.item_id);
  }
  if (typeof obj.call_id === "string" && obj.call_id) ctx.applyPatchFunctionCallIds.add(obj.call_id);
  if (Number.isInteger(obj.output_index)) {
    ctx.applyPatchFunctionOutputIndexes.add(`output:${obj.output_index}`);
  }
  if (Number.isInteger(obj.index)) {
    ctx.applyPatchFunctionOutputIndexes.add(`chat:${obj.index}`);
  }
}

function objectTargetsKnownApplyPatchCall(ctx, obj) {
  if (!ctx || !isRecord(obj)) return false;
  if (typeof obj.id === "string" && ctx.applyPatchFunctionCallItemIds.has(obj.id)) return true;
  if (typeof obj.item_id === "string" && ctx.applyPatchFunctionCallItemIds.has(obj.item_id)) {
    return true;
  }
  if (typeof obj.call_id === "string" && ctx.applyPatchFunctionCallIds.has(obj.call_id)) return true;
  if (
    Number.isInteger(obj.output_index) &&
    ctx.applyPatchFunctionOutputIndexes.has(`output:${obj.output_index}`)
  ) {
    return true;
  }
  if (
    Number.isInteger(obj.index) &&
    ctx.applyPatchFunctionOutputIndexes.has(`chat:${obj.index}`)
  ) {
    return true;
  }
  return false;
}

function objectNamesApplyPatchFunctionCall(obj) {
  if (!isRecord(obj)) return false;
  const type = typeof obj.type === "string" ? obj.type : "";
  if (type !== "function_call" && type !== "function") return false;
  return getToolName(obj) === APPLY_PATCH_TOOL_NAME;
}

function pickApplyPatchInputFromObject(obj) {
  if (!isRecord(obj)) return null;
  for (const key of APPLY_PATCH_ARGUMENT_KEYS) {
    const value = obj[key];
    if (typeof value === "string") return value;
  }
  return null;
}

function decodeJsonStringPrefix(src) {
  let out = "";
  for (let i = 0; i < src.length; i += 1) {
    const ch = src[i];
    if (ch === '"') return out;
    if (ch !== "\\") {
      out += ch;
      continue;
    }
    i += 1;
    if (i >= src.length) return out;
    const esc = src[i];
    if (esc === '"' || esc === "\\" || esc === "/") out += esc;
    else if (esc === "b") out += "\b";
    else if (esc === "f") out += "\f";
    else if (esc === "n") out += "\n";
    else if (esc === "r") out += "\r";
    else if (esc === "t") out += "\t";
    else if (esc === "u") {
      const hex = src.slice(i + 1, i + 5);
      if (!/^[0-9a-fA-F]{4}$/.test(hex)) return out;
      out += String.fromCharCode(parseInt(hex, 16));
      i += 4;
    } else {
      out += esc;
    }
  }
  return out;
}

function extractPartialJsonStringProperty(jsonText) {
  for (const key of APPLY_PATCH_ARGUMENT_KEYS) {
    const needle = JSON.stringify(key);
    const keyIndex = jsonText.indexOf(needle);
    if (keyIndex < 0) continue;
    let i = keyIndex + needle.length;
    while (i < jsonText.length && /\s/.test(jsonText[i])) i += 1;
    if (jsonText[i] !== ":") continue;
    i += 1;
    while (i < jsonText.length && /\s/.test(jsonText[i])) i += 1;
    if (jsonText[i] !== '"') continue;
    return decodeJsonStringPrefix(jsonText.slice(i + 1));
  }
  return null;
}

function extractApplyPatchInputFromFunctionArguments(value, { partial = false } = {}) {
  if (value == null) return "";
  if (isRecord(value)) {
    const picked = pickApplyPatchInputFromObject(value);
    return picked ?? safeStringify(value);
  }
  if (typeof value !== "string") return String(value);

  const trimmed = value.trimStart();
  if (!trimmed) return "";
  if (trimmed.startsWith("*** Begin Patch")) return value;

  try {
    const parsed = JSON.parse(value);
    if (typeof parsed === "string") return parsed;
    if (isRecord(parsed)) {
      const picked = pickApplyPatchInputFromObject(parsed);
      return picked ?? safeStringify(parsed);
    }
    return parsed == null ? "" : String(parsed);
  } catch {
    const partialValue = extractPartialJsonStringProperty(value);
    if (partialValue != null) return partialValue;
    if (partial && (trimmed.startsWith("{") || trimmed.startsWith("[") || trimmed.startsWith('"'))) {
      return null;
    }
    return value;
  }
}

function functionArgumentStateKey(event) {
  if (typeof event.id === "string" && event.id) return `item:${event.id}`;
  if (typeof event.item_id === "string" && event.item_id) return `item:${event.item_id}`;
  if (typeof event.call_id === "string" && event.call_id) return `call:${event.call_id}`;
  if (Number.isInteger(event.output_index)) return `output:${event.output_index}`;
  if (Number.isInteger(event.index)) return `chat:${event.index}`;
  return "default";
}

function getFunctionArgumentState(ctx, event) {
  const key = functionArgumentStateKey(event);
  let state = ctx.functionArgumentStateByKey.get(key);
  if (!state) {
    state = { raw: "", emittedInput: "" };
    ctx.functionArgumentStateByKey.set(key, state);
  }
  return state;
}

function transformApplyPatchFunctionArgumentsDelta(event, ctx) {
  const state = getFunctionArgumentState(ctx, event);
  state.raw += typeof event.delta === "string" ? event.delta : "";
  const input = extractApplyPatchInputFromFunctionArguments(state.raw, { partial: true });
  let delta = "";
  if (typeof input === "string") {
    delta = input.startsWith(state.emittedInput) ? input.slice(state.emittedInput.length) : input;
    state.emittedInput = input;
  }

  const out = { ...event, type: "response.custom_tool_call_input.delta", delta };
  delete out.arguments;
  return out;
}

function transformApplyPatchFunctionArgumentsDone(event, ctx) {
  const state = getFunctionArgumentState(ctx, event);
  const rawArgs = typeof event.arguments === "string" ? event.arguments : state.raw;
  const input = extractApplyPatchInputFromFunctionArguments(rawArgs);
  state.raw = rawArgs || state.raw;
  state.emittedInput = input;

  const out = { ...event, type: "response.custom_tool_call_input.done", input };
  delete out.arguments;
  delete out.delta;
  return out;
}

function transformApplyPatchResponseItem(item, ctx) {
  if (!isRecord(item)) return item;
  if (!objectNamesApplyPatchFunctionCall(item) && !objectTargetsKnownApplyPatchCall(ctx, item)) {
    return item;
  }
  rememberApplyPatchFunctionCall(ctx, item);
  const input = extractApplyPatchInputFromFunctionArguments(item.arguments ?? item.input ?? "");
  const out = { ...item, type: "custom_tool_call", name: APPLY_PATCH_TOOL_NAME, input };
  delete out.arguments;
  delete out.parsed_arguments;
  delete out.function;
  return out;
}

function transformApplyPatchChatToolCall(toolCall, ctx, { partial = false } = {}) {
  if (!isRecord(toolCall)) return toolCall;
  const functionObj = isRecord(toolCall.function) ? toolCall.function : {};
  const isApplyPatch =
    (toolCall.type === "function" && functionObj.name === APPLY_PATCH_TOOL_NAME) ||
    objectTargetsKnownApplyPatchCall(ctx, toolCall);
  if (!isApplyPatch) return toolCall;

  rememberApplyPatchFunctionCall(ctx, toolCall);
  const state = getFunctionArgumentState(ctx, toolCall);
  state.raw += typeof functionObj.arguments === "string" ? functionObj.arguments : "";
  const input = extractApplyPatchInputFromFunctionArguments(state.raw, { partial });
  const emittedInput =
    typeof input === "string" && partial && input.startsWith(state.emittedInput)
      ? input.slice(state.emittedInput.length)
      : input ?? "";
  if (typeof input === "string") state.emittedInput = input;

  const out = {
    ...toolCall,
    type: "custom",
    custom: {
      name: APPLY_PATCH_TOOL_NAME,
      input: emittedInput,
    },
  };
  delete out.function;
  return out;
}

function transformApplyPatchChatChoice(choice, ctx) {
  if (!isRecord(choice)) return choice;
  if (isRecord(choice.delta) && Array.isArray(choice.delta.tool_calls)) {
    choice.delta = {
      ...choice.delta,
      tool_calls: choice.delta.tool_calls.map((toolCall) =>
        transformApplyPatchChatToolCall(toolCall, ctx, { partial: true }),
      ),
    };
  }
  if (isRecord(choice.message) && Array.isArray(choice.message.tool_calls)) {
    choice.message = {
      ...choice.message,
      tool_calls: choice.message.tool_calls.map((toolCall) =>
        transformApplyPatchChatToolCall(toolCall, ctx),
      ),
    };
  }
  return choice;
}

function transformApplyPatchStreamingEvent(event, ctx) {
  if (!isRecord(event) || typeof event.type !== "string") return event;

  if (isRecord(event.item)) {
    const transformedItem = transformApplyPatchResponseItem(event.item, ctx);
    if (transformedItem !== event.item) event = { ...event, item: transformedItem };
  }

  if (
    event.type === "response.function_call_arguments.delta" &&
    objectTargetsKnownApplyPatchCall(ctx, event)
  ) {
    return transformApplyPatchFunctionArgumentsDelta(event, ctx);
  }

  if (
    event.type === "response.function_call_arguments.done" &&
    objectTargetsKnownApplyPatchCall(ctx, event)
  ) {
    return transformApplyPatchFunctionArgumentsDone(event, ctx);
  }

  return event;
}

function transformApplyPatchResponseObject(value, ctx) {
  if (!shouldTransformApplyPatchResponse(ctx)) return value;
  if (Array.isArray(value)) {
    return value.map((entry) => transformApplyPatchResponseObject(entry, ctx));
  }
  if (!isRecord(value)) return value;

  let out = value;
  if (typeof out.type === "string") {
    out = transformApplyPatchStreamingEvent(out, ctx);
  }
  if (Array.isArray(out.output)) {
    out = { ...out, output: out.output.map((item) => transformApplyPatchResponseItem(item, ctx)) };
  }
  if (isRecord(out.response)) {
    out = { ...out, response: transformApplyPatchResponseObject(out.response, ctx) };
  }
  if (Array.isArray(out.choices)) {
    out = {
      ...out,
      choices: out.choices.map((choice) => transformApplyPatchChatChoice(choice, ctx)),
    };
  }
  return out;
}

function transformToolAdapterResponseObject(value, requestMeta = {}) {
  if (Array.isArray(value)) {
    return value.map((entry) => transformToolAdapterResponseObject(entry, requestMeta));
  }
  if (!isRecord(value)) return value;

  toolAdapters.normalizeResponseSsePayload(value, requestMeta);
  toolAdapters.normalizeResponseItem(value, requestMeta);

  for (const [key, nested] of Object.entries(value)) {
    if (nested && typeof nested === "object") {
      value[key] = transformToolAdapterResponseObject(nested, requestMeta);
    }
  }
  return value;
}

function transformBridgeResponseObject(value, ctx) {
  const requestMeta = { suffix: ctx?.suffix || null };
  const afterApplyPatch = transformApplyPatchResponseObject(value, ctx);
  return transformToolAdapterResponseObject(afterApplyPatch, requestMeta);
}

function isSseContentType(contentType) {
  return String(contentType || "").toLowerCase().includes("text/event-stream");
}

function isJsonContentType(contentType) {
  return String(contentType || "").toLowerCase().includes("application/json");
}

function sseLineValue(line, prefix) {
  let value = line.slice(prefix.length);
  if (value.startsWith(" ")) value = value.slice(1);
  return value;
}

function transformSseBlock(block, ctx) {
  if (!block) return "\n\n";
  const lines = block.split(/\r?\n/);
  const passthrough = [];
  const dataParts = [];
  let eventName = null;

  for (const line of lines) {
    if (line.startsWith("event:")) {
      eventName = sseLineValue(line, "event:");
    } else if (line.startsWith("data:")) {
      dataParts.push(sseLineValue(line, "data:"));
    } else {
      passthrough.push(line);
    }
  }

  if (dataParts.length === 0) return block + "\n\n";
  const data = dataParts.join("\n");
  if (data.trim() === "[DONE]") return block + "\n\n";

  let parsed;
  try {
    parsed = JSON.parse(data);
  } catch {
    return block + "\n\n";
  }

  const transformed = transformBridgeResponseObject(parsed, ctx);
  const transformedEventName =
    isRecord(transformed) && typeof transformed.type === "string" ? transformed.type : eventName;
  const outLines = passthrough.filter((line) => line.length > 0 || passthrough.length === 1);
  if (transformedEventName) outLines.push(`event: ${transformedEventName}`);
  outLines.push(`data: ${JSON.stringify(transformed)}`);
  return outLines.join("\n") + "\n\n";
}

function pipeSseWithApplyPatchTransform(upstreamRes, clientRes, ctx) {
  const decoder = new StringDecoder("utf8");
  let pending = "";

  function flushPending(final = false) {
    while (true) {
      const match = /\r?\n\r?\n/.exec(pending);
      if (!match) break;
      const block = pending.slice(0, match.index);
      pending = pending.slice(match.index + match[0].length);
      clientRes.write(transformSseBlock(block, ctx));
    }
    if (final && pending.length > 0) {
      clientRes.write(transformSseBlock(pending, ctx));
      pending = "";
    }
  }

  upstreamRes.on("data", (chunk) => {
    pending += decoder.write(chunk);
    flushPending(false);
  });
  upstreamRes.on("end", () => {
    pending += decoder.end();
    flushPending(true);
    clientRes.end();
  });
}

function pipeJsonWithApplyPatchTransform(upstreamRes, clientRes, ctx) {
  const chunks = [];
  upstreamRes.on("data", (chunk) => chunks.push(chunk));
  upstreamRes.on("end", () => {
    const body = Buffer.concat(chunks);
    let parsed;
    try {
      parsed = JSON.parse(body.toString("utf8"));
    } catch {
      clientRes.end(body);
      return;
    }
    const transformed = transformBridgeResponseObject(parsed, ctx);
    clientRes.end(Buffer.from(JSON.stringify(transformed), "utf8"));
  });
}

function shouldTransformBridgeResponse(ctx) {
  return Boolean(ctx);
}

function forwardOutbound({
  target,
  method,
  headers,
  bodyBuf,
  clientRes,
  isStreaming,
  responseAdapterContext = null,
}) {
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
      if (shouldTransformBridgeResponse(responseAdapterContext)) {
        const contentType = upstreamRes.headers["content-type"];
        if (isSseContentType(contentType)) {
          pipeSseWithApplyPatchTransform(upstreamRes, clientRes, responseAdapterContext);
        } else if (isJsonContentType(contentType)) {
          pipeJsonWithApplyPatchTransform(upstreamRes, clientRes, responseAdapterContext);
        } else {
          upstreamRes.on("data", (chunk) => clientRes.write(chunk));
          upstreamRes.on("end", () => clientRes.end());
        }
      } else {
        upstreamRes.on("data", (chunk) => clientRes.write(chunk));
        upstreamRes.on("end", () => clientRes.end());
      }
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
  const homeStatus = await inspectSharedCodexHome();
  const lastReasoningRequest =
    LAST_REASONING_DIAGNOSTIC || (await tryReadJson(LAST_REASONING_DIAGNOSTIC_PATH));

  res.statusCode = 200;
  res.setHeader("content-type", "application/json; charset=utf-8");
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
      image_lane: {
        route: "omniroute",
        default_model: DEFAULT_OMNIROUTE_IMAGE_MODEL,
        configured: Boolean(resolveImageApiKey(provider)),
      },
      body_budget: {
        omniroute_max_body_bytes: OMNIROUTE_MAX_BODY_BYTES,
        threshold_bytes: OMNIROUTE_BODY_FALLBACK_THRESHOLD_BYTES,
        inline_image_history_budget_bytes: INLINE_IMAGE_HISTORY_BUDGET_BYTES,
        media_cache_dir: MEDIA_CACHE_DIR,
        media_cache_max_bytes: MEDIA_CACHE_MAX_BYTES,
      },
      tool_adapters: {
        tool_search_function_shim: ENABLE_TOOL_SEARCH_FUNCTION_SHIM,
        tool_search_alias_rerank: ENABLE_TOOL_SEARCH_ALIAS_RERANK,
        tool_search_shim_function_name: TOOL_SEARCH_SHIM_FUNCTION_NAME,
        apply_patch_function_adapter: ENABLE_APPLY_PATCH_FUNCTION_ADAPTER,
      },
      main_reasoning_hits: MAIN_REASONING_HITS,
      last_reasoning_request_path: LAST_REASONING_DIAGNOSTIC_PATH,
      last_reasoning_request: lastReasoningRequest,
      shared_home: homeStatus,
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
  const applyPatchAdapterContext = createApplyPatchAdapterContext(suffix);
  const bodyBuf = normalizeMainRequestBody(raw, provider, applyPatchAdapterContext, suffix);
  if (bodyBuf.length > OMNIROUTE_BODY_FALLBACK_THRESHOLD_BYTES) {
    log("error", "omniroute body rejected after 10MB compaction", {
      suffix,
      bodyBytes: bodyBuf.length,
      thresholdBytes: OMNIROUTE_BODY_FALLBACK_THRESHOLD_BYTES,
      maxBytes: OMNIROUTE_MAX_BODY_BYTES,
    });
    res.statusCode = 413;
    res.setHeader("content-type", "application/json");
    res.end(
      JSON.stringify({
        error: "omniroute_body_too_large",
        detail: `Request body is ${formatBytes(bodyBuf.length)} after inline-image compaction; OmniRoute limit is ${formatBytes(OMNIROUTE_MAX_BODY_BYTES)}.`,
      }),
    );
    return;
  }
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
      `apply_patch_adapter=${applyPatchAdapterContext.adaptedApplyPatchToolCount}`,
    );
  } else {
    log(
      "info",
      "omniroute ->",
      target.href,
      `bytes=${bodyBuf.length}`,
      `apply_patch_adapter=${applyPatchAdapterContext.adaptedApplyPatchToolCount}`,
    );
  }
  forwardOutbound({
    target,
    method: "POST",
    headers,
    bodyBuf,
    clientRes: res,
    isStreaming: true,
    responseAdapterContext: applyPatchAdapterContext,
  });
}

function resolveImageApiKey(provider) {
  return (
    process.env.CODEX_OMNI_OMNIROUTE_IMAGE_API_KEY ||
    process.env.OMNIROUTE_IMAGE_API_KEY ||
    provider?.image_api_key ||
    provider?.api_key ||
    ""
  );
}

async function handleOmniRouteImage(req, res, suffix) {
  const provider = await resolveProvider();
  if (!provider) {
    res.statusCode = 500;
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ error: "omniroute_not_configured" }));
    return;
  }

  const imageApiKey = resolveImageApiKey(provider);
  if (!imageApiKey) {
    res.statusCode = 500;
    res.setHeader("content-type", "application/json");
    res.end(
      JSON.stringify({
        error: "omniroute_image_not_configured",
        detail: "Set the OmniRoute provider api_key.",
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
    log("warn", "failed to decode inbound image body for", suffix, err?.message);
    res.statusCode = 400;
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ error: "bad_request_encoding", detail: err?.message }));
    return;
  }

  const requestPath = `/v1${suffix}`;
  const bodyBuf = normalizeImageRequestBody(raw, req.headers["content-type"], requestPath);
  const target = new URL(provider.base_url + suffix);
  const headers = buildForwardHeaders(req.headers, "omniroute", { ...provider, api_key: imageApiKey }, null);
  if (bodyBuf && bodyBuf.length > 0) headers["content-length"] = String(bodyBuf.length);
  delete headers["x-codex-base64"];
  delete headers["x-codex-base64-multipart"];

  log("info", "omniroute image ->", target.href, `bytes=${bodyBuf?.length || 0}`);
  forwardOutbound({
    target,
    method: req.method,
    headers,
    bodyBuf,
    clientRes: res,
    isStreaming: false,
  });
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

  // Image generation/editing -> OmniRoute image lane.
  if (
    (m === "POST" || m === "GET") &&
    (p === "/v1/images/generations" || p === "/images/generations")
  ) {
    return handleOmniRouteImage(req, res, "/images/generations");
  }
  if (
    (m === "POST" || m === "GET") &&
    (p === "/v1/images/edits" || p === "/images/edits")
  ) {
    return handleOmniRouteImage(req, res, "/images/edits");
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

async function inspectSharedCodexHome() {
  const result = {
    path: CODEX_HOME,
    active_runtime_home: true,
    config_present: false,
    auth_present: false,
    models_cache_present: false,
    sessions_present: false,
    stateSqlitePresent: false,
  };

  let entries = [];
  try {
    entries = await fs.readdir(CODEX_HOME, { withFileTypes: true });
  } catch {
    return result;
  }

  for (const ent of entries) {
    const name = ent.name;
    if (ent.isDirectory() && name === "sessions") result.sessions_present = true;
    if (!ent.isFile()) continue;
    if (name === "config.toml") result.config_present = true;
    if (name === "auth.json") result.auth_present = true;
    if (name === "models_cache.json") result.models_cache_present = true;
    if (/^state_\d+\.sqlite(?:-journal|-wal|-shm)?$/.test(name)) {
      result.stateSqlitePresent = true;
    }
  }
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
  maybeGcMediaCache();
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
