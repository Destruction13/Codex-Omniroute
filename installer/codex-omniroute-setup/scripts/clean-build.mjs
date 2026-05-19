import { rm } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(here, "..");

for (const name of ["dist", "dist-electron"]) {
  await rm(path.join(projectRoot, name), { recursive: true, force: true });
}
