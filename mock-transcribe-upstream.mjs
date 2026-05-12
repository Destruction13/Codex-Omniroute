#!/usr/bin/env node
/*
 * Mock transcription upstream used by tests.
 *
 * Mimics the official Codex transcription endpoint. Default port 21555.
 * Point the bridge at it for offline tests by setting:
 *   CODEX_OFFICIAL_UPSTREAM=http://127.0.0.1:21555
 *
 * Returns a fixed { text } payload regardless of input. Logs Content-Length,
 * decoded base64 envelope presence, and content-type to stdout. Never echoes
 * the body itself.
 */

import http from "node:http";
import { Buffer } from "node:buffer";

const PORT = parseInt(process.env.MOCK_TRANSCRIBE_PORT || "21555", 10);
const HOST = process.env.MOCK_TRANSCRIBE_HOST || "127.0.0.1";

const server = http.createServer(async (req, res) => {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const body = Buffer.concat(chunks);

  const ct = req.headers["content-type"] || "";
  const enc = req.headers["content-encoding"] || "";
  const b64 = req.headers["x-codex-base64"] || "";

  process.stdout.write(
    JSON.stringify({
      ts: new Date().toISOString(),
      method: req.method,
      url: req.url,
      content_type: ct,
      content_encoding: enc,
      base64_flag: b64,
      bytes: body.length,
    }) + "\n",
  );

  if (req.url && req.url.endsWith("/audio/transcriptions")) {
    res.statusCode = 200;
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ text: "(mock transcription)" }));
    return;
  }
  res.statusCode = 404;
  res.setHeader("content-type", "application/json");
  res.end(JSON.stringify({ error: "not_found", url: req.url }));
});

server.listen(PORT, HOST, () => {
  process.stdout.write(`mock-transcribe-upstream listening on http://${HOST}:${PORT}\n`);
});
