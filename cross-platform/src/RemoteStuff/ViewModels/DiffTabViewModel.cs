using System.Collections.Generic;
using CommunityToolkit.Mvvm.ComponentModel;
using RemoteStuff.Services;

namespace RemoteStuff.ViewModels;

/// <summary>A read-only, side-by-side comparison of two editor buffers, mirroring
/// the macOS app's compare view. Rows are pre-aligned by <see cref="TextDiff"/>.</summary>
public sealed partial class DiffTabViewModel : TabViewModel
{
    public override string Glyph => "⇄";

    public string LeftHeader { get; }
    public string RightHeader { get; }

    /// <summary>Aligned diff rows for the two panes (both sides share the count).</summary>
    public IReadOnlyList<DiffRow> Rows { get; }

    [ObservableProperty] private string _summary = "";

    public DiffTabViewModel(string leftTitle, string leftText, string rightTitle, string rightText)
    {
        LeftHeader = leftTitle;
        RightHeader = rightTitle;
        Title = "Compare: " + leftTitle + " ⇄ " + rightTitle;
        Rows = TextDiff.Compare(leftText, rightText);

        int added = 0, removed = 0, changed = 0;
        foreach (var r in Rows)
        {
            if (r.RightStatus == DiffRowStatus.Added) added++;
            else if (r.LeftStatus == DiffRowStatus.Deleted) removed++;
            else if (r.LeftStatus == DiffRowStatus.Changed) changed++;
        }
        Summary = added == 0 && removed == 0 && changed == 0
            ? "Files are identical"
            : $"{changed} changed · {added} added · {removed} removed";
    }
}
