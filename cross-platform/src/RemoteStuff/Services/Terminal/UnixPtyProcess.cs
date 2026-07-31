using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;

namespace RemoteStuff.Services.Terminal;

/// <summary>
/// A pseudo-terminal (PTY) backed child process on Unix (macOS / Linux), created
/// with <c>forkpty</c> so the child gets a real controlling terminal. This makes
/// interactive prompts — SSH password entry, host-key confirmation, 2FA, curses
/// apps — work exactly as they do in a normal terminal.
/// </summary>
public sealed class UnixPtyProcess : IPtyProcess
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

    // --- PTY creation. We deliberately avoid forkpty(): see Start(). ---
    [DllImport("libc", SetLastError = true)]
    private static extern int posix_openpt(int flags);

    [DllImport("libc", SetLastError = true)]
    private static extern int grantpt(int fd);

    [DllImport("libc", SetLastError = true)]
    private static extern int unlockpt(int fd);

    [DllImport("libc", SetLastError = true)]
    private static extern IntPtr ptsname(int fd);

    [DllImport("libc", SetLastError = true)]
    private static extern int fcntl(int fd, int cmd, int arg);

    // --- posix_spawn: the kernel/libc performs fork+exec, so none of OUR managed
    // code (nor non-async-signal-safe libc like setenv/malloc) ever runs on the
    // child side of a fork in this multi-threaded CLR + AppKit process. Using
    // forkpty() here crashed the fork child (SIGBUS, "crashed on child side of
    // fork pre-exec") because the CLR is not fork-safe. ---
    [DllImport("libc", SetLastError = true)]
    private static extern int posix_spawnp(out int pid, IntPtr file,
        IntPtr fileActions, IntPtr attr, IntPtr argv, IntPtr envp);

    [DllImport("libc")]
    private static extern int posix_spawn_file_actions_init(IntPtr fa);
    [DllImport("libc")]
    private static extern int posix_spawn_file_actions_destroy(IntPtr fa);
    [DllImport("libc")]
    private static extern int posix_spawn_file_actions_addopen(IntPtr fa, int fd, IntPtr path, int oflag, uint mode);
    [DllImport("libc")]
    private static extern int posix_spawn_file_actions_adddup2(IntPtr fa, int fd, int newfd);
    [DllImport("libc")]
    private static extern int posix_spawn_file_actions_addchdir_np(IntPtr fa, IntPtr path);

    [DllImport("libc")]
    private static extern int posix_spawnattr_init(IntPtr attr);
    [DllImport("libc")]
    private static extern int posix_spawnattr_destroy(IntPtr attr);
    [DllImport("libc")]
    private static extern int posix_spawnattr_setflags(IntPtr attr, short flags);

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

    // TIOCGWINSZ (read the tty's current window size) — used by the diagnostic
    // read-back so we can see the size the kernel actually stored, not just what
    // we asked for.
    private static readonly nuint TIOCGWINSZ =
        RuntimeInformation.IsOSPlatform(OSPlatform.OSX) ? (nuint)0x40087468 : (nuint)0x5413;

    // Apple Silicon needs the stack-based variadic calling convention (see ioctl_darwin_arm64).
    private static readonly bool IsMacArm64 =
        RuntimeInformation.IsOSPlatform(OSPlatform.OSX) &&
        RuntimeInformation.ProcessArchitecture == Architecture.Arm64;

    private const int WNOHANG = 1;
    private const int SIGTERM = 15;
    private const int SIGKILL = 9;

    private const int O_RDWR = 0x0002;
    // O_NOCTTY differs by platform.
    private static readonly int O_NOCTTY =
        RuntimeInformation.IsOSPlatform(OSPlatform.OSX) ? 0x20000 : 0x100;
    private const int F_SETFD = 2;
    private const int FD_CLOEXEC = 1;
    // POSIX_SPAWN_SETSID makes the child a session leader so the pty it opens
    // becomes its controlling terminal. Value differs by platform.
    private static readonly short POSIX_SPAWN_SETSID =
        RuntimeInformation.IsOSPlatform(OSPlatform.OSX) ? (short)0x0400 : (short)0x80;

    // On macOS, POSIX_SPAWN_SETSID makes the child a session leader but does NOT
    // give it a controlling terminal (the pty is opened before setsid, so the
    // open-acquires-ctty rule doesn't apply). Without a controlling terminal,
    // /dev/tty can't be opened and ssh host-key confirmation fails with "Host key
    // verification failed". The bundled native spawn-helper issues TIOCSCTTY (the
    // one call posix_spawn can't) then execs the real program. Linux acquires the
    // ctty on open (glibc runs setsid before the file actions), so it's macOS-only.
    private static readonly string? MacSpawnHelper = ResolveMacSpawnHelper();

    private static string? ResolveMacSpawnHelper()
    {
        if (!RuntimeInformation.IsOSPlatform(OSPlatform.OSX)) return null;
        var path = Path.Combine(AppContext.BaseDirectory, "spawn-helper");
        return File.Exists(path) ? path : null;
    }

    /// <summary>
    /// Open a new PTY and launch <paramref name="executable"/> in it via
    /// <c>posix_spawn</c>. We do NOT use <c>forkpty</c>: this is a multi-threaded
    /// CLR + AppKit process, and running any managed code (or non-async-signal-safe
    /// libc such as setenv/malloc) on the child side of a fork before exec corrupts
    /// the child and crashes it (SIGBUS, "crashed on child side of fork pre-exec").
    /// posix_spawn hands fork+exec to the kernel/libc, which never runs our code.
    /// </summary>
    public void Start(string executable, string[] args, ushort cols, ushort rows,
        (string Name, string Value)[]? extraEnv = null, string? workingDirectory = null)
    {
        // Create the master side of a pseudo-terminal and unlock its slave.
        var master = posix_openpt(O_RDWR | O_NOCTTY);
        if (master < 0)
            throw new InvalidOperationException("posix_openpt failed: " + Marshal.GetLastWin32Error());
        if (grantpt(master) != 0 || unlockpt(master) != 0)
        {
            close(master);
            throw new InvalidOperationException("grantpt/unlockpt failed: " + Marshal.GetLastWin32Error());
        }
        // Don't leak the master fd into the spawned child.
        fcntl(master, F_SETFD, FD_CLOEXEC);

        // Size the pty before the child starts so it never sees a 0x0 / stale window.
        var initWs = new WinSize { ws_row = rows, ws_col = cols };
        if (IsMacArm64)
            ioctl_darwin_arm64(master, TIOCSWINSZ, 0, 0, 0, 0, 0, 0, ref initWs);
        else
            ioctl(master, TIOCSWINSZ, ref initWs);

        var slavePathPtr = ptsname(master);
        if (slavePathPtr == IntPtr.Zero)
        {
            close(master);
            throw new InvalidOperationException("ptsname failed");
        }
        var slavePath = Marshal.PtrToStringAnsi(slavePathPtr)!;

        // On macOS, run the real program *through* the spawn-helper so it claims the
        // pty as its controlling terminal (see MacSpawnHelper). argv becomes
        // [spawn-helper, executable, args...]; elsewhere it's [executable, args...].
        var command = new List<string>(args.Length + 2);
        if (MacSpawnHelper is { } helper)
            command.Add(helper);
        command.Add(executable);
        command.AddRange(args);

        // Marshal argv: [command..., NULL].
        var argvList = new IntPtr[command.Count + 1];
        for (var i = 0; i < command.Count; i++)
            argvList[i] = Marshal.StringToHGlobalAnsi(command[i]);
        argvList[^1] = IntPtr.Zero;
        var argvBlock = Marshal.AllocHGlobal(IntPtr.Size * argvList.Length);
        Marshal.Copy(argvList, 0, argvBlock, argvList.Length);

        // Marshal envp: the full current environment merged with extraEnv overrides.
        var envList = BuildEnvBlock(extraEnv, out var envStrings);
        var envBlock = Marshal.AllocHGlobal(IntPtr.Size * envList.Length);
        Marshal.Copy(envList, 0, envBlock, envList.Length);

        var slaveCstr = Marshal.StringToHGlobalAnsi(slavePath);
        var cwdCstr = string.IsNullOrEmpty(workingDirectory)
            ? IntPtr.Zero : Marshal.StringToHGlobalAnsi(workingDirectory);

        // posix_spawn opaque structs. One zeroed 1KB buffer each is large enough on
        // both macOS (a single pointer) and Linux/glibc (an in-place struct).
        var fa = Marshal.AllocHGlobal(1024);
        var attr = Marshal.AllocHGlobal(1024);
        try
        {
            for (var i = 0; i < 1024; i++) { Marshal.WriteByte(fa, i, 0); Marshal.WriteByte(attr, i, 0); }

            posix_spawn_file_actions_init(fa);
            posix_spawnattr_init(attr);
            posix_spawnattr_setflags(attr, POSIX_SPAWN_SETSID);

            if (cwdCstr != IntPtr.Zero)
            {
                try { posix_spawn_file_actions_addchdir_np(fa, cwdCstr); }
                catch (EntryPointNotFoundException) { /* old libc: cwd not applied */ }
            }

            // Put the pty slave on the child's stdin/stdout/stderr. On Linux the
            // child (now a session leader via SETSID) acquires it as the controlling
            // terminal on this open; on macOS that doesn't happen here, so the
            // spawn-helper claims it with TIOCSCTTY before exec (see MacSpawnHelper).
            posix_spawn_file_actions_addopen(fa, 0, slaveCstr, O_RDWR, 0);
            posix_spawn_file_actions_adddup2(fa, 0, 1);
            posix_spawn_file_actions_adddup2(fa, 0, 2);

            var rc = posix_spawnp(out var pid, argvList[0], fa, attr, argvBlock, envBlock);
            if (rc != 0)
            {
                close(master);
                throw new InvalidOperationException($"posix_spawn failed: {rc}");
            }
            _pid = pid;
            _masterFd = master;
        }
        finally
        {
            posix_spawn_file_actions_destroy(fa);
            posix_spawnattr_destroy(attr);
            Marshal.FreeHGlobal(fa);
            Marshal.FreeHGlobal(attr);
            foreach (var p in argvList) if (p != IntPtr.Zero) Marshal.FreeHGlobal(p);
            Marshal.FreeHGlobal(argvBlock);
            foreach (var p in envStrings) Marshal.FreeHGlobal(p);
            Marshal.FreeHGlobal(envBlock);
            Marshal.FreeHGlobal(slaveCstr);
            if (cwdCstr != IntPtr.Zero) Marshal.FreeHGlobal(cwdCstr);
        }

        DiagSize("Start", cols, rows);
    }

    /// <summary>Build a NUL-terminated <c>char**</c> environment block: the current
    /// process environment merged with <paramref name="extraEnv"/> overrides. The
    /// non-null string pointers are returned via <paramref name="allocated"/> so the
    /// caller can free them after the spawn.</summary>
    private static IntPtr[] BuildEnvBlock((string Name, string Value)[]? extraEnv, out IntPtr[] allocated)
    {
        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (System.Collections.DictionaryEntry e in Environment.GetEnvironmentVariables())
            map[(string)e.Key] = e.Value?.ToString() ?? string.Empty;
        if (extraEnv != null)
            foreach (var (name, value) in extraEnv)
                map[name] = value;

        var ptrs = new IntPtr[map.Count + 1];
        var i = 0;
        foreach (var kv in map)
            ptrs[i++] = Marshal.StringToHGlobalAnsi($"{kv.Key}={kv.Value}");
        ptrs[^1] = IntPtr.Zero;
        allocated = ptrs.Where(p => p != IntPtr.Zero).ToArray();
        return ptrs;
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
        // Set the size, then read it back and retry if the kernel didn't store what
        // we asked for. An unnoticed failed set leaves the tty at its old (often
        // larger) size while the emulator has already shrunk — zsh then emits a
        // PROMPT_SP space run wider than the visible grid and blanks the screen.
        for (var attempt = 0; attempt < 3; attempt++)
        {
            var ws = new WinSize { ws_row = rows, ws_col = cols };
            if (IsMacArm64)
                ioctl_darwin_arm64(_masterFd, TIOCSWINSZ, 0, 0, 0, 0, 0, 0, ref ws);
            else
                ioctl(_masterFd, TIOCSWINSZ, ref ws);
            var (gotCols, gotRows) = ReadTtySize();
            if (gotCols == cols && gotRows == rows) break;
        }
        DiagSize("Resize", cols, rows);
    }

    /// <summary>Read the tty's current window size straight from the kernel.
    /// Returns (0,0) when unavailable. Used only by the size diagnostic.</summary>
    private (ushort cols, ushort rows) ReadTtySize()
    {
        if (_masterFd < 0) return (0, 0);
        var ws = new WinSize();
        int r = IsMacArm64
            ? ioctl_darwin_arm64(_masterFd, TIOCGWINSZ, 0, 0, 0, 0, 0, 0, ref ws)
            : ioctl(_masterFd, TIOCGWINSZ, ref ws);
        return r == 0 ? (ws.ws_col, ws.ws_row) : ((ushort)0, (ushort)0);
    }

    /// <summary>Best-effort ground-truth log: what we asked the tty to be vs what
    /// the kernel actually stored. A divergence here is the smoking gun for the
    /// intermittent blank/"failed to get size" bug. Writes to a fixed /tmp path so
    /// it can be read regardless of dev-run vs packaged app.</summary>
    private void DiagSize(string where, ushort wantCols, ushort wantRows)
    {
        try
        {
            var (gotCols, gotRows) = ReadTtySize();
            var flag = (gotCols == wantCols && gotRows == wantRows) ? "ok" : "MISMATCH";
            var line = $"{DateTime.Now:HH:mm:ss.fff} pid={_pid} fd={_masterFd} {where} " +
                       $"want={wantCols}x{wantRows} got={gotCols}x{gotRows} {flag}\n";
            System.IO.File.AppendAllText("/tmp/rscp-ptysize.log", line);
        }
        catch { /* diagnostic only */ }
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
