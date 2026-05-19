using System.IO;
using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace OmniRouteInstaller
{
    /// <summary>
    /// Mutable state shared across wizard pages and the install orchestrator.
    /// </summary>
    public sealed class InstallerState : INotifyPropertyChanged
    {
        private string installPath;
        private string baseUrl = string.Empty;
        private string apiKey = string.Empty;
        private string imageApiKey = string.Empty;
        private bool createShortcuts = true;
        private bool launchAfterInstall = true;

        public InstallerState()
        {
            string tools = Path.Combine(
                System.Environment.GetFolderPath(System.Environment.SpecialFolder.UserProfile),
                "Tools");
            installPath = Path.Combine(tools, "Codex-Omniroute");
        }

        public string InstallPath
        {
            get => installPath;
            set { installPath = value; OnChanged(); }
        }

        public string BaseUrl
        {
            get => baseUrl;
            set { baseUrl = value; OnChanged(); }
        }

        public string ApiKey
        {
            get => apiKey;
            set { apiKey = value; OnChanged(); }
        }

        public string ImageApiKey
        {
            get => imageApiKey;
            set { imageApiKey = value; OnChanged(); }
        }

        public bool CreateShortcuts
        {
            get => createShortcuts;
            set { createShortcuts = value; OnChanged(); }
        }

        public bool LaunchAfterInstall
        {
            get => launchAfterInstall;
            set { launchAfterInstall = value; OnChanged(); }
        }

        public event PropertyChangedEventHandler PropertyChanged;
        private void OnChanged([CallerMemberName] string name = null)
            => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
