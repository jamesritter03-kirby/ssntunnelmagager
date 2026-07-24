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
    public override string Glyph => ">_";

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
            Title = EffectiveBaseTitle + " — disconnected";
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

        Terminal.StartDeferred(executable, args, env, workingDirectory, runOnConnect);
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

    // Self-contained scrollback actions so they also work from the docked ⋮ menu
    // (a MenuFlyout popup can't reach the MainWindowViewModel).
    [RelayCommand]
    private void CopyScrollback() => Terminal.CopyScrollback();

    [RelayCommand]
    private void ClearScrollback() => Terminal.Clear();

    [RelayCommand]
    private async System.Threading.Tasks.Task SaveScrollback()
        => await Terminal.SaveScrollbackAsync($"{_baseTitle.Replace('/', '-')}.log");

    [RelayCommand]
    private void Disconnect()
    {
        Terminal.Terminate();
        IsRunning = false;
        Title = EffectiveBaseTitle + " — disconnected";
    }

    [RelayCommand]
    private void Reconnect()
    {
        Terminal.Restart();
        IsRunning = true;
        Title = EffectiveBaseTitle;
    }

    // ---- Host-key-changed banner ----

    /// <summary>True when ssh reported the remote host key changed for this session.</summary>
    [ObservableProperty] private bool _hostKeyChangedDetected;

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
        Terminal.DisposeSession();
        base.Close();
    }

    public override void Dispose() => Terminal.DisposeSession();
}
