import { app, BrowserWindow, dialog, ipcMain, shell } from "electron";
import type { BrowserWindow as BrowserWindowType, OpenDialogOptions } from "electron";
import fsSync from "node:fs";
import os from "node:os";
import path from "node:path";

import {
  createInitialSnapshot,
  getDefaultInstallDir,
  launchInstalledOmniRoute,
  parseHeadlessRequest,
  SetupRunner,
} from "./setup-runner.cjs";
import type { InstallRequest, SetupEvent, SetupSnapshot } from "./types.cjs";

let mainWindow: BrowserWindowType | null = null;
let currentSnapshot: SetupSnapshot = createInitialSnapshot();
let currentRunner: SetupRunner | null = null;

const writeDebug = (message: string): void => {
  if (process.env.CODEX_OMNI_SETUP_DEBUG_LOG !== "1") {
    return;
  }
  const debugPath = path.join(os.tmpdir(), "codex-omniroute-setup-debug.log");
  fsSync.appendFileSync(debugPath, `${new Date().toISOString()} ${message}\n`, "utf8");
};

writeDebug(`main loaded: ${process.argv.join(" | ")}`);
process.stdout.on("error", (error) => {
  writeDebug(`stdout error: ${error.message}`);
});
process.stderr.on("error", (error) => {
  writeDebug(`stderr error: ${error.message}`);
});
process.on("uncaughtException", (error) => {
  writeDebug(`uncaughtException: ${error.stack ?? error.message}`);
});
process.on("unhandledRejection", (error) => {
  writeDebug(`unhandledRejection: ${String(error)}`);
});

const emitSetupEvent = (event: SetupEvent): void => {
  if (event.type === "state" || event.type === "done" || event.type === "error") {
    currentSnapshot = event.snapshot;
  }
  mainWindow?.webContents.send("setup:event", event);
};

const createWindow = async (): Promise<void> => {
  writeDebug("createWindow:start");
  mainWindow = new BrowserWindow({
    width: 1120,
    height: 760,
    minWidth: 920,
    minHeight: 640,
    title: "Codex OmniRoute Setup",
    backgroundColor: "#0b0d10",
    titleBarStyle: "hidden",
    titleBarOverlay: {
      color: "#0b0d10",
      symbolColor: "#f2f5ec",
      height: 38,
    },
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });

  if (app.isPackaged) {
    writeDebug(`load packaged file: ${path.join(app.getAppPath(), "dist", "index.html")}`);
    await mainWindow.loadFile(path.join(app.getAppPath(), "dist", "index.html"));
  } else {
    writeDebug(`load dev file: ${path.join(__dirname, "..", "dist", "index.html")}`);
    await mainWindow.loadFile(path.join(__dirname, "..", "dist", "index.html"));
  }
  mainWindow.on("closed", () => {
    writeDebug("mainWindow:closed");
  });
  writeDebug("createWindow:loaded");
};

ipcMain.handle("setup:get-defaults", () => ({
  installDir: getDefaultInstallDir(),
  snapshot: currentSnapshot,
}));

ipcMain.handle("setup:select-install-dir", async (_event, current?: string) => {
  const options: OpenDialogOptions = {
    title: "Select install folder",
    defaultPath: current || getDefaultInstallDir(),
    properties: ["openDirectory", "createDirectory"],
  } as const;
  const result = mainWindow
    ? await dialog.showOpenDialog(mainWindow, options)
    : await dialog.showOpenDialog(options);
  if (result.canceled || result.filePaths.length === 0) {
    return null;
  }
  return result.filePaths[0] ?? null;
});

ipcMain.handle("setup:start", async (_event, request: InstallRequest) => {
  if (currentRunner) {
    throw new Error("Setup is already running.");
  }
  currentRunner = new SetupRunner(emitSetupEvent);
  try {
    await currentRunner.run(request);
  } finally {
    currentRunner = null;
  }
});

ipcMain.handle("setup:open-log", async () => {
  if (currentSnapshot.logPath) {
    await shell.openPath(currentSnapshot.logPath);
  }
});

ipcMain.handle("setup:launch-installed", async () => {
  if (!currentSnapshot.repoRoot) {
    throw new Error("Codex OmniRoute is not installed yet.");
  }
  await launchInstalledOmniRoute(currentSnapshot.repoRoot);
});

const runHeadless = async (request: InstallRequest): Promise<void> => {
  const runner = new SetupRunner((event) => {
    if (event.type === "state") {
      const active = event.snapshot.steps.find((step) => step.status === "running");
      if (active) {
        writeDebug(`[setup] ${active.title}: ${active.detail}`);
      }
    }
    if (event.type === "error") {
      writeDebug(`[setup] ${event.message}`);
    }
  });
  const result = await runner.run(request);
  writeDebug(`headless complete: ${result.status}`);
  app.exit(result.status === "success" ? 0 : 1);
};

app.whenReady().then(async () => {
  writeDebug("app:ready");
  const headless = parseHeadlessRequest(process.argv.slice(1));
  writeDebug(`headless: ${headless ? "yes" : "no"}`);
  if (headless) {
    await runHeadless(headless);
    return;
  }

  await createWindow();
});

app.on("window-all-closed", () => {
  writeDebug("window-all-closed");
  if (process.platform !== "darwin") {
    app.quit();
  }
});

app.on("activate", async () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    await createWindow();
  }
});
