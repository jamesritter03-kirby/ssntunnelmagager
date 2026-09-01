using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace RemoteStuff.Services;

/// <summary>One device seen on this computer's router LAN, rendered on the status page.</summary>
public sealed record RouterClientRow(string Ip, string Mac, string Hostname, string Expiry);

/// <summary>A point-in-time view of this computer's router, built on demand for the web page.</summary>
public sealed class RouterStatusSnapshot
{
    public bool Running { get; init; }
    public string HostName { get; init; } = "";
    public string Platform { get; init; } = "";
    public string RouterIp { get; init; } = "";
    public string Subnet { get; init; } = "";
    public string DhcpRange { get; init; } = "";
    public string UpstreamAdapter { get; init; } = "";
    public string DownstreamAdapter { get; init; } = "";
    public string DnsServers { get; init; } = "";
    public bool DhcpRunning { get; init; }
    public IReadOnlyList<RouterClientRow> Clients { get; init; } = Array.Empty<RouterClientRow>();
}

/// <summary>
/// Serves a small read-only status page describing this computer's router role
/// (NAT config, DHCP, and connected clients) over HTTP on localhost. Bound to
/// <c>localhost</c> so it needs no elevation or URL reservation and is never
/// exposed on the LAN. The page auto-refreshes so the client list stays current.
/// </summary>
public sealed class RouterStatusServer : IDisposable
{
    public const int DefaultPort = 8080;

    public int Port { get; }
    public string Url => $"http://localhost:{Port}/";
    public bool IsRunning { get; private set; }

    private HttpListener? _listener;
    private CancellationTokenSource? _cts;
    private Func<RouterStatusSnapshot>? _provider;

    public RouterStatusServer(int port = DefaultPort) => Port = port;

    public void Start(Func<RouterStatusSnapshot> provider)
    {
        Stop();
        _provider = provider;
        _listener = new HttpListener();
        _listener.Prefixes.Add($"http://localhost:{Port}/");
        _listener.Start();
        _cts = new CancellationTokenSource();
        IsRunning = true;
        _ = AcceptLoopAsync(_listener, _cts.Token);
    }

    public void Stop()
    {
        try { _cts?.Cancel(); } catch { }
        try { _listener?.Stop(); } catch { }
        try { _listener?.Close(); } catch { }
        _listener = null;
        _cts = null;
        IsRunning = false;
    }

    private async Task AcceptLoopAsync(HttpListener listener, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            HttpListenerContext ctx;
            try
            {
                ctx = await listener.GetContextAsync();
            }
            catch (Exception) when (token.IsCancellationRequested)
            {
                break;
            }
            catch
            {
                break;
            }

            try
            {
                var html = RenderHtml(_provider?.Invoke() ?? new RouterStatusSnapshot());
                var bytes = Encoding.UTF8.GetBytes(html);
                ctx.Response.ContentType = "text/html; charset=utf-8";
                ctx.Response.ContentLength64 = bytes.Length;
                ctx.Response.Headers["Cache-Control"] = "no-store";
                await ctx.Response.OutputStream.WriteAsync(bytes, 0, bytes.Length, token);
            }
            catch { /* client went away */ }
            finally
            {
                try { ctx.Response.Close(); } catch { }
            }
        }
    }

    private static string RenderHtml(RouterStatusSnapshot s)
    {
        string E(string? v) => WebUtility.HtmlEncode(string.IsNullOrWhiteSpace(v) ? "—" : v!.Trim());

        var rows = new StringBuilder();
        if (s.Clients.Count == 0)
        {
            rows.Append("<tr><td colspan=\"4\" class=\"empty\">No clients have leased an address yet.</td></tr>");
        }
        else
        {
            foreach (var c in s.Clients)
                rows.Append($"<tr><td>{E(c.Ip)}</td><td class=\"mono\">{E(c.Mac)}</td><td>{E(c.Hostname)}</td><td>{E(c.Expiry)}</td></tr>");
        }

        var statusClass = s.Running ? "on" : "off";
        var statusText = s.Running ? "Active" : "Stopped";
        var dhcpText = s.DhcpRunning ? "Running" : "Not running";

        return $$"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="5">
<title>Router status — {{E(s.HostName)}}</title>
<style>
  :root { color-scheme: light dark; }
  body { font-family: -apple-system, "Segoe UI", system-ui, sans-serif; margin: 0; padding: 2rem;
         background: Canvas; color: CanvasText; }
  h1 { font-size: 1.4rem; margin: 0 0 .25rem; }
  .sub { opacity: .7; margin: 0 0 1.5rem; }
  .badge { display: inline-block; padding: .15rem .6rem; border-radius: 999px; font-size: .8rem;
           font-weight: 600; vertical-align: middle; margin-left: .5rem; }
  .badge.on { background: #1f9d5522; color: #1f9d55; }
  .badge.off { background: #d9534f22; color: #d9534f; }
  .grid { display: grid; grid-template-columns: max-content 1fr; gap: .35rem 1.5rem;
          max-width: 640px; margin-bottom: 2rem; }
  .grid dt { font-weight: 600; opacity: .8; }
  .grid dd { margin: 0; }
  table { border-collapse: collapse; width: 100%; max-width: 900px; }
  th, td { text-align: left; padding: .5rem .75rem; border-bottom: 1px solid color-mix(in srgb, CanvasText 15%, transparent); }
  th { font-size: .8rem; text-transform: uppercase; letter-spacing: .04em; opacity: .7; }
  .mono { font-family: ui-monospace, "SF Mono", Consolas, monospace; }
  .empty { text-align: center; opacity: .6; font-style: italic; }
</style>
</head>
<body>
  <h1>This computer as a router <span class="badge {{statusClass}}">{{statusText}}</span></h1>
  <p class="sub">{{E(s.HostName)}} · {{E(s.Platform)}}</p>

  <dl class="grid">
    <dt>Router address</dt><dd class="mono">{{E(s.RouterIp)}}</dd>
    <dt>Subnet mask</dt><dd class="mono">{{E(s.Subnet)}}</dd>
    <dt>Internet (upstream)</dt><dd>{{E(s.UpstreamAdapter)}}</dd>
    <dt>LAN (downstream)</dt><dd>{{E(s.DownstreamAdapter)}}</dd>
    <dt>DHCP range</dt><dd class="mono">{{E(s.DhcpRange)}}</dd>
    <dt>DHCP server</dt><dd>{{dhcpText}}</dd>
    <dt>DNS handed out</dt><dd class="mono">{{E(s.DnsServers)}}</dd>
  </dl>

  <h2 style="font-size:1.1rem;">Connected clients</h2>
  <table>
    <thead><tr><th>IP address</th><th>MAC</th><th>Hostname</th><th>Lease expires</th></tr></thead>
    <tbody>{{rows}}</tbody>
  </table>
</body>
</html>
""";
    }

    public void Dispose() => Stop();
}
