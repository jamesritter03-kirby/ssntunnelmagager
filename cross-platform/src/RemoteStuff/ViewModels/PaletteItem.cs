using System;

namespace RemoteStuff.ViewModels;

/// <summary>A single actionable row in the command palette.</summary>
public sealed class PaletteItem
{
    public required string Title { get; init; }
    public string Subtitle { get; init; } = "";
    public required Action Run { get; init; }
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
