using System;
using System.Runtime.InteropServices;

namespace RemoteStuff.Services.Terminal;

/// <summary>
/// A pseudo-terminal (PTY) backed child process on Unix (macOS / Linux), created
/// with <c>forkpty</c> so the child gets a real controlling terminal. This makes
/// interactive prompts — SSH password entry, host-key confirmation, 2FA, curses
/// apps — work exactly as they do in a normal terminal.
/// </summary>
public sealed class UnixPtyProcess : IDisposable
{
    private int _masterFd = -1;
    private int _pid = -1;
    private bool _disposed;

    public int Pid => _pid;
    public bool HasExited { get; private set; }

    [StructLayout(LayoutKind.Sequential)]
    private struct WinSize
    {
        public ushort ws_row;
        public ushort ws_col;
        public ushort ws_xpixel;
        public ushort ws_ypixel;
    }

    [DllImport("libc", SetLastError = true)]
    private static extern int forkpty(out int amaster, IntPtr name, IntPtr termp, ref WinSize winp);

    [DllImport("libc", SetLastError = true)]
    private static extern int execv(IntPtr path, IntPtr argv);

    [DllImport("libc", SetLastError = true)]
    private static extern int execvp(IntPtr file, IntPtr argv);

    [DllImport("libc", SetLastError = true)]
    private static extern void _exit(int status);

    [DllImport("libc", SetLastError = true)]
    private static extern int setenv(IntPtr name, IntPtr value, int overwrite);

    [DllImport("libc", SetLastError = true)]
    private static extern int chdir(IntPtr path);

    [DllImport("libc", SetLastError = true)]
    private static extern nint read(int fd, byte[] buf, nint count);

    [DllImport("libc", SetLastError = true)]
    private static extern nint write(int fd, byte[] buf, nint count);

    [DllImport("libc", SetLastError = true)]
    private static extern int close(int fd);

    [DllImport("libc", SetLastError = true)]
    private static extern int ioctl(int fd, nuint request, ref WinSize ws);

    // Apple Silicon (macOS arm64) diverges from AAPCS64 for variadic functions: the
    // variadic arguments of ioctl(int, unsigned long, ...) are passed on the stack, not
    // in registers. A plain 3-argument P/Invoke leaves the winsize pointer in a register,
    // so ioctl(2) reads a garbage pointer and stamps a garbage window size onto the tty
    // (e.g. 27424x64240) — which makes zsh's PROMPT_SP emit tens of thousands of spaces
    // and blank the screen. Padding the call with six dummy register arguments pushes the
    // real pointer onto the stack where variadic ioctl expects it. Linux and Intel macOS
    // pass variadic args in registers, so they use the plain form above.
    [DllImport("libc", SetLastError = true, EntryPoint = "ioctl")]
    private static extern int ioctl_darwin_arm64(int fd, nuint request,
        nint d2, nint d3, nint d4, nint d5, nint d6, nint d7, ref WinSize ws);

    [DllImport("libc", SetLastError = true)]
    private static extern int waitpid(int pid, out int status, int options);

    [DllImport("libc", SetLastError = true)]
    private static extern int kill(int pid, int sig);

    // TIOCSWINSZ differs by platform.
    private static readonly nuint TIOCSWINSZ =
        RuntimeInformation.IsOSPlatform(OSPlatform.OSX) ? (nuint)0x80087467 : (nuint)0x5414;

    // Apple Silicon needs the stack-based variadic calling convention (see ioctl_darwin_arm64).
    private static readonly bool IsMacArm64 =
        RuntimeInformation.IsOSPlatform(OSPlatform.OSX) &&
        RuntimeInformation.ProcessArchitecture == Architecture.Arm64;

    private const int WNOHANG = 1;
    private const int SIGTERM = 15;
    private const int SIGKILL = 9;

    /// <summary>
    /// Fork a child in a new PTY and exec <paramref name="executable"/>.
    /// Marshalling is done *before* the fork so the child only makes simple
    /// pointer-based syscalls (no managed allocation) before <c>execvp</c>.
    /// </summary>
    public void Start(string executable, string[] args, ushort cols, ushort rows,
        (string Name, string Value)[]? extraEnv = null, string? workingDirectory = null)
    {
        // Pre-marshal everything the child needs into unmanaged memory.
        var argvList = new IntPtr[args.Length + 2];
        argvList[0] = Marshal.StringToHGlobalAnsi(executable);
        for (var i = 0; i < args.Length; i++)
            argvList[i + 1] = Marshal.StringToHGlobalAnsi(args[i]);
        argvList[^1] = IntPtr.Zero; // null terminator

        var argvBlock = Marshal.AllocHGlobal(IntPtr.Size * argvList.Length);
        Marshal.Copy(argvList, 0, argvBlock, argvList.Length);
        var filePtr = argvList[0];

        // Pre-marshal env + cwd.
        var envPtrs = new (IntPtr name, IntPtr val)[extraEnv?.Length ?? 0];
        if (extraEnv != null)
            for (var i = 0; i < extraEnv.Length; i++)
                envPtrs[i] = (Marshal.StringToHGlobalAnsi(extraEnv[i].Name),
                              Marshal.StringToHGlobalAnsi(extraEnv[i].Value));
        var cwdPtr = string.IsNullOrEmpty(workingDirectory)
            ? IntPtr.Zero : Marshal.StringToHGlobalAnsi(workingDirectory);

        var ws = new WinSize { ws_row = rows, ws_col = cols };

        var pid = forkpty(out var master, IntPtr.Zero, IntPtr.Zero, ref ws);
        if (pid < 0)
            throw new InvalidOperationException("forkpty failed: " + Marshal.GetLastWin32Error());

        if (pid == 0)
        {
            // ---- Child: only simple pointer syscalls, then exec. ----
            if (cwdPtr != IntPtr.Zero)
                chdir(cwdPtr);
            foreach (var (name, val) in envPtrs)
                setenv(name, val, 1);
            execvp(filePtr, argvBlock);
            _exit(127); // exec failed
            return;
        }

        _pid = pid;
        _masterFd = master;
    }

    /// <summary>Read available bytes from the PTY master into <paramref name="buffer"/>.</summary>
    public int Read(byte[] buffer)
    {
        if (_masterFd < 0) return 0;
        var n = (int)read(_masterFd, buffer, buffer.Length);
        return n;
    }

    /// <summary>Write bytes to the PTY master (child stdin).</summary>
    public void Write(byte[] data)
    {
        if (_masterFd < 0 || data.Length == 0) return;
        write(_masterFd, data, data.Length);
    }

    /// <summary>Resize the PTY window (cols × rows).</summary>
    public void Resize(ushort cols, ushort rows)
    {
        if (_masterFd < 0) return;
        var ws = new WinSize { ws_row = rows, ws_col = cols };
        if (IsMacArm64)
            ioctl_darwin_arm64(_masterFd, TIOCSWINSZ, 0, 0, 0, 0, 0, 0, ref ws);
        else
            ioctl(_masterFd, TIOCSWINSZ, ref ws);
    }

    /// <summary>Non-blocking check for child exit; returns the exit code when done.</summary>
    public int? TryReap()
    {
        if (_pid <= 0 || HasExited) return HasExited ? 0 : null;
        var r = waitpid(_pid, out var status, WNOHANG);
        if (r == _pid)
        {
            HasExited = true;
            // Low 7 bits = signal, next 8 bits = exit code (WEXITSTATUS).
            return (status >> 8) & 0xFF;
        }
        return null;
    }

    public void Terminate()
    {
        if (_pid > 0 && !HasExited)
            kill(_pid, SIGTERM);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        if (_pid > 0 && !HasExited)
        {
            kill(_pid, SIGTERM);
            kill(_pid, SIGKILL);
        }
        if (_masterFd >= 0)
        {
            close(_masterFd);
            _masterFd = -1;
        }
    }
}
