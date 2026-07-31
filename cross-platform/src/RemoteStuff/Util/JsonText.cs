using System.Collections.Generic;
using System.Globalization;
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

    /// <summary>Pull the numeric leaves out of a payload so a source can be graphed,
    /// mirroring the macOS app's MQTTClient.numericValues:
    /// a bare number ("23.5" → {"value":23.5}); a JSON object/array whose nested keys
    /// are flattened with '.' (array indices as [i], booleans → 1/0); or a number with
    /// a trailing unit ("1234 seconds", "21.5°C" → {"value":…}) via the leading number.
    /// Returns an empty dictionary when nothing finite &amp; numeric is found.</summary>
    public static Dictionary<string, double> NumericValues(string? raw)
    {
        var into = new Dictionary<string, double>();
        if (string.IsNullOrWhiteSpace(raw)) return into;

        var trimmed = raw.Trim();
        // Fast path: a lone scalar reading.
        if (double.TryParse(trimmed, NumberStyles.Float, CultureInfo.InvariantCulture, out var bare)
            && !double.IsNaN(bare) && !double.IsInfinity(bare))
        {
            into["value"] = bare;
            return into;
        }

        try
        {
            using var doc = JsonDocument.Parse(trimmed);
            FlattenNumeric(doc.RootElement, "", into);
            if (into.Count > 0) return into;
        }
        catch
        {
            // Not JSON — fall through to leading-number parse.
        }

        if (TryLeadingNumber(trimmed, out var lead))
            into["value"] = lead;
        return into;
    }

    private static void FlattenNumeric(JsonElement element, string prefix, IDictionary<string, double> into)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Number:
                if (element.TryGetDouble(out var d)) into[prefix.Length == 0 ? "value" : prefix] = d;
                break;
            case JsonValueKind.True:
                into[prefix.Length == 0 ? "value" : prefix] = 1;
                break;
            case JsonValueKind.False:
                into[prefix.Length == 0 ? "value" : prefix] = 0;
                break;
            case JsonValueKind.Object:
                foreach (var prop in element.EnumerateObject())
                    FlattenNumeric(prop.Value, prefix.Length == 0 ? prop.Name : prefix + "." + prop.Name, into);
                break;
            case JsonValueKind.Array:
                var i = 0;
                foreach (var item in element.EnumerateArray())
                    FlattenNumeric(item, prefix + "[" + i++ + "]", into);
                break;
        }
    }

    /// <summary>Parse the number at the very start of a string like "1234 seconds",
    /// "0.42 (…)", or "21.5°C". Returns false when it doesn't begin with a number.</summary>
    private static bool TryLeadingNumber(string text, out double value)
    {
        value = 0;
        var s = text.Trim();
        if (s.Length == 0) return false;
        var i = 0;
        if (s[i] is '+' or '-') i++;
        var seenDot = false;
        while (i < s.Length && (char.IsDigit(s[i]) || (s[i] == '.' && !seenDot)))
        {
            if (s[i] == '.') seenDot = true;
            i++;
        }
        var head = s.Substring(0, i);
        return double.TryParse(head, NumberStyles.Float, CultureInfo.InvariantCulture, out value)
               && !double.IsNaN(value) && !double.IsInfinity(value);
    }
}
