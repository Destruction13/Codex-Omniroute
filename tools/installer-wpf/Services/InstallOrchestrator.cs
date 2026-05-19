using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using OmniRouteInstaller.Views;

namespace OmniRouteInstaller.Services
{
    public sealed class InstallOrchestrator
    {
        private const string CodexProductId = "9PLM9XGG6VKS";
        private const string NodeProductId = "OpenJS.NodeJS.LTS";
        private const string DotnetProductId = "Microsoft.DotNet.SDK.8";

        private readonly InstallerState state;
        private readonly ObservableCollection<StepItem> steps;
        private readonly Action<string> log;
        private readonly WingetService winget;

        public InstallOrchestrator(InstallerState state,
                                   ObservableCollection<StepItem> steps,
                                   Action<string> log)
        {
            this.state = state;
            this.steps = steps;
            this.log = log;
            this.winget = new WingetService(log);
        }

        public async Task<bool> RunAsync()
        {
            bool ok = true;
            ok &= await StepAsync("extract", "Распаковываю", async () =>
            {
                return await RepoExtractor.ExtractAsync(state.InstallPath, log);
            });
            if (!ok) return false;

            // Provider file needs to land before Setup.ps1 starts touching it.
            ok &= await StepAsync("provider", "Записываю provider", async () =>
            {
                await WriteProviderJsonAsync();
                return true;
            });

            bool wingetOk = await StepAsync("winget", "Проверяю", async () =>
            {
                return await winget.EnsureAvailableAsync();
            });

            if (wingetOk)
            {
                await StepAsync("node", "winget install", async () =>
                {
                    var r = await winget.InstallAsync(NodeProductId, "winget");
                    return WingetSuccess(r);
                });
                await StepAsync("dotnet", "winget install", async () =>
                {
                    var r = await winget.InstallAsync(DotnetProductId, "winget", optional: true);
                    return WingetSuccess(r);
                });
                bool codexOk = await StepAsync("codex", "Microsoft Store", async () =>
                {
                    var r = await winget.InstallAsync(CodexProductId, "msstore");
                    if (r == WingetInstallResult.Failed)
                    {
                        log("[codex] winget msstore не смог получить Codex. Это типичная проблема свежих машин Windows.");
                        log("[codex] Открой Microsoft Store, найди 'Codex' от OpenAI и нажми 'Install', затем перезапусти этот установщик.");
                        ShowStoreHint();
                    }
                    return WingetSuccess(r);
                });
                ok &= codexOk;
            }
            else
            {
                MarkStep("node", StepStatus.Skipped, "winget недоступен");
                MarkStep("dotnet", StepStatus.Skipped, "winget недоступен");
                MarkStep("codex", StepStatus.Skipped, "winget недоступен");
                ok = false;
            }

            ok &= await StepAsync("setup", "Запускаю Setup.ps1", async () =>
            {
                var script = Path.Combine(state.InstallPath, "Setup.ps1");
                if (!File.Exists(script))
                {
                    log("[setup] Setup.ps1 не найден в " + state.InstallPath);
                    return false;
                }
                var args = new List<string>
                {
                    "-NonInteractive",
                    "-SkipShortcuts",
                    "-ProviderBaseUrl", state.BaseUrl,
                    "-ProviderApiKey", state.ApiKey
                };
                if (!string.IsNullOrWhiteSpace(state.ImageApiKey))
                {
                    args.Add("-ProviderImageApiKey");
                    args.Add(state.ImageApiKey);
                }
                int code = await PowerShellRunner.RunAsync(script, args, state.InstallPath, log);
                if (code != 0) log($"[setup] Setup.ps1 exit {code}");
                return code == 0;
            });

            if (state.CreateShortcuts)
            {
                await StepAsync("shortcuts", "Создаю", async () =>
                {
                    var script = Path.Combine(state.InstallPath, "Setup.ps1");
                    var args = new List<string>
                    {
                        "-NonInteractive",
                        "-SkipVerify",
                        "-ProviderBaseUrl", state.BaseUrl,
                        "-ProviderApiKey", state.ApiKey
                    };
                    int code = await PowerShellRunner.RunAsync(script, args, state.InstallPath, log);
                    return code == 0;
                });
            }

            await StepAsync("verify", "verify-codex-omniroute.ps1", async () =>
            {
                var script = Path.Combine(state.InstallPath, "verify-codex-omniroute.ps1");
                if (!File.Exists(script))
                {
                    log("[verify] verify-codex-omniroute.ps1 не найден");
                    return false;
                }
                int code = await PowerShellRunner.RunAsync(script, null, state.InstallPath, log);
                if (code != 0) log("[verify] non-zero exit " + code + " — это OK, если ты ещё не запускал Codex и bridge не активен.");
                return true;
            });

            return ok;
        }

        private async Task WriteProviderJsonAsync()
        {
            string dest = Path.Combine(state.InstallPath, "omniroute-provider.json");
            var obj = new Dictionary<string, object>
            {
                ["base_url"] = state.BaseUrl,
                ["api_key"] = state.ApiKey
            };
            if (!string.IsNullOrWhiteSpace(state.ImageApiKey))
            {
                obj["image_api_key"] = state.ImageApiKey;
            }
            string json = JsonSerializer.Serialize(obj, new JsonSerializerOptions
            {
                WriteIndented = true
            });
            await File.WriteAllTextAsync(dest, json + Environment.NewLine, new UTF8Encoding(false));
            log("[provider] wrote " + dest);
        }

        private async Task<bool> StepAsync(string id, string detail, Func<Task<bool>> action)
        {
            var step = FindStep(id);
            if (step == null) return true;
            try
            {
                Application.Current.Dispatcher.Invoke(() =>
                {
                    step.Status = StepStatus.Running;
                    step.Detail = detail;
                });
                bool ok = await action();
                Application.Current.Dispatcher.Invoke(() =>
                {
                    step.Status = ok ? StepStatus.Ok : StepStatus.Failed;
                    step.Detail = ok ? "ok" : "проверь лог";
                });
                return ok;
            }
            catch (Exception ex)
            {
                log("[" + id + "] " + ex.Message);
                Application.Current.Dispatcher.Invoke(() =>
                {
                    step.Status = StepStatus.Failed;
                    step.Detail = ex.GetType().Name;
                });
                return false;
            }
        }

        private void MarkStep(string id, StepStatus status, string detail)
        {
            var step = FindStep(id);
            if (step == null) return;
            Application.Current.Dispatcher.Invoke(() =>
            {
                step.Status = status;
                step.Detail = detail;
            });
        }

        private StepItem FindStep(string id)
        {
            foreach (var s in steps) if (s.Id == id) return s;
            return null;
        }

        private static bool WingetSuccess(WingetInstallResult r)
            => r == WingetInstallResult.Installed
            || r == WingetInstallResult.AlreadyInstalled
            || r == WingetInstallResult.OptionalFailed;

        private void ShowStoreHint()
        {
            Application.Current.Dispatcher.Invoke(() =>
            {
                MessageBox.Show(
                    "Codex Desktop не удалось установить через winget.\n\n" +
                    "Обычно это лечится так:\n" +
                    "  1. Открой Microsoft Store\n" +
                    "  2. Найди \"Codex\" от OpenAI и нажми Install\n" +
                    "  3. Закрой Store и перезапусти этот установщик.",
                    "Codex OmniRoute Installer",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
            });
        }
    }
}
