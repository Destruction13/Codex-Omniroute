using System;
using System.Windows;
using System.Windows.Controls;

namespace OmniRouteInstaller.Views
{
    public partial class CredentialsPage : PageBase
    {
        private bool suppress;

        public CredentialsPage(MainWindow host) : base(host)
        {
            InitializeComponent();
            BaseUrlBox.Text = Host.State.BaseUrl;
            ApiKeyPwd.Password = Host.State.ApiKey;
            ApiKeyPlain.Text = Host.State.ApiKey;
            ImageKeyPwd.Password = Host.State.ImageApiKey;
            ImageKeyPlain.Text = Host.State.ImageApiKey;
        }

        private void ApiKeyPwd_PasswordChanged(object sender, RoutedEventArgs e)
        {
            if (suppress) return;
            suppress = true;
            ApiKeyPlain.Text = ApiKeyPwd.Password;
            suppress = false;
        }
        private void ApiKeyPlain_TextChanged(object sender, TextChangedEventArgs e)
        {
            if (suppress) return;
            suppress = true;
            ApiKeyPwd.Password = ApiKeyPlain.Text;
            suppress = false;
        }
        private void ToggleApiKey_Click(object sender, RoutedEventArgs e)
        {
            if (ApiKeyPlain.Visibility == Visibility.Visible)
            {
                ApiKeyPwd.Password = ApiKeyPlain.Text;
                ApiKeyPwd.Visibility = Visibility.Visible;
                ApiKeyPlain.Visibility = Visibility.Collapsed;
                ToggleApiKey.Content = "Показать";
            }
            else
            {
                ApiKeyPlain.Text = ApiKeyPwd.Password;
                ApiKeyPlain.Visibility = Visibility.Visible;
                ApiKeyPwd.Visibility = Visibility.Collapsed;
                ToggleApiKey.Content = "Скрыть";
            }
        }

        private void ImageKeyPwd_PasswordChanged(object sender, RoutedEventArgs e)
        {
            if (suppress) return;
            suppress = true;
            ImageKeyPlain.Text = ImageKeyPwd.Password;
            suppress = false;
        }
        private void ImageKeyPlain_TextChanged(object sender, TextChangedEventArgs e)
        {
            if (suppress) return;
            suppress = true;
            ImageKeyPwd.Password = ImageKeyPlain.Text;
            suppress = false;
        }
        private void ToggleImageKey_Click(object sender, RoutedEventArgs e)
        {
            if (ImageKeyPlain.Visibility == Visibility.Visible)
            {
                ImageKeyPwd.Password = ImageKeyPlain.Text;
                ImageKeyPwd.Visibility = Visibility.Visible;
                ImageKeyPlain.Visibility = Visibility.Collapsed;
                ToggleImageKey.Content = "Показать";
            }
            else
            {
                ImageKeyPlain.Text = ImageKeyPwd.Password;
                ImageKeyPlain.Visibility = Visibility.Visible;
                ImageKeyPwd.Visibility = Visibility.Collapsed;
                ToggleImageKey.Content = "Скрыть";
            }
        }

        private void Back_Click(object sender, RoutedEventArgs e) => Host.GoTo(1);

        private void Continue_Click(object sender, RoutedEventArgs e)
        {
            var baseUrl = (BaseUrlBox.Text ?? string.Empty).Trim();
            var apiKey = ApiKeyPlain.Visibility == Visibility.Visible ? ApiKeyPlain.Text : ApiKeyPwd.Password;
            var imageKey = ImageKeyPlain.Visibility == Visibility.Visible ? ImageKeyPlain.Text : ImageKeyPwd.Password;

            if (string.IsNullOrWhiteSpace(baseUrl))
            {
                MessageBox.Show("Укажи base_url.", "Codex OmniRoute Installer", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            if (!Uri.TryCreate(baseUrl, UriKind.Absolute, out var uri) || (uri.Scheme != "http" && uri.Scheme != "https"))
            {
                MessageBox.Show("base_url должен быть http(s)://… URL.", "Codex OmniRoute Installer", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            if (string.IsNullOrWhiteSpace(apiKey))
            {
                MessageBox.Show("Укажи api_key.", "Codex OmniRoute Installer", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            Host.State.BaseUrl = baseUrl;
            Host.State.ApiKey = apiKey;
            Host.State.ImageApiKey = imageKey ?? string.Empty;
            Host.GoTo(3);
        }
    }
}
