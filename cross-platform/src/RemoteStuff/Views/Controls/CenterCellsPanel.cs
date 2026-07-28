using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.ComponentModel;
using System.Linq;
using Avalonia;
using Avalonia.Controls;
using RemoteStuff.ViewModels;

namespace RemoteStuff.Views.Controls;

/// <summary>
/// Hosts every center tab's control at once. The selected tab fills the whole area; in
/// tiled mode all "visible" tabs share a uniform grid.
///
/// Crucially, non-selected tabs are NOT hidden with <c>IsVisible=false</c>: on macOS that
/// tears down a browser tab's native <c>WKWebView</c>, so returning to the tab forces a full
/// page reload (slow, and it drops the logged-in page — routers/webfig then ask for the
/// password again). Instead the non-selected cells are kept realized and parked far
/// off-screen, so their native web views stay alive: switching tabs is instant and web
/// sessions survive. Visibility is driven by <see cref="TabViewModel.IsCellVisible"/>.
/// </summary>
public sealed class CenterCellsPanel : Panel
{
    // Far enough that the parked native view is well outside any real window.
    private static readonly Point OffScreen = new(-1_000_000, -1_000_000);

    private readonly Dictionary<Control, INotifyPropertyChanged> _watched = new();

    public CenterCellsPanel()
    {
        Children.CollectionChanged += OnChildrenChanged;
    }

    private void OnChildrenChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        // Rewire the IsCellVisible watchers whenever the set of child cells changes.
        foreach (var kv in _watched) kv.Value.PropertyChanged -= OnCellPropertyChanged;
        _watched.Clear();
        foreach (var child in Children)
        {
            child.DataContextChanged -= OnChildDataContextChanged;
            child.DataContextChanged += OnChildDataContextChanged;
            if (child.DataContext is INotifyPropertyChanged inpc)
            {
                inpc.PropertyChanged += OnCellPropertyChanged;
                _watched[child] = inpc;
            }
        }
        InvalidateMeasure();
        InvalidateArrange();
    }

    private void OnChildDataContextChanged(object? sender, EventArgs e)
    {
        if (sender is not Control child) return;
        if (_watched.TryGetValue(child, out var old)) old.PropertyChanged -= OnCellPropertyChanged;
        if (child.DataContext is INotifyPropertyChanged inpc)
        {
            inpc.PropertyChanged += OnCellPropertyChanged;
            _watched[child] = inpc;
        }
        InvalidateMeasure();
        InvalidateArrange();
    }

    private void OnCellPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(TabViewModel.IsCellVisible))
        {
            InvalidateMeasure();
            InvalidateArrange();
        }
    }

    private static bool IsCellVisible(Control child)
        => child.DataContext is TabViewModel vm ? vm.IsCellVisible : child.IsVisible;

    protected override Size MeasureOverride(Size availableSize)
    {
        var visibleCount = Children.Count(IsCellVisible);
        if (visibleCount < 1) visibleCount = 1;
        var (cols, rows) = GridShape(visibleCount);
        var cell = new Size(
            double.IsInfinity(availableSize.Width) ? availableSize.Width : availableSize.Width / cols,
            double.IsInfinity(availableSize.Height) ? availableSize.Height : availableSize.Height / rows);

        // Non-visible cells are measured full-size (they are parked off-screen at full size so
        // they don't reflow when brought back on screen).
        foreach (var child in Children)
            child.Measure(IsCellVisible(child) ? cell : availableSize);

        return double.IsInfinity(availableSize.Width) || double.IsInfinity(availableSize.Height)
            ? default
            : availableSize;
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        var offRect = new Rect(OffScreen, finalSize);
        foreach (var child in Children)
            if (!IsCellVisible(child))
                child.Arrange(offRect);

        var visible = Children.Where(IsCellVisible).ToList();
        if (visible.Count == 0) return finalSize;
        if (visible.Count == 1)
        {
            visible[0].Arrange(new Rect(finalSize));
            return finalSize;
        }

        var (cols, rows) = GridShape(visible.Count);
        var cw = finalSize.Width / cols;
        var ch = finalSize.Height / rows;
        for (var i = 0; i < visible.Count; i++)
        {
            var r = i / cols;
            var c = i % cols;
            visible[i].Arrange(new Rect(c * cw, r * ch, cw, ch));
        }
        return finalSize;
    }

    private static (int cols, int rows) GridShape(int n)
    {
        var cols = (int)Math.Ceiling(Math.Sqrt(n));
        var rows = (int)Math.Ceiling((double)n / cols);
        return (cols, rows);
    }
}
