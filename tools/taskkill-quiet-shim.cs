using System;
using System.Diagnostics;
using System.IO;
using System.Linq;

public static class TaskkillQuietShim
{
    public static int Main(string[] args)
    {
        try
        {
            var realTaskkill = Path.Combine(Environment.SystemDirectory, "taskkill.exe");
            var startInfo = new ProcessStartInfo
            {
                FileName = realTaskkill,
                Arguments = string.Join(" ", args.Select(QuoteArgument)),
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            };

            using (var process = Process.Start(startInfo))
            {
                if (process == null)
                {
                    return 127;
                }

                process.StandardOutput.ReadToEnd();
                process.StandardError.ReadToEnd();
                process.WaitForExit();
                return process.ExitCode;
            }
        }
        catch
        {
            return 127;
        }
    }

    private static string QuoteArgument(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return "\"\"";
        }

        if (value.IndexOfAny(new[] { ' ', '\t', '\r', '\n', '"' }) < 0)
        {
            return value;
        }

        return "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
    }
}
