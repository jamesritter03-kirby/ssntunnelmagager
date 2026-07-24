using System;
using System.Reflection;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Markup.Xaml.MarkupExtensions;
using Avalonia.Media;
using RemoteStuff.Models;

namespace RemoteStuff.Views;

public partial class HelpWindow : Window
{
    public HelpWindow()
    {
        InitializeComponent();

        var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "1.0";
        if (this.FindControl<TextBlock>("VersionText") is { } v)
            v.Text = "Version " + version;

        if (this.FindControl<ListBox>("TopicList") is { } list)
        {
            list.ItemsSource = HelpContent.Articles;
            list.SelectionChanged += OnTopicChanged;
            if (HelpContent.Articles.Count > 0)
                list.SelectedIndex = 0;
        }
    }

    private void OnTopicChanged(object? sender, SelectionChangedEventArgs e)
    {
        if (this.FindControl<StackPanel>("ContentPanel") is not { } panel) return;
        panel.Children.Clear();
        if ((sender as ListBox)?.SelectedItem is not HelpArticle article) return;

        var title = new TextBlock
        {
            Text = article.Icon + "  " + article.Title,
            FontSize = 22,
            FontWeight = FontWeight.Bold,
            Margin = new Avalonia.Thickness(0, 0, 0, 8),
        };
        DynFg(title, "AppTextBrush");
        panel.Children.Add(title);

        foreach (var block in article.Blocks)
            RenderBlock(panel, block);
    }

    /// <summary>Bind a control's Foreground to a theme brush so Help text stays
    /// readable (and follows theme switches) instead of using baked-in colours.</summary>
    private static void DynFg(TextBlock tb, string key)
        => tb[!TextBlock.ForegroundProperty] = new DynamicResourceExtension(key);

    private static void RenderBlock(StackPanel panel, HelpBlock block)
    {
        switch (block)
        {
            case HelpParagraph p:
                panel.Children.Add(Body(p.Text));
                break;

            case HelpBullets b:
                foreach (var item in b.Items)
                    panel.Children.Add(Bullet("•", item));
                break;

            case HelpSteps s:
                var n = 1;
                foreach (var item in s.Items)
                    panel.Children.Add(Bullet((n++) + ".", item));
                break;

            case HelpTip t:
                var tipText = new TextBlock
                {
                    Text = "Tip: " + t.Text,
                    TextWrapping = TextWrapping.Wrap,
                };
                DynFg(tipText, "AppTipTextBrush");
                var tip = new Border
                {
                    BorderThickness = new Avalonia.Thickness(1),
                    CornerRadius = new Avalonia.CornerRadius(4),
                    Padding = new Avalonia.Thickness(10, 8),
                    Margin = new Avalonia.Thickness(0, 4, 0, 4),
                    Child = tipText,
                };
                tip[!Border.BackgroundProperty] = new DynamicResourceExtension("AppTipBackgroundBrush");
                tip[!Border.BorderBrushProperty] = new DynamicResourceExtension("AppTipBorderBrush");
                panel.Children.Add(tip);
                break;

            case HelpShortcuts sc:
                var grid = new Grid
                {
                    ColumnDefinitions = new ColumnDefinitions("180,*"),
                    Margin = new Avalonia.Thickness(0, 4, 0, 0),
                };
                var row = 0;
                foreach (var (keys, desc) in sc.Rows)
                {
                    grid.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
                    var k = new TextBlock
                    {
                        Text = keys,
                        FontFamily = new FontFamily("Menlo, Consolas, monospace"),
                        Margin = new Avalonia.Thickness(0, 3, 0, 3),
                    };
                    DynFg(k, "AppAccentBrush");
                    Grid.SetRow(k, row);
                    Grid.SetColumn(k, 0);
                    var d = new TextBlock
                    {
                        Text = desc,
                        TextWrapping = TextWrapping.Wrap,
                        Margin = new Avalonia.Thickness(0, 3, 0, 3),
                    };
                    DynFg(d, "AppTextBrush");
                    Grid.SetRow(d, row);
                    Grid.SetColumn(d, 1);
                    grid.Children.Add(k);
                    grid.Children.Add(d);
                    row++;
                }
                panel.Children.Add(grid);
                break;
        }
    }

    private static TextBlock Body(string text)
    {
        var tb = new TextBlock
        {
            Text = text,
            TextWrapping = TextWrapping.Wrap,
            LineHeight = 20,
        };
        DynFg(tb, "AppTextBrush");
        return tb;
    }

    private static Control Bullet(string marker, string text)
    {
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("24,*") };
        var m = new TextBlock
        {
            Text = marker,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        DynFg(m, "AppAccentBrush");
        Grid.SetColumn(m, 0);
        var t = new TextBlock
        {
            Text = text,
            TextWrapping = TextWrapping.Wrap,
        };
        DynFg(t, "AppTextBrush");
        Grid.SetColumn(t, 1);
        grid.Children.Add(m);
        grid.Children.Add(t);
        grid.Margin = new Avalonia.Thickness(8, 1, 0, 1);
        return grid;
    }
}
