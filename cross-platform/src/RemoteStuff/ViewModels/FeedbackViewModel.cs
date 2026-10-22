using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RemoteStuff.Models;
using RemoteStuff.Services;

namespace RemoteStuff.ViewModels;

/// <summary>One feedback row: wraps a <see cref="FeedbackItem"/> with vote/delete
/// actions and display helpers.</summary>
public sealed partial class FeedbackItemViewModel : ObservableObject
{
    private readonly FeedbackViewModel _owner;
    public FeedbackItem Item { get; }

    public FeedbackItemViewModel(FeedbackItem item, FeedbackViewModel owner)
    {
        Item = item;
        _owner = owner;
        _votes = item.Votes;
    }

    public string Title => string.IsNullOrWhiteSpace(Item.Title) ? "(untitled)" : Item.Title;
    public string Details => Item.Details;
    public bool HasDetails => !string.IsNullOrWhiteSpace(Item.Details);
    public string KindLabel => Item.Kind switch
    {
        FeedbackKind.Feature => "Feature",
        FeedbackKind.Bug => "Bug",
        _ => "Feedback",
    };

    public string KindGlyph => Item.Kind switch
    {
        FeedbackKind.Feature => "star",
        FeedbackKind.Bug => "zap",
        _ => "clipboard",
    };

    public Avalonia.Media.IBrush KindBrush => Item.Kind switch
    {
        FeedbackKind.Feature => new Avalonia.Media.SolidColorBrush(Avalonia.Media.Color.Parse("#4C8BF5")),
        FeedbackKind.Bug => new Avalonia.Media.SolidColorBrush(Avalonia.Media.Color.Parse("#E5484D")),
        _ => new Avalonia.Media.SolidColorBrush(Avalonia.Media.Color.Parse("#8A8F98")),
    };

    public string Meta => $"{Item.CreatedUtc.ToLocalTime():yyyy-MM-dd} · {Item.AppVersion} · {Item.Platform}";

    [ObservableProperty] private int _votes;

    [RelayCommand]
    private void Upvote()
    {
        Votes++;
        Item.Votes = Votes;
        _owner.Persist();
    }

    [RelayCommand]
    private void Downvote()
    {
        if (Votes <= 0) return;
        Votes--;
        Item.Votes = Votes;
        _owner.Persist();
    }

    [RelayCommand]
    private void Delete() => _owner.Remove(this);
}

/// <summary>Backs the Feedback &amp; Feature Requests window: file feature requests,
/// bugs and notes, up-vote them to prioritize, and export the list to hand to the
/// developer.</summary>
public sealed partial class FeedbackViewModel : ObservableObject
{
    private readonly FeedbackStore _store;

    /// <summary>Raised to save an export to disk: (suggestedFileName, contents).</summary>
    public event Func<string, string, Task>? ExportRequested;

    public ObservableCollection<FeedbackItemViewModel> Items { get; } = new();

    public IReadOnlyList<string> KindChoices { get; } = new[] { "Feature request", "Bug", "Feedback" };

    [ObservableProperty] private int _newKindIndex;
    [ObservableProperty] private string _newTitle = "";
    [ObservableProperty] private string _newDetails = "";
    [ObservableProperty] private string _statusText = "";

    public bool HasItems => Items.Count > 0;

    public FeedbackViewModel(FeedbackStore store)
    {
        _store = store;
        Reload();
    }

    private void Reload()
    {
        Items.Clear();
        foreach (var i in _store.Items.OrderByDescending(i => i.Votes).ThenByDescending(i => i.CreatedUtc))
            Items.Add(new FeedbackItemViewModel(i, this));
        OnPropertyChanged(nameof(HasItems));
    }

    private static FeedbackKind KindFromIndex(int i) => i switch
    {
        1 => FeedbackKind.Bug,
        2 => FeedbackKind.Feedback,
        _ => FeedbackKind.Feature,
    };

    [RelayCommand]
    private void AddItem()
    {
        if (string.IsNullOrWhiteSpace(NewTitle))
        {
            StatusText = "Enter a short title first.";
            return;
        }
        var kind = KindFromIndex(NewKindIndex);
        _store.Add(kind, NewTitle, NewDetails);
        NewTitle = "";
        NewDetails = "";
        Reload();
        StatusText = "Added. Up-vote the items you care about most.";
    }

    public void Remove(FeedbackItemViewModel row)
    {
        _store.Remove(row.Item.Id);
        Items.Remove(row);
        OnPropertyChanged(nameof(HasItems));
    }

    /// <summary>Persist a vote change and re-order the list by votes.</summary>
    public void Persist()
    {
        _store.Save();
        var ordered = Items.OrderByDescending(i => i.Votes).ThenByDescending(i => i.Item.CreatedUtc).ToList();
        for (var i = 0; i < ordered.Count; i++)
        {
            var cur = Items.IndexOf(ordered[i]);
            if (cur != i) Items.Move(cur, i);
        }
    }

    [RelayCommand]
    private async Task ExportMarkdown()
    {
        if (ExportRequested is null) return;
        await ExportRequested("remote-stuff-feedback.md", _store.ToMarkdown());
        StatusText = "Exported. Send the file along with your request.";
    }

    [RelayCommand]
    private async Task ExportJson()
    {
        if (ExportRequested is null) return;
        await ExportRequested("remote-stuff-feedback.json", _store.ToJson());
        StatusText = "Exported JSON.";
    }
}
