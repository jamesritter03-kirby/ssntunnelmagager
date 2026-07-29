using System;

namespace RemoteStuff.Services.Terminal;

/// <summary>
/// A pseudo-terminal backed child process. Implemented with <c>forkpty</c> on
/// Unix (<see cref="UnixPtyProcess"/>) and with the Win32 pseudo-console (ConPTY)
/// on Windows (<see cref="WindowsPtyProcess"/>). The embedded terminal talks to
/// whichever implementation matches the host OS through this interface.
/// </summary>
public interface IPtyProcess : IDisposable
{
    /// <summary>True once the child has exited.</summary>
    bool HasExited { get; }

    /// <summary>Launch <paramref name="executable"/> in a new PTY sized cols × rows.</summary>
    void Start(string executable, string[] args, ushort cols, ushort rows,
        (string Name, string Value)[]? extraEnv = null, string? workingDirectory = null);

    /// <summary>Read available bytes from the PTY into <paramref name="buffer"/>.</summary>
    int Read(byte[] buffer);

    /// <summary>Write bytes to the PTY (the child's stdin).</summary>
    void Write(byte[] data);

    /// <summary>Resize the PTY window (cols × rows).</summary>
    void Resize(ushort cols, ushort rows);

    /// <summary>Non-blocking check for child exit; returns the exit code when done.</summary>
    int? TryReap();

    /// <summary>Ask the child to terminate.</summary>
    void Terminate();
}
