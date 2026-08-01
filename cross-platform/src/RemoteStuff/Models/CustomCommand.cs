using System;

namespace RemoteStuff.Models;

/// <summary>A reusable named command the user can run from the command palette.</summary>
public sealed class CustomCommand
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public string Command { get; set; } = "";
}
