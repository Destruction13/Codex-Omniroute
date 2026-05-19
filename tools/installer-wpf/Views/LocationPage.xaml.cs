using System;
using System.IO;
using System.Windows;
using System.Windows.Forms;

namespace OmniRouteInstaller.Views
{
    public partial class LocationPage : PageBase
    {
        public LocationPage(MainWindow host) : base(host)
        {
            InitializeComponent();
            PathTextBox.Text = Host.State.InstallPath;
            ShortcutCheck.IsChecked = Host.State.CreateShortcuts;
        }

        private void Browse_Click(object sender, RoutedEventArgs e)
        {
            using var dlg = new FolderBrowserDialog
            {
                Description = "Выбери папку для Codex OmniRoute",
                UseDescriptionForTitle = true,
                SelectedPath = PathTextBox.Text
            };
            if (dlg.ShowDialog() == System.Windows.Forms.DialogResult.OK)
            {
                if (!string.IsNullOrWhiteSpace(dlg.SelectedPath))
                {
                    PathTextBox.Text = Path.Combine(dlg.SelectedPath, "Codex-Omniroute");
                }
            }
        }

        private void Back_Click(object sender, RoutedEventArgs e) => Host.GoTo(0);

        private void Continue_Click(object sender, RoutedEventArgs e)
        {
            var path = (PathTextBox.Text ?? string.Empty).Trim();
            if (string.IsNullOrWhiteSpace(path))
            {
                System.Windows.MessageBox.Show("Укажи папку установки.", "Codex OmniRoute Installer",
                    MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            try { Path.GetFullPath(path); }
            catch (Exception ex)
            {
                System.Windows.MessageBox.Show("Путь некорректный: " + ex.Message, "Codex OmniRoute Installer",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            Host.State.InstallPath = path;
            Host.State.CreateShortcuts = ShortcutCheck.IsChecked == true;
            Host.GoTo(2);
        }
    }
}
