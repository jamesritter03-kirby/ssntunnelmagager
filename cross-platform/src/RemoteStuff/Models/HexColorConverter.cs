using System;
using System.Globalization;
using Avalonia.Data.Converters;
using Avalonia.Media;

namespace RemoteStuff.Models;

/// <summary>
/// Converts a hex colour string (e.g. <c>#4C8BF5</c>) into a <see cref="IBrush"/>.
/// An empty or unparsable value yields a transparent brush.
/// </summary>
public sealed class HexColorConverter : IValueConverter
{
    public static readonly HexColorConverter Instance = new();

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is string s && !string.IsNullOrWhiteSpace(s) && Color.TryParse(s, out var c))
            return new SolidColorBrush(c);
        return Brushes.Transparent;
    }

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}
