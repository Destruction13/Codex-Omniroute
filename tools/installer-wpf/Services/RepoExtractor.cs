using System;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Threading.Tasks;

namespace OmniRouteInstaller.Services
{
    /// <summary>
    /// Extracts the Codex OmniRoute repository snapshot embedded into the installer
    /// to the user-selected install directory.
    /// </summary>
    public static class RepoExtractor
    {
        private const string ResourceName = "Resources.CodexOmniRoute.zip";

        public static async Task<bool> ExtractAsync(string targetPath, Action<string> onLine)
        {
            return await Task.Run(() =>
            {
                var asm = Assembly.GetExecutingAssembly();
                string fullName = null;
                foreach (var name in asm.GetManifestResourceNames())
                {
                    if (name.EndsWith(ResourceName, StringComparison.OrdinalIgnoreCase) ||
                        name.EndsWith("CodexOmniRoute.zip", StringComparison.OrdinalIgnoreCase))
                    {
                        fullName = name;
                        break;
                    }
                }
                if (fullName == null)
                {
                    onLine?.Invoke("[extract] embedded repository archive not found");
                    return false;
                }

                Directory.CreateDirectory(targetPath);

                using var stream = asm.GetManifestResourceStream(fullName);
                if (stream == null)
                {
                    onLine?.Invoke("[extract] embedded resource stream is null");
                    return false;
                }

                using var archive = new ZipArchive(stream, ZipArchiveMode.Read);
                int total = archive.Entries.Count;
                int written = 0;
                foreach (var entry in archive.Entries)
                {
                    // Strip the leading directory so contents land directly under targetPath.
                    string rel = entry.FullName;
                    int slash = rel.IndexOf('/');
                    if (slash >= 0) rel = rel.Substring(slash + 1);
                    if (string.IsNullOrEmpty(rel)) continue;

                    string dest = Path.GetFullPath(Path.Combine(targetPath, rel));
                    string targetFull = Path.GetFullPath(targetPath);
                    if (!dest.StartsWith(targetFull, StringComparison.OrdinalIgnoreCase))
                    {
                        onLine?.Invoke("[extract] skipping suspicious path " + entry.FullName);
                        continue;
                    }

                    if (entry.FullName.EndsWith("/"))
                    {
                        Directory.CreateDirectory(dest);
                        continue;
                    }

                    Directory.CreateDirectory(Path.GetDirectoryName(dest) ?? targetPath);
                    using var input = entry.Open();
                    using var output = File.Create(dest);
                    input.CopyTo(output);

                    written++;
                    if (written % 25 == 0)
                    {
                        onLine?.Invoke($"[extract] {written}/{total}: {rel}");
                    }
                }
                onLine?.Invoke($"[extract] done — wrote {written} files into {targetPath}");
                return true;
            });
        }
    }
}
