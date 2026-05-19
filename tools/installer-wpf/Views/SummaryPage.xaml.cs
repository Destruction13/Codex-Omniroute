using System.Windows;
using System.Windows.Documents;

namespace OmniRouteInstaller.Views
{
    public partial class SummaryPage : PageBase
    {
        public SummaryPage(MainWindow host) : base(host)
        {
            InitializeComponent();
            PathLabel.Text = Host.State.InstallPath;
            BaseUrlLabel.Text = Host.State.BaseUrl;
            ApiKeyMaskLabel.Text = Mask(Host.State.ApiKey);
            if (!string.IsNullOrWhiteSpace(Host.State.ImageApiKey))
            {
                ImageKeyMaskLabel.Text = Mask(Host.State.ImageApiKey);
                ImageKeyRow.Visibility = Visibility.Visible;
            }

            if (!Host.State.CreateShortcuts)
            {
                StepShortcutsTxt.Text = "Пропускаю ярлыки (отключено на предыдущем шаге)";
            }
        }

        private static string Mask(string s)
        {
            if (string.IsNullOrEmpty(s)) return "—";
            if (s.Length <= 8) return new string('•', s.Length);
            return s.Substring(0, 4) + new string('•', System.Math.Min(20, s.Length - 8)) + s.Substring(s.Length - 4);
        }

        private void Back_Click(object sender, RoutedEventArgs e) => Host.GoTo(2);
        private void Install_Click(object sender, RoutedEventArgs e) => Host.GoTo(4);
    }
}
