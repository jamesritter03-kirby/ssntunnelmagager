using System;

namespace RemoteStuff.ViewModels;

/// <summary>A single row in the command palette — either an actionable command or a
/// non-selectable section header.</summary>
public sealed class PaletteItem
{
    public required string Title { get; init; }
    public string Subtitle { get; init; } = "";
    /// <summary>A <see cref="RemoteStuff.Views.Controls.LineIcon"/> kind shown at the row's leading edge.</summary>
    public string Icon { get; set; } = "";
    /// <summary>The section this row belongs to (used by the category filter).</summary>
    public string Section { get; set; } = "";
    /// <summary>True for a section-title row: rendered as a header and skipped by selection.</summary>
    public bool IsHeader { get; init; }
    public Action Run { get; init; } = static () => { };
    /// <summary>Optional inline edit action (custom commands only).</summary>
    public Action? Edit { get; init; }
    /// <summary>Optional inline delete action (custom commands only).</summary>
    public Action? Delete { get; init; }

    public bool IsAction => !IsHeader;
    public bool HasIcon => !string.IsNullOrEmpty(Icon);
    public bool HasSubtitle => !string.IsNullOrEmpty(Subtitle);
    public bool CanEdit => Edit is not null;
    public bool CanDelete => Delete is not null;
}

/// <summary>A recently-closed tab that can be reopened.</summary>
public sealed class ClosedItem
{
    public ClosedItem(string title, string glyph, Action reopen)
    {
        Title = title;
        Glyph = glyph;
        Reopen = reopen;
    }

    public string Title { get; }
    public string Glyph { get; }
    public Action Reopen { get; }
}
