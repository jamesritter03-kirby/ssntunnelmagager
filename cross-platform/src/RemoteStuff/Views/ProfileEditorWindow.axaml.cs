using Avalonia.Controls;
using RemoteStuff.ViewModels;

namespace RemoteStuff.Views;

public partial class ProfileEditorWindow : Window
{
    public ProfileEditorWindow()
    {
        InitializeComponent();
        DataContextChanged += (_, _) =>
        {
            if (DataContext is ProfileEditorViewModel vm)
                vm.CloseRequested += Close;
        };
    }
}
