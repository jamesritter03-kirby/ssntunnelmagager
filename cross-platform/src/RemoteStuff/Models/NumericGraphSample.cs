using System;
using System.Collections.Generic;

namespace RemoteStuff.Models;

/// <summary>One timestamped set of numeric readings feeding a live graph
/// (mirrors the macOS app's NumericGraphSample).</summary>
public sealed class NumericGraphSample
{
    public DateTime Time { get; }
    public IReadOnlyDictionary<string, double> Values { get; }

    public NumericGraphSample(DateTime time, IReadOnlyDictionary<string, double> values)
    {
        Time = time;
        Values = values;
    }
}
