using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;

internal static class CodexAppServerWrapper
{
    private static string Env(string name, string fallback)
    {
        string value = Environment.GetEnvironmentVariable(name);
        return string.IsNullOrWhiteSpace(value) ? fallback : value;
    }

    private static string QuoteWindowsArgument(string value)
    {
        if (value == null) { return "\"\""; }
        if (value.Length == 0) { return "\"\""; }
        bool needsQuotes = false;
        foreach (char ch in value)
        {
            if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == '"')
            {
                needsQuotes = true;
                break;
            }
        }
        if (!needsQuotes) { return value; }

        var result = new System.Text.StringBuilder();
        result.Append('"');
        int slashCount = 0;
        foreach (char ch in value)
        {
            if (ch == '\\')
            {
                slashCount++;
                continue;
            }
            if (ch == '"')
            {
                result.Append('\\', slashCount * 2 + 1);
                result.Append('"');
                slashCount = 0;
                continue;
            }
            if (slashCount > 0)
            {
                result.Append('\\', slashCount);
                slashCount = 0;
            }
            result.Append(ch);
        }
        if (slashCount > 0) { result.Append('\\', slashCount * 2); }
        result.Append('"');
        return result.ToString();
    }

    private static string JoinArguments(IEnumerable<string> args)
    {
        var parts = new List<string>();
        foreach (string arg in args) { parts.Add(QuoteWindowsArgument(arg)); }
        return string.Join(" ", parts.ToArray());
    }

    private static void AddConfigOverride(List<string> args, string keyValue)
    {
        args.Add("-c");
        args.Add(keyValue);
    }

    private static List<string> BuildArguments(string[] original)
    {
        var args = new List<string>();
        bool isAppServer = original.Length > 0 &&
            string.Equals(original[0], "app-server", StringComparison.OrdinalIgnoreCase);

        if (!isAppServer)
        {
            args.AddRange(original);
            return args;
        }

        string provider = Env("CODEX_OMNI_RUNTIME_PROVIDER_ID", "omniroute");
        string model = Env("CODEX_OMNI_RUNTIME_MODEL", "gpt-5.5");
        string effort = Env("CODEX_OMNI_RUNTIME_REASONING_EFFORT", "xhigh");
        string port = Env("CODEX_BRIDGE_PORT", "20333");
        string baseUrl = "http://127.0.0.1:" + port + "/v1";

        args.Add("app-server");
        AddConfigOverride(args, "model_provider=\"" + provider + "\"");
        AddConfigOverride(args, "model=\"" + model + "\"");
        AddConfigOverride(args, "model_reasoning_effort=\"" + effort + "\"");
        AddConfigOverride(args, "features.tool_search=true");
        AddConfigOverride(args, "features.apply_patch_freeform=true");
        AddConfigOverride(args, "model_providers." + provider + ".name=\"OmniRoute\"");
        AddConfigOverride(args, "model_providers." + provider + ".base_url=\"" + baseUrl + "\"");
        AddConfigOverride(args, "model_providers." + provider + ".wire_api=\"responses\"");
        AddConfigOverride(args, "model_providers." + provider + ".env_key=\"OMNIROUTE_API_KEY\"");
        AddConfigOverride(args, "model_providers." + provider + ".requires_openai_auth=true");
        AddConfigOverride(args, "model_providers." + provider + ".supports_websockets=false");

        for (int i = 1; i < original.Length; i++) { args.Add(original[i]); }
        return args;
    }

    public static int Main(string[] original)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string officialExe = Path.Combine(dir, "codex-official.exe");
        if (!File.Exists(officialExe))
        {
            Console.Error.WriteLine("codex-official.exe not found next to OmniRoute wrapper: " + officialExe);
            return 127;
        }

        var psi = new ProcessStartInfo();
        psi.FileName = officialExe;
        psi.Arguments = JoinArguments(BuildArguments(original));
        psi.UseShellExecute = false;

        using (Process child = Process.Start(psi))
        {
            child.WaitForExit();
            return child.ExitCode;
        }
    }
}
