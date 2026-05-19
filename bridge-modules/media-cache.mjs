import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";

function noopLog() {}

function serializeError(error) {
  if (!error) return null;
  return {
    name: error.name,
    message: error.message,
    stack: error.stack,
  };
}

function mediaExtensionForMime(mime) {
  const normalized = String(mime || "").toLowerCase();
  if (normalized === "image/jpeg" || normalized === "image/jpg") return "jpg";
  if (normalized === "image/png") return "png";
  if (normalized === "image/webp") return "webp";
  if (normalized === "image/gif") return "gif";
  if (normalized === "image/heic") return "heic";
  return "img";
}

function parseDataImageUrl(url) {
  if (typeof url !== "string") return null;
  const match = /^data:([^;,]+)((?:;[^,]*)?),(.*)$/is.exec(url);
  if (!match) return null;
  const mime = match[1] || "image";
  if (!mime.toLowerCase().startsWith("image/")) return null;
  const flags = match[2] || "";
  const data = match[3] || "";
  try {
    const bytes = /;base64/i.test(flags)
      ? Buffer.from(data, "base64")
      : Buffer.from(decodeURIComponent(data), "utf8");
    if (bytes.length === 0) return null;
    return { mime, bytes };
  } catch {
    return null;
  }
}

export function createMediaCache(options = {}) {
  const {
    mediaCacheDir,
    mediaCacheMaxBytes = 0,
    mediaCacheMaxAgeMs = 0,
    mediaCacheGcIntervalMs = 5 * 60 * 1000,
    logBridge = noopLog,
  } = options;

  let lastMediaCacheGcAt = 0;

  function logBridgeError(message, error, details = {}) {
    logBridge("error", message, { ...details, error: serializeError(error) });
  }

  function ensureMediaCacheDir() {
    if (mediaCacheMaxBytes <= 0) return false;
    mkdirSync(mediaCacheDir, { recursive: true, mode: 0o700 });
    return true;
  }

  function removeMediaCacheEntry(entry) {
    for (const filePath of [entry.filePath, entry.metaPath]) {
      if (!filePath) continue;
      try {
        unlinkSync(filePath);
      } catch {
        // Best-effort cache cleanup.
      }
    }
  }

  function readMediaCacheEntries() {
    if (!existsSync(mediaCacheDir)) return [];

    const entries = [];
    for (const name of readdirSync(mediaCacheDir)) {
      if (!name.endsWith(".json")) continue;
      const metaPath = `${mediaCacheDir}/${name}`;
      let meta;
      try {
        meta = JSON.parse(readFileSync(metaPath, "utf8"));
      } catch {
        continue;
      }

      const fileName = typeof meta.fileName === "string" ? meta.fileName : "";
      const filePath = fileName ? `${mediaCacheDir}/${fileName}` : "";
      let stat;
      try {
        stat = filePath ? statSync(filePath) : null;
      } catch {
        removeMediaCacheEntry({ metaPath });
        continue;
      }

      const lastUsedAt = Date.parse(meta.lastUsedAt || meta.createdAt || "") || 0;
      entries.push({
        metaPath,
        filePath,
        bytes: stat?.size || Number(meta.bytes) || 0,
        lastUsedAt,
      });
    }

    return entries;
  }

  function maybeGcMediaCache(force = false) {
    if (mediaCacheMaxBytes <= 0) return;
    const now = Date.now();
    if (!force && now - lastMediaCacheGcAt < mediaCacheGcIntervalMs) return;
    lastMediaCacheGcAt = now;

    try {
      if (!ensureMediaCacheDir()) return;
      const entries = readMediaCacheEntries();
      const retained = [];
      let totalBytes = 0;
      let removedCount = 0;
      let removedBytes = 0;

      for (const entry of entries) {
        const expired = mediaCacheMaxAgeMs > 0 && now - entry.lastUsedAt > mediaCacheMaxAgeMs;
        if (expired) {
          removeMediaCacheEntry(entry);
          removedCount += 1;
          removedBytes += entry.bytes;
          continue;
        }
        retained.push(entry);
        totalBytes += entry.bytes;
      }

      if (totalBytes > mediaCacheMaxBytes) {
        retained.sort((a, b) => a.lastUsedAt - b.lastUsedAt);
        for (const entry of retained) {
          if (totalBytes <= mediaCacheMaxBytes) break;
          removeMediaCacheEntry(entry);
          totalBytes -= entry.bytes;
          removedCount += 1;
          removedBytes += entry.bytes;
        }
      }

      if (removedCount > 0) {
        logBridge("info", "media_cache_gc", {
          cacheDir: mediaCacheDir,
          removedCount,
          removedBytes,
          retainedBytes: Math.max(0, totalBytes),
          maxBytes: mediaCacheMaxBytes,
          maxAgeMs: mediaCacheMaxAgeMs,
        });
      }
    } catch (error) {
      logBridgeError("media_cache_gc_failed", error, { cacheDir: mediaCacheDir });
    }
  }

  function storeInlineImageInMediaCache(url, requestPath = "/v1/responses") {
    if (mediaCacheMaxBytes <= 0) return null;
    const parsed = parseDataImageUrl(url);
    if (!parsed) return null;

    try {
      if (!ensureMediaCacheDir()) return null;
      const sha256 = createHash("sha256").update(parsed.bytes).digest("hex");
      const extension = mediaExtensionForMime(parsed.mime);
      const fileName = `${sha256}.${extension}`;
      const filePath = `${mediaCacheDir}/${fileName}`;
      const metaPath = `${mediaCacheDir}/${sha256}.json`;
      const nowIso = new Date().toISOString();

      if (!existsSync(filePath)) {
        writeFileSync(filePath, parsed.bytes, { mode: 0o600 });
      }

      let createdAt = nowIso;
      try {
        const previousMeta = JSON.parse(readFileSync(metaPath, "utf8"));
        if (typeof previousMeta.createdAt === "string") {
          createdAt = previousMeta.createdAt;
        }
      } catch {
        // New cache entry.
      }

      writeFileSync(
        metaPath,
        `${JSON.stringify(
          {
            sha256,
            uri: `codex-media://${sha256}`,
            mime: parsed.mime,
            bytes: parsed.bytes.length,
            fileName,
            createdAt,
            lastUsedAt: nowIso,
            lastRequestPath: requestPath,
          },
          null,
          2,
        )}\n`,
        { mode: 0o600 },
      );

      maybeGcMediaCache();

      return {
        uri: `codex-media://${sha256}`,
        sha256,
        mime: parsed.mime,
        bytes: parsed.bytes.length,
        path: filePath,
      };
    } catch (error) {
      logBridgeError("media_cache_store_failed", error, {
        requestPath,
        cacheDir: mediaCacheDir,
        dataUrlBytes: Buffer.byteLength(String(url), "utf8"),
      });
      return null;
    }
  }

  return {
    maybeGcMediaCache,
    storeInlineImageInMediaCache,
  };
}
