using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;

namespace OmniRouteInstaller.Services
{
    public sealed class WingetService
    {
        private readonly Action<string> log;

        public WingetService(Action<string> log)
        {
            this.log = log ?? (_ => { });
        }

        public async Task<bool> EnsureAvailableAsync()
        {
            string wingetPath = ResolveWinget();
            if (wingetPath == null)
            {
                log("[winget] не найден. Открой Microsoft Store и установи 'App Installer'.");
                return false;
            }
            log("[winget] " + wingetPath);
            var r = await CommandRunner.RunAsync(wingetPath, "--version", null, log);
            return r.Started && r.ExitCode == 0;
        }

        public async Task<WingetInstallResult> InstallAsync(string id, string source, bool optional = false)
        {
            string wingetPath = ResolveWinget();
            if (wingetPath == null)
            {
                return WingetInstallResult.WingetMissing;
            }

            // First — is it already installed?
            var listArgs = $"list --id {id} --source {source} --accept-source-agreements";
            var listRes = await CommandRunner.RunAsync(wingetPath, listArgs, null, log);
            if (listRes.Started && listRes.ExitCode == 0)
            {
                log($"[winget] {id} уже установлен — пропускаю.");
                return WingetInstallResult.AlreadyInstalled;
            }

            var installArgs = $"install --id {id} --source {source} --silent " +
                              "--accept-package-agreements --accept-source-agreements --disable-interactivity";
            log($"[winget] install --id {id} --source {source}");

            // Up to 2 retries for transient Store / network errors
            for (int attempt = 1; attempt <= 3; attempt++)
            {
                var run = await CommandRunner.RunAsync(wingetPath, installArgs, null, log);
                if (!run.Started)
                {
                    log("[winget] не удалось запустить: " + run.FailureReason);
                    return WingetInstallResult.LaunchFailed;
                }
                if (run.ExitCode == 0)
                {
                    return WingetInstallResult.Installed;
                }
                // Winget exit codes: 0x8A150011 already installed, transient store errors etc.
                log($"[winget] попытка {attempt}/3 → exit {run.ExitCode} (0x{run.ExitCode:X8})");
                if (attempt < 3)
                {
                    await Task.Delay(2500);
                }
                else
                {
                    return optional ? WingetInstallResult.OptionalFailed : WingetInstallResult.Failed;
                }
            }
            return optional ? WingetInstallResult.OptionalFailed : WingetInstallResult.Failed;
        }

        public static string ResolveWinget()
        {
            try
            {
                var local = Environment.GetEnvironmentVariable("LOCALAPPDATA");
                if (!string.IsNullOrEmpty(local))
                {
                    string wpRoot = Path.Combine(local, "Microsoft", "WindowsApps");
                    string candidate = Path.Combine(wpRoot, "winget.exe");
                    if (File.Exists(candidate)) return candidate;
                }

                string path = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
                foreach (string dir in path.Split(Path.PathSeparator))
                {
                    if (string.IsNullOrWhiteSpace(dir)) continue;
                    string c = Path.Combine(dir.Trim(), "winget.exe");
                    if (File.Exists(c)) return c;
                }
            }
            catch { }
            return null;
        }
    }

    public enum WingetInstallResult
    {
        Installed,
        AlreadyInstalled,
        Failed,
        OptionalFailed,
        WingetMissing,
        LaunchFailed
    }
}
