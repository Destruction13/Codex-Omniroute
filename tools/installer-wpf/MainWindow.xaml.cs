using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using OmniRouteInstaller.Views;

namespace OmniRouteInstaller
{
    public partial class MainWindow : Window
    {
        public InstallerState State { get; } = new InstallerState();

        private readonly List<string> stepTitles = new List<string>
        {
            "Welcome",
            "Folder",
            "OmniRoute",
            "Summary",
            "Install",
            "Done"
        };

        private int currentStep = 0;

        public MainWindow()
        {
            InitializeComponent();
            RenderStepDots();
            Navigate(new WelcomePage(this));
        }

        public void GoTo(int step)
        {
            currentStep = step;
            RenderStepDots();
            switch (step)
            {
                case 0: Navigate(new WelcomePage(this)); break;
                case 1: Navigate(new LocationPage(this)); break;
                case 2: Navigate(new CredentialsPage(this)); break;
                case 3: Navigate(new SummaryPage(this)); break;
                case 4: Navigate(new ProgressPage(this)); break;
                case 5: Navigate(new CompletePage(this)); break;
            }
        }

        private void Navigate(Page page)
        {
            PageFrame.Navigate(page);
        }

        private void RenderStepDots()
        {
            StepDots.Children.Clear();
            for (int i = 0; i < stepTitles.Count; i++)
            {
                bool active = i == currentStep;
                bool past = i < currentStep;
                var dot = new Ellipse
                {
                    Width = active ? 28 : 8,
                    Height = 8,
                    Margin = new Thickness(0, 0, 6, 0),
                    Fill = active
                        ? (Brush)FindResource("Accent")
                        : past
                            ? (Brush)FindResource("AccentDark")
                            : (Brush)FindResource("BorderStrong"),
                    VerticalAlignment = VerticalAlignment.Center
                };
                StepDots.Children.Add(dot);
            }
            StepLabel.Text = $"Step {currentStep + 1} of {stepTitles.Count} · {stepTitles[currentStep]}";
        }

        private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
        {
            if (e.ChangedButton == MouseButton.Left)
            {
                try { DragMove(); } catch { }
            }
        }

        private void Minimize_Click(object sender, RoutedEventArgs e)
        {
            WindowState = WindowState.Minimized;
        }

        private void Close_Click(object sender, RoutedEventArgs e)
        {
            if (currentStep == 4)
            {
                var result = MessageBox.Show(
                    "Installation is in progress. Cancel anyway?",
                    "Codex OmniRoute Installer",
                    MessageBoxButton.YesNo,
                    MessageBoxImage.Warning);
                if (result != MessageBoxResult.Yes) return;
            }
            Close();
        }
    }
}
