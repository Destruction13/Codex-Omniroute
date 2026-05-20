using System;
using System.Diagnostics;
using System.Threading.Tasks;

namespace OmniRouteInstaller.Services
{
    public sealed class RunResult
    {
        public int ExitCode { get; set; }
        public bool Started { get; set; }
        public string FailureReason { get; set; }
    }

    public static class CommandRunner
    {
        public static async Task<RunResult> RunAsync(
            string fileName,
            string arguments,
            string workingDirectory,
            Action<string> onLine)
        {
            var result = new RunResult();
            var psi = new ProcessStartInfo
            {
                FileName = fileName,
                Arguments = arguments,
                WorkingDirectory = workingDirectory ?? string.Empty,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                StandardOutputEncoding = System.Text.Encoding.UTF8,
                StandardErrorEncoding = System.Text.Encoding.UTF8
            };

            Process p;
            try
            {
                p = Process.Start(psi);
            }
            catch (Exception ex)
            {
                result.FailureReason = ex.Message;
                return result;
            }
            if (p == null)
            {
                result.FailureReason = "Process did not start.";
                return result;
            }

            result.Started = true;

            p.OutputDataReceived += (_, e) =>
            {
                if (e.Data != null) onLine?.Invoke(e.Data);
            };
            p.ErrorDataReceived += (_, e) =>
            {
                if (e.Data != null) onLine?.Invoke(e.Data);
            };
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();

            await Task.Run(() => p.WaitForExit());
            result.ExitCode = p.ExitCode;
            return result;
        }
    }
}
