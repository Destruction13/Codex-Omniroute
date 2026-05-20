import { contextBridge, ipcRenderer } from "electron";
import type { IpcRendererEvent } from "electron";

import type { InstallRequest, LaunchResult, SetupEvent, SetupSnapshot } from "./types.cjs";

const api = {
  getDefaults: (): Promise<{ installDir: string; snapshot: SetupSnapshot }> =>
    ipcRenderer.invoke("setup:get-defaults"),
  selectInstallDir: (current?: string): Promise<string | null> =>
    ipcRenderer.invoke("setup:select-install-dir", current),
  startInstall: (request: InstallRequest): Promise<void> =>
    ipcRenderer.invoke("setup:start", request),
  launchInstalled: (): Promise<LaunchResult> => ipcRenderer.invoke("setup:launch-installed"),
  openLog: (): Promise<void> => ipcRenderer.invoke("setup:open-log"),
  onEvent: (callback: (event: SetupEvent) => void): (() => void) => {
    const listener = (_: IpcRendererEvent, event: SetupEvent) => callback(event);
    ipcRenderer.on("setup:event", listener);
    return () => ipcRenderer.removeListener("setup:event", listener);
  },
};

contextBridge.exposeInMainWorld("omniSetup", api);
