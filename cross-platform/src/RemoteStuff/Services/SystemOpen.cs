using System;
using System.IO;

namespace RemoteStuff.Services;

/// <summary>Cross-platform helpers to open a file/URL with the OS default handler and
/// to reveal a file in the system file manager (Finder / Explorer / xdg).</summary>
public static class SystemOpen
{
    /// <summary>Open a file or URL with the operating system's default application.</summary>
    public static void Open(string path)
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path)
            {
                UseShellExecute = true,
                Verb = OperatingSystem.IsWindows() ? "open" : ""
            });
        }
        catch { /* no default handler available */ }
    }

    /// <summary>Select a file in the OS file manager.</summary>
    public static void Reveal(string path)
    {
        try
        {
            if (OperatingSystem.IsMacOS())
                System.Diagnostics.Process.Start("open", new[] { "-R", path });
            else if (OperatingSystem.IsWindows())
                System.Diagnostics.Process.Start("explorer", $"/select,\"{path}\"");
            else
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(
                    Path.GetDirectoryName(path) ?? path) { UseShellExecute = true });
        }
        catch { /* file manager unavailable */ }
    }
}
