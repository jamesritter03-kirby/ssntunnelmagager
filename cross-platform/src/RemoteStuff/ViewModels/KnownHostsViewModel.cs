using System.Collections.ObjectModel;
using System.Linq;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RemoteStuff.Services;

namespace RemoteStuff.ViewModels;

/// <summary>Row wrapper around a <see cref="KnownHostEntry"/> for the list.</summary>
public sealed class KnownHostRowViewModel
{
    public KnownHostEntry Entry { get; }
    public KnownHostRowViewModel(KnownHostEntry entry) => Entry = entry;

    public string HostLabel => Entry.HostLabel;
    public string KeyType => Entry.KeyType;
    public bool IsHashed => Entry.IsHashed;
}

/// <summary>Backs the "Manage Known Hosts" window: browse, filter and remove entries.</summary>
public sealed partial class KnownHostsViewModel : ViewModelBase
{
    private readonly KnownHostsStore _store = new();

    public ObservableCollection<KnownHostRowViewModel> Rows { get; } = new();

    [ObservableProperty] private string _filter = "";
    [ObservableProperty] private string _statusText = "";

    public KnownHostsViewModel()
    {
        Reload();
    }

    partial void OnFilterChanged(string value) => Rebuild();

    [RelayCommand]
    private void Reload()
    {
        _store.Reload();
        StatusText = _store.ErrorMessage
            ?? (_store.FileExists ? $"{_store.Entries.Count} host key(s)." : "No known_hosts file.");
        Rebuild();
    }

    private void Rebuild()
    {
        Rows.Clear();
        var q = Filter.Trim();
        foreach (var e in _store.Entries)
        {
            if (q.Length > 0 &&
                !e.HostLabel.Contains(q, System.StringComparison.OrdinalIgnoreCase) &&
                !e.KeyType.Contains(q, System.StringComparison.OrdinalIgnoreCase))
                continue;
            Rows.Add(new KnownHostRowViewModel(e));
        }
    }

    [RelayCommand]
    private void Remove(KnownHostRowViewModel? row)
    {
        if (row is null) return;
        _store.Remove(row.Entry);
        StatusText = _store.ErrorMessage ?? "Removed host key.";
        Rebuild();
    }
}
