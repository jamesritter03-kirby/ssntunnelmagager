using System;
using Avalonia.Metadata;
using Avalonia.Markup.Xaml;

namespace RemoteStuff.Views.Controls;

/// <summary>
/// XAML markup extension that produces a <see cref="LineIcon"/>, e.g.
/// <c>Content="{controls:Icon file-plus}"</c> or
/// <c>Content="{controls:Icon Kind=trash-2, Size=18}"</c>.
/// </summary>
public sealed class IconExtension : MarkupExtension
{
    public IconExtension() { }

    public IconExtension(string kind) => Kind = kind;

    [ConstructorArgument("kind")]
    public string? Kind { get; set; }

    /// <summary>Square edge length in device-independent pixels (default 16).</summary>
    public double Size { get; set; } = 16;

    public override object ProvideValue(IServiceProvider serviceProvider) =>
        new LineIcon { Kind = Kind, Width = Size, Height = Size };
}
