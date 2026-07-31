using System;
using System.Collections.Generic;
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace RemoteStuff.Views.Controls;

/// <summary>One (time, value) reading in a plotted series.</summary>
public readonly record struct GraphPoint(DateTime Time, double Value);

/// <summary>A named, coloured line of points to draw on a <see cref="MultiLineChart"/>.</summary>
public sealed class GraphSeries
{
    public string Name { get; }
    public IBrush Color { get; }
    public IReadOnlyList<GraphPoint> Points { get; }

    public GraphSeries(string name, IBrush color, IReadOnlyList<GraphPoint> points)
    {
        Name = name;
        Color = color;
        Points = points;
    }
}

/// <summary>One stacked pane: a single series rendered in its own auto-scaled chart.</summary>
public sealed class GraphPane
{
    public string Name { get; }
    public IBrush Color { get; }
    public IReadOnlyList<GraphSeries> Series { get; }

    public GraphPane(string name, GraphSeries series)
    {
        Name = name;
        Color = series.Color;
        Series = new[] { series };
    }
}

/// <summary>A lightweight multi-series time/line chart (no external chart library).
/// Draws each series as a coloured polyline over a shared, padded value axis with a
/// time X-axis. Used by the MQTT and Redis graph panels to mirror the macOS app's
/// NumericSeriesGraph.</summary>
public sealed class MultiLineChart : Control
{
    public static readonly StyledProperty<IReadOnlyList<GraphSeries>?> SeriesProperty =
        AvaloniaProperty.Register<MultiLineChart, IReadOnlyList<GraphSeries>?>(nameof(Series));

    public static readonly StyledProperty<IBrush> AxisBrushProperty =
        AvaloniaProperty.Register<MultiLineChart, IBrush>(nameof(AxisBrush),
            new SolidColorBrush(Color.FromArgb(0x66, 0x88, 0x88, 0x88)));

    public static readonly StyledProperty<IBrush> LabelBrushProperty =
        AvaloniaProperty.Register<MultiLineChart, IBrush>(nameof(LabelBrush),
            new SolidColorBrush(Color.FromRgb(0x99, 0x99, 0x99)));

    static MultiLineChart()
    {
        AffectsRender<MultiLineChart>(SeriesProperty, AxisBrushProperty, LabelBrushProperty);
    }

    public IReadOnlyList<GraphSeries>? Series
    {
        get => GetValue(SeriesProperty);
        set => SetValue(SeriesProperty, value);
    }

    public IBrush AxisBrush
    {
        get => GetValue(AxisBrushProperty);
        set => SetValue(AxisBrushProperty, value);
    }

    public IBrush LabelBrush
    {
        get => GetValue(LabelBrushProperty);
        set => SetValue(LabelBrushProperty, value);
    }

    public override void Render(DrawingContext ctx)
    {
        base.Render(ctx);
        var series = Series;
        double w = Bounds.Width, h = Bounds.Height;
        if (series is null || series.Count == 0 || w <= 12 || h <= 12) return;

        double vMin = double.MaxValue, vMax = double.MinValue;
        long tMin = long.MaxValue, tMax = long.MinValue;
        var total = 0;
        foreach (var s in series)
            foreach (var p in s.Points)
            {
                total++;
                if (p.Value < vMin) vMin = p.Value;
                if (p.Value > vMax) vMax = p.Value;
                var t = p.Time.Ticks;
                if (t < tMin) tMin = t;
                if (t > tMax) tMax = t;
            }
        if (total == 0) return;

        // Pad the value domain so a flat/constant series still draws visibly.
        if (Math.Abs(vMax - vMin) < 1e-9)
        {
            var pad = Math.Max(Math.Abs(vMin) * 0.05, 0.5);
            vMin -= pad;
            vMax += pad;
        }
        else
        {
            var pad = (vMax - vMin) * 0.08;
            vMin -= pad;
            vMax += pad;
        }
        var vRange = vMax - vMin;
        double tRange = Math.Max(1, tMax - tMin);

        const double left = 46, right = 10, top = 8, bottom = 8;
        var plotW = w - left - right;
        var plotH = h - top - bottom;
        if (plotW <= 4 || plotH <= 4) return;

        var axisPen = new Pen(AxisBrush, 1);
        ctx.DrawLine(axisPen, new Point(left, top), new Point(left, top + plotH));
        ctx.DrawLine(axisPen, new Point(left, top + plotH), new Point(left + plotW, top + plotH));

        var tf = new Typeface(FontFamily.Default);
        void YLabel(double val, double y)
        {
            var text = val.ToString("0.##", CultureInfo.InvariantCulture);
            var ft = new FormattedText(text, CultureInfo.InvariantCulture,
                FlowDirection.LeftToRight, tf, 10, LabelBrush);
            ctx.DrawText(ft, new Point(left - 6 - ft.Width, y - ft.Height / 2));
        }
        YLabel(vMax, top);
        YLabel(vMin, top + plotH);
        if (vRange > 1e-9)
        {
            var midY = top + plotH / 2;
            ctx.DrawLine(new Pen(AxisBrush, 0.5), new Point(left, midY), new Point(left + plotW, midY));
            YLabel(vMin + vRange / 2, midY);
        }

        double X(long ticks) => left + plotW * (ticks - tMin) / tRange;
        double Y(double v) => top + plotH * (1 - (v - vMin) / vRange);

        var showDots = total <= 60;
        foreach (var s in series)
        {
            if (s.Points.Count == 0) continue;
            if (s.Points.Count == 1)
            {
                var p = s.Points[0];
                ctx.DrawEllipse(s.Color, null, new Point(X(p.Time.Ticks), Y(p.Value)), 2.5, 2.5);
                continue;
            }
            var pen = new Pen(s.Color, 1.6, lineCap: PenLineCap.Round, lineJoin: PenLineJoin.Round);
            var geo = new StreamGeometry();
            using (var g = geo.Open())
            {
                g.BeginFigure(new Point(X(s.Points[0].Time.Ticks), Y(s.Points[0].Value)), false);
                for (var i = 1; i < s.Points.Count; i++)
                    g.LineTo(new Point(X(s.Points[i].Time.Ticks), Y(s.Points[i].Value)));
                g.EndFigure(false);
            }
            ctx.DrawGeometry(null, pen, geo);
            if (showDots)
                foreach (var p in s.Points)
                    ctx.DrawEllipse(s.Color, null, new Point(X(p.Time.Ticks), Y(p.Value)), 2, 2);
        }
    }
}
