#!/usr/bin/env node
/*
 * Codex OmniRoute -- apply_patch.bat rewriter.
 *
 * Legacy fallback for older Windows builds. The shared-home launcher no longer
 * starts this watcher by default because it enables native
 * features.apply_patch_freeform through process-level overrides. Keep this
 * helper for machines where live testing proves the native path still fails.
 *
 * Codex creates a per-session `apply_patch.bat` under
 *   $CODEX_HOME/tmp/arg0/codex-arg0.../apply_patch.bat
 * The default wrapper points at the Microsoft Store package resources under
 * WindowsApps. That works only in some packaged-process contexts and fails
 * from ordinary child shells with "Access is denied".
 *
 * This watcher keeps those generated wrappers pointed at
 * tools\Invoke-CodexApplyPatch.ps1, which accepts stdin or argv payloads and
 * forwards them to the launchable local Codex CLI under
 * %LOCALAPPDATA%\OpenAI\Codex\bin\codex.exe.
 */
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const argv = process.argv.slice(2);
const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const opts = {
  home: process.env.CODEX_HOME || path.join(os.homedir(), ".codex"),
  codex: "",
  helper: path.join(scriptDir, "Invoke-CodexApplyPatch.ps1"),
  intervalMs: 500,
  once: false,
  quiet: false,
};

for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--home") opts.home = argv[++i] || opts.home;
  else if (a === "--codex") opts.codex = argv[++i] || opts.codex;
  else if (a === "--helper") opts.helper = argv[++i] || opts.helper;
  else if (a === "--interval-ms") opts.intervalMs = Math.max(100, parseInt(argv[++i], 10) || opts.intervalMs);
  else if (a === "--once") opts.once = true;
  else if (a === "--quiet") opts.quiet = true;
  else if (a === "-h" || a === "--help") {
    process.stdout.write(
      "Usage: node apply_patch-rewriter.mjs --home <CODEX_HOME> --codex <local-codex.exe> [--helper Invoke-CodexApplyPatch.ps1] [--once]\n",
    );
    process.exit(0);
  }
}

function log(msg) {
  if (!opts.quiet) process.stdout.write(`[apply-patch-rewriter] ${msg}\n`);
}

function isFile(p) {
  try {
    return fs.statSync(p).isFile();
  } catch {
    return false;
  }
}

function resolveLocalCodex() {
  const candidates = [];
  if (opts.codex) candidates.push(opts.codex);
  if (process.env.LOCALAPPDATA) {
    candidates.push(path.join(process.env.LOCALAPPDATA, "OpenAI", "Codex", "bin", "codex.exe"));
  }
  for (const candidate of candidates) {
    if (!candidate) continue;
    if (/\\WindowsApps\\/i.test(candidate)) continue;
    if (isFile(candidate)) return path.resolve(candidate);
  }
  throw new Error("Could not find local codex.exe. Expected %LOCALAPPDATA%\\OpenAI\\Codex\\bin\\codex.exe.");
}

const localCodex = resolveLocalCodex();
if (!isFile(opts.helper)) {
  throw new Error(`Could not find apply_patch helper: ${opts.helper}`);
}
const arg0Root = path.join(path.resolve(opts.home), "tmp", "arg0");
const helperForPowerShell = path.resolve(opts.helper).replace(/'/g, "''");
const desired = [
  "@echo off",
  `powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$patch = [Console]::In.ReadToEnd(); if ([string]::IsNullOrEmpty($patch) -and $args.Count -gt 0) { $patch = $args -join ' ' }; & '${helperForPowerShell}' $patch" %*`,
  "",
].join("\r\n");

function walkApplyPatchBat(root) {
  const out = [];
  let entries = [];
  try {
    entries = fs.readdirSync(root, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const entry of entries) {
    const p = path.join(root, entry.name);
    if (entry.isDirectory()) {
      out.push(...walkApplyPatchBat(p));
    } else if (entry.isFile() && entry.name.toLowerCase() === "apply_patch.bat") {
      out.push(p);
    }
  }
  return out;
}

function rewriteOnce() {
  let changed = 0;
  for (const bat of walkApplyPatchBat(arg0Root)) {
    let current = "";
    try {
      current = fs.readFileSync(bat, "utf8");
    } catch {
      continue;
    }
    if (current === desired) continue;
    try {
      fs.writeFileSync(bat, desired, "utf8");
      changed++;
      log(`rewrote ${bat}`);
    } catch (err) {
      process.stderr.write(`[apply-patch-rewriter] failed to rewrite ${bat}: ${err?.message || err}\n`);
    }
  }
  return changed;
}

try {
  fs.mkdirSync(arg0Root, { recursive: true });
} catch {
  /* Codex may create it later; polling still works. */
}

rewriteOnce();

if (opts.once) {
  process.exit(0);
}

log(`watching ${arg0Root}`);
const timer = setInterval(rewriteOnce, opts.intervalMs);

for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(sig, () => process.exit(0));
}
