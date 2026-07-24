using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RemoteStuff.Models;
using RemoteStuff.Services;

namespace RemoteStuff.ViewModels;

/// <summary>
/// A VNC console tab. Two shapes, matching the Mac app:
/// <list type="bullet">
/// <item><b>Tunneled</b> (from a profile): runs <c>ssh -N -L …</c> and connects the
/// system VNC viewer to the local end of the tunnel.</item>
/// <item><b>Direct</b> (ad-hoc): no tunnel — the viewer connects straight to host:port.</item>
/// </list>
/// The remote desktop is opened in the OS screen-sharing / VNC viewer (a one-click
/// fallback); an embedded RFB viewer is macOS-only in the original and not ported.
/// </summary>
public sealed partial class VncTabViewModel : TabViewModel
{
    private readonly SshProfile? _profile;
    private readonly string _targetHost;
    private readonly int _targetPort;
    private readonly bool _tunneled;
    private int _localPort;
    private Process? _ssh;
    private CancellationTokenSource? _cts;
    private readonly StringBuilder _log = new();

    public override string Glyph => "🖥";

    public override (string Host, int Port)? ConnectionEndpoint =>
        string.IsNullOrWhiteSpace(_targetHost) ? null : (_targetHost, _targetPort);

    [ObservableProperty] private VncPhase _phase = VncPhase.Idle;
    [ObservableProperty] private string _statusText = "";
    [ObservableProperty] private string _logText = "";

    [NotifyPropertyChangedFor(nameof(CanOpenViewer))]
    [ObservableProperty] private bool _isReady;

    /// <summary>True while the tunnel is still coming up (drives the progress bar).</summary>
    public bool IsConnecting => Phase == VncPhase.Connecting;

    partial void OnPhaseChanged(VncPhase value) => OnPropertyChanged(nameof(IsConnecting));

    /// <summary>The <c>vnc://…</c> address the viewer connects to.</summary>
    public string ViewerAddress => _tunneled
        ? $"vnc://127.0.0.1:{_localPort}"
        : $"vnc://{_targetHost}:{_targetPort}";

    public string TargetLabel => _tunneled
        ? $"{_targetHost}:{_targetPort} (via SSH)"
        : $"{_targetHost}:{_targetPort}";

    public bool CanOpenViewer => IsReady;

    public override RemoteStuff.Services.TabSnapshot? CreateSnapshot() => new RemoteStuff.Services.TabSnapshot
    {
        Kind = _tunneled ? "vnc-tunnel" : "vnc",
        ProfileId = _profile?.Id,
        Title = Title,
        Host = _targetHost,
        Port = _targetPort
    };

    /// <summary>Create a tunneled VNC tab from a profile (forwards to the remote host's VNC port).</summary>
    public VncTabViewModel(SshProfile profile, int remoteVncPort = 5900)
    {
        _profile = profile;
        _tunneled = true;
        _targetHost = profile.Host;
        _targetPort = remoteVncPort;
        Title = "VNC · " + profile.Name;
        ProfileId = profile.Id;
        _ = StartAsync();
    }

    /// <summary>Create a direct (ad-hoc) VNC tab to a host:port with no SSH tunnel.</summary>
    public VncTabViewModel(string host, int port, string title)
    {
        _tunneled = false;
        _targetHost = host;
        _targetPort = port;
        Title = "VNC · " + title;
        Phase = VncPhase.Connected;
        StatusText = "Ready — open the viewer to connect.";
        IsReady = true;
    }

    private async Task StartAsync()
    {
        Phase = VncPhase.Connecting;
        StatusText = "Opening secure tunnel…";
        try
        {
            _localPort = FreeLocalPort();
            var args = SshCommandBuilder.VncTunnelArguments(_profile!, _localPort, _targetPort);
            var exe = File.Exists("/usr/bin/ssh") ? "/usr/bin/ssh" : "ssh";

            var psi = new ProcessStartInfo
            {
                FileName = exe,
                RedirectStandardError = true,
                RedirectStandardOutput = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            foreach (var a in args) psi.ArgumentList.Add(a);

            _ssh = new Process { StartInfo = psi, EnableRaisingEvents = true };
            _ssh.ErrorDataReceived += (_, e) => AppendLog(e.Data);
            _ssh.OutputDataReceived += (_, e) => AppendLog(e.Data);
            _ssh.Exited += (_, _) => Dispatcher.UIThread.Post(OnSshExited);

            _ssh.Start();
            _ssh.BeginErrorReadLine();
            _ssh.BeginOutputReadLine();

            _cts = new CancellationTokenSource();
            await WaitForListenerAsync(_cts.Token);
        }
        catch (Exception ex)
        {
            Phase = VncPhase.Failed;
            StatusText = "Couldn't open the tunnel: " + ex.Message;
            AppendLog(ex.Message);
        }
    }

    /// <summary>Poll the local forward until it accepts a connection (or we time out).</summary>
    private async Task WaitForListenerAsync(CancellationToken token)
    {
        var deadline = DateTime.UtcNow.AddSeconds(20);
        while (DateTime.UtcNow < deadline && !token.IsCancellationRequested)
        {
            if (_ssh is { HasExited: true }) return;   // OnSshExited handles the failure
            if (await TcpProbe.ReachableAsync("127.0.0.1", _localPort, TimeSpan.FromSeconds(1)))
            {
                Dispatcher.UIThread.Post(() =>
                {
                    Phase = VncPhase.Connected;
                    IsReady = true;
                    StatusText = "Tunnel ready — open the viewer to connect.";
                });
                return;
            }
            try { await Task.Delay(500, token); } catch (TaskCanceledException) { return; }
        }
        if (!token.IsCancellationRequested && Phase == VncPhase.Connecting)
            Dispatcher.UIThread.Post(() =>
            {
                Phase = VncPhase.Failed;
                StatusText = "Timed out waiting for the tunnel to come up.";
            });
    }

    private void OnSshExited()
    {
        IsReady = false;
        if (Phase != VncPhase.Failed)
        {
            Phase = VncPhase.Ended;
            StatusText = "The VNC tunnel was closed.";
        }
        IsRunning = false;
    }

    private void AppendLog(string? line)
    {
        if (string.IsNullOrEmpty(line)) return;
        Dispatcher.UIThread.Post(() =>
        {
            _log.AppendLine(line);
            if (_log.Length > 40_000) _log.Remove(0, _log.Length - 40_000);
            LogText = _log.ToString();
        });
    }

    /// <summary>Pick an unused local TCP port for the tunnel's listener.</summary>
    private static int FreeLocalPort()
    {
        var l = new TcpListener(IPAddress.Loopback, 0);
        l.Start();
        var port = ((IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();
        return port;
    }

    [RelayCommand(CanExecute = nameof(CanOpenViewer))]
    private void OpenViewer()
    {
        try
        {
            var psi = new ProcessStartInfo(ViewerAddress) { UseShellExecute = true };
            Process.Start(psi);
            StatusText = "Opened the system VNC viewer.";
        }
        catch (Exception ex)
        {
            StatusText = $"Couldn't launch a VNC viewer. Connect manually to {ViewerAddress}. ({ex.Message})";
        }
    }

    [RelayCommand]
    private void Reconnect()
    {
        if (!_tunneled)
        {
            Phase = VncPhase.Connected;
            IsReady = true;
            IsRunning = true;
            StatusText = "Ready — open the viewer to connect.";
            return;
        }
        Teardown();
        IsRunning = true;
        _ = StartAsync();
    }

    [RelayCommand]
    private void Disconnect()
    {
        Teardown();
        Phase = VncPhase.Ended;
        StatusText = "Disconnected.";
    }

    /// <summary>Cancel an in-progress connection attempt before the tunnel is ready.</summary>
    [RelayCommand]
    private void Abort()
    {
        Teardown();
        Phase = VncPhase.Ended;
        IsRunning = false;
        StatusText = "Connection aborted.";
    }

    private void Teardown()
    {
        try { _cts?.Cancel(); } catch { /* ignore */ }
        try
        {
            if (_ssh is { HasExited: false }) _ssh.Kill(entireProcessTree: true);
        }
        catch { /* ignore */ }
        _ssh?.Dispose();
        _ssh = null;
        IsReady = false;
    }

    public override void Dispose() => Teardown();

    protected override void Close()
    {
        Dispose();
        base.Close();
    }
}
