export type StepStatus =
  | "pending"
  | "running"
  | "success"
  | "warning"
  | "error"
  | "skipped";

export interface SetupStepSnapshot {
  id: string;
  title: string;
  detail: string;
  status: StepStatus;
  startedAt?: string;
  finishedAt?: string;
  log: string[];
}

export interface InstallRequest {
  installDir: string;
  baseUrl: string;
  apiKey: string;
  imageApiKey?: string;
  installRecommendedTools: boolean;
  launchAfterInstall: boolean;
  repoBranch?: string;
  skipShortcuts?: boolean;
}

export interface SetupSnapshot {
  status: "idle" | "running" | "success" | "error";
  installRoot?: string;
  repoRoot?: string;
  logPath?: string;
  error?: string;
  steps: SetupStepSnapshot[];
}

export type SetupEvent =
  | { type: "state"; snapshot: SetupSnapshot }
  | { type: "done"; snapshot: SetupSnapshot }
  | { type: "error"; snapshot: SetupSnapshot; message: string };

export interface ProcessResult {
  code: number;
  stdout: string;
  stderr: string;
}

export interface PowerShellHost {
  exe: string;
  label: string;
}
