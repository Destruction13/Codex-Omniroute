using System;
using System.Collections.ObjectModel;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using OmniRouteInstaller.Services;

namespace OmniRouteInstaller.Views
{
    public partial class ProgressPage : PageBase
    {
        public ObservableCollection<StepItem> Steps { get; } = new ObservableCollection<StepItem>();

        public ProgressPage(MainWindow host) : base(host)
        {
            InitializeComponent();

            var s = Host.State;
            Steps.Add(new StepItem("extract",   "Распаковка Codex OmniRoute"));
            Steps.Add(new StepItem("winget",    "Проверка winget"));
            Steps.Add(new StepItem("node",      "Установка Node.js LTS"));
            Steps.Add(new StepItem("dotnet",    "Установка .NET SDK 8"));
            Steps.Add(new StepItem("codex",     "Установка OpenAI Codex Desktop (Microsoft Store)"));
            Steps.Add(new StepItem("provider",  "Запись omniroute-provider.json"));
            Steps.Add(new StepItem("setup",     "Сборка прослойки и обновление дубля"));
            if (s.CreateShortcuts)
            {
                Steps.Add(new StepItem("shortcuts", "Создание ярлыков"));
            }
            Steps.Add(new StepItem("verify",    "Финальная диагностика"));

            StepsList.ItemsSource = Steps;

            Loaded += async (_, __) => await Run();
        }

        private async Task Run()
        {
            var orch = new InstallOrchestrator(Host.State, Steps,
                line => Dispatcher.Invoke(() => AppendLog(line)));

            bool ok = false;
            try
            {
                ok = await orch.RunAsync();
            }
            catch (Exception ex)
            {
                AppendLog("FATAL " + ex.Message);
            }

            ContinueButton.IsEnabled = true;
            if (ok)
            {
                HeaderText.Text = "Готово!";
                SubHeaderText.Text = "Codex OmniRoute установлен. Нажми «Готово» — на следующем экране запустим его.";
                ContinueButton.Content = "Готово →";
            }
            else
            {
                HeaderText.Text = "Установка не завершилась";
                SubHeaderText.Text = "Часть шагов не прошла. Проверь лог ниже и попробуй ещё раз — установщик можно перезапускать столько раз, сколько нужно.";
                ContinueButton.Content = "Закрыть";
            }
        }

        private void AppendLog(string line)
        {
            LogBox.AppendText(line + Environment.NewLine);
            LogScroller.ScrollToEnd();
        }

        private void ToggleLog_Click(object sender, RoutedEventArgs e)
        {
            if (LogScroller.Visibility == Visibility.Visible)
            {
                LogScroller.Visibility = Visibility.Collapsed;
                ToggleLogButton.Content = "Показать лог";
            }
            else
            {
                LogScroller.Visibility = Visibility.Visible;
                ToggleLogButton.Content = "Скрыть лог";
            }
        }

        private void Continue_Click(object sender, RoutedEventArgs e)
        {
            Host.GoTo(5);
        }
    }
}
