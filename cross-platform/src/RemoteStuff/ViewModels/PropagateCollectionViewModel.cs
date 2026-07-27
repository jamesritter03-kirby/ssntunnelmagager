using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RemoteStuff.Models;

namespace RemoteStuff.ViewModels;

/// <summary>
/// One list-valued profile setting the "copy lists between profiles" dialog can preview and
/// propagate. Each kind knows how to describe its items and how to copy them from one profile
/// onto another. Copied items get fresh ids so the two profiles keep independent entries.
/// </summary>
public sealed class ProfileCollectionKind
{
    public string Name { get; }
    /// <summary>One-line, human-readable descriptions of each item in a profile.</summary>
    public Func<SshProfile, IReadOnlyList<string>> Items { get; }
    /// <summary>Copy this list from source into dest. <paramref name="merge"/> appends only
    /// new items; otherwise the destination list is replaced.</summary>
    public Action<SshProfile, SshProfile, bool> Copy { get; }

    private ProfileCollectionKind(string name,
        Func<SshProfile, IReadOnlyList<string>> items,
        Action<SshProfile, SshProfile, bool> copy)
    {
        Name = name;
        Items = items;
        Copy = copy;
    }

    public override string ToString() => Name;

    public static readonly IReadOnlyList<ProfileCollectionKind> All = new[]
    {
        new ProfileCollectionKind("Saved Commands",
            p => p.Snippets.Select(s =>
            {
                var l = s.Label.Trim();
                return l.Length == 0 ? s.Command : $"{l} — {s.Command}";
            }).ToList(),
            (src, dst, merge) =>
            {
                var incoming = src.Snippets.Select(s => new CommandSnippet
                { Id = Guid.NewGuid(), Label = s.Label, Command = s.Command }).ToList();
                if (merge)
                {
                    var have = dst.Snippets.Select(s => $"{s.Label}\u0001{s.Command}").ToHashSet();
                    dst.Snippets.AddRange(incoming.Where(s => !have.Contains($"{s.Label}\u0001{s.Command}")));
                }
                else dst.Snippets = incoming;
            }),

        new ProfileCollectionKind("Links",
            p => p.Links.Select(l =>
            {
                var label = string.IsNullOrWhiteSpace(l.Label) ? l.Url : l.Label;
                return $"{label} — {l.Url}";
            }).ToList(),
            (src, dst, merge) =>
            {
                var incoming = src.Links.Select(l => new ProfileLink
                { Id = Guid.NewGuid(), Label = l.Label, Url = l.Url }).ToList();
                if (merge)
                {
                    var have = dst.Links.Select(l => $"{l.Label}\u0001{l.Url}").ToHashSet();
                    dst.Links.AddRange(incoming.Where(l => !have.Contains($"{l.Label}\u0001{l.Url}")));
                }
                else dst.Links = incoming;
            }),

        new ProfileCollectionKind("Port Forwards",
            p => p.Forwards.Select(f =>
            {
                var n = f.Name.Trim();
                return n.Length == 0 ? f.Summary : $"{n}: {f.Summary}";
            }).ToList(),
            (src, dst, merge) =>
            {
                var incoming = src.Forwards.Select(f => f.Clone()).ToList();
                if (merge)
                {
                    var have = dst.Forwards.Select(f => f.Summary).ToHashSet();
                    dst.Forwards.AddRange(incoming.Where(f => !have.Contains(f.Summary)));
                }
                else dst.Forwards = incoming;
            }),

        new ProfileCollectionKind("Environment Variables",
            p => p.Environment.Select(e => $"{e.Name}={e.Value}").ToList(),
            (src, dst, merge) =>
            {
                var incoming = src.Environment.Select(e => new EnvVar
                { Id = Guid.NewGuid(), Name = e.Name, Value = e.Value }).ToList();
                if (merge)
                {
                    var have = dst.Environment.Select(e => e.Name).ToHashSet();
                    dst.Environment.AddRange(incoming.Where(e => !have.Contains(e.Name)));
                }
                else dst.Environment = incoming;
            }),
    };
}

/// <summary>
/// Backs the "Copy Lists Between Profiles" dialog: previews one list-valued setting from a
/// chosen source profile and copies it onto the profiles ticked in the compare table.
/// </summary>
public sealed partial class PropagateCollectionViewModel : ObservableObject
{
    /// <summary>How a copied list is applied to a destination profile.</summary>
    public static readonly string[] ModeOptions = { "Add new items", "Replace all" };

    private readonly IReadOnlyList<SshProfile> _targets;
    private readonly Action _onSaved;

    public IReadOnlyList<ProfileCollectionKind> Kinds => ProfileCollectionKind.All;
    /// <summary>The two apply modes, for the mode picker.</summary>
    public IReadOnlyList<string> Modes => ModeOptions;
    /// <summary>Every profile that can be a copy source.</summary>
    public IReadOnlyList<SshProfile> Sources { get; }

    public ObservableCollection<string> PreviewItems { get; } = new();

    [ObservableProperty] private ProfileCollectionKind _selectedKind;
    [ObservableProperty] private SshProfile? _selectedSource;
    [ObservableProperty] private string _selectedMode = ModeOptions[0];
    [ObservableProperty] private string _statusText = "";

    /// <summary>Raised when the dialog should close.</summary>
    public event Action? CloseRequested;

    public PropagateCollectionViewModel(IEnumerable<SshProfile> allProfiles,
        IEnumerable<SshProfile> targets, Guid? initialSourceId, Action onSaved)
    {
        _targets = targets.ToList();
        _onSaved = onSaved;
        Sources = allProfiles.ToList();
        _selectedKind = Kinds[0];
        _selectedSource = Sources.FirstOrDefault(p => p.Id == initialSourceId);
        RebuildPreview();
    }

    /// <summary>The ticked profiles the copy applies to, excluding the source itself.</summary>
    private List<SshProfile> EffectiveTargets =>
        _targets.Where(t => t.Id != SelectedSource?.Id).ToList();

    public bool CanApply => SelectedSource is not null && EffectiveTargets.Count > 0;

    public string CopyDescription
    {
        get
        {
            var n = EffectiveTargets.Count;
            var sourceIsTicked = SelectedSource is not null && _targets.Any(t => t.Id == SelectedSource.Id);
            if (n == 0)
                return sourceIsTicked
                    ? "Tick another profile to copy to (the source profile is skipped)."
                    : "Tick one or more profiles in the table to copy to.";
            var suffix = sourceIsTicked ? " (the source profile is skipped)" : "";
            return $"Copies to {n} ticked profile(s){suffix}.";
        }
    }

    partial void OnSelectedKindChanged(ProfileCollectionKind value)
    {
        StatusText = "";
        RebuildPreview();
    }

    partial void OnSelectedSourceChanged(SshProfile? value)
    {
        RebuildPreview();
        OnPropertyChanged(nameof(CanApply));
        OnPropertyChanged(nameof(CopyDescription));
    }

    private void RebuildPreview()
    {
        PreviewItems.Clear();
        if (SelectedSource is null) return;
        foreach (var line in SelectedKind.Items(SelectedSource))
            PreviewItems.Add(line);
    }

    [RelayCommand]
    private void Apply()
    {
        if (SelectedSource is null) { StatusText = "Choose a profile to copy from."; return; }
        var dests = EffectiveTargets;
        if (dests.Count == 0) { StatusText = "Tick at least one other profile to copy to."; return; }

        var merge = SelectedMode == ModeOptions[0];
        foreach (var d in dests) SelectedKind.Copy(SelectedSource, d, merge);
        _onSaved();
        StatusText = $"Copied {SelectedKind.Name.ToLowerInvariant()} to {dests.Count} profile(s).";
    }

    [RelayCommand]
    private void Done() => CloseRequested?.Invoke();
}
