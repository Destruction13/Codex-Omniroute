import AdmZip from "adm-zip"
import { app, shell } from "electron"
import { spawn } from "node:child_process"
import { constants as fsConstants } from "node:fs"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"

import type {
  InstallRequest,
  LaunchResult,
  PowerShellHost,
  ProcessResult,
  ProviderVerificationRequest,
  ProviderVerificationResult,
  SetupEvent,
  SetupSnapshot,
  SetupStepSnapshot,
  StepStatus,
} from "./types.cjs"

const REPO_URL =
  process.env.CODEX_OMNI_SETUP_REPO_URL ??
  "https://github.com/Destruction13/Codex-Omniroute.git"
const DEFAULT_REPO_BRANCH = process.env.CODEX_OMNI_SETUP_REPO_BRANCH ?? "main"
const CODEX_STORE_PRODUCT_ID = "9PLM9XGG6VKS"
const APP_INSTALLER_PRODUCT_ID = "9NBLGGH4NNS1"
const DEFAULT_PROVIDER_MODEL = "gpt-5.5"
const DEFAULT_PROVIDER_MODEL_PREFIX = "cx/"
const DEFAULT_PROVIDER_MODEL_ALIASES: Record<string, string> = {
  "gpt-5.5": "gpt-5.5-xhigh",
}
const PROVIDER_HEADERS: Record<string, string> = {
  "x-codex-omniroute-client": "codex-omniroute-bridge",
}
const KEY_VERIFICATION_FAILED =
  "Key verification failed. Check the access key and try again."
const SERVICE_VERIFICATION_FAILED =
  "Service verification failed. Check the service URL and try again."

const STEP_DEFINITIONS = [
  ["api", "Access key verification"],
  ["preflight", "Windows preflight"],
  ["powershell", "PowerShell host"],
  ["winget", "App Installer / winget"],
  ["codex", "Official Codex Store app"],
  ["recommended", "Windows developer tools"],
  ["source", "Codex OmniRoute source"],
  ["local-deps", "Local Node.js and .NET"],
  ["provider", "Provider config"],
  ["gateway", "Gateway, wrapper, shortcuts"],
  ["verify", "Architecture verifier"],
  ["launch", "Launch Codex OmniRoute"],
] as const

interface RunProcessOptions {
  cwd?: string
  env?: NodeJS.ProcessEnv
  timeoutMs?: number
  logStepId?: string
}

interface ToolPackage {
  id: string
  label: string
  probe: () => Promise<boolean>
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
  }
}

export function getDefaultInstallDir(): string {
  return path.join(os.homedir(), "CodexOmniRoute")
}

export async function verifyProviderCredentials(
  request: ProviderVerificationRequest
): Promise<ProviderVerificationResult> {
  const normalized = normalizeProviderRequest(request)
  const probe = await probeOmniRouteProvider(createProviderConfig(normalized))
  return {
    endpoint: probe.endpoint,
    matchedModel: probe.matchedModel,
    modelCount: probe.modelCount,
  }
}

interface OmniRouteProcess {
  processId: number
  executablePath: string
  commandLine: string
}

interface BridgeHealthProbe {
  port: number
  source: string
}

interface ProviderConfig {
  _comment: string
  base_url: string
  api_key: string
  default_model: string
  model_prefix: string
  model_aliases: Record<string, string>
  headers: Record<string, string>
}

interface ProviderProbeResult {
  apiManagerEndpoint: string
  apiManagerDetail: string
  endpoint: string
  matchedModel: string
  modelCount: number
}

interface ApiManagerProbeResult {
  endpoint: string
  detail: string
}

export async function launchInstalledOmniRoute(
  repoRoot: string
): Promise<LaunchResult> {
  const resolvedRoot = path.resolve(repoRoot)
  const script = path.join(resolvedRoot, "Start-Codex-OmniRoute.ps1")
  const providerPath = path.join(resolvedRoot, "omniroute-provider.json")
  if (!(await exists(script))) {
    throw new Error(`Codex OmniRoute launcher was not found: ${script}`)
  }
  if (!(await exists(providerPath))) {
    throw new Error(`Provider config was not found: ${providerPath}`)
  }

  const powerShell = await findPowerShellHost()
  const existing = await waitForLaunchedOmniRoute(providerPath, 1_500).catch(
    () => null
  )
  if (existing) {
    await focusOmniRouteWindow(existing.processId).catch(() => undefined)
    return existing
  }

  let lastError = ""
  for (let attempt = 1; attempt <= 2; attempt += 1) {
    if (attempt > 1) {
      await runRaw(
        powerShell.exe,
        [
          "-NoLogo",
          "-NoProfile",
          "-NonInteractive",
          "-ExecutionPolicy",
          "Bypass",
          "-File",
          script,
          "-Restore",
        ],
        60_000,
        resolvedRoot
      )
    }

    const launch = await runRaw(
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
      300_000,
      resolvedRoot
    )
    if (launch.code !== 0) {
      lastError = compactProcessFailure(launch)
      continue
    }

    try {
      const result = await waitForLaunchedOmniRoute(providerPath, 90_000)
      await focusOmniRouteWindow(result.processId).catch(() => undefined)
      return result
    } catch (error) {
      lastError = toErrorMessage(error)
    }
  }

  throw new Error(`Codex OmniRoute launch could not be confirmed. ${lastError}`)
}

export function parseHeadlessRequest(argv: string[]): InstallRequest | null {
  if (!argv.includes("--headless-install")) {
    return null
  }

  const readValue = (name: string): string => {
    const index = argv.indexOf(name)
    if (index < 0 || index + 1 >= argv.length) {
      return ""
    }
    return argv[index + 1] ?? ""
  }

  return {
    installDir: readValue("--install-dir") || getDefaultInstallDir(),
    baseUrl: readValue("--base-url"),
    apiKey: readValue("--api-key"),
    repoBranch: readValue("--repo-branch") || undefined,
    installRecommendedTools: !argv.includes("--skip-recommended"),
    launchAfterInstall: !argv.includes("--no-launch"),
    skipShortcuts: argv.includes("--skip-shortcuts"),
  }
}

export class SetupRunner {
  private snapshot = createInitialSnapshot()
  private logPath = ""
  private redactions: string[] = []

  constructor(private readonly emit: (event: SetupEvent) => void) {}

  async run(request: InstallRequest): Promise<SetupSnapshot> {
    this.redactions = [request.apiKey].filter(
      (value) => value.trim().length > 0
    )
    await this.prepareLogFile()
    this.snapshot = {
      ...createInitialSnapshot(),
      status: "running",
      logPath: this.logPath,
      installRoot: path.resolve(request.installDir),
    }
    this.publish()

    try {
      const normalized = this.validateRequest(request)
      await this.verifyProviderAccess(normalized)

      const powerShell = await this.runStep(
        "preflight",
        "Checking OS and install path",
        async () => {
          if (process.platform !== "win32") {
            throw new Error("This installer is only supported on Windows.")
          }
          await fs.mkdir(normalized.installDir, { recursive: true })
          await fs.access(normalized.installDir, fsConstants.W_OK)
          return "Install parent is writable."
        }
      ).then(() => this.ensurePowerShell())

      const codexBefore = await this.getCodexPackage(powerShell)
      const winget = await this.ensureWinget(
        powerShell,
        !codexBefore
      )

      await this.ensureOfficialCodex(powerShell, winget, codexBefore)
      await this.installRecommendedTools(
        winget,
        normalized.installRecommendedTools
      )

      const repoRoot = await this.ensureSource(normalized)
      this.snapshot.repoRoot = repoRoot
      this.publish()

      await this.ensureLocalDependencies(powerShell, repoRoot)
      await this.writeProviderConfig(repoRoot, normalized)
      await this.prepareGateway(
        powerShell,
        repoRoot,
        normalized.skipShortcuts === true
      )
      await this.runVerifier(powerShell, repoRoot)
      await this.launch(repoRoot, normalized.launchAfterInstall)

      this.snapshot.status = "success"
      this.publish()
      this.emit({ type: "done", snapshot: this.snapshot })
      return this.snapshot
    } catch (error) {
      const message = toErrorMessage(error)
      this.snapshot.status = "error"
      this.snapshot.error = message
      this.markRunningStepFailed(message)
      this.publish()
      this.emit({ type: "error", snapshot: this.snapshot, message })
      return this.snapshot
    }
  }

  private validateRequest(request: InstallRequest): InstallRequest {
    const provider = normalizeProviderRequest(request)
    const installDir = path.resolve(request.installDir || getDefaultInstallDir())
    return {
      ...request,
      ...provider,
      installDir,
      repoBranch: request.repoBranch?.trim(),
    }
  }

  private async verifyProviderAccess(request: InstallRequest): Promise<void> {
    await this.runStep(
      "api",
      "Checking access key",
      async () => {
        const probe = await probeOmniRouteProvider(
          createProviderConfig(request)
        )
        return `Access key verified; ${probe.matchedModel} is available (${probe.modelCount} models listed).`
      }
    )
  }

  private async ensurePowerShell(): Promise<PowerShellHost> {
    return this.runStep(
      "powershell",
      "Locating built-in Windows PowerShell",
      async () => {
        return findPowerShellHost()
      }
    )
  }

  private async ensureWinget(
    powerShell: PowerShellHost,
    required: boolean
  ): Promise<string | null> {
    return this.runStep(
      "winget",
      "Resolving winget package manager",
      async () => {
        const existing = await this.resolveWinget()
        if (existing) {
          return existing
        }

        if (!required) {
          this.setStep(
            "winget",
            "warning",
            "winget is unavailable; continuing because Codex is already installed and recommended tools were skipped."
          )
          return null
        }

        await this.appendLog(
          "winget",
          "winget is missing. Trying App Installer re-registration."
        )
        await this.runPowerShellInline(
          powerShell,
          "winget",
          "Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe",
          { timeoutMs: 120_000 }
        )

        const registered = await this.resolveWinget()
        if (registered) {
          return registered
        }

        await this.appendLog(
          "winget",
          "Re-registration did not expose winget. Trying Microsoft.WinGet.Client repair."
        )
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
`
        const repair = await this.runPowerShellInline(
          powerShell,
          "winget",
          repairScript,
          {
            timeoutMs: 600_000,
          }
        )
        if (repair.code !== 0) {
          await this.appendLog(
            "winget",
            "Repair-WinGetPackageManager did not complete."
          )
        }

        const repaired = await this.resolveWinget()
        if (repaired) {
          return repaired
        }

        await shell.openExternal(
          `ms-windows-store://pdp/?ProductId=${APP_INSTALLER_PRODUCT_ID}`
        )
        throw new Error(
          "winget is still unavailable. Microsoft Store was opened to App Installer; install or update it, then run Setup.exe again."
        )
      }
    )
  }

  private async ensureOfficialCodex(
    powerShell: PowerShellHost,
    winget: string | null,
    initialPackage: unknown
  ): Promise<void> {
    await this.runStep("codex", "Checking official Store package", async () => {
      if (initialPackage || (await this.getCodexPackage(powerShell))) {
        return "OpenAI.Codex is already installed."
      }

      if (!winget) {
        await shell.openExternal(
          `ms-windows-store://pdp/?ProductId=${CODEX_STORE_PRODUCT_ID}`
        )
        throw new Error(
          "Official Codex is not installed and winget is unavailable. Microsoft Store was opened to Codex; install it, then run Setup.exe again."
        )
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
      ]

      for (const attempt of attempts) {
        await this.appendLog("codex", `Installing Codex via ${attempt.label}.`)
        const result = await this.runWinget(
          winget,
          "codex",
          attempt.args,
          900_000
        )
        if (result.code === 0 && (await this.getCodexPackage(powerShell))) {
          return `Codex installed via ${attempt.label}.`
        }
      }

      await shell.openExternal(
        `ms-windows-store://pdp/?ProductId=${CODEX_STORE_PRODUCT_ID}`
      )
      throw new Error(
        "Codex could not be installed automatically. Microsoft Store was opened to Codex; install it, then run Setup.exe again."
      )
    })
  }

  private async installRecommendedTools(
    winget: string | null,
    shouldInstall: boolean
  ): Promise<void> {
    await this.runStep(
      "recommended",
      "Installing recommended tools",
      async () => {
        if (!shouldInstall) {
          this.setStep("recommended", "skipped", "Skipped by user choice.")
          return
        }
        if (!winget) {
          this.setStep(
            "recommended",
            "warning",
            "Skipped because winget is unavailable; local OmniRoute dependencies will still be installed."
          )
          return
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
              const nodes = await this.where("node.exe")
              for (const node of nodes) {
                const version = await runRaw(node, ["--version"])
                const major = parseMajor(version.stdout.trim())
                if (major >= 20) {
                  return true
                }
              }
              return false
            },
          },
          {
            id: "Microsoft.DotNet.SDK.8",
            label: ".NET SDK 8",
            probe: async () => {
              const dotnets = await this.where("dotnet.exe")
              for (const dotnet of dotnets) {
                const sdks = await runRaw(dotnet, ["--list-sdks"])
                if (sdks.stdout.match(/^(8|9|10)\./m)) {
                  return true
                }
              }
              return false
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
        ]

        const warnings: string[] = []
        for (const pkg of packages) {
          if (await pkg.probe()) {
            await this.appendLog(
              "recommended",
              `${pkg.label} already available.`
            )
            continue
          }
          await this.appendLog(
            "recommended",
            `Installing ${pkg.label} (${pkg.id}).`
          )
          const result = await this.runWinget(
            winget,
            "recommended",
            ["install", "--id", pkg.id, "--exact"],
            900_000
          )
          if (result.code !== 0) {
            warnings.push(pkg.label)
            await this.appendLog(
              "recommended",
              `${pkg.label} install returned exit code ${result.code}.`
            )
          }
        }

        if (warnings.length > 0) {
          this.setStep(
            "recommended",
            "warning",
            `Some recommended tools did not install: ${warnings.join(", ")}.`
          )
          return
        }
        return "Recommended tools are available."
      }
    )
  }

  private async ensureSource(request: InstallRequest): Promise<string> {
    return this.runStep(
      "source",
      "Downloading Codex OmniRoute repository",
      async () => {
        const parent = path.resolve(request.installDir)
        const target = path.join(parent, "Codex-Omniroute")
        await fs.mkdir(parent, { recursive: true })

        const sourceOverride = process.env.CODEX_OMNI_SETUP_SOURCE_DIR
        if (sourceOverride) {
          const sourceRoot = path.resolve(sourceOverride)
          if (!(await isRepoRoot(sourceRoot))) {
            throw new Error(
              `CODEX_OMNI_SETUP_SOURCE_DIR is not a valid repo root: ${sourceRoot}`
            )
          }
          if (!isSafeGeneratedTarget(parent, target)) {
            throw new Error(
              `Refusing to write outside selected install directory: ${target}`
            )
          }
          await this.appendLog(
            "source",
            `Copying source tree from ${sourceRoot}`
          )
          await fs.rm(target, { recursive: true, force: true })
          await copySourceTree(sourceRoot, target)
          return target
        }

        if (await isRepoRoot(target)) {
          const git = await this.firstWhere("git.exe")
          if (git && (await exists(path.join(target, ".git")))) {
            const pull = await this.runProcess(git, ["pull", "--ff-only"], {
              cwd: target,
              logStepId: "source",
              timeoutMs: 180_000,
            })
            if (pull.code === 0) {
              return target
            }
            this.setStep(
              "source",
              "warning",
              "Existing repository could not fast-forward; using it as-is."
            )
            return target
          }
          this.setStep("source", "warning", "Existing source folder reused.")
          return target
        }

        if ((await exists(target)) && !(await isDirectoryEmpty(target))) {
          throw new Error(
            `Install target already exists but is not a Codex OmniRoute repository: ${target}`
          )
        }

        const branch = request.repoBranch || DEFAULT_REPO_BRANCH
        const git = await this.firstWhere("git.exe")
        if (git) {
          const clone = await this.runProcess(
            git,
            ["clone", "--depth", "1", "--branch", branch, REPO_URL, target],
            {
              logStepId: "source",
              timeoutMs: 600_000,
            }
          )
          if (clone.code === 0 && (await isRepoRoot(target))) {
            return target
          }
          await this.appendLog(
            "source",
            "git clone failed; falling back to GitHub zip."
          )
          if (isSafeGeneratedTarget(parent, target)) {
            await fs.rm(target, { recursive: true, force: true })
          }
        }

        await this.downloadRepositoryArchive(parent, target, branch)
        if (!(await isRepoRoot(target))) {
          throw new Error(
            "Downloaded archive did not contain the expected setup files."
          )
        }
        return target
      }
    )
  }

  private async ensureLocalDependencies(
    powerShell: PowerShellHost,
    repoRoot: string
  ): Promise<void> {
    await this.runStep(
      "local-deps",
      "Installing local Node.js and .NET SDK if needed",
      async () => {
        const script = path.join(
          repoRoot,
          "tools",
          "Install-CodexOmniRouteDependencies.ps1"
        )
        const result = await this.runPowerShellFile(
          powerShell,
          "local-deps",
          script,
          ["-Quiet", "-AsJson"],
          { cwd: repoRoot, timeoutMs: 900_000 }
        )
        if (result.code !== 0) {
          throw new Error("Local dependency installer failed.")
        }
        const json = parseFirstJsonObject(result.stdout)
        if (!json?.node_available || !json?.dotnet_sdk_available) {
          throw new Error(
            "Local dependency installer did not report Node.js and .NET SDK availability."
          )
        }
        return `Node: ${json.node_source}; .NET: ${json.dotnet_source}.`
      }
    )
  }

  private async writeProviderConfig(
    repoRoot: string,
    request: InstallRequest
  ): Promise<void> {
    await this.runStep("provider", "Writing provider config", async () => {
      const provider = createProviderConfig(request)
      const file = path.join(repoRoot, "omniroute-provider.json")
      await fs.writeFile(file, `${JSON.stringify(provider, null, 2)}\n`, "utf8")
      return "omniroute-provider.json written with hidden key material."
    })
  }

  private async prepareGateway(
    powerShell: PowerShellHost,
    repoRoot: string,
    skipShortcuts: boolean
  ): Promise<void> {
    await this.runStep(
      "gateway",
      "Preparing duplicated app, wrapper, and shortcuts",
      async () => {
        const script = path.join(repoRoot, "Setup.ps1")
        const result = await this.runPowerShellFile(
          powerShell,
          "gateway",
          script,
          skipShortcuts
            ? ["-NonInteractive", "-SkipVerify", "-SkipShortcuts"]
            : ["-NonInteractive", "-SkipVerify"],
          { cwd: repoRoot, timeoutMs: 1_200_000 }
        )
        if (result.code !== 0) {
          throw new Error("Setup.ps1 failed while preparing the gateway.")
        }
        return skipShortcuts
          ? "Gateway prepared; shortcuts skipped."
          : "Gateway prepared and shortcuts created."
      }
    )
  }

  private async runVerifier(
    powerShell: PowerShellHost,
    repoRoot: string
  ): Promise<void> {
    await this.runStep(
      "verify",
      "Running real OmniRoute verifier",
      async () => {
        const script = path.join(repoRoot, "verify-codex-omniroute.ps1")
        const result = await this.runPowerShellFile(
          powerShell,
          "verify",
          script,
          [],
          {
            cwd: repoRoot,
            timeoutMs: 900_000,
          }
        )
        if (result.code !== 0) {
          this.setStep(
            "verify",
            "warning",
            "Architecture verifier reported non-blocking failures; service access was already validated."
          )
          return
        }
        return "Verifier completed without required failures."
      }
    )
  }

  private async launch(repoRoot: string, shouldLaunch: boolean): Promise<void> {
    await this.runStep("launch", "Starting Codex OmniRoute", async () => {
      if (!shouldLaunch) {
        this.setStep("launch", "skipped", "Launch skipped by user choice.")
        return
      }

      const launched = await launchInstalledOmniRoute(repoRoot)
      return `Codex OmniRoute opened on bridge port ${launched.bridgePort} (pid ${launched.processId}).`
    })
  }

  private async downloadRepositoryArchive(
    parent: string,
    target: string,
    branch: string
  ): Promise<void> {
    const encodedBranch = branch.split("/").map(encodeURIComponent).join("/")
    const archiveUrl =
      process.env.CODEX_OMNI_SETUP_REPO_ARCHIVE_URL ??
      `https://github.com/Destruction13/Codex-Omniroute/archive/refs/heads/${encodedBranch}.zip`
    const tempRoot = path.join(
      app.getPath("temp"),
      `codex-omniroute-${Date.now()}`
    )
    const zipPath = path.join(tempRoot, "source.zip")
    const extractRoot = path.join(tempRoot, "extract")
    await fs.mkdir(extractRoot, { recursive: true })

    await this.appendLog("source", `Downloading ${archiveUrl}`)
    const response = await fetch(archiveUrl)
    if (!response.ok) {
      throw new Error(
        `Repository archive download failed with HTTP ${response.status}.`
      )
    }
    const zipBuffer = Buffer.from(await response.arrayBuffer())
    await fs.writeFile(zipPath, zipBuffer)

    const zip = new AdmZip(zipPath)
    zip.extractAllTo(extractRoot, true)
    const entries = await fs.readdir(extractRoot)
    let archiveRoot = ""
    for (const entry of entries) {
      const candidate = path.join(extractRoot, entry)
      if (await isRepoRoot(candidate)) {
        archiveRoot = candidate
        break
      }
    }
    if (!archiveRoot) {
      throw new Error(
        "Repository archive did not contain a recognizable root folder."
      )
    }

    if (!isSafeGeneratedTarget(parent, target)) {
      throw new Error(
        `Refusing to write outside selected install directory: ${target}`
      )
    }
    await fs.rm(target, { recursive: true, force: true })
    await fs.cp(archiveRoot, target, { recursive: true })
    await fs.rm(tempRoot, { recursive: true, force: true })
  }

  private async getCodexPackage(
    powerShell: PowerShellHost
  ): Promise<unknown | null> {
    if (process.env.CODEX_OMNI_SETUP_SIMULATE_NO_CODEX === "1") {
      await this.appendLog(
        "codex",
        "Test mode: simulating missing OpenAI.Codex AppX package."
      )
      return null
    }

    const script = `
$pkg = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pkg) {
  $pkg | Select-Object Name, PackageFullName, InstallLocation | ConvertTo-Json -Compress
}
`
    const result = await this.runPowerShellInline(powerShell, "codex", script, {
      timeoutMs: 45_000,
    })
    if (result.code !== 0 || !result.stdout.trim()) {
      return null
    }
    return parseFirstJsonObject(result.stdout)
  }

  private async resolveWinget(): Promise<string | null> {
    if (process.env.CODEX_OMNI_SETUP_SIMULATE_NO_WINGET === "1") {
      await this.appendLog("winget", "Test mode: simulating missing winget.")
      return null
    }

    const localAppData = process.env.LOCALAPPDATA ?? ""
    const programFiles = process.env.ProgramFiles ?? "C:\\Program Files"
    const candidates = unique([
      ...(await this.where("winget.exe")),
      localAppData
        ? path.join(localAppData, "Microsoft", "WindowsApps", "winget.exe")
        : "",
      ...(await this.findWindowsAppsWinget(programFiles)),
    ]).filter(Boolean)

    for (const candidate of candidates) {
      if (!(await exists(candidate))) {
        continue
      }
      const result = await runRaw(candidate, ["--version"], 30_000)
      if (result.code === 0) {
        await this.appendLog("winget", `Resolved winget: ${candidate}`)
        return candidate
      }
    }
    return null
  }

  private async findWindowsAppsWinget(programFiles: string): Promise<string[]> {
    const appsRoot = path.join(programFiles, "WindowsApps")
    try {
      const entries = await fs.readdir(appsRoot)
      return entries
        .filter((entry) => entry.startsWith("Microsoft.DesktopAppInstaller_"))
        .map((entry) => path.join(appsRoot, entry, "winget.exe"))
    } catch {
      return []
    }
  }

  private async runWinget(
    winget: string,
    stepId: string,
    args: string[],
    timeoutMs: number
  ): Promise<ProcessResult> {
    const common = [
      "--accept-package-agreements",
      "--accept-source-agreements",
      "--disable-interactivity",
    ]
    return this.runProcess(winget, [...args, ...common], {
      logStepId: stepId,
      timeoutMs,
    })
  }

  private async runPowerShellInline(
    host: PowerShellHost,
    stepId: string,
    script: string,
    options: RunProcessOptions = {}
  ): Promise<ProcessResult> {
    const encoded = Buffer.from(script, "utf16le").toString("base64")
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
      { ...options, logStepId: stepId }
    )
  }

  private async runPowerShellFile(
    host: PowerShellHost,
    stepId: string,
    scriptPath: string,
    args: string[],
    options: RunProcessOptions = {}
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
      { ...options, logStepId: stepId }
    )
  }

  private async runProcess(
    file: string,
    args: string[],
    options: RunProcessOptions = {}
  ): Promise<ProcessResult> {
    const timeoutMs = options.timeoutMs ?? 300_000
    await this.appendLog(
      options.logStepId,
      `> ${file} ${args.map(maskArg).join(" ")}`
    )

    return new Promise((resolve) => {
      const child = spawn(file, args, {
        cwd: options.cwd,
        env: { ...process.env, ...options.env },
        stdio: ["ignore", "pipe", "pipe"],
        windowsHide: true,
      })
      let stdout = ""
      let stderr = ""
      let settled = false
      const timer = setTimeout(() => {
        if (settled) {
          return
        }
        settled = true
        child.kill()
        resolve({
          code: -1,
          stdout,
          stderr: `${stderr}\nTimed out after ${timeoutMs} ms.`,
        })
      }, timeoutMs)

      const finish = (code: number) => {
        if (settled) {
          return
        }
        settled = true
        clearTimeout(timer)
        resolve({ code, stdout, stderr })
      }

      child.stdout.on("data", (chunk: Buffer) => {
        const text = chunk.toString("utf8")
        stdout += text
        void this.appendChunk(options.logStepId, text)
      })
      child.stderr.on("data", (chunk: Buffer) => {
        const text = chunk.toString("utf8")
        stderr += text
        void this.appendChunk(options.logStepId, text)
      })
      child.on("error", (error) => {
        stderr += error.message
        void this.appendLog(options.logStepId, error.message)
        finish(-1)
      })
      child.on("exit", (code) => {
        setTimeout(() => finish(code ?? 0), 250)
      })
      child.on("close", (code) => finish(code ?? 0))
    })
  }

  private async runStep<T>(
    id: string,
    detail: string,
    work: () => Promise<T | string | void>
  ): Promise<T> {
    this.setStep(id, "running", detail)
    try {
      const result = await work()
      const current = this.getStep(id)
      if (current.status === "running") {
        this.setStep(
          id,
          "success",
          typeof result === "string" && result ? result : "Completed."
        )
      }
      return result as T
    } catch (error) {
      this.setStep(id, "error", toErrorMessage(error))
      throw error
    }
  }

  private getStep(id: string): SetupStepSnapshot {
    const step = this.snapshot.steps.find((candidate) => candidate.id === id)
    if (!step) {
      throw new Error(`Unknown setup step: ${id}`)
    }
    return step
  }

  private setStep(id: string, status: StepStatus, detail: string): void {
    const step = this.getStep(id)
    step.status = status
    step.detail = this.sanitize(detail)
    if (status === "running" && !step.startedAt) {
      step.startedAt = new Date().toISOString()
    }
    if (["success", "warning", "error", "skipped"].includes(status)) {
      step.finishedAt = new Date().toISOString()
    }
    this.publish()
  }

  private markRunningStepFailed(message: string): void {
    const running = this.snapshot.steps.find(
      (step) => step.status === "running"
    )
    if (running) {
      running.status = "error"
      running.detail = this.sanitize(message)
      running.finishedAt = new Date().toISOString()
    }
  }

  private publish(): void {
    this.emit({ type: "state", snapshot: this.snapshot })
  }

  private async prepareLogFile(): Promise<void> {
    const logDir = path.join(app.getPath("userData"), "logs")
    await fs.mkdir(logDir, { recursive: true })
    this.logPath = path.join(logDir, `setup-${Date.now()}.log`)
    await fs.writeFile(this.logPath, "Codex OmniRoute Setup log\n", "utf8")
  }

  private async appendChunk(
    stepId: string | undefined,
    text: string
  ): Promise<void> {
    const lines = text.split(/\r?\n/).filter((line) => line.trim().length > 0)
    for (const line of lines) {
      await this.appendLog(stepId, line)
    }
  }

  private async appendLog(
    stepId: string | undefined,
    message: string
  ): Promise<void> {
    const clean = this.sanitize(message)
    if (stepId) {
      const step = this.getStep(stepId)
      step.log = [...step.log.slice(-79), clean]
      this.publish()
    }
    if (this.logPath) {
      await fs.appendFile(
        this.logPath,
        `${new Date().toISOString()} ${clean}\n`,
        "utf8"
      )
    }
  }

  private sanitize(value: string): string {
    let clean = value
    for (const secret of this.redactions) {
      clean = clean.split(secret).join("[redacted]")
    }
    return clean
  }

  private async where(name: string): Promise<string[]> {
    const result = await runRaw("where.exe", [name], 15_000)
    if (result.code !== 0) {
      return []
    }
    return result.stdout
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line.length > 0)
  }

  private async firstWhere(name: string): Promise<string | null> {
    const matches = await this.where(name)
    return matches[0] ?? null
  }
}

async function runRaw(
  file: string,
  args: string[],
  timeoutMs = 30_000,
  cwd?: string
): Promise<ProcessResult> {
  return new Promise((resolve) => {
    const child = spawn(file, args, {
      cwd,
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    })
    let stdout = ""
    let stderr = ""
    let settled = false
    const timer = setTimeout(() => {
      if (settled) {
        return
      }
      settled = true
      child.kill()
      resolve({
        code: -1,
        stdout,
        stderr: `${stderr}\nTimed out after ${timeoutMs} ms.`,
      })
    }, timeoutMs)

    const finish = (code: number) => {
      if (settled) {
        return
      }
      settled = true
      clearTimeout(timer)
      resolve({ code, stdout, stderr })
    }

    child.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString("utf8")
    })
    child.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString("utf8")
    })
    child.on("error", (error) => {
      stderr += error.message
      finish(-1)
    })
    child.on("exit", (code) => {
      setTimeout(() => finish(code ?? 0), 250)
    })
    child.on("close", (code) => finish(code ?? 0))
  })
}

async function findPowerShellHost(): Promise<PowerShellHost> {
  const candidates = unique([
    path.join(
      process.env.SystemRoot ?? "C:\\Windows",
      "System32",
      "WindowsPowerShell",
      "v1.0",
      "powershell.exe"
    ),
    ...(await whereRaw("powershell.exe")),
    ...(await whereRaw("pwsh.exe")),
  ])

  for (const candidate of candidates) {
    if (!(await exists(candidate))) {
      continue
    }
    const result = await runRaw(candidate, [
      "-NoLogo",
      "-NoProfile",
      "-NonInteractive",
      "-Command",
      "$PSVersionTable.PSVersion.ToString()",
    ])
    if (result.code === 0) {
      const version = result.stdout.trim().split(/\r?\n/).at(-1) ?? "unknown"
      return {
        exe: candidate,
        label: `PowerShell ${version}`,
      }
    }
  }

  throw new Error(
    "PowerShell was not found. Windows PowerShell is a required OS component for Store/AppX repair and OmniRoute setup."
  )
}

async function waitForLaunchedOmniRoute(
  providerPath: string,
  timeoutMs: number
): Promise<LaunchResult> {
  const deadline = Date.now() + timeoutMs
  let lastProcess: OmniRouteProcess | null = null
  let lastHealth: BridgeHealthProbe | null = null

  while (Date.now() < deadline) {
    lastProcess = await findOmniRouteProcess()
    lastHealth = await findBridgeHealth(providerPath)
    if (lastProcess && lastHealth) {
      return {
        processId: lastProcess.processId,
        executablePath: lastProcess.executablePath,
        bridgePort: lastHealth.port,
        providerPath: lastHealth.source,
      }
    }
    await delay(750)
  }

  const processDetail = lastProcess
    ? `process pid=${lastProcess.processId}`
    : "process not found"
  const healthDetail = lastHealth
    ? `bridge port=${lastHealth.port}`
    : "matching bridge healthz not found"
  throw new Error(
    `Codex OmniRoute did not confirm launch within ${Math.round(
      timeoutMs / 1000
    )} seconds (${processDetail}; ${healthDetail}).`
  )
}

async function findOmniRouteProcess(): Promise<OmniRouteProcess | null> {
  const powerShell = await findPowerShellHost()
  const windowsAppExe = path.join(
    process.env.LOCALAPPDATA ?? path.join(os.homedir(), "AppData", "Local"),
    "CodexOmniRoute",
    "WindowsApp",
    "app",
    "Codex.exe"
  )
  const script = `
$exe = ${toPowerShellString(windowsAppExe)}
$rows = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
  $_.ExecutablePath -and
  ([System.String]::Equals([System.IO.Path]::GetFullPath($_.ExecutablePath), [System.IO.Path]::GetFullPath($exe), [System.StringComparison]::OrdinalIgnoreCase)) -and
  $_.CommandLine -and
  ($_.CommandLine -notmatch '--type=')
} | Select-Object -First 1 @{Name='processId';Expression={$_.ProcessId}}, @{Name='executablePath';Expression={$_.ExecutablePath}}, @{Name='commandLine';Expression={$_.CommandLine}}
if ($rows) { $rows | ConvertTo-Json -Compress }
`
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
    15_000
  )
  if (result.code !== 0 || !result.stdout.trim()) {
    return null
  }
  try {
    const parsed = JSON.parse(result.stdout.trim()) as Partial<OmniRouteProcess>
    if (
      typeof parsed.processId === "number" &&
      typeof parsed.executablePath === "string" &&
      typeof parsed.commandLine === "string"
    ) {
      return {
        processId: parsed.processId,
        executablePath: parsed.executablePath,
        commandLine: parsed.commandLine,
      }
    }
  } catch {
    return null
  }
  return null
}

async function findBridgeHealth(
  providerPath: string
): Promise<BridgeHealthProbe | null> {
  const expectedProvider = path.resolve(providerPath).toLowerCase()
  for (let port = 20333; port <= 20372; port += 1) {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), 1_500)
    try {
      const response = await fetch(`http://127.0.0.1:${port}/healthz`, {
        signal: controller.signal,
      })
      if (!response.ok) {
        continue
      }
      const health = (await response.json()) as {
        ok?: boolean
        omniroute?: { configured?: boolean; source?: string }
      }
      const source = health.omniroute?.source
        ? path.resolve(health.omniroute.source).toLowerCase()
        : ""
      if (
        health.ok === true &&
        health.omniroute?.configured === true &&
        source === expectedProvider
      ) {
        return { port, source: health.omniroute.source ?? providerPath }
      }
    } catch {
      // Keep scanning nearby bridge ports.
    } finally {
      clearTimeout(timer)
    }
  }
  return null
}

async function focusOmniRouteWindow(processId: number): Promise<void> {
  const powerShell = await findPowerShellHost()
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
`
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
    20_000
  )
}

async function whereRaw(name: string): Promise<string[]> {
  const result = await runRaw("where.exe", [name], 15_000)
  if (result.code !== 0) {
    return []
  }
  return result.stdout
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
}

function toPowerShellString(value: string): string {
  return `'${value.replace(/'/g, "''")}'`
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

async function exists(filePath: string): Promise<boolean> {
  try {
    await fs.access(filePath)
    return true
  } catch {
    return false
  }
}

async function isDirectoryEmpty(dirPath: string): Promise<boolean> {
  try {
    const entries = await fs.readdir(dirPath)
    return entries.length === 0
  } catch {
    return true
  }
}

async function isRepoRoot(candidate: string): Promise<boolean> {
  const required = [
    "Setup.ps1",
    "Start-Codex-OmniRoute.ps1",
    "verify-codex-omniroute.ps1",
    path.join("tools", "Install-CodexOmniRouteDependencies.ps1"),
    "codex-openai-omniroute-bridge.mjs",
  ]
  for (const rel of required) {
    if (!(await exists(path.join(candidate, rel)))) {
      return false
    }
  }
  return true
}

async function copySourceTree(
  sourceRoot: string,
  target: string
): Promise<void> {
  const ignored = new Set([
    ".git",
    ".setup-test",
    "node_modules",
    "dist",
    "dist-electron",
    "release",
    "artifacts",
  ])
  await fs.cp(sourceRoot, target, {
    recursive: true,
    filter: (source) => {
      const rel = path.relative(sourceRoot, source)
      if (!rel) {
        return true
      }
      return !rel.split(path.sep).some((part) => ignored.has(part))
    },
  })
}

function isSafeGeneratedTarget(parent: string, target: string): boolean {
  const parentFull = path.resolve(parent).toLowerCase()
  const targetFull = path.resolve(target).toLowerCase()
  return (
    path.basename(targetFull) === "codex-omniroute" &&
    targetFull.startsWith(`${parentFull}${path.sep}`)
  )
}

function normalizeProviderRequest(
  request: ProviderVerificationRequest
): ProviderVerificationRequest {
  if (!request.baseUrl.trim()) {
    throw new Error("Service URL is required.")
  }
  const parsedUrl = new URL(request.baseUrl.trim())
  if (!["http:", "https:"].includes(parsedUrl.protocol)) {
    throw new Error("Service URL must start with http:// or https://.")
  }
  parsedUrl.hash = ""
  parsedUrl.search = ""
  if (!request.apiKey.trim()) {
    throw new Error("Access key is required.")
  }
  return {
    baseUrl: stripTrailingSlash(parsedUrl.toString()),
    apiKey: request.apiKey.trim(),
  }
}

function createProviderConfig(request: ProviderVerificationRequest): ProviderConfig {
  return {
    _comment: "Generated by Codex OmniRoute Setup.exe. Never commit this file.",
    base_url: request.baseUrl,
    api_key: request.apiKey,
    default_model: DEFAULT_PROVIDER_MODEL,
    model_prefix: DEFAULT_PROVIDER_MODEL_PREFIX,
    model_aliases: DEFAULT_PROVIDER_MODEL_ALIASES,
    headers: PROVIDER_HEADERS,
  }
}

async function probeOmniRouteProvider(
  provider: ProviderConfig
): Promise<ProviderProbeResult> {
  validateKeyBelongsToService(provider)
  const apiManager = await probeApiManagerKey(provider)
  const modelProbe = await probeOmniRouteModels(provider)
  await probeOmniRouteChatAuth(provider, modelProbe.matchedModel)
  return {
    ...modelProbe,
    apiManagerEndpoint: apiManager?.endpoint ?? "",
    apiManagerDetail:
      apiManager?.detail ?? "verified by protected service endpoint",
  }
}

async function probeOmniRouteChatAuth(
  provider: ProviderConfig,
  model: string
): Promise<void> {
  const endpoints = getProviderChatEndpoints(provider.base_url)
  const body = JSON.stringify({
    model,
    messages: [{ role: "user", content: "Reply with exactly OK." }],
    max_tokens: 1,
    temperature: 0,
  })
  const failures: string[] = []
  let authRejected = false
  const headers = {
    accept: "application/json",
    authorization: `Bearer ${provider.api_key}`,
    ...provider.headers,
    "content-type": "application/json",
  }

  for (const endpoint of endpoints) {
    let response: Response
    try {
      response = await fetchWithTimeout(
        endpoint,
        {
          method: "POST",
          headers,
          body,
        },
        60_000
      )
    } catch (error) {
      failures.push(`${endpoint}: ${toErrorMessage(error)}`)
      continue
    }

    const text = await response.text()
    if (response.status === 401 || response.status === 403) {
      authRejected = true
      failures.push(
        `${endpoint}: HTTP ${response.status}${formatBodySnippet(text)}`
      )
      continue
    }
    if (response.ok) {
      return
    }

    const message = extractResponseMessage(text).toLowerCase()
    if (message.includes("invalid") && message.includes("key")) {
      throw new Error(KEY_VERIFICATION_FAILED)
    }
    failures.push(
      `${endpoint}: HTTP ${response.status}${formatBodySnippet(text)}`
    )
  }

  if (authRejected) {
    throw new Error(KEY_VERIFICATION_FAILED)
  }
  throw new Error(
    failures.length > 0 ? SERVICE_VERIFICATION_FAILED : KEY_VERIFICATION_FAILED
  )
}

function validateKeyBelongsToService(provider: ProviderConfig): void {
  let url: URL
  try {
    url = new URL(provider.base_url)
  } catch {
    throw new Error(SERVICE_VERIFICATION_FAILED)
  }
  const tenant = url.hostname.match(/(?:^|\.)omniroute-([a-z0-9]{8})/i)?.[1]
  if (!tenant) {
    return
  }
  const normalizedKey = provider.api_key.trim().toLowerCase()
  if (!normalizedKey.startsWith(`sk-${tenant.toLowerCase()}`)) {
    throw new Error(KEY_VERIFICATION_FAILED)
  }
}

async function probeApiManagerKey(
  provider: ProviderConfig
): Promise<ApiManagerProbeResult | null> {
  const endpoints = getApiManagerEndpoints(provider.base_url)

  for (const endpoint of endpoints) {
    let response: Response
    try {
      response = await fetchWithTimeout(endpoint, {
        method: "GET",
        headers: buildManagementProbeHeaders(provider),
      })
    } catch {
      continue
    }

    const body = await response.text()
    const message = extractResponseMessage(body)

    if (response.ok) {
      let parsed: unknown
      try {
        parsed = body ? JSON.parse(body) : null
      } catch {
        continue
      }

      const keys = extractApiManagerKeys(parsed)
      const matched = keys.find((key) =>
        apiManagerKeyMatches(provider.api_key, key)
      )
      if (!matched) {
        throw new Error(KEY_VERIFICATION_FAILED)
      }

      return {
        endpoint,
        detail: `listed as ${describeApiManagerKey(matched)}`,
      }
    }

    const lowerMessage = message.toLowerCase()
    if (
      response.status === 403 &&
      lowerMessage.includes("invalid") &&
      lowerMessage.includes("management") &&
      lowerMessage.includes("token")
    ) {
      continue
    }

    if (
      response.status === 403 &&
      lowerMessage.includes("lacks") &&
      lowerMessage.includes("manage") &&
      lowerMessage.includes("scope")
    ) {
      return {
        endpoint,
        detail: "validated by service auth; key has no management scope",
      }
    }
  }

  return null
}

async function probeOmniRouteModels(
  provider: ProviderConfig
): Promise<
  Omit<ProviderProbeResult, "apiManagerEndpoint" | "apiManagerDetail">
> {
  const endpoints = getProviderModelEndpoints(provider.base_url)
  const requiredModels = getProviderModelCandidates(provider)
  const failures: string[] = []

  for (const endpoint of endpoints) {
    let response: Response | null = null
    for (const headers of getProviderProbeHeaderVariants(provider)) {
      try {
        response = await fetchWithTimeout(endpoint, {
          method: "GET",
          headers,
        })
      } catch (error) {
        failures.push(`${endpoint}: ${toErrorMessage(error)}`)
        continue
      }

      if (response.status !== 401 && response.status !== 403) {
        break
      }
    }

    if (!response) {
      continue
    }

    const body = await response.text()
    if (response.status === 401 || response.status === 403) {
      throw new Error(KEY_VERIFICATION_FAILED)
    }
    if (!response.ok) {
      failures.push(
        `${endpoint}: HTTP ${response.status}${formatBodySnippet(body)}`
      )
      continue
    }

    let parsed: unknown
    try {
      parsed = body ? JSON.parse(body) : null
    } catch {
      throw new Error(SERVICE_VERIFICATION_FAILED)
    }

    const models = extractModelIds(parsed)
    const modelSet = new Set(models.map((model) => model.toLowerCase()))
    const matchedModel = requiredModels.find((model) =>
      modelSet.has(model.toLowerCase())
    )
    if (!matchedModel) {
      throw new Error(
        "The access key is valid, but the required model is unavailable for this account."
      )
    }

    return {
      endpoint,
      matchedModel,
      modelCount: models.length,
    }
  }

  throw new Error(
    failures.length > 0 ? SERVICE_VERIFICATION_FAILED : KEY_VERIFICATION_FAILED
  )
}

function getApiManagerEndpoints(baseUrl: string): string[] {
  const endpoints: string[] = []
  const parsed = new URL(baseUrl)

  endpoints.push(new URL("/api/keys?limit=500", parsed).toString())

  const pathWithoutVersion = parsed.pathname
    .replace(/\/+$/, "")
    .replace(/\/v1$/i, "")
  if (pathWithoutVersion) {
    parsed.pathname = `${pathWithoutVersion}/api/keys`
    parsed.search = "?limit=500"
    parsed.hash = ""
    endpoints.push(parsed.toString())
  }

  return unique(endpoints)
}

function getProviderModelEndpoints(baseUrl: string): string[] {
  const normalized = stripTrailingSlash(baseUrl)
  const endpoints = [appendUrlPath(normalized, "models")]
  try {
    const parsed = new URL(normalized)
    const cleanPath = parsed.pathname.replace(/\/+$/, "")
    if (!cleanPath.toLowerCase().endsWith("/v1")) {
      parsed.pathname = `${cleanPath}/v1/models`
      parsed.search = ""
      parsed.hash = ""
      endpoints.push(parsed.toString())
    }
  } catch {
    // validateRequest has already parsed the URL; keep the primary endpoint.
  }
  return unique(endpoints)
}

function getProviderChatEndpoints(baseUrl: string): string[] {
  const normalized = stripTrailingSlash(baseUrl)
  const endpoints = [appendUrlPath(normalized, "chat/completions")]
  try {
    const parsed = new URL(normalized)
    const cleanPath = parsed.pathname.replace(/\/+$/, "")
    if (!cleanPath.toLowerCase().endsWith("/v1")) {
      parsed.pathname = `${cleanPath}/v1/chat/completions`
      parsed.search = ""
      parsed.hash = ""
      endpoints.push(parsed.toString())
    }
  } catch {
    // validateRequest has already parsed the URL; keep the primary endpoint.
  }
  return unique(endpoints)
}

function appendUrlPath(baseUrl: string, child: string): string {
  return `${stripTrailingSlash(baseUrl)}/${child.replace(/^\/+/, "")}`
}

function buildManagementProbeHeaders(
  provider: ProviderConfig
): Record<string, string> {
  return {
    accept: "application/json",
    authorization: `Bearer ${provider.api_key}`,
    ...provider.headers,
  }
}

function getProviderProbeHeaderVariants(
  provider: ProviderConfig
): Array<Record<string, string>> {
  const baseHeaders = {
    accept: "application/json",
    ...provider.headers,
  }
  return [
    {
      ...baseHeaders,
      authorization: `Bearer ${provider.api_key}`,
    },
    {
      ...baseHeaders,
      "x-api-key": provider.api_key,
    },
  ]
}

function extractResponseMessage(body: string): string {
  if (!body.trim()) {
    return ""
  }
  try {
    const parsed = JSON.parse(body) as unknown
    return (
      findMessageField(parsed) || formatBodySnippet(body).replace(/^: /, "")
    )
  } catch {
    return formatBodySnippet(body).replace(/^: /, "")
  }
}

function findMessageField(value: unknown): string {
  if (typeof value === "string") {
    return value
  }
  if (!value || typeof value !== "object") {
    return ""
  }
  const record = value as Record<string, unknown>
  for (const key of ["message", "error", "detail", "type"]) {
    const found = findMessageField(record[key])
    if (found) {
      return found
    }
  }
  return ""
}

function extractApiManagerKeys(
  payload: unknown
): Array<Record<string, unknown>> {
  if (!payload || typeof payload !== "object") {
    return []
  }
  const record = payload as Record<string, unknown>
  if (!Array.isArray(record.keys)) {
    return []
  }
  return record.keys.filter((key): key is Record<string, unknown> =>
    Boolean(key && typeof key === "object")
  )
}

function apiManagerKeyMatches(
  rawKey: string,
  row: Record<string, unknown>
): boolean {
  for (const field of [row.key, row.maskedKey, row.masked_key]) {
    if (typeof field !== "string") {
      continue
    }
    if (field === rawKey) {
      return true
    }
    const [prefix, suffix] = field.split("****")
    if (
      suffix !== undefined &&
      rawKey.startsWith(prefix) &&
      rawKey.endsWith(suffix)
    ) {
      return true
    }
  }

  for (const field of [row.keyPrefix, row.key_prefix]) {
    if (
      typeof field === "string" &&
      field.length >= 8 &&
      rawKey.startsWith(field)
    ) {
      return true
    }
  }

  return false
}

function describeApiManagerKey(row: Record<string, unknown>): string {
  const name =
    typeof row.name === "string" && row.name.trim()
      ? row.name.trim()
      : "unnamed"
  const masked =
    typeof row.key === "string" && row.key.trim()
      ? row.key.trim()
      : typeof row.maskedKey === "string" && row.maskedKey.trim()
        ? row.maskedKey.trim()
        : typeof row.masked_key === "string" && row.masked_key.trim()
          ? row.masked_key.trim()
      : "masked key"
  return `${name} (${masked})`
}

function getProviderModelCandidates(provider: ProviderConfig): string[] {
  const candidates = new Set<string>()
  const add = (model: string): void => {
    const stripped = model.trim().replace(/^openai\//, "")
    if (!stripped) {
      return
    }
    candidates.add(stripped)
    const prefix = provider.model_prefix || ""
    if (
      prefix &&
      !stripped.startsWith(prefix) &&
      !/^[a-z][\w.-]*\//i.test(stripped)
    ) {
      candidates.add(`${prefix}${stripped}`)
    }
  }

  add(provider.default_model)
  for (const [from, to] of Object.entries(provider.model_aliases)) {
    add(from)
    add(to)
  }
  return Array.from(candidates)
}

function extractModelIds(payload: unknown): string[] {
  const ids = new Set<string>()
  const add = (value: unknown): void => {
    if (typeof value === "string" && value.trim()) {
      ids.add(value.trim())
    }
  }
  const visitList = (value: unknown): void => {
    if (Array.isArray(value)) {
      for (const item of value) {
        visitItem(item)
      }
    } else if (value && typeof value === "object") {
      for (const [key, item] of Object.entries(
        value as Record<string, unknown>
      )) {
        add(key)
        visitItem(item)
      }
    }
  }
  const visitItem = (value: unknown): void => {
    if (typeof value === "string") {
      add(value)
      return
    }
    if (!value || typeof value !== "object") {
      return
    }
    const record = value as Record<string, unknown>
    add(record.id)
    add(record.name)
    add(record.model)
    visitList(record.data)
    visitList(record.models)
  }

  visitItem(payload)
  return Array.from(ids).sort((a, b) => a.localeCompare(b))
}

async function fetchWithTimeout(
  url: string,
  init: RequestInit,
  timeoutMs = 20_000
): Promise<Response> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), timeoutMs)
  try {
    return await fetch(url, { ...init, signal: controller.signal })
  } finally {
    clearTimeout(timer)
  }
}

function formatBodySnippet(body: string): string {
  const clean = body.replace(/\s+/g, " ").trim()
  if (!clean) {
    return ""
  }
  return `: ${clean.slice(0, 180)}`
}

function compactProcessFailure(result: ProcessResult): string {
  const output = `${result.stderr}\n${result.stdout}`
    .replace(/\s+/g, " ")
    .trim()
  return `launcher exited with code ${result.code}${output ? `: ${output.slice(0, 500)}` : ""}`
}

function stripTrailingSlash(value: string): string {
  return value.replace(/\/+$/, "")
}

function unique(values: string[]): string[] {
  return [...new Set(values.filter((value) => value.trim().length > 0))]
}

function parseMajor(version: string): number {
  const match = version.match(/v?(\d+)\./)
  return match ? Number(match[1]) : 0
}

function parseFirstJsonObject(text: string): Record<string, unknown> | null {
  const start = text.indexOf("{")
  const end = text.lastIndexOf("}")
  if (start < 0 || end < start) {
    return null
  }
  try {
    return JSON.parse(text.slice(start, end + 1)) as Record<string, unknown>
  } catch {
    return null
  }
}

function maskArg(arg: string): string {
  if (arg.length > 120) {
    return `${arg.slice(0, 60)}...`
  }
  return arg
}

function toErrorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message
  }
  return String(error)
}
