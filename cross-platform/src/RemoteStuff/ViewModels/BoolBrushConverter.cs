using System;
using System.Globalization;
using Avalonia.Data.Converters;
using Avalonia.Media;

namespace RemoteStuff.ViewModels;

/// <summary>
/// Maps a boolean to a brush: <c>true</c> yields an accent fill, <c>false</c>
/// yields transparent. Used to highlight the current workspace pill.
/// </summary>
public sealed class BoolBrushConverter : IValueConverter
{
    public static readonly BoolBrushConverter Accent = new(new SolidColorBrush(Color.Parse("#0E639C")));

    private readonly IBrush _onTrue;

    private BoolBrushConverter(IBrush onTrue) => _onTrue = onTrue;

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => value is true ? _onTrue : Brushes.Transparent;

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}
