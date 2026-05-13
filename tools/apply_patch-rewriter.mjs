#!/usr/bin/env node
/*
 * Codex OmniRoute -- apply_patch.bat rewriter daemon.
 *
 * Why this exists
 * ---------------
 * Codex Desktop creates `apply_patch.bat` at runtime in
 * `<CODEX_HOME>/tmp/arg0/codex-arg0XXXXX/apply_patch.bat` (the
 * subdirectory name is random per session). The bat hardcodes an
 * absolute path to a specific `codex.exe`:
 *
 *     @echo off
 *     "C:\Program Files\WindowsApps\OpenAI.Codex_<ver>\app\resources\codex.exe" --codex-run-as-apply-patch %*
 *
 * That WindowsApps codex.exe is only invocable from a process holding
 * AppX package identity. Codex Desktop itself holds the identity, but
 * the package identity does NOT propagate to the shells Codex spawns
 * for the agent, so when the agent invokes `apply_patch.bat`, the bat's
 * spawn of codex.exe fails with "Access is denied" and the apply_patch
 * tool call dies.
 *
 * Independent mitigations we ship in the launcher:
 *   1. `experimental_use_freeform_apply_patch = true` in the managed
 *      config -- routes apply_patch through an in-process freeform tool
 *      that never touches the bat. Empirically not always honored.
 *   2. `apply_patch.bat` shim in our user-local Codex bin dir, kept
 *      first on PATH -- works for PATH-resolved invocations, but Codex
 *      prepends its session-tmp dir AHEAD of our bin on the agent
 *      shell's PATH, so this shim is shadowed.
 *
 * This rewriter is the last line of defense. It polls
 * `<CODEX_HOME>/tmp/arg0/` for `<subdir>/apply_patch.bat` files. When
 * one appears with the WindowsApps hardcoded path, it rewrites the
 * file in place to invoke the user-local codex.exe (which lives
 * outside WindowsApps and has no AppX containment issues). The agent
 * then calls the SAME bat path Codex generated, but the bat now points
 * at a working binary.
 *
 * Operational notes:
 *   - Single-process daemon; runs detached, like the bridge.
 *   - Idempotent: a bat that's already been rewritten is left alone.
 *   - Conservative: only rewrites bats whose content matches the exact
 *     WindowsApps Codex install pattern. Anything else is left as is.
 *   - Polls every 500 ms. Bat is created at session start, called
 *     much later when the agent decides to use apply_patch, so polling
 *     is comfortably fast enough.
 *
 * Usage:
 *   node apply_patch-rewriter.mjs <CODEX_HOME> <USER_LOCAL_CODEX_EXE> [<APPLY_PATCH_WRAPPER_JS>]
 *
 * When the optional wrapper-mjs path is supplied, the bat is rewritten
 * to invoke a Node-side helper (apply_patch-wrapper.mjs) instead of
 * codex.exe directly. The wrapper handles stdin/argv robustly and
 * normalizes CRLF/whitespace, so the bat works under both pipe-style
 * invocation (`$patch | apply_patch`) and positional-arg invocation
 * (`apply_patch $patch`) from a PowerShell agent shell -- where cmd.exe
 * would otherwise mangle the multi-line argument and codex.exe would
 * reject the patch as malformed.
 */
import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const codexHome = process.argv[2] || process.env.CODEX_HOME;
const targetExe = process.argv[3];
const wrapperMjs = process.argv[4]; // optional

if (!codexHome) {
  console.error("error: CODEX_HOME is required (argv[2] or env)");
  process.exit(64);
}
if (!targetExe) {
  console.error("error: target codex.exe path is required (argv[3])");
  process.exit(64);
}

const watchRoot = path.join(codexHome, "tmp", "arg0");
const logPath   = path.join(codexHome, "apply-patch-rewriter.log");
const pidPath   = path.join(codexHome, "apply-patch-rewriter.pid");

const APPX_RE   = /"[^"]*\\Program Files\\WindowsApps\\OpenAI\.Codex[^"]+\\codex\.exe"\s*--codex-run-as-apply-patch\s*%\*/i;
const RAW_EXE   = targetExe.replace(/"/g, '\\"');
const RAW_WRAP  = wrapperMjs ? wrapperMjs.replace(/"/g, '\\"') : null;

function log(msg) {
  try {
    fs.appendFileSync(logPath, `[${new Date().toISOString()}] ${msg}\n`);
  } catch { /* ignore */ }
}

function shouldRewrite(content) {
  // Rewrite if the bat still uses the WindowsApps-protected codex.exe,
  // OR (when we know the wrapper path) if it does not already go through
  // our wrapper -- so a stale rewrite that only swapped the codex.exe
  // path but did not route through the wrapper gets upgraded the next
  // time we see it.
  if (APPX_RE.test(content)) return true;
  if (RAW_WRAP) {
    return !content.includes(RAW_WRAP);
  }
  return false;
}

function rewriteIfBroken(filePath) {
  let content;
  try { content = fs.readFileSync(filePath, "utf8"); }
  catch { return; }
  if (!shouldRewrite(content)) return;

  let fixed;
  if (RAW_WRAP) {
    // Replace the entire bat body with one that calls our Node wrapper.
    // The wrapper handles stdin/argv robustly and finally invokes
    // <codex.exe> --codex-run-as-apply-patch <patch> via CreateProcess.
    fixed = `@echo off\r\nnode "${RAW_WRAP}" "${RAW_EXE}" %*\r\n`;
  } else {
    // Fallback: just patch the hardcoded path. cmd.exe %* quirks still
    // apply, but at least Access Denied is avoided.
    fixed = content.replace(
      APPX_RE,
      `"${RAW_EXE}" --codex-run-as-apply-patch %*`,
    );
  }
  try {
    fs.writeFileSync(filePath, fixed);
    log(`rewrote ${filePath}`);
  } catch (e) {
    log(`failed to rewrite ${filePath}: ${e?.message || e}`);
  }
}

function scan() {
  let entries;
  try { entries = fs.readdirSync(watchRoot, { withFileTypes: true }); }
  catch { return; }                              // root doesn't exist yet
  for (const e of entries) {
    if (!e.isDirectory()) continue;
    const batPath = path.join(watchRoot, e.name, "apply_patch.bat");
    if (fs.existsSync(batPath)) rewriteIfBroken(batPath);
  }
}

// Ensure parent dirs exist; if missing now, polling will pick them up
// when Codex Desktop creates them.
try { fs.mkdirSync(watchRoot, { recursive: true }); } catch {}

try {
  fs.writeFileSync(pidPath, String(process.pid));
} catch (e) {
  log(`failed to write pid file: ${e?.message || e}`);
}

log(`started pid=${process.pid} watching=${watchRoot} target=${targetExe}`);

// Initial pass + steady polling. The poll interval is generous because
// the bat is created at session start and only invoked when the agent
// makes an apply_patch tool call later.
scan();
setInterval(scan, 500).unref?.();

// Swallow EPIPE so the daemon survives parent-pipe teardown after
// detach (same trick the bridge uses).
process.stdout.on?.("error", () => {});
process.stderr.on?.("error", () => {});

for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(sig, () => {
    log(`received ${sig}, exiting`);
    try { fs.unlinkSync(pidPath); } catch {}
    process.exit(0);
  });
}

// Keep the event loop alive forever.
setInterval(() => {}, 60_000);
