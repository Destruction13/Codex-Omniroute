/// <reference types="vite/client" />

type SetupStepStatus =
  | "pending"
  | "running"
  | "success"
  | "warning"
  | "error"
  | "skipped";

interface SetupStepSnapshot {
  id: string;
  title: string;
  detail: string;
  status: SetupStepStatus;
  startedAt?: string;
  finishedAt?: string;
  log: string[];
}

interface InstallRequest {
  installDir: string;
  baseUrl: string;
  apiKey: string;
  installRecommendedTools: boolean;
  launchAfterInstall: boolean;
  repoBranch?: string;
  skipShortcuts?: boolean;
}

interface ProviderVerificationRequest {
  baseUrl: string;
  apiKey: string;
}

interface ProviderVerificationResult {
  endpoint: string;
  matchedModel: string;
  modelCount: number;
}

interface SetupSnapshot {
  status: "idle" | "running" | "success" | "error";
  installRoot?: string;
  repoRoot?: string;
  logPath?: string;
  error?: string;
  steps: SetupStepSnapshot[];
}

interface LaunchResult {
  processId: number;
  executablePath: string;
  bridgePort: number;
  providerPath: string;
}

type SetupEvent =
  | { type: "state"; snapshot: SetupSnapshot }
  | { type: "done"; snapshot: SetupSnapshot }
  | { type: "error"; snapshot: SetupSnapshot; message: string };

interface OmniSetupApi {
  getDefaults: () => Promise<{ installDir: string; snapshot: SetupSnapshot }>;
  selectInstallDir: (current?: string) => Promise<string | null>;
  verifyProvider: (
    request: ProviderVerificationRequest
  ) => Promise<ProviderVerificationResult>;
  startInstall: (request: InstallRequest) => Promise<void>;
  launchInstalled: () => Promise<LaunchResult>;
  openLog: () => Promise<void>;
  onEvent: (callback: (event: SetupEvent) => void) => () => void;
}

interface Window {
  omniSetup?: OmniSetupApi;
}
