import {
  AlertTriangle,
  Check,
  ChevronLeft,
  ChevronRight,
  Circle,
  FolderOpen,
  LoaderCircle,
  Logs,
  Rocket,
  RotateCcw,
  ShieldCheck,
  TerminalSquare,
  X,
} from "lucide-react"
import { useEffect, useMemo, useState } from "react"

import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Checkbox } from "@/components/ui/checkbox"
import {
  Field,
  FieldContent,
  FieldDescription,
  FieldGroup,
  FieldLabel,
  FieldTitle,
} from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import { Progress } from "@/components/ui/progress"
import { ScrollArea } from "@/components/ui/scroll-area"
import { Separator } from "@/components/ui/separator"
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip"
import { cn } from "@/lib/utils"

const initialSteps: SetupStepSnapshot[] = [
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
].map(([id, title]) => ({
  id,
  title,
  detail: "Waiting",
  status: "pending",
  log: [],
}))

const fallbackApi: OmniSetupApi = {
  getDefaults: async () => ({
    installDir: "C:\\Users\\You\\CodexOmniRoute",
    snapshot: { status: "idle", steps: initialSteps },
  }),
  selectInstallDir: async () => null,
  startInstall: async () => undefined,
  openLog: async () => undefined,
  onEvent: () => () => undefined,
}

function App() {
  const setup = window.omniSetup ?? fallbackApi
  const [screen, setScreen] = useState<"location" | "credentials" | "install">(
    "location"
  )
  const [installDir, setInstallDir] = useState("")
  const [baseUrl, setBaseUrl] = useState("")
  const [apiKey, setApiKey] = useState("")
  const [imageApiKey, setImageApiKey] = useState("")
  const [installRecommendedTools, setInstallRecommendedTools] = useState(true)
  const [launchAfterInstall, setLaunchAfterInstall] = useState(true)
  const [snapshot, setSnapshot] = useState<SetupSnapshot>({
    status: "idle",
    steps: initialSteps,
  })
  const [formError, setFormError] = useState("")

  useEffect(() => {
    let mounted = true
    setup.getDefaults().then((defaults) => {
      if (!mounted) {
        return
      }
      setInstallDir(defaults.installDir)
      setSnapshot(defaults.snapshot)
    })
    const dispose = setup.onEvent((event) => {
      setSnapshot(event.snapshot)
      if (event.type === "error") {
        setFormError(event.message)
      }
    })
    return () => {
      mounted = false
      dispose()
    }
  }, [setup])

  const completedCount = snapshot.steps.filter((step) =>
    ["success", "warning", "skipped"].includes(step.status)
  ).length
  const progress = Math.round((completedCount / snapshot.steps.length) * 100)
  const activeStep =
    snapshot.steps.find((step) => step.status === "running") ??
    snapshot.steps.find((step) => step.status === "error") ??
    snapshot.steps.find((step) => step.status === "warning")
  const logs = useMemo(
    () =>
      snapshot.steps
        .flatMap((step) =>
          step.log.map((line) => ({
            step: step.title,
            line,
          }))
        )
        .slice(-140),
    [snapshot.steps]
  )

  const chooseFolder = async () => {
    const selected = await setup.selectInstallDir(installDir)
    if (selected) {
      setInstallDir(selected)
    }
  }

  const validateLocation = () => {
    if (!installDir.trim()) {
      setFormError("Select an install folder.")
      return
    }
    setFormError("")
    setScreen("credentials")
  }

  const validateAndStart = async () => {
    setFormError("")
    try {
      const parsed = new URL(baseUrl.trim())
      if (!["http:", "https:"].includes(parsed.protocol)) {
        setFormError("Base URL must start with http:// or https://.")
        return
      }
    } catch {
      setFormError("Enter a valid Base URL.")
      return
    }
    if (!apiKey.trim()) {
      setFormError("API key is required.")
      return
    }
    setScreen("install")
    await setup.startInstall({
      installDir,
      baseUrl,
      apiKey,
      imageApiKey,
      installRecommendedTools,
      launchAfterInstall,
    })
  }

  const retry = async () => {
    setFormError("")
    await validateAndStart()
  }

  const statusLabel =
    snapshot.status === "success"
      ? "Setup successful"
      : snapshot.status === "error"
        ? "Needs attention"
        : snapshot.status === "running"
          ? "Installing"
          : "Ready"

  return (
    <main className="installer-shell">
      <section className="installer-chrome">
        <div className="brand-lockup">
          <div className="brand-mark">
            <TerminalSquare />
          </div>
          <div>
            <p className="eyebrow">Windows bootstrapper</p>
            <h1>Codex OmniRoute Setup</h1>
          </div>
        </div>
        <Badge className={cn("status-badge", `status-${snapshot.status}`)}>
          {statusLabel}
        </Badge>
      </section>

      <section className="installer-grid">
        <aside className="setup-panel">
          <div className="panel-heading">
            <span>01</span>
            <div>
              <h2>Install target</h2>
              <p>Source, provider config, shortcuts, and local dependencies.</p>
            </div>
          </div>

          {screen === "location" && (
            <FieldGroup>
              <Field>
                <FieldLabel htmlFor="installDir">Folder</FieldLabel>
                <div className="folder-row">
                  <Input
                    id="installDir"
                    value={installDir}
                    onChange={(event) => setInstallDir(event.target.value)}
                    spellCheck={false}
                  />
                  <Tooltip>
                    <TooltipTrigger asChild>
                      <Button type="button" variant="secondary" onClick={chooseFolder}>
                        <FolderOpen data-icon="inline-start" />
                        Browse
                      </Button>
                    </TooltipTrigger>
                    <TooltipContent>Select a parent install folder.</TooltipContent>
                  </Tooltip>
                </div>
                <FieldDescription>
                  Final source path: {installDir || "..."}\Codex-Omniroute
                </FieldDescription>
              </Field>

              <div className="option-stack">
                <Field orientation="horizontal">
                  <Checkbox
                    id="recommended"
                    checked={installRecommendedTools}
                    onCheckedChange={(checked) =>
                      setInstallRecommendedTools(checked === true)
                    }
                  />
                  <FieldContent>
                    <FieldTitle>Install Windows developer tools</FieldTitle>
                    <FieldDescription>
                      PowerShell 7, Git, Node.js LTS, .NET SDK, Python, and GitHub CLI.
                    </FieldDescription>
                  </FieldContent>
                </Field>
                <Field orientation="horizontal">
                  <Checkbox
                    id="launchAfter"
                    checked={launchAfterInstall}
                    onCheckedChange={(checked) => setLaunchAfterInstall(checked === true)}
                  />
                  <FieldContent>
                    <FieldTitle>Launch after setup</FieldTitle>
                    <FieldDescription>
                      Start the OmniRoute desktop shortcut when verification completes.
                    </FieldDescription>
                  </FieldContent>
                </Field>
              </div>

              <div className="action-row">
                <Button type="button" onClick={validateLocation}>
                  Continue
                  <ChevronRight data-icon="inline-end" />
                </Button>
              </div>
            </FieldGroup>
          )}

          {screen === "credentials" && (
            <FieldGroup>
              <Field>
                <FieldLabel htmlFor="baseUrl">Base URL</FieldLabel>
                <Input
                  id="baseUrl"
                  value={baseUrl}
                  onChange={(event) => setBaseUrl(event.target.value)}
                  placeholder="https://your-omniroute.example/v1"
                  spellCheck={false}
                />
              </Field>
              <Field>
                <FieldLabel htmlFor="apiKey">API key</FieldLabel>
                <Input
                  id="apiKey"
                  value={apiKey}
                  onChange={(event) => setApiKey(event.target.value)}
                  type="password"
                  spellCheck={false}
                />
              </Field>
              <Field>
                <FieldLabel htmlFor="imageApiKey">Image API key</FieldLabel>
                <Input
                  id="imageApiKey"
                  value={imageApiKey}
                  onChange={(event) => setImageApiKey(event.target.value)}
                  type="password"
                  spellCheck={false}
                />
                <FieldDescription>Optional. Empty uses the main key.</FieldDescription>
              </Field>
              <div className="action-row split">
                <Button
                  type="button"
                  variant="secondary"
                  onClick={() => setScreen("location")}
                >
                  <ChevronLeft data-icon="inline-start" />
                  Back
                </Button>
                <Button type="button" onClick={validateAndStart}>
                  <ShieldCheck data-icon="inline-start" />
                  Verify and install
                </Button>
              </div>
            </FieldGroup>
          )}

          {screen === "install" && (
            <div className="install-summary">
              <div className="summary-meter">
                <Progress value={progress} />
                <span>{progress}%</span>
              </div>
              <Separator />
              <div className="summary-copy">
                <p>{activeStep?.title ?? "Complete"}</p>
                <span>{activeStep?.detail ?? "All steps finished."}</span>
              </div>
              {snapshot.status === "success" && (
                <div className="finish-actions">
                  <Button type="button" onClick={() => window.close()}>
                    <Rocket data-icon="inline-start" />
                    Finish
                  </Button>
                  <Button type="button" variant="secondary" onClick={setup.openLog}>
                    <Logs data-icon="inline-start" />
                    Open log
                  </Button>
                </div>
              )}
              {snapshot.status === "error" && (
                <div className="finish-actions">
                  <Button type="button" onClick={retry}>
                    <RotateCcw data-icon="inline-start" />
                    Retry
                  </Button>
                  <Button type="button" variant="secondary" onClick={setup.openLog}>
                    <Logs data-icon="inline-start" />
                    Open log
                  </Button>
                </div>
              )}
            </div>
          )}

          {formError && (
            <Alert variant="destructive">
              <AlertTriangle />
              <AlertTitle>Setup stopped</AlertTitle>
              <AlertDescription>{formError}</AlertDescription>
            </Alert>
          )}
        </aside>

        <section className="roadmap-panel">
          <div className="roadmap-header">
            <div>
              <p className="eyebrow">Roadmap</p>
              <h2>Dependency chain</h2>
            </div>
            <Badge variant="secondary">{completedCount}/{snapshot.steps.length}</Badge>
          </div>

          <div className="roadmap-list">
            {snapshot.steps.map((step, index) => (
              <RoadmapStep
                key={step.id}
                step={step}
                isLast={index === snapshot.steps.length - 1}
              />
            ))}
          </div>
        </section>

        <section className="log-panel">
          <div className="roadmap-header">
            <div>
              <p className="eyebrow">Trace</p>
              <h2>Installer output</h2>
            </div>
            <Button
              type="button"
              variant="ghost"
              size="sm"
              onClick={setup.openLog}
              disabled={!snapshot.logPath}
            >
              <Logs data-icon="inline-start" />
              Log file
            </Button>
          </div>
          <ScrollArea className="log-scroll">
            {logs.length === 0 ? (
              <div className="log-empty">Waiting for setup output.</div>
            ) : (
              <div className="log-lines">
                {logs.map((entry, index) => (
                  <div className="log-line" key={`${entry.step}-${index}`}>
                    <span>{entry.step}</span>
                    <p>{entry.line}</p>
                  </div>
                ))}
              </div>
            )}
          </ScrollArea>
        </section>
      </section>
    </main>
  )
}

function RoadmapStep({
  step,
  isLast,
}: {
  step: SetupStepSnapshot
  isLast: boolean
}) {
  const Icon =
    step.status === "success"
      ? Check
      : step.status === "warning"
        ? AlertTriangle
        : step.status === "error"
          ? X
          : step.status === "running"
            ? LoaderCircle
            : Circle

  return (
    <article className={cn("roadmap-step", `step-${step.status}`)}>
      <div className="rail">
        <span className="rail-node">
          <Icon className={step.status === "running" ? "spin" : undefined} />
        </span>
        {!isLast && <span className="rail-line" />}
      </div>
      <div className="step-copy">
        <div className="step-title">
          <h3>{step.title}</h3>
          <Badge variant="outline">{step.status}</Badge>
        </div>
        <p>{step.detail}</p>
      </div>
    </article>
  )
}

export default App
