using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RemoteStuff.Models;
using RemoteStuff.Views.Controls;

namespace RemoteStuff.ViewModels;

/// <summary>
/// A live terminal session tab. Owns its <see cref="TerminalControl"/> (the PTY host)
/// and exposes snippets, typed-command history, theme, font zoom and reconnect.
/// </summary>
public sealed partial class TerminalTabViewModel : TabViewModel
{
    public TerminalControl Terminal { get; }
    public override string Glyph => "square-terminal";

    /// <summary>ControlMaster socket path for a profile-backed ssh tunnel, enabling
    /// live add/remove of port forwards via <c>ssh -O forward</c>. Null otherwise.</summary>
    public string? ControlSocketPath { get; set; }

    /// <summary>The profile (saved or ad-hoc) this terminal connects with. Backs the
    /// tab's "Edit Connection Settings…" and "Copy IP Address" right-click actions.</summary>
    public SshProfile? Profile { get; set; }

    /// <summary>A per-tab command auto-run on connect, kept independent of the
    /// backing profile so several tabs on the same server can each fire a different
    /// command. Editable from the tab's connection-settings sheet and persisted in
    /// the workspace snapshot.</summary>
    public string? RunOnConnect { get; set; }

    public override bool SupportsConnection => Profile is { IsLocal: false };
    public override string? Host => Profile?.Host;

    public override (string Host, int Port)? ConnectionEndpoint =>
        Profile is { IsLocal: false, Host: { Length: > 0 } h }
            ? (h, int.TryParse(Profile.Port, out var pt) && pt > 0 ? pt : 22)
            : null;

    public override RemoteStuff.Services.TabSnapshot? CreateSnapshot()
    {
        // Only connection terminals recreate; one-off tabs (key setup) carry no Profile.
        if (Profile is not { } p) return null;
        return new RemoteStuff.Services.TabSnapshot
        {
            Kind = p.IsLocal ? "local" : "ssh",
            ProfileId = p.Id,
            Title = Title,
            Host = p.Host,
            Port = int.TryParse(p.Port, out var pt) ? pt : 22,
            Username = p.Username,
            RunOnConnect = RunOnConnect,
            ThemeId = _currentTheme.Id,
            FontSize = Terminal.FontSize
        };
    }

    public override System.Collections.Generic.IReadOnlyList<ThemeMenuItem> ThemeMenuItems
        => System.Linq.Enumerable.ToList(
               System.Linq.Enumerable.Select(
                   TerminalTheme.All, t => new ThemeMenuItem(t, ApplyTerminalTheme)));
    public override bool SupportsTheme => true;

    /// <summary>The colour theme currently applied to this terminal. Tracked (not just
    /// held on the control) so it survives a workspace save/restore round-trip.</summary>
    private TerminalTheme _currentTheme = TerminalTheme.Default;

    private void ApplyTerminalTheme(TerminalTheme theme)
    {
        _currentTheme = theme;
        Terminal.ColorTheme = theme;
    }

    protected override void OnThemeSelected(TerminalTheme theme) => ApplyTerminalTheme(theme);
    public ObservableCollection<CommandSnippet> Snippets { get; } = new();
    public ObservableCollection<string> History { get; } = new();

    /// <summary>The connection's own name (profile / ad-hoc name). Used as the tab
    /// title when there is no run-on-connect command to name the tab after.</summary>
    private readonly string _baseTitle;

    /// <summary>The base program name of the run-on-connect command (e.g. "tmux"),
    /// or null when the tab has no such command. When set it takes precedence over
    /// <see cref="_baseTitle"/> so the tab reflects the command it is running.</summary>
    private string? _runCommandTitle;

    /// <summary>The tab's resting title: the run-on-connect command's program name
    /// when present, otherwise the connection name.</summary>
    private string EffectiveBaseTitle => _runCommandTitle ?? _baseTitle;

    /// <summary>Extract the base program name from a shell command line: split on
    /// whitespace, skip <c>NAME=value</c> env assignments and the sudo/env/command/exec
    /// wrappers and any leading switches, then return the last path component of the
    /// first real token (e.g. "tmux attach || tmux new" → "tmux",
    /// "/usr/bin/htop -d 5" → "htop"). Returns null when nothing usable is found.</summary>
    internal static string? BaseCommandName(string? command)
    {
        if (string.IsNullOrWhiteSpace(command)) return null;
        var tokens = command.Trim().Split(new[] { ' ', '\t' },
            System.StringSplitOptions.RemoveEmptyEntries);
        foreach (var token in tokens)
        {
            // Skip env assignments (FOO=bar) and shell wrappers.
            if (token.Contains('=') && !token.StartsWith('/')) continue;
            if (token is "sudo" or "env" or "command" or "exec") continue;
            if (token.StartsWith('-')) continue;   // shouldn't lead, but be safe
            var baseName = System.IO.Path.GetFileName(token).Trim();
            if (baseName.Length > 0) return baseName;
        }
        return null;
    }

    public override bool HasSnippets => Snippets.Count > 0;
    public override bool HasHistory => History.Count > 0;

    /// <summary>Replace the tab's live snippets (e.g. after editing them in the
    /// ad-hoc connection sheet) and refresh the header \u274f button visibility.</summary>
    public void ReplaceSnippets(System.Collections.Generic.IEnumerable<CommandSnippet> snippets)
    {
        Snippets.Clear();
        foreach (var s in snippets) Snippets.Add(s);
        OnPropertyChanged(nameof(HasSnippets));
    }

    public TerminalTabViewModel(string title, string executable, string[] args,
        (string, string)[]? env, string? workingDirectory, string? runOnConnect,
        double fontSize, TerminalTheme theme,
        System.Collections.Generic.IEnumerable<CommandSnippet>? snippets,
        string? autoPassword = null)
    {
        _baseTitle = title;
        _runCommandTitle = BaseCommandName(runOnConnect);
        Title = EffectiveBaseTitle;
        RunOnConnect = string.IsNullOrWhiteSpace(runOnConnect) ? null : runOnConnect;
        _currentTheme = theme;
        Terminal = new TerminalControl { FontSize = fontSize, ColorTheme = theme };
        Terminal.SetAutoPassword(autoPassword);

        if (snippets != null)
            foreach (var s in snippets) Snippets.Add(s);

        Terminal.Exited += _ => Avalonia.Threading.Dispatcher.UIThread.Post(() =>
        {
            IsRunning = false;
            Health = ConnectionHealth.Unknown;
            Title = EffectiveBaseTitle + (IsPaused ? " — suspended" : " — disconnected");
            if (Profile?.AutoReconnect == true && !IsPaused && !_userStopped)
            {
                // A connection that stayed up a while counts as a success: restart the
                // backoff sequence from the bottom (matches the Swift app's reset-on-connect).
                if ((System.DateTime.UtcNow - _lastConnectAt).TotalSeconds > 20)
                    _reconnectAttempts = 0;
                ScheduleAutoReconnect();
            }
        });

        Terminal.LineEntered += line => Avalonia.Threading.Dispatcher.UIThread.Post(() =>
        {
            History.Remove(line);          // de-dupe, most-recent-first
            History.Insert(0, line);
            while (History.Count > 200) History.RemoveAt(History.Count - 1);
            OnPropertyChanged(nameof(HasHistory));
        });

        Terminal.HostKeyChanged += () =>
            Avalonia.Threading.Dispatcher.UIThread.Post(() => HostKeyChangedDetected = true);

        Terminal.BadKeyPermissions += () =>
            Avalonia.Threading.Dispatcher.UIThread.Post(() => BadKeyPermissionsDetected = true);

        Terminal.StartDeferred(executable, args, env, workingDirectory, runOnConnect);
        if (SupportsConnection) StartHealthProbe();
    }

    [RelayCommand]
    private void InsertSnippet(CommandSnippet? snippet)
    {
        if (snippet == null) return;
        Terminal.SendText(snippet.Command);
        Terminal.Focus();
    }

    [RelayCommand]
    private void RunHistory(string? command)
    {
        if (string.IsNullOrEmpty(command)) return;
        Terminal.SendText(command + "\n");
        Terminal.Focus();
    }

    /// <summary>Raised when the tab's snippets change (e.g. a history line is saved as a
    /// snippet) so the owner can persist the backing profile to disk.</summary>
    public System.Action? SnippetsPersistRequested;

    /// <summary>Save a history command as a reusable snippet: add it to this tab's live
    /// snippet list (and its backing profile, when any) so it shows in the ❏ menu.</summary>
    [RelayCommand]
    private void AddHistoryToSnippets(string? command)
    {
        var cmd = command?.Trim();
        if (string.IsNullOrEmpty(cmd)) return;
        if (System.Linq.Enumerable.Any(Snippets,
                s => string.Equals(s.Command, cmd, System.StringComparison.Ordinal)))
            return;
        var label = cmd.Length > 40 ? cmd[..40].TrimEnd() + "…" : cmd;
        Snippets.Add(new CommandSnippet { Label = label, Command = cmd });
        Profile?.Snippets.Add(new CommandSnippet { Label = label, Command = cmd });
        OnPropertyChanged(nameof(HasSnippets));
        SnippetsPersistRequested?.Invoke();
    }

    // Self-contained scrollback actions so they also work from the docked ⋮ menu
    // (a MenuFlyout popup can't reach the MainWindowViewModel).
    [RelayCommand]
    private void CopyScrollback() => Terminal.CopyScrollback();

    [RelayCommand]
    private void ClearScrollback() => Terminal.Clear();

    [RelayCommand]
    private async System.Threading.Tasks.Task SaveScrollback()
        => await Terminal.SaveScrollbackAsync($"{_baseTitle.Replace('/', '-')}.log");

    // ---- Session logging (write a transcript of output to a .log file) ----

    /// <summary>True while this tab is recording its output to a transcript file.</summary>
    [ObservableProperty] private bool _isLoggingSession;

    /// <summary>Path of this tab's current (or most recent) transcript, or null.</summary>
    [ObservableProperty] private string? _sessionLogPath;

    /// <summary>True once a transcript exists for this tab (so "Open Log" can show).</summary>
    public override bool HasSessionLog => !string.IsNullOrEmpty(SessionLogPath);
    public override bool ShowStartLog => !IsLoggingSession;
    public override bool ShowStopLog => IsLoggingSession;

    partial void OnSessionLogPathChanged(string? value) => OnPropertyChanged(nameof(HasSessionLog));

    partial void OnIsLoggingSessionChanged(bool value)
    {
        OnPropertyChanged(nameof(ShowStartLog));
        OnPropertyChanged(nameof(ShowStopLog));
    }

    /// <summary>Start recording this session's output to <paramref name="path"/>.</summary>
    public void BeginSessionLog(string path, string? header = null)
    {
        Terminal.StartLogging(path, header);
        IsLoggingSession = Terminal.IsLogging;
        SessionLogPath = Terminal.LogPath;
    }

    /// <summary>Stop recording; the transcript stays on disk and openable.</summary>
    public void EndSessionLog()
    {
        Terminal.StopLogging();
        IsLoggingSession = false;
    }

    /// <summary>Start recording this tab's output from the tab menu.</summary>
    [RelayCommand]
    private void StartLog()
    {
        if (IsLoggingSession) return;
        var title = string.IsNullOrWhiteSpace(Title) ? _baseTitle : Title;
        var preview = Profile is { IsLocal: false } p
            ? RemoteStuff.Services.SshCommandBuilder.CommandPreview(p)
            : null;
        BeginSessionLog(RemoteStuff.Services.SessionLogs.NewLogPath(title),
                        RemoteStuff.Services.SessionLogs.Header(title, preview));
    }

    /// <summary>Stop recording this tab's output from the tab menu, then open the
    /// finished transcript in the OS default viewer.</summary>
    [RelayCommand]
    private void StopLog()
    {
        EndSessionLog();
        OpenLog();
    }

    /// <summary>Open this tab's transcript in the OS default text viewer.</summary>
    [RelayCommand]
    private void OpenLog()
    {
        if (!string.IsNullOrEmpty(SessionLogPath))
            RemoteStuff.Services.SystemOpen.Open(SessionLogPath!);
    }

    /// <summary>Reveal this tab's transcript in Finder / Explorer / file manager.</summary>
    [RelayCommand]
    private void RevealLog()
    {
        if (!string.IsNullOrEmpty(SessionLogPath))
            RemoteStuff.Services.SystemOpen.Reveal(SessionLogPath!);
    }

    /// <summary>True when the user deliberately stopped this session (Disconnect), so a
    /// dropped-connection event must NOT trigger auto-reconnect. Cleared on manual Reconnect.
    /// Mirrors the Swift app's <c>userInitiatedStop</c> flag.</summary>
    private bool _userStopped;

    /// <summary>Consecutive failed/dropped connection count, driving the reconnect backoff.
    /// Reset to 0 on a manual reconnect or after a connection stays up long enough to count
    /// as a success.</summary>
    private int _reconnectAttempts;

    /// <summary>Cancels a pending auto-reconnect (e.g. when the user reconnects/disconnects
    /// manually before the timer fires), preventing a double launch.</summary>
    private System.Threading.CancellationTokenSource? _reconnectCts;

    /// <summary>When the current connection was (re)launched, used to decide whether a drop
    /// followed a real session (reset backoff) or a fast connect failure (grow backoff).</summary>
    private System.DateTime _lastConnectAt = System.DateTime.UtcNow;

    [RelayCommand]
    private void Disconnect()
    {
        _userStopped = true;
        _reconnectCts?.Cancel();
        IsPaused = false;
        Terminal.Terminate();
        IsRunning = false;
        Health = ConnectionHealth.Unknown;
        Title = EffectiveBaseTitle + " — disconnected";
    }

    [RelayCommand]
    private void Reconnect()
    {
        _userStopped = false;
        _reconnectAttempts = 0;
        _reconnectCts?.Cancel();
        IsPaused = false;
        _lastConnectAt = System.DateTime.UtcNow;
        Terminal.Restart();
        IsRunning = true;
        Title = EffectiveBaseTitle;
    }

    private async void ScheduleAutoReconnect()
    {
        _reconnectCts?.Cancel();
        var cts = _reconnectCts = new System.Threading.CancellationTokenSource();
        // Exponential backoff 2,4,8,16,32 → capped at 30s (matches the Swift app).
        var attempt = System.Math.Min(++_reconnectAttempts, 5);
        var delay = System.TimeSpan.FromSeconds(System.Math.Min(30.0, System.Math.Pow(2, attempt)));
        try { await System.Threading.Tasks.Task.Delay(delay, cts.Token); }
        catch (System.OperationCanceledException) { return; }
        await Avalonia.Threading.Dispatcher.UIThread.InvokeAsync(() =>
        {
            if (cts.IsCancellationRequested) return;
            if (!IsRunning && !IsPaused && !_userStopped)
            {
                _lastConnectAt = System.DateTime.UtcNow;
                Terminal.Restart();
                IsRunning = true;
                Title = EffectiveBaseTitle;
            }
        });
    }

    // ---- Live connection health (TCP reachability probe, mirrors Swift tunnelHealth) ----

    /// <summary>Live reachability of this session's endpoint: Unknown until first probed,
    /// Healthy when the host/port accepts a TCP connection, Degraded when it refuses or
    /// times out. Mirrors the Swift app's per-session <c>tunnelHealth</c>.</summary>
    [ObservableProperty] private ConnectionHealth _health = ConnectionHealth.Unknown;

    private System.Timers.Timer? _healthTimer;
    private int _healthProbing;   // 0/1 guard so a slow probe never overlaps the next tick

    /// <summary>Whether to show the health dot: a remote tab that has a network endpoint.</summary>
    public bool ShowHealth => SupportsConnection && ConnectionEndpoint is not null;

    partial void OnHealthChanged(ConnectionHealth value)
    {
        OnPropertyChanged(nameof(HealthBrush));
        OnPropertyChanged(nameof(HealthTooltip));
    }

    /// <summary>Dot colour for the tab header: green healthy, amber degraded, grey unknown.</summary>
    public Avalonia.Media.IBrush HealthBrush => Health switch
    {
        ConnectionHealth.Healthy => new Avalonia.Media.SolidColorBrush(Avalonia.Media.Color.Parse("#3FB950")),
        ConnectionHealth.Degraded => new Avalonia.Media.SolidColorBrush(Avalonia.Media.Color.Parse("#D29922")),
        _ => new Avalonia.Media.SolidColorBrush(Avalonia.Media.Color.Parse("#6E7681")),
    };

    public string HealthTooltip => Health switch
    {
        ConnectionHealth.Healthy => "Connected — endpoint reachable",
        ConnectionHealth.Degraded => "Degraded — endpoint not responding",
        _ => "Connection status unknown",
    };

    private void StartHealthProbe()
    {
        _healthTimer = new System.Timers.Timer(5000) { AutoReset = true };
        _healthTimer.Elapsed += (_, _) => _ = ProbeHealthAsync();
        _healthTimer.Start();
    }

    private async System.Threading.Tasks.Task ProbeHealthAsync()
    {
        if (System.Threading.Interlocked.Exchange(ref _healthProbing, 1) == 1) return;
        try
        {
            if (!IsRunning || IsPaused || ConnectionEndpoint is not { } ep)
            {
                await Avalonia.Threading.Dispatcher.UIThread.InvokeAsync(
                    () => Health = ConnectionHealth.Unknown);
                return;
            }
            var ok = await ProbeTcpAsync(ep.Host, ep.Port);
            await Avalonia.Threading.Dispatcher.UIThread.InvokeAsync(() =>
            {
                if (IsRunning && !IsPaused)
                    Health = ok ? ConnectionHealth.Healthy : ConnectionHealth.Degraded;
            });
        }
        finally { System.Threading.Interlocked.Exchange(ref _healthProbing, 0); }
    }

    private static async System.Threading.Tasks.Task<bool> ProbeTcpAsync(string host, int port)
    {
        try
        {
            using var client = new System.Net.Sockets.TcpClient();
            var connect = client.ConnectAsync(host, port);
            var done = await System.Threading.Tasks.Task.WhenAny(
                connect, System.Threading.Tasks.Task.Delay(2500));
            return done == connect && !connect.IsFaulted && client.Connected;
        }
        catch { return false; }
    }

    // ---- Workspace pause / resume ----

    /// <summary>True while this session is paused as part of a workspace pause. Distinct
    /// from a plain disconnect so the workspace can offer a matching Resume action and
    /// the tab can show a paused indicator.</summary>
    [ObservableProperty] private bool _isPaused;

    public override bool IsSuspended => IsPaused;
    partial void OnIsPausedChanged(bool value) => OnPropertyChanged(nameof(IsSuspended));

    /// <summary>Pause a live session: drop the connection but remember it should come
    /// back when the workspace is resumed. No-op if not currently running.</summary>
    public void PauseSession()
    {
        if (!IsRunning) return;
        _reconnectCts?.Cancel();
        IsPaused = true;
        Terminal.Terminate();
        IsRunning = false;
        Health = ConnectionHealth.Unknown;
        Title = EffectiveBaseTitle + " — suspended";
    }

    /// <summary>Resume a paused session by reconnecting it.</summary>
    public void ResumeSession()
    {
        if (!IsPaused) return;
        IsPaused = false;
        _lastConnectAt = System.DateTime.UtcNow;
        Terminal.Restart();
        IsRunning = true;
        Title = EffectiveBaseTitle;
    }

    // ---- Host-key-changed banner ----

    /// <summary>True when ssh reported the remote host key changed for this session.</summary>
    [ObservableProperty] private bool _hostKeyChangedDetected;

    /// <summary>True when ssh refused the key file due to unsafe permissions.</summary>
    [ObservableProperty] private bool _badKeyPermissionsDetected;

    /// <summary>Remove the stale entry from <c>known_hosts</c> (via <c>ssh-keygen -R</c>)
    /// and reconnect. Mirrors the macOS "Remove Key &amp; Reconnect" action.</summary>
    [RelayCommand]
    private async System.Threading.Tasks.Task RemoveKeyAndReconnect()
    {
        var host = Profile?.Host;
        if (!string.IsNullOrWhiteSpace(host))
        {
            await RunSshKeygenRemove(host!);
            if (Profile is { Port: { Length: > 0 } port } && port != "22")
                await RunSshKeygenRemove($"[{host}]:{port}");
        }
        HostKeyChangedDetected = false;
        Reconnect();
    }

    private static async System.Threading.Tasks.Task RunSshKeygenRemove(string host)
    {
        try
        {
            var psi = new System.Diagnostics.ProcessStartInfo("ssh-keygen")
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            };
            psi.ArgumentList.Add("-R");
            psi.ArgumentList.Add(host);
            using var p = System.Diagnostics.Process.Start(psi);
            if (p != null) await p.WaitForExitAsync();
        }
        catch { /* best-effort */ }
    }

    /// <summary>Dismiss the host-key-changed banner without touching known_hosts.</summary>
    [RelayCommand]
    private void DismissHostKeyBanner() => HostKeyChangedDetected = false;

    [RelayCommand]
    private async System.Threading.Tasks.Task FixKeyPermissions()
    {
        var path = RemoteStuff.Services.SshCommandBuilder.ExpandPath(Profile?.IdentityFile?.Trim() ?? "");
        if (string.IsNullOrEmpty(path)) { BadKeyPermissionsDetected = false; return; }
        try
        {
            System.Diagnostics.ProcessStartInfo psi;
            if (System.OperatingSystem.IsWindows())
                psi = new System.Diagnostics.ProcessStartInfo("icacls")
                {
                    Arguments = $"\"{ path}\" /inheritance:r /grant:r \"{System.Environment.UserName}:R\"",
                    UseShellExecute = false, RedirectStandardOutput = true,
                    RedirectStandardError = true, CreateNoWindow = true
                };
            else
                psi = new System.Diagnostics.ProcessStartInfo("chmod")
                {
                    Arguments = $"600 \"{path}\"",
                    UseShellExecute = false, RedirectStandardOutput = true,
                    RedirectStandardError = true, CreateNoWindow = true
                };
            using var proc = System.Diagnostics.Process.Start(psi)!;
            await proc.WaitForExitAsync();
        }
        catch { /* ignore — user will see the raw SSH error if it persists */ }
        BadKeyPermissionsDetected = false;
        Reconnect();
    }

    [RelayCommand]
    private void DismissKeyPermissionsBanner() => BadKeyPermissionsDetected = false;

    /// <summary>Re-point this terminal at a new connection (new host/port/user args
    /// and/or a new run-on-connect command) and reconnect in place. Backs the tab's
    /// "Edit Connection Settings…" action.</summary>
    public void Repoint(string executable, string[] args, (string, string)[]? env,
        string? workingDirectory, string? runOnConnect, string? autoPassword)
    {
        RunOnConnect = string.IsNullOrWhiteSpace(runOnConnect) ? null : runOnConnect;
        _runCommandTitle = BaseCommandName(RunOnConnect);
        Terminal.SetAutoPassword(autoPassword);
        Terminal.RelaunchWith(executable, args, env, workingDirectory, RunOnConnect);
        IsRunning = true;
        Title = EffectiveBaseTitle;
    }

    [RelayCommand] private void ZoomIn() => Terminal.ZoomIn();
    [RelayCommand] private void ZoomOut() => Terminal.ZoomOut();
    [RelayCommand] private void ZoomReset() => Terminal.ZoomReset();

    protected override void Close()
    {
        _reconnectCts?.Cancel();
        _healthTimer?.Stop();
        _healthTimer?.Dispose();
        Terminal.DisposeSession();
        base.Close();
    }

    public override void Dispose()
    {
        _reconnectCts?.Cancel();
        _healthTimer?.Stop();
        _healthTimer?.Dispose();
        Terminal.DisposeSession();
    }
}

/// <summary>Live reachability state of a session's endpoint, shown as the tab health dot.</summary>
public enum ConnectionHealth { Unknown, Healthy, Degraded }
