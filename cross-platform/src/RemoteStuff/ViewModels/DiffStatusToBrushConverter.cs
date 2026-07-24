using System;
using System.Globalization;
using Avalonia.Data.Converters;
using Avalonia.Media;
using RemoteStuff.Services;

namespace RemoteStuff.ViewModels;

/// <summary>Maps a <see cref="DiffRowStatus"/> to the row background brush used in
/// the side-by-side compare view (added/deleted/changed tinting; filler dimmed).</summary>
public sealed class DiffStatusToBrushConverter : IValueConverter
{
    public static readonly DiffStatusToBrushConverter Instance = new();

    private static readonly IBrush Added = new SolidColorBrush(Color.Parse("#1E3A24"));
    private static readonly IBrush Deleted = new SolidColorBrush(Color.Parse("#3A1F1F"));
    private static readonly IBrush Changed = new SolidColorBrush(Color.Parse("#3A3016"));
    private static readonly IBrush Filler = new SolidColorBrush(Color.Parse("#181818"));

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => value switch
        {
            DiffRowStatus.Added => Added,
            DiffRowStatus.Deleted => Deleted,
            DiffRowStatus.Changed => Changed,
            DiffRowStatus.Filler => Filler,
            _ => Brushes.Transparent,
        };

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}
