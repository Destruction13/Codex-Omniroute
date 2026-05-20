import {
  AlertTriangle,
  Check,
  ChevronLeft,
  ChevronRight,
  Circle,
  FolderOpen,
  Globe2,
  LoaderCircle,
  Logs,
  Rocket,
  RotateCcw,
  ShieldCheck,
  TerminalSquare,
  X,
} from "lucide-react"
import { useEffect, useState } from "react"

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
import {
  Select,
  SelectContent,
  SelectGroup,
  SelectItem,
  SelectLabel,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
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
  ["api", "OmniRoute API Manager key"],
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
  launchInstalled: async () => ({
    processId: 0,
    executablePath: "",
    bridgePort: 0,
    providerPath: "",
  }),
  openLog: async () => undefined,
  onEvent: () => () => undefined,
}

const englishMessages = {
  actionBack: "Back",
  actionBrowse: "Browse",
  actionContinue: "Continue",
  actionFinish: "Finish",
  actionLogFile: "Log file",
  actionOpenLog: "Open log",
  actionRetry: "Retry",
  actionVerifyInstall: "Verify and install",
  activeDetailFallback: "The dependency chain is waiting to start.",
  activeReady: "Ready to install",
  alertSetupStopped: "Setup stopped",
  brandEyebrow: "Windows bootstrapper",
  completed: "completed",
  credentialsDescription:
    "Add the gateway endpoint and API key before installation starts.",
  credentialsTitle: "Provider access",
  dependencyChain: "Dependency chain",
  fieldApiKey: "API key",
  fieldBaseUrl: "Base URL",
  fieldFolder: "Folder",
  finalSourcePath: "Final source path",
  installDeveloperTools: "Install Windows developer tools",
  installDeveloperToolsDescription:
    "PowerShell 7, Git, Node.js LTS, .NET SDK, Python, and GitHub CLI.",
  installerOutput: "Installer output",
  language: "Language",
  launchAfterSetup: "Launch after setup",
  launchAfterSetupDescription:
    "Start the OmniRoute desktop shortcut when verification completes.",
  liveInstall: "Live install",
  locationDescription: "Choose where Codex OmniRoute will be installed.",
  locationTitle: "Install target",
  logEmpty: "Waiting for setup output.",
  roadmap: "Roadmap",
  statusError: "Needs attention",
  statusIdle: "Ready",
  statusRunning: "Installing",
  statusSuccess: "Setup successful",
  stepApi: "OmniRoute API Manager key",
  stepCodex: "Official Codex Store app",
  stepGateway: "Gateway, wrapper, shortcuts",
  stepLaunch: "Launch Codex OmniRoute",
  stepLocalDeps: "Local Node.js and .NET",
  stepPowerShell: "PowerShell host",
  stepPreflight: "Windows preflight",
  stepProvider: "OmniRoute provider config",
  stepRecommended: "Windows developer tools",
  stepSource: "Codex OmniRoute source",
  stepStatusError: "error",
  stepStatusPending: "pending",
  stepStatusRunning: "running",
  stepStatusSkipped: "skipped",
  stepStatusSuccess: "success",
  stepStatusWarning: "warning",
  stepVerify: "Architecture verifier",
  stepWinget: "App Installer / winget",
  tooltipInstallFolder: "Select a parent install folder.",
  trace: "Trace",
  validationApiKey: "API key is required.",
  validationBaseUrl: "Enter a valid Base URL.",
  validationBaseUrlProtocol: "Base URL must start with http:// or https://.",
  validationInstallFolder: "Select an install folder.",
  waiting: "Waiting",
} as const

type TranslationKey = keyof typeof englishMessages
type LanguageCode = "en" | "ru"

const translations: Record<LanguageCode, Record<TranslationKey, string>> = {
  en: englishMessages,
  ru: {
    actionBack: "Назад",
    actionBrowse: "Обзор",
    actionContinue: "Продолжить",
    actionFinish: "Готово",
    actionLogFile: "Файл лога",
    actionOpenLog: "Открыть лог",
    actionRetry: "Повторить",
    actionVerifyInstall: "Проверить и установить",
    activeDetailFallback: "Цепочка зависимостей ждёт запуска.",
    activeReady: "Готово к установке",
    alertSetupStopped: "Установка остановлена",
    brandEyebrow: "Windows установщик",
    completed: "завершено",
    credentialsDescription:
      "Добавь endpoint шлюза и API ключ перед началом установки.",
    credentialsTitle: "Доступ к провайдеру",
    dependencyChain: "Цепочка зависимостей",
    fieldApiKey: "API ключ",
    fieldBaseUrl: "Base URL",
    fieldFolder: "Папка",
    finalSourcePath: "Итоговый путь исходников",
    installDeveloperTools: "Установить инструменты разработчика Windows",
    installDeveloperToolsDescription:
      "PowerShell 7, Git, Node.js LTS, .NET SDK, Python и GitHub CLI.",
    installerOutput: "Вывод установщика",
    language: "Язык",
    launchAfterSetup: "Запустить после установки",
    launchAfterSetupDescription:
      "Запустить ярлык OmniRoute Desktop после завершения проверки.",
    liveInstall: "Установка",
    locationDescription: "Выбери папку, куда будет установлен Codex OmniRoute.",
    locationTitle: "Папка установки",
    logEmpty: "Жду вывод установщика.",
    roadmap: "План",
    statusError: "Нужно внимание",
    statusIdle: "Готов",
    statusRunning: "Установка",
    statusSuccess: "Установка успешна",
    stepApi: "Ключ OmniRoute API Manager",
    stepCodex: "Официальное приложение Codex Store",
    stepGateway: "Gateway, wrapper и ярлыки",
    stepLaunch: "Запуск Codex OmniRoute",
    stepLocalDeps: "Локальные Node.js и .NET",
    stepPowerShell: "PowerShell host",
    stepPreflight: "Проверка Windows",
    stepProvider: "Конфиг провайдера OmniRoute",
    stepRecommended: "Инструменты разработчика Windows",
    stepSource: "Исходники Codex OmniRoute",
    stepStatusError: "ошибка",
    stepStatusPending: "ожидание",
    stepStatusRunning: "идёт",
    stepStatusSkipped: "пропущено",
    stepStatusSuccess: "готово",
    stepStatusWarning: "предупреждение",
    stepVerify: "Проверка архитектуры",
    stepWinget: "App Installer / winget",
    tooltipInstallFolder: "Выбери родительскую папку для установки.",
    trace: "Трассировка",
    validationApiKey: "API ключ обязателен.",
    validationBaseUrl: "Введи корректный Base URL.",
    validationBaseUrlProtocol:
      "Base URL должен начинаться с http:// или https://.",
    validationInstallFolder: "Выбери папку установки.",
    waiting: "Ожидание",
  },
}

const languageOptions: Array<{ code: LanguageCode; label: string }> = [
  { code: "en", label: "English" },
  { code: "ru", label: "Русский" },
]

const stepTitleKeys: Record<string, TranslationKey> = {
  api: "stepApi",
  codex: "stepCodex",
  gateway: "stepGateway",
  launch: "stepLaunch",
  "local-deps": "stepLocalDeps",
  powershell: "stepPowerShell",
  preflight: "stepPreflight",
  provider: "stepProvider",
  recommended: "stepRecommended",
  source: "stepSource",
  verify: "stepVerify",
  winget: "stepWinget",
}

const stepStatusKeys: Record<SetupStepStatus, TranslationKey> = {
  error: "stepStatusError",
  pending: "stepStatusPending",
  running: "stepStatusRunning",
  skipped: "stepStatusSkipped",
  success: "stepStatusSuccess",
  warning: "stepStatusWarning",
}

function App() {
  const setup = window.omniSetup ?? fallbackApi
  const [screen, setScreen] = useState<"location" | "credentials" | "install">(
    "location"
  )
  const [installDir, setInstallDir] = useState("")
  const [baseUrl, setBaseUrl] = useState("")
  const [apiKey, setApiKey] = useState("")
  const [installRecommendedTools, setInstallRecommendedTools] = useState(true)
  const [launchAfterInstall, setLaunchAfterInstall] = useState(true)
  const [snapshot, setSnapshot] = useState<SetupSnapshot>({
    status: "idle",
    steps: initialSteps,
  })
  const [formError, setFormError] = useState("")
  const [isFinishing, setIsFinishing] = useState(false)
  const [language, setLanguage] = useState<LanguageCode>("en")
  const t = (key: TranslationKey) => translations[language][key]
  const getStepTitle = (step: SetupStepSnapshot) => {
    const key = stepTitleKeys[step.id]
    return key ? t(key) : step.title
  }
  const getStepDetail = (step: SetupStepSnapshot) =>
    step.detail === "Waiting" ? t("waiting") : step.detail

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
  const logs = snapshot.steps
    .flatMap((step) =>
      step.log.map((line) => ({
        step: getStepTitle(step),
        line,
      }))
    )
    .slice(-140)

  const chooseFolder = async () => {
    const selected = await setup.selectInstallDir(installDir)
    if (selected) {
      setInstallDir(selected)
    }
  }

  const validateLocation = () => {
    if (!installDir.trim()) {
      setFormError(t("validationInstallFolder"))
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
        setFormError(t("validationBaseUrlProtocol"))
        return
      }
    } catch {
      setFormError(t("validationBaseUrl"))
      return
    }
    if (!apiKey.trim()) {
      setFormError(t("validationApiKey"))
      return
    }
    setScreen("install")
    await setup.startInstall({
      installDir,
      baseUrl,
      apiKey,
      installRecommendedTools,
      launchAfterInstall,
    })
  }

  const retry = async () => {
    setFormError("")
    await validateAndStart()
  }

  const finishAndLaunch = async () => {
    setFormError("")
    setIsFinishing(true)
    try {
      await setup.launchInstalled()
      window.close()
    } catch (error) {
      setFormError(error instanceof Error ? error.message : String(error))
      setIsFinishing(false)
    }
  }

  const statusLabel =
    snapshot.status === "success"
      ? t("statusSuccess")
      : snapshot.status === "error"
        ? t("statusError")
        : snapshot.status === "running"
          ? t("statusRunning")
          : t("statusIdle")

  return (
    <main
      className={cn(
        "installer-shell",
        screen === "install" && "installer-shell-install"
      )}
    >
      <section className="installer-chrome">
        <div className="brand-lockup">
          <div className="brand-mark">
            <TerminalSquare />
          </div>
          <div>
            <p className="eyebrow">{t("brandEyebrow")}</p>
            <h1>Codex OmniRoute Setup</h1>
          </div>
        </div>
        <div className="chrome-actions">
          <Select
            value={language}
            onValueChange={(value) => setLanguage(value as LanguageCode)}
          >
            <SelectTrigger className="language-trigger" size="sm">
              <Globe2 />
              <SelectValue aria-label={t("language")} />
            </SelectTrigger>
            <SelectContent>
              <SelectGroup>
                <SelectLabel>{t("language")}</SelectLabel>
                {languageOptions.map((option) => (
                  <SelectItem key={option.code} value={option.code}>
                    {option.label}
                  </SelectItem>
                ))}
              </SelectGroup>
            </SelectContent>
          </Select>
          <Badge className={cn("status-badge", `status-${snapshot.status}`)}>
            {statusLabel}
          </Badge>
        </div>
      </section>

      {screen !== "install" && (
        <section className="wizard-page">
          <aside className="setup-panel wizard-panel">
            <div className="panel-heading">
              <span>{screen === "location" ? "01" : "02"}</span>
              <div>
                <h2>
                  {screen === "location"
                    ? t("locationTitle")
                    : t("credentialsTitle")}
                </h2>
                <p>
                  {screen === "location"
                    ? t("locationDescription")
                    : t("credentialsDescription")}
                </p>
              </div>
            </div>

            {screen === "location" && (
              <FieldGroup>
                <Field>
                  <FieldLabel htmlFor="installDir">
                    {t("fieldFolder")}
                  </FieldLabel>
                  <div className="folder-row">
                    <Input
                      id="installDir"
                      value={installDir}
                      onChange={(event) => setInstallDir(event.target.value)}
                      spellCheck={false}
                    />
                    <Tooltip>
                      <TooltipTrigger asChild>
                        <Button
                          type="button"
                          variant="secondary"
                          onClick={chooseFolder}
                        >
                          <FolderOpen data-icon="inline-start" />
                          {t("actionBrowse")}
                        </Button>
                      </TooltipTrigger>
                      <TooltipContent>
                        {t("tooltipInstallFolder")}
                      </TooltipContent>
                    </Tooltip>
                  </div>
                  <FieldDescription>
                    {t("finalSourcePath")}: {installDir || "..."}
                    \Codex-Omniroute
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
                      <FieldTitle>{t("installDeveloperTools")}</FieldTitle>
                      <FieldDescription>
                        {t("installDeveloperToolsDescription")}
                      </FieldDescription>
                    </FieldContent>
                  </Field>
                  <Field orientation="horizontal">
                    <Checkbox
                      id="launchAfter"
                      checked={launchAfterInstall}
                      onCheckedChange={(checked) =>
                        setLaunchAfterInstall(checked === true)
                      }
                    />
                    <FieldContent>
                      <FieldTitle>{t("launchAfterSetup")}</FieldTitle>
                      <FieldDescription>
                        {t("launchAfterSetupDescription")}
                      </FieldDescription>
                    </FieldContent>
                  </Field>
                </div>

                <div className="action-row">
                  <Button type="button" onClick={validateLocation}>
                    {t("actionContinue")}
                    <ChevronRight data-icon="inline-end" />
                  </Button>
                </div>
              </FieldGroup>
            )}

            {screen === "credentials" && (
              <FieldGroup>
                <Field>
                  <FieldLabel htmlFor="baseUrl">{t("fieldBaseUrl")}</FieldLabel>
                  <Input
                    id="baseUrl"
                    value={baseUrl}
                    onChange={(event) => setBaseUrl(event.target.value)}
                    placeholder="https://your-omniroute.example/v1"
                    spellCheck={false}
                  />
                </Field>
                <Field>
                  <FieldLabel htmlFor="apiKey">{t("fieldApiKey")}</FieldLabel>
                  <Input
                    id="apiKey"
                    value={apiKey}
                    onChange={(event) => setApiKey(event.target.value)}
                    type="password"
                    spellCheck={false}
                  />
                </Field>
                <div className="action-row split">
                  <Button
                    type="button"
                    variant="secondary"
                    onClick={() => setScreen("location")}
                  >
                    <ChevronLeft data-icon="inline-start" />
                    {t("actionBack")}
                  </Button>
                  <Button type="button" onClick={validateAndStart}>
                    <ShieldCheck data-icon="inline-start" />
                    {t("actionVerifyInstall")}
                  </Button>
                </div>
              </FieldGroup>
            )}

            {formError && (
              <Alert variant="destructive">
                <AlertTriangle />
                <AlertTitle>{t("alertSetupStopped")}</AlertTitle>
                <AlertDescription>{formError}</AlertDescription>
              </Alert>
            )}
          </aside>
        </section>
      )}

      {screen === "install" && (
        <section className="install-page">
          <section className="install-hero">
            <div className="install-hero-copy">
              <p className="eyebrow">{t("liveInstall")}</p>
              <h2>
                {activeStep ? getStepTitle(activeStep) : t("activeReady")}
              </h2>
              <p>
                {activeStep
                  ? getStepDetail(activeStep)
                  : t("activeDetailFallback")}
              </p>
            </div>
            <div className="install-summary">
              <div className="summary-meter">
                <Progress value={progress} />
                <span>{progress}%</span>
              </div>
              <Separator />
              <div className="summary-copy">
                <p>
                  {completedCount}/{snapshot.steps.length} {t("completed")}
                </p>
                <span>{statusLabel}</span>
              </div>
              {(snapshot.status === "success" ||
                snapshot.status === "error") && (
                <div className="finish-actions">
                  {snapshot.status === "success" ? (
                    <Button
                      type="button"
                      onClick={finishAndLaunch}
                      disabled={isFinishing}
                    >
                      <Rocket data-icon="inline-start" />
                      {t("actionFinish")}
                    </Button>
                  ) : (
                    <Button type="button" onClick={retry}>
                      <RotateCcw data-icon="inline-start" />
                      {t("actionRetry")}
                    </Button>
                  )}
                  <Button
                    type="button"
                    variant="secondary"
                    onClick={setup.openLog}
                  >
                    <Logs data-icon="inline-start" />
                    {t("actionOpenLog")}
                  </Button>
                </div>
              )}
            </div>
          </section>

          {formError && (
            <Alert variant="destructive">
              <AlertTriangle />
              <AlertTitle>{t("alertSetupStopped")}</AlertTitle>
              <AlertDescription>{formError}</AlertDescription>
            </Alert>
          )}

          <section className="install-workspace">
            <section className="roadmap-panel install-roadmap">
              <div className="roadmap-header">
                <div>
                  <p className="eyebrow">{t("roadmap")}</p>
                  <h2>{t("dependencyChain")}</h2>
                </div>
                <Badge variant="secondary">
                  {completedCount}/{snapshot.steps.length}
                </Badge>
              </div>

              <div className="roadmap-list">
                {snapshot.steps.map((step, index) => (
                  <RoadmapStep
                    key={step.id}
                    step={step}
                    title={getStepTitle(step)}
                    detail={getStepDetail(step)}
                    statusLabel={t(stepStatusKeys[step.status])}
                    isLast={index === snapshot.steps.length - 1}
                  />
                ))}
              </div>
            </section>

            <section className="log-panel install-log">
              <div className="roadmap-header">
                <div>
                  <p className="eyebrow">{t("trace")}</p>
                  <h2>{t("installerOutput")}</h2>
                </div>
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  onClick={setup.openLog}
                  disabled={!snapshot.logPath}
                >
                  <Logs data-icon="inline-start" />
                  {t("actionLogFile")}
                </Button>
              </div>
              <ScrollArea className="log-scroll">
                {logs.length === 0 ? (
                  <div className="log-empty">{t("logEmpty")}</div>
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
        </section>
      )}
    </main>
  )
}

function RoadmapStep({
  step,
  title,
  detail,
  statusLabel,
  isLast,
}: {
  step: SetupStepSnapshot
  title: string
  detail: string
  statusLabel: string
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
          <h3>{title}</h3>
          <Badge variant="outline">{statusLabel}</Badge>
        </div>
        <p>{detail}</p>
      </div>
    </article>
  )
}

export default App
