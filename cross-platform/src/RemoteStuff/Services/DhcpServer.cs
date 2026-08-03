using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading;

namespace RemoteStuff.Services;

/// <summary>
/// Lightweight in-process DHCP server for the WinNAT router mode.
/// Windows client editions have no built-in DHCP — ICS provided one but it is
/// locked to 192.168.137.0/24 on Windows 11 24H2+.  This serves any subnet.
/// Requires administrator privileges (binds UDP port 67).
/// Ported from PC_Shared_Network_Manager/Services/DhcpServerService.cs.
/// </summary>
public sealed class DhcpServer : IDisposable
{
    public sealed class Config
    {
        public string ServerIp { get; set; } = "10.1.1.1";
        public string SubnetMask { get; set; } = "255.255.255.0";
        public string PoolStart { get; set; } = "10.1.1.100";
        public string PoolEnd { get; set; } = "10.1.1.254";
        public int LeaseSeconds { get; set; } = 86400;
        public List<string> DnsServers { get; set; } = new();
        public int InterfaceIndex { get; set; }  // 0 = no filter
    }

    public sealed class Lease
    {
        public string Mac { get; set; } = "";
        public string Ip { get; set; } = "";
        public string Hostname { get; set; } = "";
        public DateTime Expiry { get; set; }
        public DateTime LastSeen { get; set; }
    }

    private const byte DISCOVER = 1, OFFER = 2, REQUEST = 3, DECLINE = 4,
                        ACK = 5, NAK = 6, RELEASE = 7, INFORM = 8;

    private Socket? _socket;
    private CancellationTokenSource? _cts;
    private Thread? _worker;
    private Config _cfg = new();
    private readonly object _sync = new();
    private readonly Dictionary<string, Lease> _leases = new();

    private static readonly string LeaseFile = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "RemoteStuff", "dhcp-leases.json");

    public bool IsRunning { get; private set; }
    public event Action? LeasesChanged;

    public void Start(Config config)
    {
        Stop();
        _cfg = config;
        LoadLeases();

        _socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
        _socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        _socket.EnableBroadcast = true;
        try { _socket.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.PacketInformation, true); } catch { }
        _socket.Bind(new IPEndPoint(IPAddress.Any, 67));

        _cts = new CancellationTokenSource();
        _worker = new Thread(() => ReceiveLoop(_cts.Token))
        {
            IsBackground = true, Name = "DhcpServer"
        };
        _worker.Start();
        IsRunning = true;
    }

    public void Stop()
    {
        if (!IsRunning && _socket == null) return;
        try { _cts?.Cancel(); } catch { }
        try { _socket?.Close(); } catch { }
        _socket = null;
        _worker = null;
        IsRunning = false;
    }

    private void ReceiveLoop(CancellationToken token)
    {
        var buffer = new byte[2048];
        while (!token.IsCancellationRequested)
        {
            try
            {
                EndPoint remote = new IPEndPoint(IPAddress.Any, 0);
                var flags = SocketFlags.None;
                int n = _socket!.ReceiveMessageFrom(buffer, 0, buffer.Length, ref flags, ref remote, out var pkt);
                if (n < 240) continue;
                if (_cfg.InterfaceIndex != 0 && pkt.Interface != _cfg.InterfaceIndex) continue;
                HandlePacket(buffer, n);
            }
            catch (SocketException) { if (token.IsCancellationRequested) break; }
            catch (ObjectDisposedException) { break; }
            catch { /* keep server alive */ }
        }
    }

    private void HandlePacket(byte[] data, int len)
    {
        if (data[0] != 1) return;
        uint xid = ReadU32(data, 4);
        ushort flags = (ushort)((data[10] << 8) | data[11]);
        var chaddr = new byte[6];
        Array.Copy(data, 28, chaddr, 0, 6);
        string mac = FormatMac(chaddr);
        var opts = ParseOptions(data, len);
        if (!opts.TryGetValue(53, out var mt) || mt.Length < 1) return;
        string? hostname = opts.TryGetValue(12, out var hn) ? Encoding.ASCII.GetString(hn).Trim('\0') : null;
        string? reqIp = opts.TryGetValue(50, out var ri) && ri.Length == 4 ? $"{ri[0]}.{ri[1]}.{ri[2]}.{ri[3]}" : null;
        uint giaddr = ReadU32(data, 24);
        uint ciaddr = ReadU32(data, 12);

        switch (mt[0])
        {
            case DISCOVER:
                var offer = Allocate(mac, reqIp);
                if (offer == null) return;
                Stamp(mac, offer, hostname, commit: false);
                Send(OFFER, xid, flags, chaddr, offer, giaddr);
                break;
            case REQUEST:
                if (opts.TryGetValue(54, out var sid) && sid.Length == 4)
                {
                    var chosen = $"{sid[0]}.{sid[1]}.{sid[2]}.{sid[3]}";
                    if (chosen != _cfg.ServerIp) return;
                }
                string? tgt = reqIp ?? (ciaddr != 0 ? U32ToIp(ciaddr) : null);
                if (tgt != null && Assignable(mac, tgt))
                {
                    Stamp(mac, tgt, hostname, commit: true);
                    Send(ACK, xid, flags, chaddr, tgt, giaddr);
                }
                else Send(NAK, xid, flags, chaddr, "0.0.0.0", giaddr);
                break;
            case RELEASE:
            case DECLINE:
                lock (_sync) { _leases.Remove(mac); }
                SaveLeases(); LeasesChanged?.Invoke();
                break;
            case INFORM:
                Send(ACK, xid, flags, chaddr, "0.0.0.0", giaddr, inform: true);
                break;
        }
    }

    private bool Assignable(string mac, string ip)
    {
        if (!InPool(ip) || ip == _cfg.ServerIp) return false;
        lock (_sync)
            foreach (var l in _leases.Values)
                if (l.Ip == ip && l.Mac != mac && l.Expiry > DateTime.UtcNow) return false;
        return true;
    }

    private string? Allocate(string mac, string? requested)
    {
        lock (_sync)
        {
            if (_leases.TryGetValue(mac, out var ex) && InPool(ex.Ip)) return ex.Ip;
            var inUse = new HashSet<string>(_leases.Values.Where(l => l.Expiry > DateTime.UtcNow).Select(l => l.Ip));
            if (requested != null && InPool(requested) && requested != _cfg.ServerIp && !inUse.Contains(requested))
                return requested;
            uint s = IpToU32(_cfg.PoolStart), e = IpToU32(_cfg.PoolEnd), srv = IpToU32(_cfg.ServerIp);
            for (uint a = s; a <= e; a++)
            {
                if (a == srv) continue;
                var ip = U32ToIp(a);
                if (!inUse.Contains(ip)) return ip;
            }
        }
        return null;
    }

    private void Stamp(string mac, string ip, string? hostname, bool commit)
    {
        lock (_sync)
        {
            if (!_leases.TryGetValue(mac, out var r)) { r = new Lease { Mac = mac }; _leases[mac] = r; }
            r.Ip = ip;
            if (!string.IsNullOrEmpty(hostname)) r.Hostname = hostname!;
            r.LastSeen = DateTime.UtcNow;
            if (commit) r.Expiry = DateTime.UtcNow.AddSeconds(_cfg.LeaseSeconds);
            else if (r.Expiry < DateTime.UtcNow.AddSeconds(30)) r.Expiry = DateTime.UtcNow.AddSeconds(30);
        }
        if (commit) { SaveLeases(); LeasesChanged?.Invoke(); }
    }

    private void Send(byte type, uint xid, ushort flags, byte[] chaddr, string yiaddr, uint giaddr, bool inform = false)
    {
        var pkt = new byte[300];
        pkt[0] = 2; pkt[1] = 1; pkt[2] = 6;
        WriteU32(pkt, 4, xid);
        pkt[10] = (byte)(flags >> 8); pkt[11] = (byte)(flags & 0xFF);
        if (!inform) WriteU32(pkt, 16, IpToU32(yiaddr));
        WriteU32(pkt, 20, IpToU32(_cfg.ServerIp));
        WriteU32(pkt, 24, giaddr);
        Array.Copy(chaddr, 0, pkt, 28, 6);
        int i = 236;
        pkt[i++] = 99; pkt[i++] = 130; pkt[i++] = 83; pkt[i++] = 99;
        pkt[i++] = 53; pkt[i++] = 1; pkt[i++] = type;
        i = Opt(pkt, i, 54, IPAddress.Parse(_cfg.ServerIp).GetAddressBytes());
        if (type is ACK or OFFER)
        {
            i = Opt(pkt, i, 1, IPAddress.Parse(_cfg.SubnetMask).GetAddressBytes());
            i = Opt(pkt, i, 3, IPAddress.Parse(_cfg.ServerIp).GetAddressBytes());
            var dns = new List<byte>();
            foreach (var d in _cfg.DnsServers)
                if (IPAddress.TryParse(d, out var da)) dns.AddRange(da.GetAddressBytes());
            // Under WinNAT the gateway is NOT a DNS resolver — fall back to public DNS.
            if (dns.Count == 0) { dns.AddRange(new byte[] { 8, 8, 8, 8 }); dns.AddRange(new byte[] { 1, 1, 1, 1 }); }
            i = Opt(pkt, i, 6, dns.ToArray());
            if (!inform)
            {
                var lt = BitConverter.GetBytes(_cfg.LeaseSeconds);
                if (BitConverter.IsLittleEndian) Array.Reverse(lt);
                i = Opt(pkt, i, 51, lt);
            }
        }
        pkt[i] = 255;

        try
        {
            // Send to the subnet-directed broadcast so the reply exits the right adapter
            // on multi-homed systems (dock + Wi-Fi + ZeroTier + Hyper-V all coexist).
            IPEndPoint dest = giaddr != 0
                ? new IPEndPoint(new IPAddress(new[] { (byte)(giaddr >> 24), (byte)(giaddr >> 16), (byte)(giaddr >> 8), (byte)giaddr }), 67)
                : new IPEndPoint(DirBcast(_cfg.ServerIp, _cfg.SubnetMask), 68);
            _socket!.SendTo(pkt, 0, i + 1, SocketFlags.None, dest);
        }
        catch { /* ignore send errors */ }
    }

    private static IPAddress DirBcast(string serverIp, string mask)
    {
        uint ip = IpToU32(serverIp), m = IpToU32(mask), b = (ip & m) | ~m;
        return new IPAddress(new[] { (byte)(b >> 24), (byte)(b >> 16), (byte)(b >> 8), (byte)b });
    }

    public List<Lease> GetLeases()
    {
        lock (_sync)
            return _leases.Values.OrderBy(l => IpToU32(l.Ip)).ToList();
    }

    private bool InPool(string ip) { uint a = IpToU32(ip); return a >= IpToU32(_cfg.PoolStart) && a <= IpToU32(_cfg.PoolEnd); }

    private static Dictionary<byte, byte[]> ParseOptions(byte[] data, int len)
    {
        var d = new Dictionary<byte, byte[]>();
        int i = 236;
        if (i + 4 > len || data[i] != 99 || data[i + 1] != 130 || data[i + 2] != 83 || data[i + 3] != 99) return d;
        i += 4;
        while (i < len) { byte c = data[i++]; if (c == 255) break; if (c == 0) continue; if (i >= len) break; byte l = data[i++]; if (i + l > len) break; var v = new byte[l]; Array.Copy(data, i, v, 0, l); d[c] = v; i += l; }
        return d;
    }

    private static int Opt(byte[] buf, int o, byte code, byte[] val) { buf[o++] = code; buf[o++] = (byte)val.Length; Array.Copy(val, 0, buf, o, val.Length); return o + val.Length; }
    private static uint ReadU32(byte[] b, int o) => (uint)(b[o] << 24 | b[o + 1] << 16 | b[o + 2] << 8 | b[o + 3]);
    private static void WriteU32(byte[] b, int o, uint v) { b[o] = (byte)(v >> 24); b[o + 1] = (byte)(v >> 16); b[o + 2] = (byte)(v >> 8); b[o + 3] = (byte)v; }
    private static uint IpToU32(string ip) { var p = IPAddress.Parse(ip).GetAddressBytes(); return (uint)(p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]); }
    private static string U32ToIp(uint v) => $"{(v >> 24) & 0xFF}.{(v >> 16) & 0xFF}.{(v >> 8) & 0xFF}.{v & 0xFF}";
    private static string FormatMac(byte[] m) => string.Join(":", m.Select(b => b.ToString("X2")));

    private void LoadLeases()
    {
        try
        {
            if (!File.Exists(LeaseFile)) return;
            var recs = JsonSerializer.Deserialize<List<Lease>>(File.ReadAllText(LeaseFile));
            if (recs == null) return;
            lock (_sync) { _leases.Clear(); foreach (var r in recs) if (!string.IsNullOrEmpty(r.Mac)) _leases[r.Mac] = r; }
        }
        catch { }
    }

    private void SaveLeases()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(LeaseFile)!);
            List<Lease> snap; lock (_sync) { snap = _leases.Values.ToList(); }
            File.WriteAllText(LeaseFile, JsonSerializer.Serialize(snap));
        }
        catch { }
    }

    public void Dispose() => Stop();
}
