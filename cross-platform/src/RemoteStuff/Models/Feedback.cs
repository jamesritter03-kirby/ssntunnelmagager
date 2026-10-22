using System;

namespace RemoteStuff.Models;

/// <summary>What a piece of feedback is about.</summary>
public enum FeedbackKind
{
    Feature,
    Bug,
    Feedback,
}

/// <summary>One user-submitted feature request, bug report, or general note.
/// Stored locally; the user can up-vote items and export the whole list to hand
/// to the developer.</summary>
public sealed class FeedbackItem
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public FeedbackKind Kind { get; set; } = FeedbackKind.Feature;
    public string Title { get; set; } = "";
    public string Details { get; set; } = "";

    /// <summary>Local vote count the user bumps to signal priority.</summary>
    public int Votes { get; set; } = 1;

    /// <summary>Freeform status (e.g. Open, Planned, Done) the user can edit.</summary>
    public string Status { get; set; } = "Open";

    public DateTime CreatedUtc { get; set; } = DateTime.UtcNow;

    /// <summary>App version in use when the item was filed (helps triage bugs).</summary>
    public string AppVersion { get; set; } = "";

    /// <summary>OS the item was filed on.</summary>
    public string Platform { get; set; } = "";
}
