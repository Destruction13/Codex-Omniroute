using System;
using System.Diagnostics;
using System.IO;
using System.Windows;

namespace OmniRouteInstaller.Views
{
    public partial class CompletePage : PageBase
    {
        public CompletePage(MainWindow host) : base(host)
        {
            InitializeComponent();
            PathLabel.Text = "Папка: " + Host.State.InstallPath;
        }

        private void OpenFolder_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                if (Directory.Exists(Host.State.InstallPath))
                {
                    Process.Start(new ProcessStartInfo
                    {
                        FileName = "explorer.exe",
                        Arguments = "\"" + Host.State.InstallPath + "\"",
                        UseShellExecute = true
                    });
                }
            }
            catch { }
        }

        private void Launch_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                string starter = Path.Combine(Host.State.InstallPath, "Start-Codex-OmniRoute.ps1");
                if (File.Exists(starter))
                {
                    var pwsh = ResolvePowerShell();
                    Process.Start(new ProcessStartInfo
                    {
                        FileName = pwsh,
                        Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File \"" + starter + "\"",
                        WorkingDirectory = Host.State.InstallPath,
                        UseShellExecute = true
                    });
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show("Не удалось запустить Codex OmniRoute: " + ex.Message,
                    "Codex OmniRoute Installer", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            Host.Close();
        }

        private void Close_Click(object sender, RoutedEventArgs e) => Host.Close();

        private static string ResolvePowerShell()
        {
            var systemRoot = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            var builtin = Path.Combine(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
            return File.Exists(builtin) ? builtin : "powershell.exe";
        }
    }
}
