using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading.Tasks;

namespace OmniRouteInstaller.Services
{
    /// <summary>
    /// Runs PowerShell scripts shipped inside the repository (Setup.ps1, launcher scripts).
    /// </summary>
    public static class PowerShellRunner
    {
        public static string ResolvePowerShell()
        {
            string systemRoot = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string builtin = Path.Combine(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
            if (File.Exists(builtin)) return builtin;

            string path = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
            foreach (string dir in path.Split(Path.PathSeparator))
            {
                if (string.IsNullOrWhiteSpace(dir)) continue;
                string c = Path.Combine(dir.Trim(), "powershell.exe");
                if (File.Exists(c)) return c;
                string c2 = Path.Combine(dir.Trim(), "pwsh.exe");
                if (File.Exists(c2)) return c2;
            }
            return null;
        }

        public static async Task<int> RunAsync(
            string scriptPath,
            IList<string> argumentList,
            string workingDirectory,
            Action<string> onLine)
        {
            string ps = ResolvePowerShell();
            if (ps == null)
            {
                onLine?.Invoke("[powershell] не найден");
                return -1;
            }

            var sb = new StringBuilder();
            sb.Append("-NoLogo -NoProfile -ExecutionPolicy Bypass -File ");
            sb.Append(Quote(scriptPath));
            if (argumentList != null)
            {
                foreach (string arg in argumentList)
                {
                    sb.Append(' ');
                    sb.Append(Quote(arg));
                }
            }

            var run = await CommandRunner.RunAsync(ps, sb.ToString(), workingDirectory, onLine);
            return run.ExitCode;
        }

        private static string Quote(string s)
        {
            if (string.IsNullOrEmpty(s)) return "\"\"";
            if (s.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return s;
            return "\"" + s.Replace("\"", "\\\"") + "\"";
        }
    }
}
