using System;
using System.Collections.Concurrent;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace RemoteStuff.Services.Terminal;

/// <summary>
/// A WinBox-style "connect by MAC address" transport for MikroTik RouterOS,
/// implemented as an <see cref="IPtyProcess"/> so the embedded terminal can drive
/// it exactly like a local PTY. It speaks the open MAC-Telnet protocol over UDP
/// broadcast (port 20561): the router's MAC address in each packet header selects
/// which device answers, so a freshly-flattened switch with no IP address can
/// still be reached on the same broadcast domain — no raw sockets, Npcap or admin
/// rights required.
/// </summary>
public sealed class MacTelnetPtyProcess : IPtyProcess
{
    private const int MacTelnetPort = 20561;
    private static readonly byte[] CpMagic = { 0x56, 0x34, 0x12, 0xff };

    // Packet types.
    private const byte PTYPE_SESSIONSTART = 0;
    private const byte PTYPE_DATA = 1;
    private const byte PTYPE_ACK = 2;
    private const byte PTYPE_PING = 4;
    private const byte PTYPE_PONG = 5;
    private const byte PTYPE_END = 255;

    // Control packet types.
    private const byte CP_BEGINAUTH = 0;
    private const byte CP_ENCRYPTIONKEY = 1;
    private const byte CP_PASSWORD = 2;
    private const byte CP_USERNAME = 3;
    private const byte CP_TERM_TYPE = 4;
    private const byte CP_TERM_WIDTH = 5;
    private const byte CP_TERM_HEIGHT = 6;
    private const byte CP_END_AUTH = 9;
    private const byte CP_PLAINDATA = 0xff;

    private enum State { SessionStart, BeginAuth, EncKey, AuthDone, Connected, Closed }

    private readonly byte[] _dstMac;
    private readonly string _username;
    private readonly string _password;
    private readonly string? _targetIp;

    private byte[] _srcMac = new byte[6];
    private readonly ushort _sesKey = (ushort)Random.Shared.Next(1, 0xFFFF);
    private uint _outCounter;
    private uint _inCounter;

    private Socket? _sock;
    private Thread? _rx;
    private State _state = State.SessionStart;
    private byte[]? _retryPacket;
    private int _retries;
    private ushort _cols = 80, _rows = 24;

    private readonly BlockingCollection<byte[]> _rxQueue = new();
    private byte[]? _pending;
    private int _pendingOff;
    private readonly CancellationTokenSource _cts = new();
    private volatile bool _exited;

    public bool HasExited => _exited;

    /// <param name="macAddress">Router MAC, e.g. "E4:8D:8C:11:22:33" or "e48d8c112233".</param>
    public MacTelnetPtyProcess(string macAddress, string username, string password, string? targetIp = null)
    {
        _dstMac = ParseMac(macAddress);
        _username = username ?? "";
        _password = password ?? "";
        _targetIp = string.IsNullOrWhiteSpace(targetIp) ? null : targetIp;
    }

    public void Start(string executable, string[] args, ushort cols, ushort rows,
        (string Name, string Value)[]? extraEnv = null, string? workingDirectory = null)
    {
        _cols = cols > 0 ? cols : (ushort)80;
        _rows = rows > 0 ? rows : (ushort)24;

        _srcMac = PickSourceMac(_targetIp);

        _sock = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
        _sock.EnableBroadcast = true;
        try { _sock.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true); }
        catch { /* not all platforms */ }
        // Stop Windows from surfacing ICMP "port unreachable" (from a prior unicast
        // send) as a ConnectionReset exception on the next ReceiveFrom, which would
        // otherwise spin the receive loop.
        if (OperatingSystem.IsWindows())
        {
            try
            {
                const int SIO_UDP_CONNRESET = -1744830452;
                _sock.IOControl((IOControlCode)SIO_UDP_CONNRESET, new byte[] { 0, 0, 0, 0 }, null);
            }
            catch { /* best effort */ }
        }
        _sock.Bind(new IPEndPoint(IPAddress.Any, 0));
        _sock.ReceiveTimeout = 1000;

        Feed($"\u001b[2mConnecting via MAC-Telnet to {FormatMac(_dstMac)} as {_username}…\u001b[0m\r\n");

        // Kick off the handshake, then let the receive loop drive the state machine.
        _retryPacket = BuildHeader(PTYPE_SESSIONSTART, 0);
        SendToRouter(_retryPacket);

        _rx = new Thread(ReceiveLoop) { IsBackground = true, Name = "mac-telnet-rx" };
        _rx.Start();
    }

    // ------------------------------------------------------------------
    // IPtyProcess reads/writes
    // ------------------------------------------------------------------

    public int Read(byte[] buffer)
    {
        if (_pending is null || _pendingOff >= _pending.Length)
        {
            if (_exited && _rxQueue.Count == 0) return 0;
            try { _pending = _rxQueue.Take(_cts.Token); _pendingOff = 0; }
            catch { return 0; } // cancelled → EOF
        }
        int n = Math.Min(buffer.Length, _pending!.Length - _pendingOff);
        Array.Copy(_pending, _pendingOff, buffer, 0, n);
        _pendingOff += n;
        return n;
    }

    public void Write(byte[] data)
    {
        if (_exited || _state != State.Connected || data.Length == 0) return;
        // Terminal input is carried as raw PLAINDATA appended after the header.
        var pkt = BuildHeader(PTYPE_DATA, _outCounter, data);
        _outCounter += (uint)data.Length;
        SendToRouter(pkt);
    }

    public void Resize(ushort cols, ushort rows)
    {
        _cols = cols > 0 ? cols : _cols;
        _rows = rows > 0 ? rows : _rows;
        if (_exited || _state != State.Connected) return;
        var payload = Concat(
            Control(CP_TERM_WIDTH, LeU16(_cols)),
            Control(CP_TERM_HEIGHT, LeU16(_rows)));
        var pkt = BuildHeader(PTYPE_DATA, _outCounter, payload);
        _outCounter += (uint)payload.Length;
        SendToRouter(pkt);
    }

    public int? TryReap() => _exited ? 0 : null;

    public void Terminate()
    {
        if (_exited) return;
        try { SendToRouter(BuildHeader(PTYPE_END, _outCounter)); } catch { }
        Shutdown();
    }

    public void Dispose()
    {
        Shutdown();
        try { _cts.Cancel(); } catch { }
        try { _sock?.Dispose(); } catch { }
        _rxQueue.Dispose();
        _cts.Dispose();
    }

    private void Shutdown()
    {
        if (_exited) return;
        _exited = true;
        _state = State.Closed;
        try { _cts.Cancel(); } catch { }
        try { _rxQueue.CompleteAdding(); } catch { }
    }

    // ------------------------------------------------------------------
    // Receive loop / protocol state machine
    // ------------------------------------------------------------------

    private void ReceiveLoop()
    {
        var buf = new byte[4096];
        EndPoint remote = new IPEndPoint(IPAddress.Any, 0);
        var deadline = DateTime.UtcNow.AddSeconds(12);

        while (!_exited)
        {
            int n;
            try { n = _sock!.ReceiveFrom(buf, ref remote); }
            catch (SocketException)
            {
                // Receive timeout: resend the last handshake packet until connected.
                if (_state == State.Connected) continue;
                if (DateTime.UtcNow > deadline)
                {
                    Feed("\r\n\u001b[31mNo response from the device. MAC-Telnet may be disabled " +
                         "on its interface, or it is on a different broadcast domain.\u001b[0m\r\n");
                    Shutdown();
                    return;
                }
                if (_retryPacket is not null && _retries++ < 12) SendToRouter(_retryPacket);
                continue;
            }
            catch { Shutdown(); return; }

            if (n < 20) continue;
            HandlePacket(buf, n);
        }
    }

    private void HandlePacket(byte[] data, int n)
    {
        byte ptype = data[1];
        // Ignore packets not addressed to our session (someone else's reply).
        ushort seskey = (ushort)((data[14] << 8) | data[15]);
        if (seskey != _sesKey && ptype != PTYPE_SESSIONSTART) return;
        uint counter = (uint)((data[16] << 24) | (data[17] << 16) | (data[18] << 8) | data[19]);

        switch (ptype)
        {
            case PTYPE_ACK:
                return;

            case PTYPE_PING:
                // Echo the ping payload back as a pong.
                var pong = BuildHeader(PTYPE_PONG, counter,
                    n > 20 ? data.AsSpan(20, n - 20).ToArray() : Array.Empty<byte>());
                SendToRouter(pong);
                return;

            case PTYPE_END:
                Feed("\r\n\u001b[2m— session closed by device —\u001b[0m\r\n");
                Shutdown();
                return;

            case PTYPE_SESSIONSTART:
                if (_state == State.SessionStart) SendBeginAuth();
                return;

            case PTYPE_DATA:
                int payloadLen = n - 20;
                // Acknowledge every data packet so the router does not retransmit.
                SendToRouter(BuildHeader(PTYPE_ACK, counter + (uint)payloadLen));
                // Process each packet's payload only once (dedupe retransmits).
                if (counter == _inCounter)
                {
                    _inCounter += (uint)payloadLen;
                    ProcessControl(data, 20, n);
                }
                return;
        }
    }

    private void ProcessControl(byte[] data, int start, int end)
    {
        int pos = start;
        while (pos < end)
        {
            if (end - pos >= 9 && data.AsSpan(pos, 4).SequenceEqual(CpMagic))
            {
                byte cptype = data[pos + 4];
                uint len = (uint)((data[pos + 5] << 24) | (data[pos + 6] << 16) | (data[pos + 7] << 8) | data[pos + 8]);
                int dataStart = pos + 9;
                if (dataStart + len > end) len = (uint)(end - dataStart);

                switch (cptype)
                {
                    case CP_ENCRYPTIONKEY:
                        if (_state is State.BeginAuth or State.SessionStart && len >= 16)
                            SendAuth(data, dataStart);
                        break;
                    case CP_END_AUTH:
                        if (_state != State.Connected)
                        {
                            _state = State.Connected;
                            _retryPacket = null;
                            Feed("\u001b[2m— connected —\u001b[0m\r\n");
                        }
                        break;
                    case CP_PLAINDATA:
                        if (len > 0) Feed(data, dataStart, (int)len);
                        break;
                }
                pos = dataStart + (int)len;
            }
            else
            {
                // Anything without the control magic is raw terminal output.
                Feed(data, pos, end - pos);
                pos = end;
            }
        }
    }

    private void SendBeginAuth()
    {
        var payload = Control(CP_BEGINAUTH, Array.Empty<byte>());
        _retryPacket = BuildHeader(PTYPE_DATA, _outCounter, payload);
        _outCounter += (uint)payload.Length;
        _state = State.BeginAuth;
        _retries = 0;
        SendToRouter(_retryPacket);
    }

    private void SendAuth(byte[] saltPacket, int saltStart)
    {
        // password field = 0x00 + md5( 0x00 + password + 16-byte salt )
        var toHash = new byte[1 + _password.Length + 16];
        toHash[0] = 0;
        var pw = Encoding.ASCII.GetBytes(_password);
        Array.Copy(pw, 0, toHash, 1, pw.Length);
        Array.Copy(saltPacket, saltStart, toHash, 1 + pw.Length, 16);
        var digest = MD5.HashData(toHash);
        var passField = new byte[17];
        passField[0] = 0;
        Array.Copy(digest, 0, passField, 1, 16);

        var payload = Concat(
            Control(CP_PASSWORD, passField),
            Control(CP_USERNAME, Encoding.ASCII.GetBytes(_username)),
            Control(CP_TERM_TYPE, Encoding.ASCII.GetBytes("xterm")),
            Control(CP_TERM_WIDTH, LeU16(_cols)),
            Control(CP_TERM_HEIGHT, LeU16(_rows)));

        _retryPacket = BuildHeader(PTYPE_DATA, _outCounter, payload);
        _outCounter += (uint)payload.Length;
        _state = State.AuthDone;
        _retries = 0;
        SendToRouter(_retryPacket);
    }

    // ------------------------------------------------------------------
    // Packet construction / transmit
    // ------------------------------------------------------------------

    private byte[] BuildHeader(byte ptype, uint counter, byte[]? payload = null)
    {
        int len = 20 + (payload?.Length ?? 0);
        var p = new byte[len];
        p[0] = 1;
        p[1] = ptype;
        Array.Copy(_srcMac, 0, p, 2, 6);
        Array.Copy(_dstMac, 0, p, 8, 6);
        p[14] = (byte)(_sesKey >> 8);
        p[15] = (byte)(_sesKey & 0xFF);
        p[16] = (byte)(counter >> 24);
        p[17] = (byte)(counter >> 16);
        p[18] = (byte)(counter >> 8);
        p[19] = (byte)(counter & 0xFF);
        if (payload is { Length: > 0 }) Array.Copy(payload, 0, p, 20, payload.Length);
        return p;
    }

    private static byte[] Control(byte cptype, byte[] data)
    {
        var p = new byte[9 + data.Length];
        Array.Copy(CpMagic, 0, p, 0, 4);
        p[4] = cptype;
        uint len = (uint)data.Length;
        p[5] = (byte)(len >> 24);
        p[6] = (byte)(len >> 16);
        p[7] = (byte)(len >> 8);
        p[8] = (byte)(len & 0xFF);
        if (data.Length > 0) Array.Copy(data, 0, p, 9, data.Length);
        return p;
    }

    private void SendToRouter(byte[] packet)
    {
        if (_sock is null) return;
        try
        {
            // Unicast to the device when we know its IP, otherwise broadcast so a
            // device with no IP can still be reached on the local segment.
            if (_targetIp is not null && IPAddress.TryParse(_targetIp, out var ip))
                _sock.SendTo(packet, new IPEndPoint(ip, MacTelnetPort));
            _sock.SendTo(packet, new IPEndPoint(IPAddress.Broadcast, MacTelnetPort));
            foreach (var b in DirectedBroadcasts())
                try { _sock.SendTo(packet, new IPEndPoint(b, MacTelnetPort)); } catch { }
        }
        catch { /* transient send failure — the retry loop will resend */ }
    }

    // ------------------------------------------------------------------
    // Terminal output plumbing
    // ------------------------------------------------------------------

    private void Feed(string text) => Feed(Encoding.UTF8.GetBytes(text), 0, -1);

    private void Feed(byte[] data, int offset, int count)
    {
        if (_exited) return;
        if (count < 0) count = data.Length - offset;
        if (count <= 0) return;
        var chunk = new byte[count];
        Array.Copy(data, offset, chunk, 0, count);
        try { _rxQueue.Add(chunk); } catch { /* queue closed */ }
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    private static byte[] LeU16(ushort v) => new[] { (byte)(v & 0xFF), (byte)(v >> 8) };

    private static byte[] Concat(params byte[][] parts)
    {
        var total = parts.Sum(p => p.Length);
        var r = new byte[total];
        int o = 0;
        foreach (var p in parts) { Array.Copy(p, 0, r, o, p.Length); o += p.Length; }
        return r;
    }

    private static byte[] ParseMac(string mac)
    {
        var hex = new string(mac.Where(Uri.IsHexDigit).ToArray());
        if (hex.Length != 12) throw new ArgumentException($"Invalid MAC address: {mac}");
        var b = new byte[6];
        for (int i = 0; i < 6; i++) b[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);
        return b;
    }

    private static string FormatMac(byte[] mac) => string.Join(":", mac.Select(b => b.ToString("X2")));

    /// <summary>Choose the local interface MAC to put in the packet header. Prefers
    /// the interface on the same subnet as <paramref name="targetIp"/> when known,
    /// otherwise the first up, non-loopback interface with a hardware address.</summary>
    private static byte[] PickSourceMac(string? targetIp)
    {
        NetworkInterface[] nics;
        try { nics = NetworkInterface.GetAllNetworkInterfaces(); }
        catch { return new byte[6]; }

        IPAddress? target = targetIp is not null && IPAddress.TryParse(targetIp, out var t) ? t : null;
        NetworkInterface? fallback = null;

        foreach (var nic in nics)
        {
            if (nic.OperationalStatus != OperationalStatus.Up) continue;
            if (nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            var phys = nic.GetPhysicalAddress().GetAddressBytes();
            if (phys.Length != 6 || phys.All(x => x == 0)) continue;

            IPInterfaceProperties props;
            try { props = nic.GetIPProperties(); }
            catch { continue; }
            var v4 = props.UnicastAddresses
                .FirstOrDefault(a => a.Address.AddressFamily == AddressFamily.InterNetwork);
            if (v4 is null) continue;

            fallback ??= nic;

            if (target is not null && v4.IPv4Mask is { } mask && SameSubnet(v4.Address, target, mask))
                return phys;
        }
        return fallback?.GetPhysicalAddress().GetAddressBytes() ?? new byte[6];
    }

    private static bool SameSubnet(IPAddress a, IPAddress b, IPAddress mask)
    {
        var ab = a.GetAddressBytes(); var bb = b.GetAddressBytes(); var mb = mask.GetAddressBytes();
        if (ab.Length != 4 || bb.Length != 4 || mb.Length != 4) return false;
        for (int i = 0; i < 4; i++)
            if ((ab[i] & mb[i]) != (bb[i] & mb[i])) return false;
        return true;
    }

    private static System.Collections.Generic.IEnumerable<IPAddress> DirectedBroadcasts()
    {
        NetworkInterface[] nics;
        NetworkInterface[] all;
        try { all = NetworkInterface.GetAllNetworkInterfaces(); }
        catch { yield break; }
        nics = all;
        foreach (var nic in nics)
        {
            if (nic.OperationalStatus != OperationalStatus.Up) continue;
            if (nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            IPInterfaceProperties props;
            try { props = nic.GetIPProperties(); }
            catch { continue; }
            foreach (var ua in props.UnicastAddresses)
            {
                if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                if (ua.IPv4Mask is not { } mask) continue;
                var ip = ua.Address.GetAddressBytes();
                var nm = mask.GetAddressBytes();
                if (ip.Length != 4 || nm.Length != 4) continue;
                var bc = new byte[4];
                for (int i = 0; i < 4; i++) bc[i] = (byte)(ip[i] | (~nm[i] & 0xFF));
                yield return new IPAddress(bc);
            }
        }
    }
}
