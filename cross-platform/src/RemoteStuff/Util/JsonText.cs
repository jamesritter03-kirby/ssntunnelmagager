using System.Collections.Generic;
using System.Text.Json;

namespace RemoteStuff.Util;

/// <summary>Helpers for pretty-printing payloads/values as JSON and for pulling
/// numeric fields out of JSON objects so telemetry can be graphed (mirrors the
/// macOS app's MQTT/Redis JSON handling).</summary>
public static class JsonText
{
    private static readonly JsonSerializerOptions PrettyOptions = new() { WriteIndented = true };

    /// <summary>Return <paramref name="raw"/> pretty-printed when it is valid JSON,
    /// otherwise return it unchanged (never throws).</summary>
    public static string Pretty(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return raw ?? "";
        try
        {
            using var doc = JsonDocument.Parse(raw);
            return JsonSerializer.Serialize(doc.RootElement, PrettyOptions);
        }
        catch
        {
            return raw;
        }
    }

    /// <summary>When <paramref name="raw"/> is a JSON object, collect its top-level
    /// numeric fields into <paramref name="into"/> (field name → value). Returns
    /// true if at least one numeric field was found.</summary>
    public static bool TryExtractNumericFields(string? raw, IDictionary<string, double> into)
    {
        if (string.IsNullOrWhiteSpace(raw)) return false;
        try
        {
            using var doc = JsonDocument.Parse(raw);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return false;
            var found = false;
            foreach (var prop in doc.RootElement.EnumerateObject())
            {
                if (prop.Value.ValueKind == JsonValueKind.Number && prop.Value.TryGetDouble(out var d))
                {
                    into[prop.Name] = d;
                    found = true;
                }
            }
            return found;
        }
        catch
        {
            return false;
        }
    }
}
