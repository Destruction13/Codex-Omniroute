#!/usr/bin/env node
/*
 * Codex OmniRoute -- apply_patch wrapper (Node).
 *
 * Purpose
 * -------
 * Replace Codex's runtime-generated `apply_patch.bat` shim so that it
 * can robustly receive a multi-line patch from EITHER stdin or argv,
 * without being mangled by cmd.exe's quoting/newline handling.
 *
 * Codex's own bat is literally:
 *     @echo off
 *     "<absolute-path>\codex.exe" --codex-run-as-apply-patch %*
 *
 * This has two failure modes inside a non-AppX-activated Codex session:
 *
 *   1. The hardcoded absolute path points at the AppX-protected
 *      WindowsApps codex.exe -- "Access is denied". The
 *      apply_patch-rewriter.mjs daemon rewrites the bat to point at the
 *      user-local copy so this no longer happens.
 *
 *   2. cmd.exe's `%*` flattens / mangles multi-line arguments. When the
 *      agent shell invokes `apply_patch $patch` from PowerShell with
 *      `$patch` being a multi-line here-string, the patch reaches the
 *      bat as one argument, BUT internal newlines / trailing whitespace
 *      get rewritten in unexpected ways. codex.exe then complains
 *      "Invalid patch: The last line of the patch must be '*** End Patch'".
 *      And piping the patch into the bat (`$patch | apply_patch`) does
 *      nothing useful because the bat's `%*` is empty (stdin is not
 *      forwarded).
 *
 * This wrapper bypasses both problems by replacing the bat body with
 *
 *     @echo off
 *     node "<path>\apply_patch-wrapper.mjs" "<codex.exe>" %*
 *
 * The wrapper:
 *   - reads patch text from argv[3..] joined with newlines (this is
 *     reasonably robust for the single-arg PowerShell case where
 *     cmd.exe stuffs everything into one big argv entry),
 *   - if that does not look like a valid patch, falls back to reading
 *     stdin (UTF-8),
 *   - normalizes CRLF to LF and trims trailing whitespace so codex.exe
 *     does not bail with "last line must be *** End Patch",
 *   - invokes <codex.exe> --codex-run-as-apply-patch <patch> via
 *     CreateProcess (Node child_process), so the final argument is
 *     passed cleanly without going back through cmd.exe.
 *
 * Either way, the patch reaches codex.exe in its canonical form. This
 * is a behaviorally-transparent fix: same Codex binary, same flag, same
 * outcome; only the input plumbing changes.
 */
import fs from "node:fs";
import { spawnSync } from "node:child_process";
import process from "node:process";

const codexExe = process.argv[2];
if (!codexExe) {
  process.stderr.write("apply_patch-wrapper: missing codex.exe path (argv[2])\n");
  process.exit(64);
}

function looksLikePatch(s) {
  return typeof s === "string" && s.includes("*** Begin Patch") && s.includes("*** End Patch");
}

function normalize(s) {
  if (typeof s !== "string") return s;
  // Strip BOM, normalize CRLF -> LF, strip trailing whitespace so the
  // last line is exactly the literal "*** End Patch" Codex expects.
  return s
    .replace(/^\uFEFF/, "")
    .replace(/\r\n/g, "\n")
    .replace(/\s+$/, "");
}

// Try the args path first. PowerShell normally collapses a multi-line
// here-string into a single argv entry by the time we see it; cmd.exe's
// %* expansion preserves that single entry. Joining with "\n" handles
// the rare case where cmd splits on internal newlines into separate
// argv entries.
let patch = process.argv.slice(3).join("\n");
patch = normalize(patch);

if (!looksLikePatch(patch)) {
  // Fall back to stdin. apply_patch invocations from PowerShell via
  // `$patch | apply_patch` end up here.
  try {
    const stdinBuf = fs.readFileSync(0);
    const stdinPatch = normalize(stdinBuf.toString("utf8"));
    if (looksLikePatch(stdinPatch)) patch = stdinPatch;
  } catch {
    // No stdin available; leave patch as whatever argv produced.
  }
}

if (!looksLikePatch(patch)) {
  process.stderr.write(
    "apply_patch-wrapper: no valid patch found in argv or stdin (must contain *** Begin Patch and *** End Patch)\n",
  );
  process.exit(64);
}

const result = spawnSync(
  codexExe,
  ["--codex-run-as-apply-patch", patch],
  { stdio: "inherit", windowsHide: true },
);
if (result.error) {
  process.stderr.write(`apply_patch-wrapper: spawn failed: ${result.error.message}\n`);
  process.exit(127);
}
process.exit(result.status ?? 0);
