using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Media;

namespace OmniRouteInstaller.Views
{
    public enum StepStatus { Pending, Running, Ok, Skipped, Failed }

    public sealed class StepItem : INotifyPropertyChanged
    {
        private StepStatus status = StepStatus.Pending;
        private string detail = string.Empty;

        public string Id { get; }
        public string Title { get; }

        public StepItem(string id, string title)
        {
            Id = id;
            Title = title;
        }

        public StepStatus Status
        {
            get => status;
            set
            {
                status = value;
                OnChanged();
                OnChanged(nameof(StatusGlyph));
                OnChanged(nameof(StatusBg));
                OnChanged(nameof(StatusBorder));
                OnChanged(nameof(StatusText));
            }
        }

        public string Detail
        {
            get => detail;
            set { detail = value; OnChanged(); }
        }

        public string StatusGlyph => status switch
        {
            StepStatus.Pending => "",
            StepStatus.Running => "•",
            StepStatus.Ok => "✓",
            StepStatus.Skipped => "–",
            StepStatus.Failed => "!",
            _ => ""
        };

        public Brush StatusBg => status switch
        {
            StepStatus.Pending => (Brush)System.Windows.Application.Current.FindResource("BgPanelMuted"),
            StepStatus.Running => (Brush)System.Windows.Application.Current.FindResource("Accent"),
            StepStatus.Ok => (Brush)System.Windows.Application.Current.FindResource("Success"),
            StepStatus.Skipped => (Brush)System.Windows.Application.Current.FindResource("BgPanelMuted"),
            StepStatus.Failed => (Brush)System.Windows.Application.Current.FindResource("Danger"),
            _ => Brushes.Transparent
        };

        public Brush StatusBorder => status switch
        {
            StepStatus.Pending => (Brush)System.Windows.Application.Current.FindResource("BorderStrong"),
            StepStatus.Running => (Brush)System.Windows.Application.Current.FindResource("Accent"),
            StepStatus.Ok => (Brush)System.Windows.Application.Current.FindResource("Success"),
            StepStatus.Skipped => (Brush)System.Windows.Application.Current.FindResource("BorderStrong"),
            StepStatus.Failed => (Brush)System.Windows.Application.Current.FindResource("Danger"),
            _ => Brushes.Transparent
        };

        public Brush StatusText => status switch
        {
            StepStatus.Pending => (Brush)System.Windows.Application.Current.FindResource("TextMuted"),
            StepStatus.Running => (Brush)System.Windows.Application.Current.FindResource("TextPrimary"),
            StepStatus.Ok => (Brush)System.Windows.Application.Current.FindResource("TextPrimary"),
            StepStatus.Skipped => (Brush)System.Windows.Application.Current.FindResource("TextDim"),
            StepStatus.Failed => (Brush)System.Windows.Application.Current.FindResource("Danger"),
            _ => Brushes.White
        };

        public event PropertyChangedEventHandler PropertyChanged;
        private void OnChanged([CallerMemberName] string name = null)
            => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
