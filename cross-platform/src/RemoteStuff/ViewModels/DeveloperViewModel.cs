using System;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RemoteStuff.Services;

namespace RemoteStuff.ViewModels;

/// <summary>Backs the Developer Tools popout: a live snapshot of runtime and
/// app state (built on demand by the main view-model) that can be refreshed and
/// copied to the clipboard.</summary>
public sealed partial class DeveloperViewModel : ObservableObject
{
    private readonly Func<string> _reportProvider;

    [ObservableProperty] private string _report = "";
    [ObservableProperty] private bool _autoRefresh;
    [ObservableProperty] private string _statusText = "";

    private readonly System.Timers.Timer _timer;

    public DeveloperViewModel(Func<string> reportProvider)
    {
        _reportProvider = reportProvider;
        _timer = new System.Timers.Timer(2_000) { AutoReset = true };
        _timer.Elapsed += (_, _) =>
            Avalonia.Threading.Dispatcher.UIThread.Post(Refresh);
        Refresh();
    }

    [RelayCommand]
    private void Refresh()
    {
        Report = _reportProvider();
        StatusText = "Updated " + DateTime.Now.ToString("HH:mm:ss");
    }

    [RelayCommand]
    private async Task Copy()
    {
        if (DialogService.Top?.Clipboard is { } cb)
        {
            await cb.SetTextAsync(Report);
            StatusText = "Copied to clipboard";
        }
    }

    partial void OnAutoRefreshChanged(bool value)
    {
        if (value) _timer.Start();
        else _timer.Stop();
    }

    /// <summary>Stop the auto-refresh timer when the window closes.</summary>
    public void Stop()
    {
        _timer.Stop();
        _timer.Dispose();
    }
}
