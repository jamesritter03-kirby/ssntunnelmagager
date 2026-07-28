using System;
using System.Collections.Concurrent;
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Documents;
using Avalonia.Media;

namespace RemoteStuff.Views.Controls;

/// <summary>
/// Renders a monochrome line icon by name (see <see cref="AppIcons"/>), matching the
/// macOS app's SF-Symbol look. Unknown names — including raw emoji or user-picked
/// glyphs — fall back to being drawn as centered text, so it is a safe drop-in
/// replacement anywhere a glyph <c>TextBlock</c> or emoji button content was used.
/// The icon colour follows the inherited <c>Foreground</c>.
/// </summary>
public sealed class LineIcon : Control
{
    private static readonly ConcurrentDictionary<string, Geometry?> GeoCache = new();

    public static readonly StyledProperty<string?> KindProperty =
        AvaloniaProperty.Register<LineIcon, string?>(nameof(Kind));

    public static readonly StyledProperty<IBrush?> ForegroundProperty =
        TextElement.ForegroundProperty.AddOwner<LineIcon>();

    public static readonly StyledProperty<double> StrokeWidthProperty =
        AvaloniaProperty.Register<LineIcon, double>(nameof(StrokeWidth), 2.0);

    static LineIcon()
    {
        AffectsRender<LineIcon>(KindProperty, ForegroundProperty, StrokeWidthProperty);
        AffectsMeasure<LineIcon>(KindProperty);
    }

    public string? Kind
    {
        get => GetValue(KindProperty);
        set => SetValue(KindProperty, value);
    }

    public IBrush? Foreground
    {
        get => GetValue(ForegroundProperty);
        set => SetValue(ForegroundProperty, value);
    }

    public double StrokeWidth
    {
        get => GetValue(StrokeWidthProperty);
        set => SetValue(StrokeWidthProperty, value);
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        static double Pick(double v) => double.IsInfinity(v) || v <= 0 ? 16 : v;
        var s = Math.Min(Pick(availableSize.Width), Pick(availableSize.Height));
        return new Size(s, s);
    }

    public override void Render(DrawingContext context)
    {
        var kind = Kind;
        if (string.IsNullOrEmpty(kind)) return;

        var brush = Foreground ?? Brushes.Black;
        var size = Math.Min(Bounds.Width, Bounds.Height);
        if (size <= 0) return;

        var geometry = GetGeometry(kind);
        if (geometry is not null)
        {
            var scale = size / 24.0;
            var pen = new Pen(brush, StrokeWidth)
            {
                LineCap = PenLineCap.Round,
                LineJoin = PenLineJoin.Round,
            };
            var offsetX = (Bounds.Width - 24 * scale) / 2;
            var offsetY = (Bounds.Height - 24 * scale) / 2;
            using (context.PushTransform(Matrix.CreateScale(scale, scale) * Matrix.CreateTranslation(offsetX, offsetY)))
                context.DrawGeometry(null, pen, geometry);
            return;
        }

        // Fallback: draw the raw glyph/emoji as centered text.
        var text = new FormattedText(kind, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
            Typeface.Default, size, brush);
        var origin = new Point((Bounds.Width - text.Width) / 2, (Bounds.Height - text.Height) / 2);
        context.DrawText(text, origin);
    }

    private static Geometry? GetGeometry(string kind) => GeoCache.GetOrAdd(kind, static k =>
    {
        var data = AppIcons.Resolve(k);
        if (string.IsNullOrEmpty(data)) return null;
        try { return Geometry.Parse(data); }
        catch { return null; }
    });
}
