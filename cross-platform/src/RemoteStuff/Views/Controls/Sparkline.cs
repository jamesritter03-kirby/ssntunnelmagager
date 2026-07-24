using System.Collections.Generic;
using System.Collections.Specialized;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace RemoteStuff.Views.Controls;

/// <summary>A tiny live line chart that plots a rolling series of values across its
/// bounds. Used by the workspace Connection Health dialog to show latency history.
/// Negative values (a failed probe) are treated as the series minimum so a dropout
/// dips the line to the baseline instead of skewing the scale.</summary>
public sealed class Sparkline : Control
{
    public static readonly StyledProperty<IReadOnlyList<double>?> ValuesProperty =
        AvaloniaProperty.Register<Sparkline, IReadOnlyList<double>?>(nameof(Values));

    public static readonly StyledProperty<IBrush> StrokeProperty =
        AvaloniaProperty.Register<Sparkline, IBrush>(nameof(Stroke), Brushes.DeepSkyBlue);

    public static readonly StyledProperty<double> StrokeThicknessProperty =
        AvaloniaProperty.Register<Sparkline, double>(nameof(StrokeThickness), 1.5);

    public static readonly StyledProperty<IBrush?> FillProperty =
        AvaloniaProperty.Register<Sparkline, IBrush?>(nameof(Fill));

    static Sparkline()
    {
        AffectsRender<Sparkline>(ValuesProperty, StrokeProperty, StrokeThicknessProperty, FillProperty);
    }

    public IReadOnlyList<double>? Values
    {
        get => GetValue(ValuesProperty);
        set => SetValue(ValuesProperty, value);
    }

    public IBrush Stroke
    {
        get => GetValue(StrokeProperty);
        set => SetValue(StrokeProperty, value);
    }

    public double StrokeThickness
    {
        get => GetValue(StrokeThicknessProperty);
        set => SetValue(StrokeThicknessProperty, value);
    }

    public IBrush? Fill
    {
        get => GetValue(FillProperty);
        set => SetValue(FillProperty, value);
    }

    private INotifyCollectionChanged? _observed;

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        if (change.Property != ValuesProperty) return;

        if (_observed is not null)
            _observed.CollectionChanged -= OnCollectionChanged;
        _observed = change.GetNewValue<IReadOnlyList<double>?>() as INotifyCollectionChanged;
        if (_observed is not null)
            _observed.CollectionChanged += OnCollectionChanged;
        InvalidateVisual();
    }

    private void OnCollectionChanged(object? sender, NotifyCollectionChangedEventArgs e) => InvalidateVisual();

    public override void Render(DrawingContext ctx)
    {
        base.Render(ctx);
        var vals = Values;
        double w = Bounds.Width, h = Bounds.Height;
        if (vals is null || vals.Count < 2 || w <= 2 || h <= 2) return;

        double min = double.MaxValue, max = double.MinValue;
        foreach (var v in vals)
        {
            var u = v < 0 ? 0 : v;
            if (u < min) min = u;
            if (u > max) max = u;
        }
        if (min < 0) min = 0;
        if (max <= min) max = min + 1;
        var range = max - min;

        const double pad = 2.0;
        var plotW = w - pad * 2;
        var plotH = h - pad * 2;
        var n = vals.Count;

        var pts = new Point[n];
        for (var i = 0; i < n; i++)
        {
            var v = vals[i] < 0 ? min : vals[i];
            var x = pad + plotW * i / (n - 1);
            var y = pad + plotH * (1 - (v - min) / range);
            pts[i] = new Point(x, y);
        }

        if (Fill is { } fill)
        {
            var fillGeo = new StreamGeometry();
            using (var g = fillGeo.Open())
            {
                g.BeginFigure(new Point(pts[0].X, h - pad), true);
                g.LineTo(pts[0]);
                for (var i = 1; i < n; i++) g.LineTo(pts[i]);
                g.LineTo(new Point(pts[n - 1].X, h - pad));
                g.EndFigure(true);
            }
            ctx.DrawGeometry(fill, null, fillGeo);
        }

        var lineGeo = new StreamGeometry();
        using (var g = lineGeo.Open())
        {
            g.BeginFigure(pts[0], false);
            for (var i = 1; i < n; i++) g.LineTo(pts[i]);
            g.EndFigure(false);
        }
        ctx.DrawGeometry(null, new Pen(Stroke, StrokeThickness), lineGeo);
    }
}
