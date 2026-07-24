using System;
using System.Collections.Generic;
using System.Net.Sockets;
using System.Threading.Tasks;

namespace RemoteStuff.Services;

/// <summary>
/// A tiny TCP reachability probe used by the tunnel-health indicator: it tries
/// to open a socket to each forwarded local port. A faithful port of the macOS
/// <c>TCPProbe</c>.
/// </summary>
public static class TcpProbe
{
    /// <summary>True if a TCP connection to <paramref name="host"/>:<paramref name="port"/> succeeds within the timeout.</summary>
    public static async Task<bool> ReachableAsync(string host, int port, TimeSpan timeout)
    {
        try
        {
            using var client = new TcpClient();
            var connectTask = client.ConnectAsync(host, port);
            var completed = await Task.WhenAny(connectTask, Task.Delay(timeout));
            return completed == connectTask && client.Connected;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>True only if <b>every</b> endpoint is reachable within the timeout.</summary>
    public static async Task<bool> AllReachableAsync(IEnumerable<(string Host, int Port)> endpoints, TimeSpan timeout)
    {
        foreach (var (host, port) in endpoints)
            if (!await ReachableAsync(host, port, timeout))
                return false;
        return true;
    }
}
