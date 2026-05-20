using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace OmniRouteInstaller.Views
{
    public class PageBase : Page
    {
        protected MainWindow Host { get; }

        protected PageBase(MainWindow host)
        {
            Host = host;
            Background = Brushes.Transparent;
            Loaded += PageBase_Loaded;
            RenderTransform = new TranslateTransform();
        }

        private void PageBase_Loaded(object sender, RoutedEventArgs e)
        {
            var sb = (Storyboard)FindResource("PageEnterStoryboard");
            Storyboard.SetTarget(sb, this);
            sb.Begin();
        }
    }
}
