using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace RemoteStuff.Services.Terminal;

/// <summary>
/// A pseudo-terminal backed child process on Windows, created with the Win32
/// pseudo-console (ConPTY) API introduced in Windows 10 1809. ConPTY gives the
/// child a real console with VT input/output, so interactive prompts — SSH
/// password entry, host-key confirmation, 2FA, curses apps — behave the same as
/// they do under a Unix PTY. Output is UTF-8 VT that the terminal emulator already
/// understands; input we forward is written straight to the pseudo-console's
/// input pipe.
/// </summary>
public sealed class WindowsPtyProcess : IPtyProcess
{
    private IntPtr _hpc = IntPtr.Zero;          // HPCON pseudo-console handle
    private IntPtr _inputWrite = IntPtr.Zero;   // we write child stdin here
    private IntPtr _outputRead = IntPtr.Zero;   // we read child stdout here
    private IntPtr _inputRead = IntPtr.Zero;    // owned by the pseudo-console
    private IntPtr _outputWrite = IntPtr.Zero;  // owned by the pseudo-console
    private IntPtr _procHandle = IntPtr.Zero;
    private IntPtr _threadHandle = IntPtr.Zero;
    private IntPtr _attrList = IntPtr.Zero;
    private bool _disposed;

    public bool HasExited { get; private set; }

    // ---- Win32 constants ----
    private const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    private const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    private static readonly IntPtr PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = (IntPtr)0x00020016;
    private const uint STILL_ACTIVE = 259;
    private const uint HANDLE_FLAG_INHERIT = 0x00000001;
    private const uint INFINITE = 0xFFFFFFFF;

    [StructLayout(LayoutKind.Sequential)]
    private struct COORD
    {
        public short X;
        public short Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SECURITY_ATTRIBUTES
    {
        public int nLength;
        public IntPtr lpSecurityDescriptor;
        public int bInheritHandle;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct STARTUPINFO
    {
        public int cb;
        public IntPtr lpReserved;
        public IntPtr lpDesktop;
        public IntPtr lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct STARTUPINFOEX
    {
        public STARTUPINFO StartupInfo;
        public IntPtr lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    // ---- P/Invokes ----
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CreatePipe(out IntPtr hReadPipe, out IntPtr hWritePipe,
        ref SECURITY_ATTRIBUTES lpPipeAttributes, int nSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetHandleInformation(IntPtr hObject, uint dwMask, uint dwFlags);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern int CreatePseudoConsole(COORD size, IntPtr hInput, IntPtr hOutput,
        uint dwFlags, out IntPtr phPC);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern int ResizePseudoConsole(IntPtr hPC, COORD size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern void ClosePseudoConsole(IntPtr hPC);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList,
        int dwAttributeCount, int dwFlags, ref IntPtr lpSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UpdateProcThreadAttribute(IntPtr lpAttributeList, uint dwFlags,
        IntPtr attribute, IntPtr lpValue, IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern void DeleteProcThreadAttributeList(IntPtr lpAttributeList);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcess(string? lpApplicationName, string lpCommandLine,
        IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles,
        uint dwCreationFlags, IntPtr lpEnvironment, string? lpCurrentDirectory,
        ref STARTUPINFOEX lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadFile(IntPtr hFile, byte[] lpBuffer, int nNumberOfBytesToRead,
        out int lpNumberOfBytesRead, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool WriteFile(IntPtr hFile, byte[] lpBuffer, int nNumberOfBytesToWrite,
        out int lpNumberOfBytesWritten, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

    /// <summary>
    /// Create the pseudo-console, wire up the pipes, and launch the child.
    /// </summary>
    public void Start(string executable, string[] args, ushort cols, ushort rows,
        (string Name, string Value)[]? extraEnv = null, string? workingDirectory = null)
    {
        var sa = new SECURITY_ATTRIBUTES
        {
            nLength = Marshal.SizeOf<SECURITY_ATTRIBUTES>(),
            bInheritHandle = 0,
            lpSecurityDescriptor = IntPtr.Zero,
        };

        if (!CreatePipe(out _inputRead, out _inputWrite, ref sa, 0))
            throw new InvalidOperationException("CreatePipe (input) failed: " + Marshal.GetLastWin32Error());
        if (!CreatePipe(out _outputRead, out _outputWrite, ref sa, 0))
            throw new InvalidOperationException("CreatePipe (output) failed: " + Marshal.GetLastWin32Error());

        // Our own ends must not be inherited by the child.
        SetHandleInformation(_inputWrite, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(_outputRead, HANDLE_FLAG_INHERIT, 0);

        var size = new COORD { X = (short)Math.Max((ushort)1, cols), Y = (short)Math.Max((ushort)1, rows) };
        var hr = CreatePseudoConsole(size, _inputRead, _outputWrite, 0, out _hpc);
        if (hr != 0)
            throw new InvalidOperationException($"CreatePseudoConsole failed: 0x{hr:X8}");

        // The pseudo-console has duplicated the pipe ends it needs; close ours.
        if (_inputRead != IntPtr.Zero) { CloseHandle(_inputRead); _inputRead = IntPtr.Zero; }
        if (_outputWrite != IntPtr.Zero) { CloseHandle(_outputWrite); _outputWrite = IntPtr.Zero; }

        // Build STARTUPINFOEX with the pseudo-console attribute.
        var si = new STARTUPINFOEX();
        si.StartupInfo.cb = Marshal.SizeOf<STARTUPINFOEX>();

        var lpSize = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref lpSize);
        _attrList = Marshal.AllocHGlobal(lpSize);
        if (!InitializeProcThreadAttributeList(_attrList, 1, 0, ref lpSize))
            throw new InvalidOperationException("InitializeProcThreadAttributeList failed: " + Marshal.GetLastWin32Error());
        if (!UpdateProcThreadAttribute(_attrList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                _hpc, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
            throw new InvalidOperationException("UpdateProcThreadAttribute failed: " + Marshal.GetLastWin32Error());
        si.lpAttributeList = _attrList;

        var commandLine = BuildCommandLine(executable, args);
        var envBlock = BuildEnvironmentBlock(extraEnv);
        var cwd = string.IsNullOrEmpty(workingDirectory) ? null : workingDirectory;

        var envPtr = IntPtr.Zero;
        try
        {
            if (envBlock != null)
                envPtr = Marshal.StringToHGlobalUni(envBlock);

            var ok = CreateProcess(
                null,
                commandLine,
                IntPtr.Zero,
                IntPtr.Zero,
                false,
                EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
                envPtr,
                cwd,
                ref si,
                out var pi);
            if (!ok)
                throw new InvalidOperationException("CreateProcess failed: " + Marshal.GetLastWin32Error());

            _procHandle = pi.hProcess;
            _threadHandle = pi.hThread;
        }
        finally
        {
            if (envPtr != IntPtr.Zero) Marshal.FreeHGlobal(envPtr);
        }
    }

    /// <summary>Read available bytes from the child's stdout pipe.</summary>
    public int Read(byte[] buffer)
    {
        if (_outputRead == IntPtr.Zero) return 0;
        if (!ReadFile(_outputRead, buffer, buffer.Length, out var read, IntPtr.Zero))
            return 0; // broken pipe -> EOF
        return read;
    }

    /// <summary>Write bytes to the child's stdin pipe.</summary>
    public void Write(byte[] data)
    {
        if (_inputWrite == IntPtr.Zero || data.Length == 0) return;
        WriteFile(_inputWrite, data, data.Length, out _, IntPtr.Zero);
    }

    /// <summary>Resize the pseudo-console window (cols × rows).</summary>
    public void Resize(ushort cols, ushort rows)
    {
        if (_hpc == IntPtr.Zero) return;
        var size = new COORD { X = (short)Math.Max((ushort)1, cols), Y = (short)Math.Max((ushort)1, rows) };
        ResizePseudoConsole(_hpc, size);
    }

    /// <summary>Non-blocking check for child exit; returns the exit code when done.</summary>
    public int? TryReap()
    {
        if (_procHandle == IntPtr.Zero || HasExited) return HasExited ? 0 : null;
        if (!GetExitCodeProcess(_procHandle, out var code)) return null;
        if (code == STILL_ACTIVE) return null;
        HasExited = true;
        return (int)code;
    }

    public void Terminate()
    {
        if (_procHandle != IntPtr.Zero && !HasExited)
            TerminateProcess(_procHandle, 0);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        if (_procHandle != IntPtr.Zero && !HasExited)
        {
            TerminateProcess(_procHandle, 0);
            // Give the child a brief moment so ConPTY can flush before we close it.
            WaitForSingleObject(_procHandle, 200);
        }

        if (_hpc != IntPtr.Zero) { ClosePseudoConsole(_hpc); _hpc = IntPtr.Zero; }
        if (_attrList != IntPtr.Zero)
        {
            DeleteProcThreadAttributeList(_attrList);
            Marshal.FreeHGlobal(_attrList);
            _attrList = IntPtr.Zero;
        }
        if (_inputWrite != IntPtr.Zero) { CloseHandle(_inputWrite); _inputWrite = IntPtr.Zero; }
        if (_outputRead != IntPtr.Zero) { CloseHandle(_outputRead); _outputRead = IntPtr.Zero; }
        if (_inputRead != IntPtr.Zero) { CloseHandle(_inputRead); _inputRead = IntPtr.Zero; }
        if (_outputWrite != IntPtr.Zero) { CloseHandle(_outputWrite); _outputWrite = IntPtr.Zero; }
        if (_threadHandle != IntPtr.Zero) { CloseHandle(_threadHandle); _threadHandle = IntPtr.Zero; }
        if (_procHandle != IntPtr.Zero) { CloseHandle(_procHandle); _procHandle = IntPtr.Zero; }
    }

    /// <summary>Quote an executable + args into a single Win32 command line using
    /// the standard CommandLineToArgvW rules.</summary>
    private static string BuildCommandLine(string executable, string[] args)
    {
        var sb = new StringBuilder();
        AppendArg(sb, executable);
        foreach (var a in args)
        {
            sb.Append(' ');
            AppendArg(sb, a);
        }
        return sb.ToString();
    }

    private static void AppendArg(StringBuilder sb, string arg)
    {
        // Quote if empty or containing whitespace/quotes; escape per CommandLineToArgvW.
        if (arg.Length > 0 && arg.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0)
        {
            sb.Append(arg);
            return;
        }
        sb.Append('"');
        for (var i = 0; i < arg.Length; i++)
        {
            var backslashes = 0;
            while (i < arg.Length && arg[i] == '\\') { backslashes++; i++; }
            if (i == arg.Length)
            {
                sb.Append('\\', backslashes * 2);
                break;
            }
            if (arg[i] == '"')
            {
                sb.Append('\\', backslashes * 2 + 1);
                sb.Append('"');
            }
            else
            {
                sb.Append('\\', backslashes);
                sb.Append(arg[i]);
            }
        }
        sb.Append('"');
    }

    /// <summary>Build a Unicode environment block (current process env + extras),
    /// terminated by a double null. Returns null to inherit the parent environment
    /// unchanged when there are no extras.</summary>
    private static string? BuildEnvironmentBlock((string Name, string Value)[]? extraEnv)
    {
        if (extraEnv == null || extraEnv.Length == 0) return null;

        var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (System.Collections.DictionaryEntry e in Environment.GetEnvironmentVariables())
            map[(string)e.Key] = (string?)e.Value ?? string.Empty;
        foreach (var (name, value) in extraEnv)
            map[name] = value;

        var sb = new StringBuilder();
        foreach (var kv in map)
        {
            if (string.IsNullOrEmpty(kv.Key)) continue;
            sb.Append(kv.Key).Append('=').Append(kv.Value).Append('\0');
        }
        sb.Append('\0');
        return sb.ToString();
    }
}
