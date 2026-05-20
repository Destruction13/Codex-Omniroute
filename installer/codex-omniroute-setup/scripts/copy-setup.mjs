import { copyFile, mkdir, stat } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(here, "..");
const repoRoot = path.resolve(projectRoot, "..", "..");
const builtSetup = path.join(projectRoot, "release", "CodexOmniRouteSetup.exe");
const rootSetup = path.join(repoRoot, "Setup.exe");

await stat(builtSetup);
await mkdir(repoRoot, { recursive: true });
await copyFile(builtSetup, rootSetup);

console.log(`[setup-package] copied ${builtSetup} -> ${rootSetup}`);
