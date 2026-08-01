using System;
using System.Collections.Generic;
using System.Linq;
using Avalonia;
using Avalonia.Media;
using AvaloniaEdit.CodeCompletion;
using AvaloniaEdit.Document;
using AvaloniaEdit.Editing;
using AvaloniaEdit.Folding;
using AvaloniaEdit.Rendering;

namespace RemoteStuff.Views;

/// <summary>A minimal <see cref="ISegment"/> for geometry queries.</summary>
internal readonly struct SimpleSeg : ISegment
{
    public SimpleSeg(int offset, int length) { Offset = offset; Length = length; }
    public int Offset { get; }
    public int Length { get; }
    public int EndOffset => Offset + Length;
}

/// <summary>Which side of an edit a change-history mark represents.</summary>
internal enum ChangeKind { Modified, Saved }

/// <summary>Builds fold regions for brace/bracket languages (JSON and C-like).
/// XML/HTML use AvaloniaEdit's built-in <see cref="XmlFoldingStrategy"/> instead.</summary>
internal static class BraceFoldingStrategy
{
    public static List<NewFolding> CreateFoldings(TextDocument document)
    {
        var foldings = new List<NewFolding>();
        AddForPair(document, foldings, '{', '}');
        AddForPair(document, foldings, '[', ']');
        foldings.Sort((a, b) => a.StartOffset.CompareTo(b.StartOffset));
        return foldings;
    }

    private static void AddForPair(TextDocument document, List<NewFolding> foldings, char open, char close)
    {
        var stack = new Stack<int>();
        for (int i = 0; i < document.TextLength; i++)
        {
            char c = document.GetCharAt(i);
            if (c == open) stack.Push(i);
            else if (c == close && stack.Count > 0)
            {
                int start = stack.Pop();
                // Only fold when the block spans more than one line.
                if (document.GetLineByOffset(start).LineNumber != document.GetLineByOffset(i).LineNumber)
                    foldings.Add(new NewFolding(start, i + 1));
            }
        }
    }
}

/// <summary>Draws faint vertical guides at each indentation level.</summary>
internal sealed class IndentGuideRenderer : IBackgroundRenderer
{
    private readonly Func<bool> _enabled;
    private readonly int _indentSize;
    private readonly Pen _pen;

    public IndentGuideRenderer(Func<bool> enabled, int indentSize = 4)
    {
        _enabled = enabled;
        _indentSize = Math.Max(1, indentSize);
        _pen = new Pen(new SolidColorBrush(Color.FromArgb(60, 128, 128, 128)), 1);
    }

    public KnownLayer Layer => KnownLayer.Background;

    public void Draw(TextView textView, DrawingContext drawingContext)
    {
        if (!_enabled() || !textView.VisualLinesValid) return;
        double spaceWidth = textView.WideSpaceWidth;
        if (spaceWidth <= 0) return;

        foreach (var visualLine in textView.VisualLines)
        {
            var docLine = visualLine.FirstDocumentLine;
            var text = textView.Document.GetText(docLine.Offset, docLine.Length);
            int indentColumns = LeadingColumns(text);
            if (indentColumns <= 0) continue;

            var lineRects = BackgroundGeometryBuilder
                .GetRectsForSegment(textView, new SimpleSeg(docLine.Offset, docLine.Length)).ToList();
            if (lineRects.Count == 0) continue;
            double top = lineRects.Min(r => r.Top);
            double bottom = lineRects.Max(r => r.Bottom);

            var originRects = BackgroundGeometryBuilder
                .GetRectsForSegment(textView, new SimpleSeg(docLine.Offset, 0)).ToList();
            double originX = originRects.Count > 0 ? originRects[0].Left : 0;

            for (int col = _indentSize; col < indentColumns; col += _indentSize)
            {
                double x = Math.Round(originX + col * spaceWidth) + 0.5;
                drawingContext.DrawLine(_pen, new Point(x, top), new Point(x, bottom));
            }
        }
    }

    private int LeadingColumns(string text)
    {
        int cols = 0;
        foreach (char c in text)
        {
            if (c == ' ') cols++;
            else if (c == '\t') cols += _indentSize - (cols % _indentSize);
            else break;
        }
        return cols;
    }
}

/// <summary>Highlights bookmarked lines and draws a marker strip at the left edge.</summary>
internal sealed class BookmarkRenderer : IBackgroundRenderer
{
    private readonly Func<bool> _enabled;
    private readonly ISet<int> _lines;
    private readonly IBrush _fill = new SolidColorBrush(Color.FromArgb(28, 90, 160, 255));
    private readonly IBrush _marker = new SolidColorBrush(Color.FromArgb(220, 70, 140, 245));

    public BookmarkRenderer(Func<bool> enabled, ISet<int> bookmarkLines)
    {
        _enabled = enabled;
        _lines = bookmarkLines;
    }

    public KnownLayer Layer => KnownLayer.Background;

    public void Draw(TextView textView, DrawingContext drawingContext)
    {
        if (!_enabled() || _lines.Count == 0 || !textView.VisualLinesValid) return;
        foreach (var visualLine in textView.VisualLines)
        {
            int lineNumber = visualLine.FirstDocumentLine.LineNumber;
            if (!_lines.Contains(lineNumber)) continue;
            var docLine = visualLine.FirstDocumentLine;
            foreach (var rect in BackgroundGeometryBuilder.GetRectsForSegment(
                         textView, new SimpleSeg(docLine.Offset, docLine.Length)))
            {
                var full = new Rect(0, rect.Top, textView.Bounds.Width, rect.Height);
                drawingContext.FillRectangle(_fill, full);
                drawingContext.FillRectangle(_marker, new Rect(0, rect.Top, 3, rect.Height));
            }
        }
    }
}

/// <summary>Git-style change strip: a coloured bar at the far left of edited/saved lines.</summary>
internal sealed class ChangeHistoryRenderer : IBackgroundRenderer
{
    private readonly Func<bool> _enabled;
    private readonly IDictionary<int, ChangeKind> _lines;
    private readonly IBrush _modified = new SolidColorBrush(Color.FromArgb(230, 210, 150, 40));
    private readonly IBrush _saved = new SolidColorBrush(Color.FromArgb(230, 70, 160, 90));

    public ChangeHistoryRenderer(Func<bool> enabled, IDictionary<int, ChangeKind> changedLines)
    {
        _enabled = enabled;
        _lines = changedLines;
    }

    public KnownLayer Layer => KnownLayer.Background;

    public void Draw(TextView textView, DrawingContext drawingContext)
    {
        if (!_enabled() || _lines.Count == 0 || !textView.VisualLinesValid) return;
        foreach (var visualLine in textView.VisualLines)
        {
            int lineNumber = visualLine.FirstDocumentLine.LineNumber;
            if (!_lines.TryGetValue(lineNumber, out var kind)) continue;
            var docLine = visualLine.FirstDocumentLine;
            var brush = kind == ChangeKind.Saved ? _saved : _modified;
            foreach (var rect in BackgroundGeometryBuilder.GetRectsForSegment(
                         textView, new SimpleSeg(docLine.Offset, docLine.Length)))
                drawingContext.FillRectangle(brush, new Rect(0, rect.Top, 2, rect.Height));
        }
    }
}

/// <summary>One word suggestion in the "Complete word" popup.</summary>
internal sealed class WordCompletionData : ICompletionData
{
    public WordCompletionData(string text) { Text = text; }

    public IImage? Image => null;
    public string Text { get; }
    public object Content => Text;
    public object Description => Text;
    public double Priority => 0;

    public void Complete(TextArea textArea, ISegment completionSegment, EventArgs insertionRequestEventArgs)
        => textArea.Document.Replace(completionSegment, Text);
}
