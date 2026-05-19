import { readFileSync, statSync } from "node:fs";

export const DEFAULT_TOOL_SEARCH_QUERY_ALIAS_RULES = [
  {
    id: "gmail_email",
    query: "Gmail email inbox mail thread message draft label search_emails",
    minLimit: 10,
    targetNamespace: "mcp__codex_apps__gmail",
    matchAny: ["gmail", "inbox", "mailbox", "search email", "search emails", "email thread", "email threads"],
  },
  {
    id: "google_drive_files",
    query: "Google Drive files Docs Sheets Slides documents spreadsheets presentations folders search",
    minLimit: 10,
    targetNamespace: "mcp__codex_apps__google_drive",
    matchAny: [
      "google drive",
      "google-drive",
      "drive file",
      "drive files",
      "google docs",
      "google sheets",
      "google slides",
      "docs sheets slides",
      "gdoc",
      "gsheet",
      "gslide",
    ],
    rejectAny: ["calendar", "event", "events", "meeting", "meetings", "availability", "schedule"],
  },
  {
    id: "google_calendar_events",
    query: "Google Calendar events meetings availability schedule invite",
    minLimit: 8,
    targetNamespace: "mcp__codex_apps__google_calendar",
    matchAny: ["google calendar", "calendar", "event", "events", "meeting", "meetings", "availability", "schedule"],
  },
  {
    id: "github_code_hosting",
    query: "GitHub repositories pull requests issues code search CI",
    minLimit: 8,
    targetNamespace: "mcp__codex_apps__github",
    matchAny: ["github", "pull request", "pull requests", "pr", "repository", "repositories", "issue", "issues"],
  },
  {
    id: "roxy_browser_automation",
    query: "RoxyBrowser browser profile proxy fingerprint anti-detect automation workspace account",
    minLimit: 10,
    targetNamespace: "mcp__roxybrowser_openapi__",
    matchAny: [
      "roxy",
      "roxybrowser",
      "roxy browser",
      "rocks browser",
      "browser profile",
      "profile browser",
      "proxy browser",
      "browser fingerprint",
      "antidetect browser",
      "anti-detect browser",
      "рокси",
      "рокс браузер",
      "профиль браузера",
      "браузерный профиль",
      "прокси браузер",
      "антидетект",
    ],
  },
  {
    id: "twentyfirst_magic_components",
    query: "21st Magic React UI component builder inspiration shadcn hero section landing page form menu",
    minLimit: 10,
    targetNamespace: "mcp__twentyfirst_magic__",
    matchAny: [
      "magic",
      "magic mcp",
      "21st",
      "21st magic",
      "twentyfirst magic",
      "ui component",
      "ui components",
      "react component",
      "component builder",
      "component inspiration",
      "shadcn component",
      "hero section",
      "landing components",
      "restaurant landing components",
      "reservation form",
      "menu section",
      "готовые компоненты",
      "ui компоненты",
      "компоненты",
      "красивый лендинг",
      "продающий лендинг",
      "анимашки",
      "анимации",
      "сайт ресторана",
      "ресторанный лендинг",
      "ресторан",
    ],
  },
  {
    id: "canva_design",
    query: "Canva design presentation doc social media brand template",
    minLimit: 8,
    targetNamespace: "mcp__codex_apps__canva",
    matchAny: ["canva", "canva presentation", "canva design", "brand kit"],
  },
  {
    id: "figma_design",
    query: "Figma design FigJam slides code connect design system",
    minLimit: 8,
    targetNamespace: "mcp__codex_apps__figma",
    matchAny: ["figma", "figjam", "figma slides", "figma design", "figma code connect"],
  },
];

const EMPTY_OPTIONAL_RESPONSE_ARG_FIELDS = new Set([
  "shell",
  "sandbox_permissions",
  "approval_policy",
  "workdir",
  "yield_time_ms",
  "max_output_tokens",
]);

function noopLog() {}

export function createToolAdapters(options = {}) {
  const {
    enableToolSearchFunctionShim = true,
    enableToolSearchAliasRerank = true,
    enableApplyPatchFunctionAdapter = true,
    logResponseToolItems = true,
    toolSearchShimFunctionName = "omniroute_tool_search",
    toolSearchAliasesPath = "",
    isOmniRouteRoute = (routeKind) => routeKind === "omniroute" || routeKind === "omniroute_reserve",
    logBridge = noopLog,
  } = options;

  let toolSearchAliasRuleCache = {
    path: null,
    mtimeMs: null,
    rules: DEFAULT_TOOL_SEARCH_QUERY_ALIAS_RULES,
  };

  function log(level, message, details = {}) {
    logBridge(level, message, details);
  }

  function isToolSearchTool(tool) {
    return tool && typeof tool === "object" && !Array.isArray(tool) && tool.type === "tool_search";
  }

  function payloadHasToolSearchTool(payload) {
    const tools = Array.isArray(payload?.tools) ? payload.tools : [];
    return tools.some(isToolSearchTool);
  }

  function payloadHasFunctionTool(payload, name) {
    const tools = Array.isArray(payload?.tools) ? payload.tools : [];
    return tools.some(
      (tool) =>
        tool &&
        typeof tool === "object" &&
        !Array.isArray(tool) &&
        tool.type === "function" &&
        tool.name === name,
    );
  }

  function maybeInjectToolSearchFunctionShim(payload, routeKind) {
    if (
      !enableToolSearchFunctionShim ||
      !isOmniRouteRoute(routeKind) ||
      !Array.isArray(payload.tools) ||
      !payloadHasToolSearchTool(payload) ||
      payloadHasFunctionTool(payload, toolSearchShimFunctionName)
    ) {
      return false;
    }

    payload.tools = [
      ...payload.tools,
      {
        type: "function",
        name: toolSearchShimFunctionName,
        description:
          "Search the Codex client tool catalog for deferred MCP/plugin tools. Use this when native tool_search is needed.",
        strict: false,
        parameters: {
          type: "object",
          properties: {
            query: {
              type: "string",
              description: "Short search query for the tool or integration, for example github or magic.",
            },
            limit: {
              type: "integer",
              minimum: 1,
              maximum: 20,
              description: "Maximum number of tool namespaces to return.",
            },
          },
          required: ["query"],
          additionalProperties: false,
        },
      },
    ];

    return true;
  }

  function maybeStripNativeToolSearchTool(payload, routeKind) {
    if (
      !enableToolSearchFunctionShim ||
      !isOmniRouteRoute(routeKind) ||
      !Array.isArray(payload.tools) ||
      !payloadHasToolSearchTool(payload) ||
      !payloadHasFunctionTool(payload, toolSearchShimFunctionName)
    ) {
      return 0;
    }

    const nextTools = payload.tools.filter((tool) => !isToolSearchTool(tool));
    const strippedCount = payload.tools.length - nextTools.length;
    if (strippedCount > 0) {
      payload.tools = nextTools;
    }
    return strippedCount;
  }

  function isApplyPatchCustomTool(tool) {
    if (!tool || typeof tool !== "object" || Array.isArray(tool)) return false;
    const type = typeof tool.type === "string" ? tool.type : "";
    const name = typeof tool.name === "string" ? tool.name : "";
    return (type === "custom" || type === "custom_tool") && name === "apply_patch";
  }

  function payloadHasApplyPatchCustomTool(payload) {
    const tools = Array.isArray(payload?.tools) ? payload.tools : [];
    return tools.some(isApplyPatchCustomTool);
  }

  function buildApplyPatchFunctionTool() {
    return {
      type: "function",
      name: "apply_patch",
      description:
        "Apply a Codex patch. Pass the full patch text as patchText, beginning with *** Begin Patch and ending with *** End Patch.",
      strict: false,
      parameters: {
        type: "object",
        properties: {
          patchText: {
            type: "string",
            description: "Complete Codex apply_patch patch text.",
          },
        },
        required: ["patchText"],
        additionalProperties: false,
      },
    };
  }

  function maybeAdaptApplyPatchCustomTool(payload, routeKind) {
    if (
      !enableApplyPatchFunctionAdapter ||
      !isOmniRouteRoute(routeKind) ||
      !Array.isArray(payload.tools) ||
      !payloadHasApplyPatchCustomTool(payload)
    ) {
      return false;
    }

    let adaptedCount = 0;
    const hasFunctionTool = payloadHasFunctionTool(payload, "apply_patch");
    const nextTools = [];
    for (const tool of payload.tools) {
      if (!isApplyPatchCustomTool(tool)) {
        nextTools.push(tool);
        continue;
      }

      adaptedCount += 1;
      if (!hasFunctionTool && !nextTools.some((candidate) => candidate?.type === "function" && candidate?.name === "apply_patch")) {
        nextTools.push(buildApplyPatchFunctionTool());
      }
    }

    if (adaptedCount === 0) return false;
    payload.tools = nextTools;
    return true;
  }

  function parseMaybeJsonObject(value) {
    if (!value || typeof value !== "string") return null;
    try {
      const parsed = JSON.parse(value);
      return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : null;
    } catch {
      return null;
    }
  }

  function getToolSearchAliasRules() {
    if (!toolSearchAliasesPath) return DEFAULT_TOOL_SEARCH_QUERY_ALIAS_RULES;

    let mtimeMs = 0;
    try {
      mtimeMs = statSync(toolSearchAliasesPath).mtimeMs;
    } catch {}

    if (toolSearchAliasRuleCache.path === toolSearchAliasesPath && toolSearchAliasRuleCache.mtimeMs === mtimeMs) {
      return toolSearchAliasRuleCache.rules;
    }

    const rules = loadToolSearchAliasRules();
    toolSearchAliasRuleCache = { path: toolSearchAliasesPath, mtimeMs, rules };
    return rules;
  }

  function loadToolSearchAliasRules() {
    let payload = null;
    try {
      payload = JSON.parse(readFileSync(toolSearchAliasesPath, "utf8"));
    } catch {
      return DEFAULT_TOOL_SEARCH_QUERY_ALIAS_RULES;
    }

    const rules = Array.isArray(payload?.rules) ? payload.rules : [];
    const normalized = rules
      .map((rule) => {
        const query = String(rule?.canonicalQuery || rule?.query || "").trim();
        const matchAny = uniqueStrings([...(rule?.aliases || []), rule?.id, rule?.targetNamespace, rule?.canonicalQuery]);
        if (!rule?.id || !query || !matchAny.length) return null;
        return {
          id: String(rule.id),
          query,
          minLimit: Number.isFinite(Number(rule.minLimit)) ? Math.max(1, Number(rule.minLimit)) : 10,
          targetNamespace: typeof rule.targetNamespace === "string" ? rule.targetNamespace : null,
          matchAny,
          rejectAny: uniqueStrings([...(rule?.rejectAny || []), ...(rule?.rejectWhenPresent || [])]),
        };
      })
      .filter(Boolean);

    return normalized.length ? normalized : DEFAULT_TOOL_SEARCH_QUERY_ALIAS_RULES;
  }

  function uniqueStrings(values) {
    const out = [];
    const seen = new Set();
    for (const value of values.flat().filter((item) => item !== undefined && item !== null && item !== "")) {
      const text = String(value);
      const key = text.toLowerCase();
      if (seen.has(key)) continue;
      seen.add(key);
      out.push(text);
    }
    return out;
  }

  function normalizeToolSearchQueryForAlias(query) {
    return String(query || "")
      .toLowerCase()
      .replace(/[_-]+/g, " ")
      .replace(/[^\p{L}\p{N}]+/gu, " ")
      .replace(/\s+/g, " ")
      .trim();
  }

  function toolSearchQueryHasPhrase(normalizedQuery, phrase) {
    const normalizedPhrase = normalizeToolSearchQueryForAlias(phrase);
    return normalizedPhrase && ` ${normalizedQuery} `.includes(` ${normalizedPhrase} `);
  }

  function resolveToolSearchAlias(query) {
    if (!enableToolSearchAliasRerank) return null;

    const normalizedQuery = normalizeToolSearchQueryForAlias(query);
    if (!normalizedQuery) return null;

    for (const rule of getToolSearchAliasRules()) {
      if ((rule.rejectAny || []).some((phrase) => toolSearchQueryHasPhrase(normalizedQuery, phrase))) continue;
      if ((rule.matchAny || []).some((phrase) => toolSearchQueryHasPhrase(normalizedQuery, phrase))) return rule;
    }

    return null;
  }

  function applyToolSearchAliasRerank(args) {
    const alias = resolveToolSearchAlias(args.query);
    if (!alias) return args;
    return {
      ...args,
      query: alias.query,
      limit: Math.max(args.limit, alias.minLimit || args.limit),
      originalQuery: args.query,
      aliasId: alias.id,
      targetNamespace: alias.targetNamespace,
    };
  }

  function sanitizeResponseFunctionArguments(item, requestMeta = {}) {
    if (!item || typeof item !== "object" || Array.isArray(item) || item.type !== "function_call") return false;
    const args = parseMaybeJsonObject(item.arguments);
    if (!args) return false;

    const removed = [];
    for (const key of EMPTY_OPTIONAL_RESPONSE_ARG_FIELDS) {
      if (Object.prototype.hasOwnProperty.call(args, key) && (args[key] === "" || args[key] == null)) {
        delete args[key];
        removed.push(key);
      }
    }

    if (removed.length === 0) return false;
    item.arguments = JSON.stringify(args);
    log("warn", "sanitized_response_tool_args", {
      ...requestMeta,
      callId: typeof item.call_id === "string" ? item.call_id : null,
      toolName: typeof item.name === "string" ? item.name : null,
      removed,
    });
    return true;
  }

  function coerceToolSearchArguments(value) {
    const args = typeof value === "string" ? parseMaybeJsonObject(value) : value;
    if (!args || typeof args !== "object" || Array.isArray(args)) return null;

    const query = typeof args.query === "string" ? args.query.trim() : "";
    if (!query) return null;

    const limit = Number.isFinite(args.limit) ? Math.max(1, Math.floor(args.limit)) : 8;
    return applyToolSearchAliasRerank({ query, limit });
  }

  function shouldLogToolSearchInvalidArgs(item) {
    const status = typeof item.status === "string" ? item.status : "";
    const hasArguments =
      Object.prototype.hasOwnProperty.call(item, "arguments") && item.arguments != null && item.arguments !== "";

    if (status === "completed") return true;
    if (status && status !== "completed") return false;
    return hasArguments;
  }

  function maybeRewriteToolSearchShim(item, requestMeta = {}) {
    if (
      !enableToolSearchFunctionShim ||
      !item ||
      typeof item !== "object" ||
      Array.isArray(item) ||
      item.type !== "function_call" ||
      item.name !== toolSearchShimFunctionName
    ) {
      return false;
    }

    const args = coerceToolSearchArguments(item.arguments);
    if (!args) {
      if (shouldLogToolSearchInvalidArgs(item)) {
        log("warn", "tool_search_function_shim_invalid_args", {
          ...requestMeta,
          callId: typeof item.call_id === "string" ? item.call_id : null,
        });
      }
      return false;
    }

    const clientArgs = { query: args.query, limit: args.limit };
    item.type = "tool_search_call";
    delete item.name;
    item.status = typeof item.status === "string" ? item.status : "completed";
    item.execution = "client";
    item.arguments = clientArgs;

    log("info", "tool_search_function_shim_rewritten", {
      ...requestMeta,
      callId: typeof item.call_id === "string" ? item.call_id : null,
      query: clientArgs.query,
      limit: clientArgs.limit,
      originalQuery: args.originalQuery || null,
      aliasId: args.aliasId || null,
      targetNamespace: args.targetNamespace || null,
    });
    return true;
  }

  function coerceApplyPatchInput(value) {
    if (typeof value === "string") {
      const trimmed = value.trim();
      if (trimmed.startsWith("*** Begin Patch")) return trimmed;
      const parsed = parseMaybeJsonObject(value);
      if (parsed) return coerceApplyPatchInput(parsed);
    }

    if (!value || typeof value !== "object" || Array.isArray(value)) return null;
    for (const key of ["patchText", "patch", "input", "content", "text"]) {
      const candidate = value[key];
      if (typeof candidate === "string" && candidate.trim().startsWith("*** Begin Patch")) {
        return candidate.trim();
      }
    }
    return null;
  }

  function maybeRewriteApplyPatchFunctionCall(item, requestMeta = {}) {
    if (
      !enableApplyPatchFunctionAdapter ||
      !item ||
      typeof item !== "object" ||
      Array.isArray(item) ||
      item.type !== "function_call" ||
      item.name !== "apply_patch"
    ) {
      return false;
    }

    const patchInput = coerceApplyPatchInput(item.arguments);
    if (!patchInput) {
      log("warn", "apply_patch_function_adapter_invalid_args", {
        ...requestMeta,
        callId: typeof item.call_id === "string" ? item.call_id : null,
      });
      return false;
    }

    item.type = "custom_tool_call";
    item.input = patchInput;
    item.status = typeof item.status === "string" ? item.status : "completed";
    delete item.arguments;

    log("info", "apply_patch_function_adapter_rewritten", {
      ...requestMeta,
      callId: typeof item.call_id === "string" ? item.call_id : null,
    });
    return true;
  }

  function logResponseToolItem(item, requestMeta = {}) {
    if (!logResponseToolItems || !item || typeof item !== "object" || Array.isArray(item)) return;

    const type = typeof item.type === "string" ? item.type : "";
    const name = typeof item.name === "string" ? item.name : null;
    const isInteresting =
      type === "function_call" ||
      type === "custom_tool_call" ||
      type === "tool_search_call" ||
      type === "tool_search_output" ||
      name === "apply_patch" ||
      name === toolSearchShimFunctionName;

    if (!isInteresting) return;
    log("info", "response_tool_item_observed", {
      ...requestMeta,
      responseItemType: type || null,
      toolName: name,
      callId: typeof item.call_id === "string" ? item.call_id : null,
      execution: typeof item.execution === "string" ? item.execution : null,
      status: typeof item.status === "string" ? item.status : null,
      toolCount: Array.isArray(item.tools) ? item.tools.length : null,
    });
  }

  function normalizeResponseItem(item, requestMeta = {}) {
    if (!item || typeof item !== "object" || Array.isArray(item)) return item;
    maybeRewriteApplyPatchFunctionCall(item, requestMeta);
    sanitizeResponseFunctionArguments(item, requestMeta);
    maybeRewriteToolSearchShim(item, requestMeta);
    logResponseToolItem(item, requestMeta);
    return item;
  }

  function normalizeResponseSsePayload(payload, requestMeta = {}) {
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) return payload;

    if (payload.type === "response.output_item.added" && payload.item) {
      payload.item = normalizeResponseItem(payload.item, requestMeta);
    } else if (payload.type === "response.output_item.done" && payload.item) {
      payload.item = normalizeResponseItem(payload.item, requestMeta);
    } else if (payload.type === "response.completed" && payload.response?.output && Array.isArray(payload.response.output)) {
      payload.response.output = payload.response.output.map((item) => normalizeResponseItem(item, requestMeta));
    } else if (
      payload.type === "function_call" ||
      payload.type === "custom_tool_call" ||
      payload.type === "tool_search_call" ||
      payload.type === "tool_search_output"
    ) {
      normalizeResponseItem(payload, requestMeta);
    }

    return payload;
  }

  return {
    getToolSearchAliasRules,
    maybeAdaptApplyPatchCustomTool,
    maybeInjectToolSearchFunctionShim,
    maybeStripNativeToolSearchTool,
    normalizeResponseItem,
    normalizeResponseSsePayload,
    payloadHasFunctionTool,
    payloadHasToolSearchTool,
    shouldLogToolSearchInvalidArgs,
  };
}
