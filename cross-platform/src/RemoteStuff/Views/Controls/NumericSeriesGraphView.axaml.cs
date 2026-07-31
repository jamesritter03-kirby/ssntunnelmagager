using System;
using System.IO;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Markup.Xaml;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using RemoteStuff.ViewModels;

namespace RemoteStuff.Views.Controls;

/// <summary>Shared numeric graph panel (MQTT + Redis). The view hosts the chart and
/// chips; export (data + image) lives here because it needs a save dialog / clipboard
/// and the rendered visual.</summary>
public partial class NumericSeriesGraphView : UserControl
{
    public NumericSeriesGraphView()
    {
        InitializeComponent();
    }

    private void InitializeComponent() => AvaloniaXamlLoader.Load(this);

    private NumericGraphViewModel? Vm => DataContext as NumericGraphViewModel;

    private async void OnExportCsv(object? sender, RoutedEventArgs e)
    {
        try
        {
            if (Vm is not { } vm) return;
            await SaveTextAsync(vm.SanitizedName + "-history.csv", "csv", vm.BuildCsv());
        }
        catch { /* export cancelled or failed */ }
    }

    private async void OnExportJson(object? sender, RoutedEventArgs e)
    {
        try
        {
            if (Vm is not { } vm) return;
            await SaveTextAsync(vm.SanitizedName + "-history.json", "json", vm.BuildJson());
        }
        catch { /* export cancelled or failed */ }
    }

    private async void OnSaveImage(object? sender, RoutedEventArgs e)
    {
        try
        {
            if (Vm is not { } vm) return;
            if (RenderChart() is not { } bmp) return;
            using (bmp)
            {
                if (TopLevel.GetTopLevel(this)?.StorageProvider is not { } sp) return;
                var file = await sp.SaveFilePickerAsync(new FilePickerSaveOptions
                {
                    SuggestedFileName = vm.SanitizedName + ".png",
                    DefaultExtension = "png"
                });
                if (file is null) return;
                await using var stream = await file.OpenWriteAsync();
                bmp.Save(stream);
            }
        }
        catch { /* export cancelled or failed */ }
    }

    private async void OnCopyImage(object? sender, RoutedEventArgs e)
    {
        try
        {
            if (RenderChart() is not { } bmp) return;
            using (bmp)
            {
                if (TopLevel.GetTopLevel(this)?.Clipboard is not { } clipboard) return;
                using var ms = new MemoryStream();
                bmp.Save(ms);
                var bytes = ms.ToArray();
                var data = new DataObject();
                data.Set("public.png", bytes);   // macOS UTI
                data.Set("image/png", bytes);     // generic
                await clipboard.SetDataObjectAsync(data);
            }
        }
        catch { /* clipboard image not supported here */ }
    }

    /// <summary>Rasterize the chart surface for saving or copying.</summary>
    private RenderTargetBitmap? RenderChart()
    {
        var visual = this.FindControl<Border>("ChartExportRoot");
        if (visual is null) return null;
        var size = visual.Bounds.Size;
        if (size.Width < 4 || size.Height < 4) return null;
        var scale = 2.0;
        var pixel = new PixelSize(
            Math.Max(1, (int)Math.Ceiling(size.Width * scale)),
            Math.Max(1, (int)Math.Ceiling(size.Height * scale)));
        var bmp = new RenderTargetBitmap(pixel, new Vector(96 * scale, 96 * scale));
        bmp.Render(visual);
        return bmp;
    }

    private async Task SaveTextAsync(string suggestedName, string ext, string text)
    {
        if (TopLevel.GetTopLevel(this)?.StorageProvider is not { } sp) return;
        var file = await sp.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            SuggestedFileName = suggestedName,
            DefaultExtension = ext
        });
        if (file is null) return;
        await using var stream = await file.OpenWriteAsync();
        await using var writer = new StreamWriter(stream);
        await writer.WriteAsync(text);
    }
}
