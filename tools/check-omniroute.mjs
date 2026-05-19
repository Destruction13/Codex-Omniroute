#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';

const files = [
  'codex-openai-omniroute-bridge.mjs',
  'bridge-modules/tool-adapters.mjs',
  'bridge-modules/media-cache.mjs',
  'tools/apply_patch-rewriter.mjs',
  'tools/mcp_probe.mjs',
  'tools/omniroute-catalog.mjs',
  'tools/omniroute-mcp-registry.mjs',
  'tools/mcp-tool-alias-proxy.mjs',
];

let failed = false;
for (const file of files) {
  if (!existsSync(file)) {
    console.warn(`[check] skip missing ${file}`);
    continue;
  }
  const result = spawnSync(process.execPath, ['--check', file], {
    stdio: 'inherit',
    windowsHide: true,
  });
  if (result.status !== 0) {
    failed = true;
  }
}

if (failed) {
  process.exit(1);
}

console.log(`[check] ${files.length} OmniRoute JavaScript module(s) checked`);
