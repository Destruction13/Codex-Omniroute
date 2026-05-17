#!/usr/bin/env node
/*
 * Codex OmniRoute -- centralised MCP / skills catalog client.
 *
 * Loads a JSON catalog describing MCP servers and skills, with a strict
 * fallback chain so the fork keeps working out-of-the-box on every machine:
 *
 *   1. Remote URL (if --catalog-url is set, fetched with optional Bearer)
 *   2. Last-known-good cache file written from the previous successful fetch
 *   3. Bundled default-mcp-catalog.json shipped inside the repository
 *
 * For each loaded MCP entry the helper emits a [mcp_servers.<name>] TOML
 * block to --toml-out. For each loaded skill entry it writes the skill
 * markdown to <isolated-home>/skills/<name>/SKILL.md. The launcher then
 * picks up the TOML via the existing Get-ImportableConfigBlocks pipeline,
 * so no duplicate parser logic lives in PowerShell.
 *
 * A status JSON is emitted on stdout for the launcher to log:
 *
 *   {
 *     "source": "url" | "cache" | "bundle" | "none",
 *     "mcp_count": <int>,
 *     "skill_count": <int>,
 *     "mcp_names": [...],
 *     "skill_names": [...],
 *     "warnings": [...]
 *   }
 *
 * Exit codes: 0 on success (even when the only source is the bundle), 2 on
 * tooling errors (bad arguments, write failures). Network failures are
 * absorbed into the warnings array and never raise the exit code.
 *
 * Catalog schema (server, cache and bundle all use the same shape):
 *
 *   {
 *     "version": "<date or semver>",
 *     "servers": [
 *       {
 *         "name": "filesystem",
 *         "transport": "stdio_local",
 *         "package": "@modelcontextprotocol/server-filesystem",
 *         "version": "latest",
 *         "args": ["${USERPROFILE}"],
 *         "env": { "FOO": "bar" }
 *       },
 *       {
 *         "name": "shadcn",
 *         "transport": "http",
 *         "url": "https://omniroute.example.com/mcp/shadcn",
 *         "headers": { "Authorization": "Bearer ${OMNIROUTE_API_KEY}" }
 *       }
 *     ],
 *     "skills": [
 *       {
 *         "name": "frontend-tools",
 *         "version": "1.0.0",
 *         "content": "---\n...\n---\n# body"
 *       },
 *       {
 *         "name": "remote-skill",
 *         "version": "2.0.0",
 *         "sha256": "abc123...",
 *         "content_url": "/v1/skills/remote-skill@2.0.0"
 *       }
 *     ]
 *   }
 *
 * Variable expansion: ${VAR} in args/env/headers/url is expanded against
 * process.env at runtime. Unknown variables expand to the empty string and
 * generate a warning so the launcher can surface them.
 *
 * Dependencies: Node >= 18.18 stdlib only.
 */

import { createHash } from "node:crypto";
import { promises as fs } from "node:fs";
import path from "node:path";
import process from "node:process";

const DEFAULT_TIMEOUT_MS = 5000;

const argv = process.argv.slice(2);
const opts = {
  catalogUrl: "",
  apiKey: "",
  cachePath: "",
  bundlePath: "",
  tomlOut: "",
  isolatedHome: "",
  timeoutMs: DEFAULT_TIMEOUT_MS,
  disabled: false,
};

for (let i = 0; i < argv.length; i += 1) {
  const a = argv[i];
  if (a === "--catalog-url") opts.catalogUrl = argv[++i] || "";
  else if (a === "--api-key") opts.apiKey = argv[++i] || "";
  else if (a === "--cache") opts.cachePath = argv[++i] || "";
  else if (a === "--bundle") opts.bundlePath = argv[++i] || "";
  else if (a === "--toml-out") opts.tomlOut = argv[++i] || "";
  else if (a === "--isolated-home") opts.isolatedHome = argv[++i] || "";
  else if (a === "--timeout-ms") opts.timeoutMs = parseInt(argv[++i], 10) || DEFAULT_TIMEOUT_MS;
  else if (a === "--disabled") opts.disabled = true;
  else if (a === "-h" || a === "--help") {
    process.stdout.write(
      "Usage: omniroute-catalog.mjs --toml-out <path> --isolated-home <path>\n" +
      "                             [--catalog-url <url>] [--api-key <key>]\n" +
      "                             [--cache <path>] [--bundle <path>]\n" +
      "                             [--timeout-ms N] [--disabled]\n",
    );
    process.exit(0);
  }
}

if (!opts.tomlOut) bail("--toml-out is required");
if (!opts.isolatedHome) bail("--isolated-home is required");

const warnings = [];

function warn(message) {
  warnings.push(String(message));
}

function bail(message) {
  process.stderr.write(`omniroute-catalog: ${message}\n`);
  process.exit(2);
}

function preview(value, max = 200) {
  const s = String(value ?? "").replace(/\s+/g, " ").trim();
  return s.length > max ? `${s.slice(0, max)}...` : s;
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function expandEnvString(value) {
  if (typeof value !== "string") return value;
  return value.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g, (_, name) => {
    const raw = process.env[name];
    if (raw === undefined || raw === null || raw === "") {
      warn(`env var \${${name}} is not set; expanding to empty string`);
      return "";
    }
    return raw;
  });
}

function expandValue(value) {
  if (typeof value === "string") return expandEnvString(value);
  if (Array.isArray(value)) return value.map(expandValue);
  if (isPlainObject(value)) {
    const out = {};
    for (const [k, v] of Object.entries(value)) out[k] = expandValue(v);
    return out;
  }
  return value;
}

// ----------------------------------------------------------------------------
// TOML emission (mcp_servers.* blocks only -- the launcher consumes via
// Get-ImportableConfigBlocks which only honours the section header schema).
// ----------------------------------------------------------------------------

function tomlEscapeString(value) {
  const s = String(value ?? "");
  return '"' + s
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .replace(/\r/g, "\\r")
    .replace(/\n/g, "\\n")
    .replace(/\t/g, "\\t") + '"';
}

function tomlArray(values) {
  const items = values.map(tomlEscapeString).join(", ");
  return `[ ${items} ]`;
}

function tomlInlineTable(obj) {
  const parts = Object.entries(obj).map(([k, v]) => {
    const key = /^[A-Za-z_][A-Za-z0-9_-]*$/.test(k) ? k : tomlEscapeString(k);
    return `${key} = ${tomlEscapeString(v)}`;
  });
  return `{ ${parts.join(", ")} }`;
}

function emitMcpBlock(server) {
  const name = String(server.name || "").trim();
  if (!name) {
    warn("server entry without a name was skipped");
    return null;
  }
  if (!/^[A-Za-z0-9_.-]+$/.test(name)) {
    warn(`server name "${preview(name)}" has unsafe characters; skipped`);
    return null;
  }

  const transport = String(server.transport || "stdio_local").toLowerCase();
  const lines = [`[mcp_servers.${name}]`];

  if (transport === "stdio_local" || transport === "stdio") {
    let command;
    let args = [];
    if (server.package) {
      command = expandEnvString(server.command || "npx");
      const pkgRef = server.version
        ? `${server.package}@${server.version}`
        : String(server.package);
      args = ["-y", pkgRef, ...(Array.isArray(server.args) ? server.args : [])];
    } else if (server.command) {
      command = expandEnvString(server.command);
      args = Array.isArray(server.args) ? server.args : [];
    } else {
      warn(`stdio server "${name}" has neither package nor command; skipped`);
      return null;
    }
    lines.push(`command = ${tomlEscapeString(command)}`);
    if (args.length > 0) {
      lines.push(`args = ${tomlArray(args.map(expandValue))}`);
    }
    if (isPlainObject(server.env) && Object.keys(server.env).length > 0) {
      const env = expandValue(server.env);
      lines.push(`env = ${tomlInlineTable(env)}`);
    }
  } else if (transport === "http" || transport === "streamable_http" || transport === "sse") {
    if (!server.url) {
      warn(`http server "${name}" missing url; skipped`);
      return null;
    }
    lines.push(`transport = ${tomlEscapeString(transport === "stdio" ? "stdio" : "http")}`);
    lines.push(`url = ${tomlEscapeString(expandEnvString(server.url))}`);
    if (isPlainObject(server.headers) && Object.keys(server.headers).length > 0) {
      const headers = expandValue(server.headers);
      lines.push(`http_headers = ${tomlInlineTable(headers)}`);
    }
  } else {
    warn(`server "${name}" has unknown transport "${transport}"; skipped`);
    return null;
  }

  return lines.join("\n");
}

// ----------------------------------------------------------------------------
// Catalog loading: url -> cache -> bundle
// ----------------------------------------------------------------------------

async function fetchFromUrl(url, apiKey, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try { timer.unref(); } catch {}
  try {
    const headers = { accept: "application/json" };
    if (apiKey) headers.authorization = `Bearer ${apiKey}`;
    const resp = await fetch(url, { method: "GET", headers, signal: controller.signal });
    if (!resp.ok) {
      throw new Error(`HTTP ${resp.status} ${resp.statusText}`);
    }
    const text = await resp.text();
    return JSON.parse(text);
  } finally {
    clearTimeout(timer);
  }
}

async function readJsonFile(filePath) {
  const text = await fs.readFile(filePath, "utf8");
  return JSON.parse(text);
}

function validateCatalog(raw) {
  if (!isPlainObject(raw)) {
    throw new Error("catalog is not an object");
  }
  const servers = Array.isArray(raw.servers) ? raw.servers.filter(isPlainObject) : [];
  const skills = Array.isArray(raw.skills) ? raw.skills.filter(isPlainObject) : [];
  return { version: raw.version ? String(raw.version) : "", servers, skills };
}

async function loadCatalog() {
  if (opts.disabled) {
    return { source: "none", catalog: { version: "", servers: [], skills: [] } };
  }

  // 1) remote URL
  if (opts.catalogUrl) {
    try {
      const remote = await fetchFromUrl(opts.catalogUrl, opts.apiKey, opts.timeoutMs);
      const catalog = validateCatalog(remote);
      if (opts.cachePath) {
        try {
          await fs.mkdir(path.dirname(opts.cachePath), { recursive: true });
          await fs.writeFile(opts.cachePath, JSON.stringify(remote, null, 2), "utf8");
        } catch (err) {
          warn(`failed to write cache ${opts.cachePath}: ${err?.message || err}`);
        }
      }
      return { source: "url", catalog };
    } catch (err) {
      warn(`catalog fetch from ${opts.catalogUrl} failed: ${preview(err?.message || err)}`);
    }
  }

  // 2) cache
  if (opts.cachePath) {
    try {
      const cached = await readJsonFile(opts.cachePath);
      return { source: "cache", catalog: validateCatalog(cached) };
    } catch (err) {
      if (err && err.code !== "ENOENT") {
        warn(`catalog cache ${opts.cachePath} unreadable: ${preview(err?.message || err)}`);
      }
    }
  }

  // 3) bundle
  if (opts.bundlePath) {
    try {
      const bundle = await readJsonFile(opts.bundlePath);
      return { source: "bundle", catalog: validateCatalog(bundle) };
    } catch (err) {
      warn(`catalog bundle ${opts.bundlePath} unreadable: ${preview(err?.message || err)}`);
    }
  }

  return { source: "none", catalog: { version: "", servers: [], skills: [] } };
}

// ----------------------------------------------------------------------------
// Skill emission: validate sha256 (when provided), write SKILL.md
// ----------------------------------------------------------------------------

async function fetchSkillContent(skill, baseUrl) {
  if (typeof skill.content === "string") return skill.content;
  if (!skill.content_url) return null;
  let url = String(skill.content_url);
  if (!/^https?:\/\//i.test(url) && baseUrl) {
    try {
      url = new URL(url, baseUrl).toString();
    } catch (err) {
      warn(`skill "${skill.name}" content_url cannot be resolved: ${err?.message || err}`);
      return null;
    }
  }
  if (!/^https?:\/\//i.test(url)) {
    warn(`skill "${skill.name}" has relative content_url but no base url to resolve it`);
    return null;
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), opts.timeoutMs);
  try { timer.unref(); } catch {}
  try {
    const headers = {};
    if (opts.apiKey) headers.authorization = `Bearer ${opts.apiKey}`;
    const resp = await fetch(url, { method: "GET", headers, signal: controller.signal });
    if (!resp.ok) throw new Error(`HTTP ${resp.status} ${resp.statusText}`);
    return await resp.text();
  } finally {
    clearTimeout(timer);
  }
}

function sha256Hex(text) {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

async function writeSkills(skills, baseUrl) {
  const written = [];
  if (!skills || skills.length === 0) return written;

  const skillsRoot = path.join(opts.isolatedHome, "skills");
  await fs.mkdir(skillsRoot, { recursive: true });

  for (const skill of skills) {
    const name = String(skill.name || "").trim();
    if (!name) {
      warn("skill entry without a name was skipped");
      continue;
    }
    if (!/^[A-Za-z0-9_.-]+$/.test(name)) {
      warn(`skill name "${preview(name)}" has unsafe characters; skipped`);
      continue;
    }
    let body;
    try {
      body = await fetchSkillContent(skill, baseUrl);
    } catch (err) {
      warn(`skill "${name}" fetch failed: ${preview(err?.message || err)}`);
      continue;
    }
    if (typeof body !== "string" || body.length === 0) {
      warn(`skill "${name}" has empty body; skipped`);
      continue;
    }
    if (skill.sha256) {
      const expected = String(skill.sha256).toLowerCase();
      const actual = sha256Hex(body);
      if (expected !== actual) {
        warn(`skill "${name}" sha256 mismatch (expected ${preview(expected)}, got ${preview(actual)}); skipped`);
        continue;
      }
    }
    const dir = path.join(skillsRoot, name);
    try {
      await fs.mkdir(dir, { recursive: true });
      await fs.writeFile(path.join(dir, "SKILL.md"), body, "utf8");
      written.push(name);
    } catch (err) {
      warn(`skill "${name}" write failed: ${preview(err?.message || err)}`);
    }
  }
  return written;
}

// ----------------------------------------------------------------------------
// Main
// ----------------------------------------------------------------------------

async function main() {
  const { source, catalog } = await loadCatalog();
  const mcpNames = [];
  const tomlChunks = [];
  for (const server of catalog.servers) {
    const block = emitMcpBlock(server);
    if (block) {
      tomlChunks.push(block);
      mcpNames.push(server.name);
    }
  }

  const tomlText = tomlChunks.length > 0
    ? "# Generated by omniroute-catalog.mjs -- do not edit by hand\n" +
      tomlChunks.join("\n\n") + "\n"
    : "";

  try {
    await fs.mkdir(path.dirname(opts.tomlOut), { recursive: true });
    await fs.writeFile(opts.tomlOut, tomlText, "utf8");
  } catch (err) {
    bail(`failed to write ${opts.tomlOut}: ${err?.message || err}`);
  }

  let skillNames = [];
  try {
    skillNames = await writeSkills(catalog.skills, opts.catalogUrl);
  } catch (err) {
    warn(`skills emission failed: ${preview(err?.message || err)}`);
  }

  const status = {
    source,
    catalog_version: catalog.version || "",
    mcp_count: mcpNames.length,
    skill_count: skillNames.length,
    mcp_names: mcpNames,
    skill_names: skillNames,
    warnings,
  };
  process.stdout.write(JSON.stringify(status) + "\n");
}

main().catch((err) => {
  bail(err?.stack || err?.message || String(err));
});
