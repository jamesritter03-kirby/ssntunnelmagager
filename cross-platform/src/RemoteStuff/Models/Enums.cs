using System.Text.Json.Serialization;

namespace RemoteStuff.Models;

/// <summary>Which edge a session tab is docked to (Center = the main tab area).</summary>
public enum DockSide
{
    Center,
    Left,
    Right,
    Top,
    Bottom
}

/// <summary>How a profile launches relative to workspaces.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<WorkspaceLaunch>))]
public enum WorkspaceLaunch
{
    /// <summary>Open tabs in the current workspace / tab area.</summary>
    Current,
    /// <summary>Open in a new dedicated workspace named after the profile.</summary>
    NewWorkspace
}

/// <summary>Live tunnel-health for a profile's forwards, driving the sidebar dot.</summary>
public enum TunnelHealth
{
    /// <summary>Not probed yet, or the profile has no local forwards.</summary>
    Unknown,
    /// <summary>Every local forward answered on its last probe.</summary>
    Healthy,
    /// <summary>At least one local forward stopped answering.</summary>
    Degraded
}

/// <summary>The connection state of a VNC console tab.</summary>
public enum VncPhase
{
    /// <summary>Not started yet.</summary>
    Idle,
    /// <summary>Opening the SSH tunnel / waiting for the local listener.</summary>
    Connecting,
    /// <summary>The tunnel (or direct target) is ready to view.</summary>
    Connected,
    /// <summary>The tunnel failed to open.</summary>
    Failed,
    /// <summary>The tunnel was closed / disconnected.</summary>
    Ended
}

/// <summary>The kind of SSH port forwarding.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<ForwardType>))]
public enum ForwardType
{
    Local,
    Remote,
    Dynamic
}

public static class ForwardTypeExtensions
{
    /// <summary>The <c>ssh</c> command-line flag for this forward type.</summary>
    public static string Flag(this ForwardType type) => type switch
    {
        ForwardType.Local => "-L",
        ForwardType.Remote => "-R",
        ForwardType.Dynamic => "-D",
        _ => "-L"
    };

    public static string Title(this ForwardType type) => type switch
    {
        ForwardType.Local => "Local  ·  -L",
        ForwardType.Remote => "Remote  ·  -R",
        ForwardType.Dynamic => "Dynamic / SOCKS  ·  -D",
        _ => "Local"
    };

    public static string Explanation(this ForwardType type) => type switch
    {
        ForwardType.Local =>
            "Opens a port on THIS machine and forwards it through the server to a target reachable from the server. (e.g. reach a remote database locally)",
        ForwardType.Remote =>
            "Opens a port on the SERVER and forwards it back to a target reachable from this machine. (e.g. expose a local service to the server)",
        ForwardType.Dynamic =>
            "Runs a SOCKS proxy on this machine; apps pointed at it route their traffic through the server.",
        _ => ""
    };
}

/// <summary>
/// What a (local) port forward exposes, so the app can offer a matching "Open" action.
/// Purely a convenience layer over a normal <c>-L</c> forward.
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter<ForwardCategory>))]
public enum ForwardCategory
{
    None,
    Webpage,
    Mqtt,
    Redis
}

public static class ForwardCategoryExtensions
{
    public static string Title(this ForwardCategory c) => c switch
    {
        ForwardCategory.None => "None",
        ForwardCategory.Webpage => "Web Page",
        ForwardCategory.Mqtt => "MQTT",
        ForwardCategory.Redis => "Redis",
        _ => "None"
    };

    public static bool IsLaunchable(this ForwardCategory c) => c != ForwardCategory.None;

    public static int DefaultPort(this ForwardCategory c) => c switch
    {
        ForwardCategory.Webpage => 8080,
        ForwardCategory.Mqtt => 1883,
        ForwardCategory.Redis => 6379,
        _ => 0
    };
}

/// <summary>How <c>ssh</c> verifies the server's host key when connecting.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<StrictHostKeyChecking>))]
public enum StrictHostKeyChecking
{
    /// <summary>ssh's own default: prompt to confirm a new host, refuse a changed one.</summary>
    Ask,
    /// <summary>Trust an unseen host automatically, still refuse a changed key.</summary>
    AcceptNew,
    /// <summary>Refuse to connect unless the host key is already known.</summary>
    Yes,
    /// <summary>Disable host-key checking entirely (insecure).</summary>
    No
}

public static class StrictHostKeyCheckingExtensions
{
    public static string Title(this StrictHostKeyChecking s) => s switch
    {
        StrictHostKeyChecking.Ask => "Ask (default)",
        StrictHostKeyChecking.AcceptNew => "Accept new hosts automatically",
        StrictHostKeyChecking.Yes => "Refuse unknown hosts",
        StrictHostKeyChecking.No => "Disable checking (insecure)",
        _ => "Ask (default)"
    };

    /// <summary>The value for <c>-o StrictHostKeyChecking=…</c>, or null to leave ssh's default.</summary>
    public static string? OptionValue(this StrictHostKeyChecking s) => s switch
    {
        StrictHostKeyChecking.AcceptNew => "accept-new",
        StrictHostKeyChecking.Yes => "yes",
        StrictHostKeyChecking.No => "no",
        _ => null
    };
}
