using System;
using System.Diagnostics;
using System.IO;
using System.Linq;

internal static class Program
{
    private static int Main(string[] args)
    {
        try
        {
            string exeDir = AppContext.BaseDirectory;
            string setupScript = ResolveSetupScript(exeDir);
            if (setupScript == null)
            {
                Console.Error.WriteLine("Setup.ps1 was not found next to Setup.exe or in the parent directory.");
                Console.Error.WriteLine("Extract the full Codex OmniRoute release, then run Setup.exe again.");
                PauseIfInteractive();
                return 2;
            }

            string powershell = ResolvePowerShell();
            if (powershell == null)
            {
                Console.Error.WriteLine("Windows PowerShell was not found.");
                PauseIfInteractive();
                return 2;
            }

            var psi = new ProcessStartInfo
            {
                FileName = powershell,
                UseShellExecute = false,
                WorkingDirectory = Path.GetDirectoryName(setupScript) ?? exeDir,
            };
            psi.ArgumentList.Add("-NoLogo");
            psi.ArgumentList.Add("-NoProfile");
            psi.ArgumentList.Add("-ExecutionPolicy");
            psi.ArgumentList.Add("Bypass");
            psi.ArgumentList.Add("-File");
            psi.ArgumentList.Add(setupScript);
            foreach (string arg in args)
            {
                psi.ArgumentList.Add(arg);
            }

            using Process process = Process.Start(psi);
            if (process == null)
            {
                Console.Error.WriteLine("Failed to start Setup.ps1.");
                PauseIfInteractive();
                return 2;
            }
            process.WaitForExit();
            return process.ExitCode;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.Message);
            PauseIfInteractive();
            return 1;
        }
    }

    private static string ResolveSetupScript(string exeDir)
    {
        string[] candidates =
        {
            Path.Combine(exeDir, "Setup.ps1"),
            Path.Combine(exeDir, "..", "Setup.ps1"),
        };
        return candidates.Select(Path.GetFullPath).FirstOrDefault(File.Exists);
    }

    private static string ResolvePowerShell()
    {
        string systemRoot = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        string builtin = Path.Combine(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        if (File.Exists(builtin))
        {
            return builtin;
        }

        string path = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        foreach (string dir in path.Split(Path.PathSeparator))
        {
            if (string.IsNullOrWhiteSpace(dir))
            {
                continue;
            }
            string candidate = Path.Combine(dir.Trim(), "powershell.exe");
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }
        return null;
    }

    private static void PauseIfInteractive()
    {
        if (Console.IsInputRedirected)
        {
            return;
        }
        Console.WriteLine();
        Console.Write("Press Enter to exit...");
        Console.ReadLine();
    }
}
