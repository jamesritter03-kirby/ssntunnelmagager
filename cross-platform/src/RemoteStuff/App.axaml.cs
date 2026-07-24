using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Avalonia.Styling;
using System.Linq;
using RemoteStuff.Services;
using RemoteStuff.ViewModels;
using RemoteStuff.Views;

namespace RemoteStuff;

public partial class App : Application
{
    private TrayService? _tray;
    public override void Initialize()
    {
        AvaloniaXamlLoader.Load(this);
    }

    /// <summary>Switch the whole app between the Light and Dark theme variants.</summary>
    public static void ApplyTheme(string theme)
    {
        if (Current is { } app)
            app.RequestedThemeVariant =
                theme.Equals("Light", System.StringComparison.OrdinalIgnoreCase)
                    ? ThemeVariant.Light
                    : ThemeVariant.Dark;
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            // Disable Avalonia's built-in validation that duplicates DataAnnotations.
            DisableAvaloniaDataAnnotationValidation();

            var store = new ProfileStore();
            var secrets = new SecretStore();
            var settings = new AppSettings();
            ApplyTheme(settings.AppTheme);
            var vm = new MainWindowViewModel(store, secrets, settings);
            var window = new MainWindow { DataContext = vm };
            desktop.MainWindow = window;
            Services.DialogService.Top = desktop.MainWindow;

            _tray = new TrayService(this, vm, desktop);
            _tray.Install();

            // Restore the previous session / auto-connect once the window is shown.
            window.Opened += (_, _) => vm.RunStartupTasks();

            // Persist the open session on shutdown so it can be resumed next launch.
            desktop.ShutdownRequested += (_, _) =>
            {
                vm.SaveLastSession();
                settings.Save();
            };
        }

        base.OnFrameworkInitializationCompleted();
    }

    private static void DisableAvaloniaDataAnnotationValidation()
    {
        var dataValidationPluginsToRemove =
            Avalonia.Data.Core.Plugins.BindingPlugins.DataValidators
                .OfType<Avalonia.Data.Core.Plugins.DataAnnotationsValidationPlugin>()
                .ToArray();

        foreach (var plugin in dataValidationPluginsToRemove)
        {
            Avalonia.Data.Core.Plugins.BindingPlugins.DataValidators.Remove(plugin);
        }
    }
}
