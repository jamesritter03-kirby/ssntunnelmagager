using System;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using AvaloniaEdit;
using AvaloniaEdit.Document;

namespace RemoteStuff.Views.Controls;

/// <summary>
/// A VS Code–style document map: a scaled overview of the whole document drawn as
/// faint per-line text runs, with a draggable viewport box. Clicking or dragging
/// scrolls the attached <see cref="TextEditor"/>. AvaloniaEdit has no built-in
/// minimap, so this renders the overview itself and caches it to a bitmap.
/// </summary>
public sealed class Minimap : Control
{
    private const double MaxRowHeight = 3.0;   // px per line when the doc is short
    private const double AssumedColumns = 110; // columns mapped across the width

    public static readonly StyledProperty<IBrush?> LineBrushProperty =
        AvaloniaProperty.Register<Minimap, IBrush?>(nameof(LineBrush),
            new SolidColorBrush(Color.FromArgb(150, 160, 160, 170)));

    public static readonly StyledProperty<IBrush?> ViewportBrushProperty =
        AvaloniaProperty.Register<Minimap, IBrush?>(nameof(ViewportBrush),
            new SolidColorBrush(Color.FromArgb(40, 130, 170, 255)));

    public static readonly StyledProperty<IBrush?> ViewportBorderProperty =
        AvaloniaProperty.Register<Minimap, IBrush?>(nameof(ViewportBorder),
            new SolidColorBrush(Color.FromArgb(120, 130, 170, 255)));

    public static readonly StyledProperty<IBrush?> BackgroundProperty =
        AvaloniaProperty.Register<Minimap, IBrush?>(nameof(Background));

    public IBrush? Background { get => GetValue(BackgroundProperty); set => SetValue(BackgroundProperty, value); }

    public IBrush? LineBrush { get => GetValue(LineBrushProperty); set => SetValue(LineBrushProperty, value); }
    public IBrush? ViewportBrush { get => GetValue(ViewportBrushProperty); set => SetValue(ViewportBrushProperty, value); }
    public IBrush? ViewportBorder { get => GetValue(ViewportBorderProperty); set => SetValue(ViewportBorderProperty, value); }

    private TextEditor? _editor;
    private RenderTargetBitmap? _cache;
    private bool _contentDirty = true;
    private double _scaleY = 1.0;

    /// <summary>The editor this map mirrors. Setting it wires content/scroll updates.</summary>
    public TextEditor? Editor
    {
        get => _editor;
        set
        {
            if (ReferenceEquals(_editor, value)) return;
            Detach();
            _editor = value;
            Attach();
            _contentDirty = true;
            InvalidateVisual();
        }
    }

    private void Attach()
    {
        if (_editor is null) return;
        _editor.TextChanged += OnEditorChanged;
        _editor.TextArea.TextView.VisualLinesChanged += OnVisualLinesChanged;
    }

    private void Detach()
    {
        if (_editor is null) return;
        _editor.TextChanged -= OnEditorChanged;
        _editor.TextArea.TextView.VisualLinesChanged -= OnVisualLinesChanged;
    }

    /// <summary>Force a full redraw of the overview (e.g. after a theme change).</summary>
    public void Refresh()
    {
        _contentDirty = true;
        InvalidateVisual();
    }

    private void OnEditorChanged(object? sender, EventArgs e)
    {
        _contentDirty = true;
        InvalidateVisual();
    }

    private void OnVisualLinesChanged(object? sender, EventArgs e) => InvalidateVisual();

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        if (change.Property == BoundsProperty)
        {
            _contentDirty = true;
        }
        else if (change.Property == LineBrushProperty)
        {
            _contentDirty = true;
            InvalidateVisual();
        }
    }

    public override void Render(DrawingContext context)
    {
        base.Render(context);
        double w = Bounds.Width, h = Bounds.Height;
        if (Background is { } bg && w > 0 && h > 0)
            context.FillRectangle(bg, new Rect(0, 0, w, h));
        var doc = _editor?.Document;
        if (doc is null || w < 2 || h < 2) return;

        int lineCount = Math.Max(1, doc.LineCount);
        _scaleY = Math.Min(MaxRowHeight, h / lineCount);

        EnsureCache(doc, lineCount, (int)Math.Ceiling(w), (int)Math.Ceiling(h));
        if (_cache is not null)
            context.DrawImage(_cache, new Rect(0, 0, w, h));

        DrawViewport(context, lineCount, w);
    }

    private void EnsureCache(TextDocument doc, int lineCount, int pw, int ph)
    {
        if (!_contentDirty && _cache is not null
            && _cache.PixelSize.Width == pw && _cache.PixelSize.Height == ph)
            return;

        _cache?.Dispose();
        _cache = new RenderTargetBitmap(new PixelSize(Math.Max(1, pw), Math.Max(1, ph)), new Vector(96, 96));
        double w = pw;
        double colW = w / AssumedColumns;
        var brush = LineBrush ?? Brushes.Gray;

        using var ctx = _cache.CreateDrawingContext();
        for (int i = 1; i <= lineCount; i++)
        {
            var line = doc.GetLineByNumber(i);
            if (line.Length == 0) continue;
            double y = (i - 1) * _scaleY;
            double rh = Math.Max(0.6, _scaleY * 0.8);
            string text = doc.GetText(line.Offset, Math.Min(line.Length, (int)AssumedColumns + 20));

            // Draw each run of non-whitespace as a faint bar.
            int col = 0, runStart = -1;
            for (int c = 0; c <= text.Length; c++)
            {
                bool ws = c == text.Length || char.IsWhiteSpace(text[c]);
                if (!ws && runStart < 0) runStart = col;
                if (ws && runStart >= 0)
                {
                    double x0 = runStart * colW;
                    double rw = (col - runStart) * colW;
                    if (x0 < w)
                        ctx.FillRectangle(brush, new Rect(x0, y, Math.Min(rw, w - x0), rh));
                    runStart = -1;
                }
                if (c < text.Length)
                    col += text[c] == '\t' ? 4 : 1;
            }
        }
        _contentDirty = false;
    }

    private void DrawViewport(DrawingContext context, int lineCount, double w)
    {
        if (_editor is null) return;
        var vls = _editor.TextArea.TextView.VisualLines;
        int first = 1, last = lineCount;
        if (vls.Count > 0)
        {
            first = vls[0].FirstDocumentLine.LineNumber;
            last = vls[^1].LastDocumentLine.LineNumber;
        }
        double y1 = (first - 1) * _scaleY;
        double y2 = Math.Min(Bounds.Height, last * _scaleY);
        var rect = new Rect(0, y1, w, Math.Max(2, y2 - y1));
        context.FillRectangle(ViewportBrush ?? Brushes.Transparent, rect);
        var pen = new Pen(ViewportBorder ?? Brushes.Gray, 1);
        context.DrawRectangle(null, pen, rect);
    }

    // --- Navigation ---

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        e.Pointer.Capture(this);
        ScrollToPoint(e.GetPosition(this).Y);
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        if (e.GetCurrentPoint(this).Properties.IsLeftButtonPressed)
            ScrollToPoint(e.GetPosition(this).Y);
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);
        e.Pointer.Capture(null);
    }

    private void ScrollToPoint(double y)
    {
        var doc = _editor?.Document;
        if (doc is null || _scaleY <= 0) return;
        int line = (int)Math.Round(y / _scaleY) + 1;
        line = Math.Clamp(line, 1, doc.LineCount);
        _editor!.ScrollToLine(line);
    }
}
