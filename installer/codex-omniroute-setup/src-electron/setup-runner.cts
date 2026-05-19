import AdmZip from "adm-zip";
import { app, shell } from "electron";
import { spawn } from "node:child_process";
import { constants as fsConstants } from "node:fs";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import type {
  InstallRequest,
  LaunchResult,
  PowerShellHost,
  ProcessResult,
  SetupEvent,
  SetupSnapshot,
  SetupStepSnapshot,
  StepStatus,
} from "./types.cjs";

const REPO_URL =
  process.env.CODEX_OMNI_SETUP_REPO_URL ??
  "https://github.com/Destruction13/Codex-Omniroute.git";
const DEFAULT_REPO_BRANCH =
  process.env.CODEX_OMNI_SETUP_REPO_BRANCH ?? "main";
const CODEX_STORE_PRODUCT_ID = "9PLM9XGG6VKS";
const APP_INSTALLER_PRODUCT_ID = "9NBLGGH4NNS1";

const STEP_DEFINITIONS = [
  ["preflight", "Windows preflight"],
  ["powershell", "PowerShell host"],
  ["winget", "App Installer / winget"],
  ["codex", "Official Codex Store app"],
  ["recommended", "Windows developer tools"],
  ["source", "Codex OmniRoute source"],
  ["local-deps", "Local Node.js and .NET"],
  ["provider", "OmniRoute provider config"],
  ["gateway", "Gateway, wrapper, shortcuts"],
  ["verify", "Architecture verifier"],
  ["launch", "Launch Codex OmniRoute"],
] as const;

interface RunProcessOptions {
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  timeoutMs?: number;
  logStepId?: string;
}

interface ToolPackage {
  id: string;
  label: string;
  probe: () => Promise<boolean>;
}

export function createInitialSnapshot(): SetupSnapshot {
  return {
    status: "idle",
    steps: STEP_DEFINITIONS.map(([id, title]) => ({
      id,
      title,
      detail: "Waiting",
      status: "pending",
      log: [],
    })),
  };
}

export function getDefaultInstallDir(): string {
  return path.join(os.homedir(), "CodexOmniRoute");
}

interface OmniRouteProcess {
  processId: number;
  executablePath: string;
  commandLine: string;
}

interface BridgeHealthProbe {
  port: number;
  source: string;
}

export async function launchInstalledOmniRoute(repoRoot: string): Promise<LaunchResult> {
  const resolvedRoot = path.resolve(repoRoot);
  const script = path.join(resolvedRoot, "Start-Codex-OmniRoute.ps1");
  const providerPath = path.join(resolvedRoot, "omniroute-provider.json");
  if (!(await exists(script))) {
    throw new Error(`Codex OmniRoute launcher was not found: ${script}`);
  }
  if (!(await exists(providerPath))) {
    throw new Error(`OmniRoute provider config was not found: ${providerPath}`);
  }

  const powerShell = await findPowerShellHost();
  await spawnDetached(
    powerShell.exe,
    [
      "-NoLogo",
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      script,
    ],
    resolvedRoot,
  );

  const result = await waitForLaunchedOmniRoute(resolvedRoot, providerPath, 60_000);
  await focusOmniRouteWindow(result.processId).catch(() => undefined);
  return result;
}

export function parseHeadlessRequest(argv: string[]): InstallRequest | null {
  if (!argv.includes("--headless-install")) {
    return null;
  }

  const readValue = (name: string): string => {
    const index = argv.indexOf(name);
    if (index < 0 || index + 1 >= argv.length) {
      return "";
    }
    return argv[index + 1] ?? "";
  };

  return {
    installDir: readValue("--install-dir") || getDefaultInstallDir(),
    baseUrl: readValue("--base-url"),
    apiKey: readValue("--api-key"),
    imageApiKey: readValue("--image-api-key"),
    repoBranch: readValue("--repo-branch") || undefined,
    installRecommendedTools: !argv.includes("--skip-recommended"),
    launchAfterInstall: !argv.includes("--no-launch"),
    skipShortcuts: argv.includes("--skip-shortcuts"),
  };
}

export class SetupRunner {
  private snapshot = createInitialSnapshot();
  private logPath = "";
  private redactions: string[] = [];

  constructor(private readonly emit: (event: SetupEvent) => void) {}

  async run(request: InstallRequest): Promise<SetupSnapshot> {
    this.redactions = [request.apiKey, request.imageApiKey ?? ""].filter(
      (value) => value.trim().length > 0,
    );
    await this.prepareLogFile();
    this.snapshot = {
      ...createInitialSnapshot(),
      status: "running",
      logPath: this.logPath,
      installRoot: path.resolve(request.installDir),
    };
    this.publish();

    try {
      const normalized = this.validateRequest(request);
      const powerShell = await this.runStep("preflight", "Checking OS and install path", async () => {
        if (process.platform !== "win32") {
          throw new Error("This installer is only supported on Windows.");
        }
        await fs.mkdir(normalized.installDir, { recursive: true });
        await fs.access(normalized.installDir, fsConstants.W_OK);
        return "Install parent is writable.";
      }).then(() => this.ensurePowerShell());

      const codexBefore = await this.getCodexPackage(powerShell);
      const winget = await this.ensureWinget(
        powerShell,
        normalized.installRecommendedTools || !codexBefore,
      );

      await this.ensureOfficialCodex(powerShell, winget, codexBefore);
      await this.installRecommendedTools(winget, normalized.installRecommendedTools);

      const repoRoot = await this.ensureSource(normalized);
      this.snapshot.repoRoot = repoRoot;
      this.publish();

      await this.ensureLocalDependencies(powerShell, repoRoot);
      await this.writeProviderConfig(repoRoot, normalized);
      await this.prepareGateway(powerShell, repoRoot, normalized.skipShortcuts === true);
      await this.runVerifier(powerShell, repoRoot);
      await this.launch(repoRoot, normalized.launchAfterInstall);

      this.snapshot.status = "success";
      this.publish();
      this.emit({ type: "done", snapshot: this.snapshot });
      return this.snapshot;
    } catch (error) {
      const message = toErrorMessage(error);
      this.snapshot.status = "error";
      this.snapshot.error = message;
      this.markRunningStepFailed(message);
      this.publish();
      this.emit({ type: "error", snapshot: this.snapshot, message });
      return this.snapshot;
    }
  }

  private validateRequest(request: InstallRequest): InstallRequest {
    const installDir = path.resolve(request.installDir || getDefaultInstallDir());
    if (!request.baseUrl.trim()) {
      throw new Error("Base URL is required.");
    }
    const parsedUrl = new URL(request.baseUrl.trim());
    if (!["http:", "https:"].includes(parsedUrl.protocol)) {
      throw new Error("Base URL must start with http:// or https://.");
    }
    if (!request.apiKey.trim()) {
      throw new Error("API key is required.");
    }
    return {
      ...request,
      installDir,
      baseUrl: request.baseUrl.trim(),
      apiKey: request.apiKey.trim(),
      imageApiKey: request.imageApiKey?.trim(),
      repoBranch: request.repoBranch?.trim(),
    };
  }

  private async ensurePowerShell(): Promise<PowerShellHost> {
    return this.runStep("powershell", "Locating built-in Windows PowerShell", async () => {
      return findPowerShellHost();
    });
  }

  private async ensureWinget(
    powerShell: PowerShellHost,
    required: boolean,
  ): Promise<string | null> {
    return this.runStep("winget", "Resolving winget package manager", async () => {
      const existing = await this.resolveWinget();
      if (existing) {
        return existing;
      }

      if (!required) {
        this.setStep(
          "winget",
          "warning",
          "winget is unavailable; continuing because Codex is already installed and recommended tools were skipped.",
        );
        return null;
      }

      await this.appendLog(
        "winget",
        "winget is missing. Trying App Installer re-registration.",
      );
      await this.runPowerShellInline(
        powerShell,
        "winget",
        "Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe",
        { timeoutMs: 120_000 },
      );

      const registered = await this.resolveWinget();
      if (registered) {
        return registered;
      }

      await this.appendLog(
        "winget",
        "Re-registration did not expose winget. Trying Microsoft.WinGet.Client repair.",
      );
      const repairScript = `
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
  Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
}
if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
  Register-PSRepository -Default
}
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Install-Module Microsoft.WinGet.Client -Force -AllowClobber -Scope CurrentUser
Import-Module Microsoft.WinGet.Client
Repair-WinGetPackageManager
`;
      const repair = await this.runPowerShellInline(powerShell, "winget", repairScript, {
        timeoutMs: 600_000,
      });
      if (repair.code !== 0) {
        await this.appendLog("winget", "Repair-WinGetPackageManager did not complete.");
      }

      const repaired = await this.resolveWinget();
      if (repaired) {
        return repaired;
      }

      await shell.openExternal(
        `ms-windows-store://pdp/?ProductId=${APP_INSTALLER_PRODUCT_ID}`,
      );
      throw new Error(
        "winget is still unavailable. Microsoft Store was opened to App Installer; install or update it, then run Setup.exe again.",
      );
    });
  }

  private async ensureOfficialCodex(
    powerShell: PowerShellHost,
    winget: string | null,
    initialPackage: unknown,
  ): Promise<void> {
    await this.runStep("codex", "Checking official Store package", async () => {
      if (initialPackage || (await this.getCodexPackage(powerShell))) {
        return "OpenAI.Codex is already installed.";
      }

      if (!winget) {
        await shell.openExternal(
          `ms-windows-store://pdp/?ProductId=${CODEX_STORE_PRODUCT_ID}`,
        );
        throw new Error(
          "Official Codex is not installed and winget is unavailable. Microsoft Store was opened to Codex; install it, then run Setup.exe again.",
        );
      }

      const attempts: Array<{ label: string; args: string[] }> = [
        {
          label: "Microsoft Store product ID",
          args: [
            "install",
            "--id",
            CODEX_STORE_PRODUCT_ID,
            "--source",
            "msstore",
            "--exact",
          ],
        },
        {
          label: "Microsoft Store search alias",
          args: ["install", "Codex", "--source", "msstore"],
        },
        {
          label: "OpenAI.Codex package id",
          args: ["install", "--id", "OpenAI.Codex", "--exact"],
        },
      ];

      for (const attempt of attempts) {
        await this.appendLog("codex", `Installing Codex via ${attempt.label}.`);
        const result = await this.runWinget(winget, "codex", attempt.args, 900_000);
        if (result.code === 0 && (await this.getCodexPackage(powerShell))) {
          return `Codex installed via ${attempt.label}.`;
        }
      }

      await shell.openExternal(
        `ms-windows-store://pdp/?ProductId=${CODEX_STORE_PRODUCT_ID}`,
      );
      throw new Error(
        "Codex could not be installed automatically. Microsoft Store was opened to Codex; install it, then run Setup.exe again.",
      );
    });
  }

  private async installRecommendedTools(
    winget: string | null,
    shouldInstall: boolean,
  ): Promise<void> {
    await this.runStep("recommended", "Installing recommended tools", async () => {
      if (!shouldInstall) {
        this.setStep("recommended", "skipped", "Skipped by user choice.");
        return;
      }
      if (!winget) {
        this.setStep(
          "recommended",
          "warning",
          "Skipped because winget is unavailable; local OmniRoute dependencies will still be installed.",
        );
        return;
      }

      const packages: ToolPackage[] = [
        {
          id: "Microsoft.PowerShell",
          label: "PowerShell 7",
          probe: async () => (await this.where("pwsh.exe")).length > 0,
        },
        {
          id: "Git.Git",
          label: "Git",
          probe: async () => (await this.where("git.exe")).length > 0,
        },
        {
          id: "OpenJS.NodeJS.LTS",
          label: "Node.js LTS",
          probe: async () => {
            const nodes = await this.where("node.exe");
            for (const node of nodes) {
              const version = await runRaw(node, ["--version"]);
              const major = parseMajor(version.stdout.trim());
              if (major >= 20) {
                return true;
              }
            }
            return false;
          },
        },
        {
          id: "Microsoft.DotNet.SDK.8",
          label: ".NET SDK 8",
          probe: async () => {
            const dotnets = await this.where("dotnet.exe");
            for (const dotnet of dotnets) {
              const sdks = await runRaw(dotnet, ["--list-sdks"]);
              if (sdks.stdout.match(/^(8|9|10)\./m)) {
                return true;
              }
            }
            return false;
          },
        },
        {
          id: "Python.Python.3.14",
          label: "Python 3.14",
          probe: async () => (await this.where("python.exe")).length > 0,
        },
        {
          id: "GitHub.cli",
          label: "GitHub CLI",
          probe: async () => (await this.where("gh.exe")).length > 0,
        },
      ];

      const warnings: string[] = [];
      for (const pkg of packages) {
        if (await pkg.probe()) {
          await this.appendLog("recommended", `${pkg.label} already available.`);
          continue;
        }
        await this.appendLog("recommended", `Installing ${pkg.label} (${pkg.id}).`);
        const result = await this.runWinget(
          winget,
          "recommended",
          ["install", "--id", pkg.id, "--exact"],
          900_000,
        );
        if (result.code !== 0) {
          warnings.push(pkg.label);
          await this.appendLog(
            "recommended",
            `${pkg.label} install returned exit code ${result.code}.`,
          );
        }
      }

      if (warnings.length > 0) {
        this.setStep(
          "recommended",
          "warning",
          `Some recommended tools did not install: ${warnings.join(", ")}.`,
        );
        return;
      }
      return "Recommended tools are available.";
    });
  }

  private async ensureSource(request: InstallRequest): Promise<string> {
    return this.runStep("source", "Downloading Codex OmniRoute repository", async () => {
      const parent = path.resolve(request.installDir);
      const target = path.join(parent, "Codex-Omniroute");
      await fs.mkdir(parent, { recursive: true });

      const sourceOverride = process.env.CODEX_OMNI_SETUP_SOURCE_DIR;
      if (sourceOverride) {
        const sourceRoot = path.resolve(sourceOverride);
        if (!(await isRepoRoot(sourceRoot))) {
          throw new Error(`CODEX_OMNI_SETUP_SOURCE_DIR is not a valid repo root: ${sourceRoot}`);
        }
        if (!isSafeGeneratedTarget(parent, target)) {
          throw new Error(`Refusing to write outside selected install directory: ${target}`);
        }
        await this.appendLog("source", `Copying source tree from ${sourceRoot}`);
        await fs.rm(target, { recursive: true, force: true });
        await copySourceTree(sourceRoot, target);
        return target;
      }

      if (await isRepoRoot(target)) {
        const git = await this.firstWhere("git.exe");
        if (git && (await exists(path.join(target, ".git")))) {
          const pull = await this.runProcess(git, ["pull", "--ff-only"], {
            cwd: target,
            logStepId: "source",
            timeoutMs: 180_000,
          });
          if (pull.code === 0) {
            return target;
          }
          this.setStep(
            "source",
            "warning",
            "Existing repository could not fast-forward; using it as-is.",
          );
          return target;
        }
        this.setStep("source", "warning", "Existing source folder reused.");
        return target;
      }

      if ((await exists(target)) && !(await isDirectoryEmpty(target))) {
        throw new Error(
          `Install target already exists but is not a Codex OmniRoute repository: ${target}`,
        );
      }

      const branch = request.repoBranch || DEFAULT_REPO_BRANCH;
      const git = await this.firstWhere("git.exe");
      if (git) {
        const clone = await this.runProcess(
          git,
          ["clone", "--depth", "1", "--branch", branch, REPO_URL, target],
          {
            logStepId: "source",
            timeoutMs: 600_000,
          },
        );
        if (clone.code === 0 && (await isRepoRoot(target))) {
          return target;
        }
        await this.appendLog("source", "git clone failed; falling back to GitHub zip.");
        if (isSafeGeneratedTarget(parent, target)) {
          await fs.rm(target, { recursive: true, force: true });
        }
      }

      await this.downloadRepositoryArchive(parent, target, branch);
      if (!(await isRepoRoot(target))) {
        throw new Error("Downloaded archive did not contain the expected setup files.");
      }
      return target;
    });
  }

  private async ensureLocalDependencies(
    powerShell: PowerShellHost,
    repoRoot: string,
  ): Promise<void> {
    await this.runStep("local-deps", "Installing local Node.js and .NET SDK if needed", async () => {
      const script = path.join(repoRoot, "tools", "Install-CodexOmniRouteDependencies.ps1");
      const result = await this.runPowerShellFile(
        powerShell,
        "local-deps",
        script,
        ["-Quiet", "-AsJson"],
        { cwd: repoRoot, timeoutMs: 900_000 },
      );
      if (result.code !== 0) {
        throw new Error("Local dependency installer failed.");
      }
      const json = parseFirstJsonObject(result.stdout);
      if (!json?.node_available || !json?.dotnet_sdk_available) {
        throw new Error("Local dependency installer did not report Node.js and .NET SDK availability.");
      }
      return `Node: ${json.node_source}; .NET: ${json.dotnet_source}.`;
    });
  }

  private async writeProviderConfig(
    repoRoot: string,
    request: InstallRequest,
  ): Promise<void> {
    await this.runStep("provider", "Writing provider config", async () => {
      const provider = {
        _comment: "Generated by Codex OmniRoute Setup.exe. Never commit this file.",
        base_url: request.baseUrl,
        api_key: request.apiKey,
        default_model: "gpt-5.5",
        model_prefix: "cx/",
        model_aliases: {
          "gpt-5.5": "gpt-5.5-xhigh",
        },
        image_api_key: request.imageApiKey || "",
        image_model: "chatgpt-web/gpt-5.3-instant",
        headers: {
          "x-codex-omniroute-client": "codex-omniroute-bridge",
        },
      };
      const file = path.join(repoRoot, "omniroute-provider.json");
      await fs.writeFile(file, `${JSON.stringify(provider, null, 2)}\n`, "utf8");
      return "omniroute-provider.json written with hidden key material.";
    });
  }

  private async prepareGateway(
    powerShell: PowerShellHost,
    repoRoot: string,
    skipShortcuts: boolean,
  ): Promise<void> {
    await this.runStep("gateway", "Preparing duplicated app, wrapper, and shortcuts", async () => {
      const script = path.join(repoRoot, "Setup.ps1");
      const result = await this.runPowerShellFile(
        powerShell,
        "gateway",
        script,
        skipShortcuts
          ? ["-NonInteractive", "-SkipVerify", "-SkipShortcuts"]
          : ["-NonInteractive", "-SkipVerify"],
        { cwd: repoRoot, timeoutMs: 1_200_000 },
      );
      if (result.code !== 0) {
        throw new Error("Setup.ps1 failed while preparing the gateway.");
      }
      return skipShortcuts
        ? "Gateway prepared; shortcuts skipped."
        : "Gateway prepared and shortcuts created.";
    });
  }

  private async runVerifier(powerShell: PowerShellHost, repoRoot: string): Promise<void> {
    await this.runStep("verify", "Running real OmniRoute verifier", async () => {
      const script = path.join(repoRoot, "verify-codex-omniroute.ps1");
      const result = await this.runPowerShellFile(powerShell, "verify", script, [], {
        cwd: repoRoot,
        timeoutMs: 900_000,
      });
      if (result.code !== 0) {
        throw new Error("verify-codex-omniroute.ps1 reported a failure.");
      }
      return "Verifier completed without required failures.";
    });
  }

  private async launch(repoRoot: string, shouldLaunch: boolean): Promise<void> {
    await this.runStep("launch", "Starting Codex OmniRoute", async () => {
      if (!shouldLaunch) {
        this.setStep("launch", "skipped", "Launch skipped by user choice.");
        return;
      }

      const launched = await launchInstalledOmniRoute(repoRoot);
      return `Codex OmniRoute opened on bridge port ${launched.bridgePort} (pid ${launched.processId}).`;
    });
  }

  private async downloadRepositoryArchive(
    parent: string,
    target: string,
    branch: string,
  ): Promise<void> {
    const encodedBranch = branch.split("/").map(encodeURIComponent).join("/");
    const archiveUrl =
      process.env.CODEX_OMNI_SETUP_REPO_ARCHIVE_URL ??
      `https://github.com/Destruction13/Codex-Omniroute/archive/refs/heads/${encodedBranch}.zip`;
    const tempRoot = path.join(app.getPath("temp"), `codex-omniroute-${Date.now()}`);
    const zipPath = path.join(tempRoot, "source.zip");
    const extractRoot = path.join(tempRoot, "extract");
    await fs.mkdir(extractRoot, { recursive: true });

    await this.appendLog("source", `Downloading ${archiveUrl}`);
    const response = await fetch(archiveUrl);
    if (!response.ok) {
      throw new Error(`Repository archive download failed with HTTP ${response.status}.`);
    }
    const zipBuffer = Buffer.from(await response.arrayBuffer());
    await fs.writeFile(zipPath, zipBuffer);

    const zip = new AdmZip(zipPath);
    zip.extractAllTo(extractRoot, true);
    const entries = await fs.readdir(extractRoot);
    let archiveRoot = "";
    for (const entry of entries) {
      const candidate = path.join(extractRoot, entry);
      if (await isRepoRoot(candidate)) {
        archiveRoot = candidate;
        break;
      }
    }
    if (!archiveRoot) {
      throw new Error("Repository archive did not contain a recognizable root folder.");
    }

    if (!isSafeGeneratedTarget(parent, target)) {
      throw new Error(`Refusing to write outside selected install directory: ${target}`);
    }
    await fs.rm(target, { recursive: true, force: true });
    await fs.cp(archiveRoot, target, { recursive: true });
    await fs.rm(tempRoot, { recursive: true, force: true });
  }

  private async getCodexPackage(powerShell: PowerShellHost): Promise<unknown | null> {
    const script = `
$pkg = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pkg) {
  $pkg | Select-Object Name, PackageFullName, InstallLocation | ConvertTo-Json -Compress
}
`;
    const result = await this.runPowerShellInline(powerShell, "codex", script, {
      timeoutMs: 45_000,
    });
    if (result.code !== 0 || !result.stdout.trim()) {
      return null;
    }
    return parseFirstJsonObject(result.stdout);
  }

  private async resolveWinget(): Promise<string | null> {
    const localAppData = process.env.LOCALAPPDATA ?? "";
    const programFiles = process.env.ProgramFiles ?? "C:\\Program Files";
    const candidates = unique([
      ...(await this.where("winget.exe")),
      localAppData ? path.join(localAppData, "Microsoft", "WindowsApps", "winget.exe") : "",
      ...(await this.findWindowsAppsWinget(programFiles)),
    ]).filter(Boolean);

    for (const candidate of candidates) {
      if (!(await exists(candidate))) {
        continue;
      }
      const result = await runRaw(candidate, ["--version"], 30_000);
      if (result.code === 0) {
        await this.appendLog("winget", `Resolved winget: ${candidate}`);
        return candidate;
      }
    }
    return null;
  }

  private async findWindowsAppsWinget(programFiles: string): Promise<string[]> {
    const appsRoot = path.join(programFiles, "WindowsApps");
    try {
      const entries = await fs.readdir(appsRoot);
      return entries
        .filter((entry) => entry.startsWith("Microsoft.DesktopAppInstaller_"))
        .map((entry) => path.join(appsRoot, entry, "winget.exe"));
    } catch {
      return [];
    }
  }

  private async runWinget(
    winget: string,
    stepId: string,
    args: string[],
    timeoutMs: number,
  ): Promise<ProcessResult> {
    const common = [
      "--accept-package-agreements",
      "--accept-source-agreements",
      "--disable-interactivity",
    ];
    return this.runProcess(winget, [...args, ...common], {
      logStepId: stepId,
      timeoutMs,
    });
  }

  private async runPowerShellInline(
    host: PowerShellHost,
    stepId: string,
    script: string,
    options: RunProcessOptions = {},
  ): Promise<ProcessResult> {
    const encoded = Buffer.from(script, "utf16le").toString("base64");
    return this.runProcess(
      host.exe,
      [
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-EncodedCommand",
        encoded,
      ],
      { ...options, logStepId: stepId },
    );
  }

  private async runPowerShellFile(
    host: PowerShellHost,
    stepId: string,
    scriptPath: string,
    args: string[],
    options: RunProcessOptions = {},
  ): Promise<ProcessResult> {
    return this.runProcess(
      host.exe,
      [
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        scriptPath,
        ...args,
      ],
      { ...options, logStepId: stepId },
    );
  }

  private async runProcess(
    file: string,
    args: string[],
    options: RunProcessOptions = {},
  ): Promise<ProcessResult> {
    const timeoutMs = options.timeoutMs ?? 300_000;
    await this.appendLog(options.logStepId, `> ${file} ${args.map(maskArg).join(" ")}`);

    return new Promise((resolve) => {
      const child = spawn(file, args, {
        cwd: options.cwd,
        env: { ...process.env, ...options.env },
        stdio: ["ignore", "pipe", "pipe"],
        windowsHide: true,
      });
      let stdout = "";
      let stderr = "";
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        child.kill();
        resolve({ code: -1, stdout, stderr: `${stderr}\nTimed out after ${timeoutMs} ms.` });
      }, timeoutMs);

      const finish = (code: number) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        resolve({ code, stdout, stderr });
      };

      child.stdout.on("data", (chunk: Buffer) => {
        const text = chunk.toString("utf8");
        stdout += text;
        void this.appendChunk(options.logStepId, text);
      });
      child.stderr.on("data", (chunk: Buffer) => {
        const text = chunk.toString("utf8");
        stderr += text;
        void this.appendChunk(options.logStepId, text);
      });
      child.on("error", (error) => {
        stderr += error.message;
        void this.appendLog(options.logStepId, error.message);
        finish(-1);
      });
      child.on("exit", (code) => {
        setTimeout(() => finish(code ?? 0), 250);
      });
      child.on("close", (code) => finish(code ?? 0));
    });
  }

  private async runStep<T>(
    id: string,
    detail: string,
    work: () => Promise<T | string | void>,
  ): Promise<T> {
    this.setStep(id, "running", detail);
    try {
      const result = await work();
      const current = this.getStep(id);
      if (current.status === "running") {
        this.setStep(
          id,
          "success",
          typeof result === "string" && result ? result : "Completed.",
        );
      }
      return result as T;
    } catch (error) {
      this.setStep(id, "error", toErrorMessage(error));
      throw error;
    }
  }

  private getStep(id: string): SetupStepSnapshot {
    const step = this.snapshot.steps.find((candidate) => candidate.id === id);
    if (!step) {
      throw new Error(`Unknown setup step: ${id}`);
    }
    return step;
  }

  private setStep(id: string, status: StepStatus, detail: string): void {
    const step = this.getStep(id);
    step.status = status;
    step.detail = this.sanitize(detail);
    if (status === "running" && !step.startedAt) {
      step.startedAt = new Date().toISOString();
    }
    if (["success", "warning", "error", "skipped"].includes(status)) {
      step.finishedAt = new Date().toISOString();
    }
    this.publish();
  }

  private markRunningStepFailed(message: string): void {
    const running = this.snapshot.steps.find((step) => step.status === "running");
    if (running) {
      running.status = "error";
      running.detail = this.sanitize(message);
      running.finishedAt = new Date().toISOString();
    }
  }

  private publish(): void {
    this.emit({ type: "state", snapshot: this.snapshot });
  }

  private async prepareLogFile(): Promise<void> {
    const logDir = path.join(app.getPath("userData"), "logs");
    await fs.mkdir(logDir, { recursive: true });
    this.logPath = path.join(logDir, `setup-${Date.now()}.log`);
    await fs.writeFile(this.logPath, "Codex OmniRoute Setup log\n", "utf8");
  }

  private async appendChunk(stepId: string | undefined, text: string): Promise<void> {
    const lines = text.split(/\r?\n/).filter((line) => line.trim().length > 0);
    for (const line of lines) {
      await this.appendLog(stepId, line);
    }
  }

  private async appendLog(stepId: string | undefined, message: string): Promise<void> {
    const clean = this.sanitize(message);
    if (stepId) {
      const step = this.getStep(stepId);
      step.log = [...step.log.slice(-79), clean];
      this.publish();
    }
    if (this.logPath) {
      await fs.appendFile(this.logPath, `${new Date().toISOString()} ${clean}\n`, "utf8");
    }
  }

  private sanitize(value: string): string {
    let clean = value;
    for (const secret of this.redactions) {
      clean = clean.split(secret).join("[redacted]");
    }
    return clean;
  }

  private async where(name: string): Promise<string[]> {
    const result = await runRaw("where.exe", [name], 15_000);
    if (result.code !== 0) {
      return [];
    }
    return result.stdout
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line.length > 0);
  }

  private async firstWhere(name: string): Promise<string | null> {
    const matches = await this.where(name);
    return matches[0] ?? null;
  }
}

async function runRaw(
  file: string,
  args: string[],
  timeoutMs = 30_000,
  cwd?: string,
): Promise<ProcessResult> {
  return new Promise((resolve) => {
    const child = spawn(file, args, {
      cwd,
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    });
    let stdout = "";
    let stderr = "";
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) {
        return;
      }
      settled = true;
      child.kill();
      resolve({ code: -1, stdout, stderr: `${stderr}\nTimed out after ${timeoutMs} ms.` });
    }, timeoutMs);

    const finish = (code: number) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      resolve({ code, stdout, stderr });
    };

    child.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString("utf8");
    });
    child.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", (error) => {
      stderr += error.message;
      finish(-1);
    });
    child.on("exit", (code) => {
      setTimeout(() => finish(code ?? 0), 250);
    });
    child.on("close", (code) => finish(code ?? 0));
  });
}

async function spawnDetached(file: string, args: string[], cwd: string): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const child = spawn(file, args, {
      cwd,
      detached: true,
      stdio: "ignore",
      windowsHide: true,
    });
    child.once("spawn", () => {
      child.unref();
      resolve();
    });
    child.once("error", reject);
  });
}

async function findPowerShellHost(): Promise<PowerShellHost> {
  const candidates = unique([
    path.join(
      process.env.SystemRoot ?? "C:\\Windows",
      "System32",
      "WindowsPowerShell",
      "v1.0",
      "powershell.exe",
    ),
    ...(await whereRaw("powershell.exe")),
    ...(await whereRaw("pwsh.exe")),
  ]);

  for (const candidate of candidates) {
    if (!(await exists(candidate))) {
      continue;
    }
    const result = await runRaw(candidate, [
      "-NoLogo",
      "-NoProfile",
      "-NonInteractive",
      "-Command",
      "$PSVersionTable.PSVersion.ToString()",
    ]);
    if (result.code === 0) {
      const version = result.stdout.trim().split(/\r?\n/).at(-1) ?? "unknown";
      return {
        exe: candidate,
        label: `PowerShell ${version}`,
      };
    }
  }

  throw new Error(
    "PowerShell was not found. Windows PowerShell is a required OS component for Store/AppX repair and OmniRoute setup.",
  );
}

async function waitForLaunchedOmniRoute(
  repoRoot: string,
  providerPath: string,
  timeoutMs: number,
): Promise<LaunchResult> {
  const deadline = Date.now() + timeoutMs;
  let lastProcess: OmniRouteProcess | null = null;
  let lastHealth: BridgeHealthProbe | null = null;

  while (Date.now() < deadline) {
    lastProcess = await findOmniRouteProcess(repoRoot);
    lastHealth = await findBridgeHealth(providerPath);
    if (lastProcess && lastHealth) {
      return {
        processId: lastProcess.processId,
        executablePath: lastProcess.executablePath,
        bridgePort: lastHealth.port,
        providerPath: lastHealth.source,
      };
    }
    await delay(750);
  }

  const processDetail = lastProcess
    ? `process pid=${lastProcess.processId}`
    : "process not found";
  const healthDetail = lastHealth
    ? `bridge port=${lastHealth.port}`
    : "matching bridge healthz not found";
  throw new Error(
    `Codex OmniRoute did not confirm launch within ${Math.round(
      timeoutMs / 1000,
    )} seconds (${processDetail}; ${healthDetail}).`,
  );
}

async function findOmniRouteProcess(repoRoot: string): Promise<OmniRouteProcess | null> {
  const powerShell = await findPowerShellHost();
  const windowsAppExe = path.join(
    process.env.LOCALAPPDATA ?? path.join(os.homedir(), "AppData", "Local"),
    "CodexOmniRoute",
    "WindowsApp",
    "app",
    "Codex.exe",
  );
  const script = `
$exe = ${toPowerShellString(windowsAppExe)}
$root = ${toPowerShellString(path.resolve(repoRoot))}
$rows = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
  $_.ExecutablePath -and
  ([System.String]::Equals([System.IO.Path]::GetFullPath($_.ExecutablePath), [System.IO.Path]::GetFullPath($exe), [System.StringComparison]::OrdinalIgnoreCase)) -and
  $_.CommandLine -and
  ($_.CommandLine.IndexOf($root, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -and
  ($_.CommandLine -notmatch '--type=')
} | Select-Object -First 1 @{Name='processId';Expression={$_.ProcessId}}, @{Name='executablePath';Expression={$_.ExecutablePath}}, @{Name='commandLine';Expression={$_.CommandLine}}
if ($rows) { $rows | ConvertTo-Json -Compress }
`;
  const result = await runRaw(
    powerShell.exe,
    [
      "-NoLogo",
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy",
      "Bypass",
      "-EncodedCommand",
      Buffer.from(script, "utf16le").toString("base64"),
    ],
    15_000,
  );
  if (result.code !== 0 || !result.stdout.trim()) {
    return null;
  }
  try {
    const parsed = JSON.parse(result.stdout.trim()) as Partial<OmniRouteProcess>;
    if (
      typeof parsed.processId === "number" &&
      typeof parsed.executablePath === "string" &&
      typeof parsed.commandLine === "string"
    ) {
      return {
        processId: parsed.processId,
        executablePath: parsed.executablePath,
        commandLine: parsed.commandLine,
      };
    }
  } catch {
    return null;
  }
  return null;
}

async function findBridgeHealth(providerPath: string): Promise<BridgeHealthProbe | null> {
  const expectedProvider = path.resolve(providerPath).toLowerCase();
  for (let port = 20333; port <= 20372; port += 1) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 1_500);
    try {
      const response = await fetch(`http://127.0.0.1:${port}/healthz`, {
        signal: controller.signal,
      });
      if (!response.ok) {
        continue;
      }
      const health = (await response.json()) as {
        ok?: boolean;
        omniroute?: { configured?: boolean; source?: string };
      };
      const source = health.omniroute?.source
        ? path.resolve(health.omniroute.source).toLowerCase()
        : "";
      if (health.ok === true && health.omniroute?.configured === true && source === expectedProvider) {
        return { port, source: health.omniroute.source ?? providerPath };
      }
    } catch {
      // Keep scanning nearby bridge ports.
    } finally {
      clearTimeout(timer);
    }
  }
  return null;
}

async function focusOmniRouteWindow(processId: number): Promise<void> {
  const powerShell = await findPowerShellHost();
  const script = `
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class OmniRouteWindow {
  [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@
$deadline = [DateTime]::UtcNow.AddSeconds(15)
do {
  $proc = Get-Process -Id ${processId} -ErrorAction SilentlyContinue
  if ($proc -and $proc.MainWindowHandle -and $proc.MainWindowHandle -ne 0) {
    [void][OmniRouteWindow]::ShowWindowAsync($proc.MainWindowHandle, 9)
    [void][OmniRouteWindow]::SetForegroundWindow($proc.MainWindowHandle)
    exit 0
  }
  Start-Sleep -Milliseconds 300
} while ([DateTime]::UtcNow -lt $deadline)
exit 0
`;
  await runRaw(
    powerShell.exe,
    [
      "-NoLogo",
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy",
      "Bypass",
      "-EncodedCommand",
      Buffer.from(script, "utf16le").toString("base64"),
    ],
    20_000,
  );
}

async function whereRaw(name: string): Promise<string[]> {
  const result = await runRaw("where.exe", [name], 15_000);
  if (result.code !== 0) {
    return [];
  }
  return result.stdout
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
}

function toPowerShellString(value: string): string {
  return `'${value.replace(/'/g, "''")}'`;
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function exists(filePath: string): Promise<boolean> {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

async function isDirectoryEmpty(dirPath: string): Promise<boolean> {
  try {
    const entries = await fs.readdir(dirPath);
    return entries.length === 0;
  } catch {
    return true;
  }
}

async function isRepoRoot(candidate: string): Promise<boolean> {
  const required = [
    "Setup.ps1",
    "Start-Codex-OmniRoute.ps1",
    "verify-codex-omniroute.ps1",
    path.join("tools", "Install-CodexOmniRouteDependencies.ps1"),
    "codex-openai-omniroute-bridge.mjs",
  ];
  for (const rel of required) {
    if (!(await exists(path.join(candidate, rel)))) {
      return false;
    }
  }
  return true;
}

async function copySourceTree(sourceRoot: string, target: string): Promise<void> {
  const ignored = new Set([
    ".git",
    ".setup-test",
    "node_modules",
    "dist",
    "dist-electron",
    "release",
    "artifacts",
  ]);
  await fs.cp(sourceRoot, target, {
    recursive: true,
    filter: (source) => {
      const rel = path.relative(sourceRoot, source);
      if (!rel) {
        return true;
      }
      return !rel.split(path.sep).some((part) => ignored.has(part));
    },
  });
}

function isSafeGeneratedTarget(parent: string, target: string): boolean {
  const parentFull = path.resolve(parent).toLowerCase();
  const targetFull = path.resolve(target).toLowerCase();
  return (
    path.basename(targetFull) === "codex-omniroute" &&
    targetFull.startsWith(`${parentFull}${path.sep}`)
  );
}

function unique(values: string[]): string[] {
  return [...new Set(values.filter((value) => value.trim().length > 0))];
}

function parseMajor(version: string): number {
  const match = version.match(/v?(\d+)\./);
  return match ? Number(match[1]) : 0;
}

function parseFirstJsonObject(text: string): Record<string, unknown> | null {
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start < 0 || end < start) {
    return null;
  }
  try {
    return JSON.parse(text.slice(start, end + 1)) as Record<string, unknown>;
  } catch {
    return null;
  }
}

function maskArg(arg: string): string {
  if (arg.length > 120) {
    return `${arg.slice(0, 60)}...`;
  }
  return arg;
}

function toErrorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }
  return String(error);
}
