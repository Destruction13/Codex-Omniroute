using System.Diagnostics;
using System.Windows;

namespace OmniRouteInstaller.Views
{
    public partial class WelcomePage : PageBase
    {
        public WelcomePage(MainWindow host) : base(host)
        {
            InitializeComponent();
        }

        private void Continue_Click(object sender, RoutedEventArgs e)
        {
            Host.GoTo(1);
        }

        private void OpenRepo_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "https://github.com/Destruction13/Codex-Omniroute",
                    UseShellExecute = true
                });
            }
            catch { }
        }
    }
}
