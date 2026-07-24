using System;
using System.Threading.Tasks;
using Avalonia.Controls;
using Avalonia.Data;
using Avalonia.Layout;
using Avalonia.Markup.Xaml;
using RemoteStuff.Models;
using RemoteStuff.ViewModels;

namespace RemoteStuff.Views;

public partial class SpreadsheetTabView : UserControl
{
    private SpreadsheetTabViewModel? _vm;
    private DataGrid? _grid;
    private ComboBox? _delimiterBox;
    private bool _suppressDelimiter;

    public SpreadsheetTabView()
    {
        InitializeComponent();
        _grid = this.FindControl<DataGrid>("Grid");
        _delimiterBox = this.FindControl<ComboBox>("DelimiterBox");
        if (_grid != null)
            _grid.CellEditEnded += OnCellEditEnded;
        DataContextChanged += OnDataContextChanged;
    }

    private void InitializeComponent() => AvaloniaXamlLoader.Load(this);

    private void OnDataContextChanged(object? sender, EventArgs e)
    {
        if (_vm != null)
        {
            _vm.StructureChanged -= RebuildColumns;
            _vm.NameRequested -= PromptForName;
        }
        _vm = DataContext as SpreadsheetTabViewModel;
        if (_vm != null)
        {
            _vm.StructureChanged += RebuildColumns;
            _vm.NameRequested += PromptForName;
            RebuildColumns();
            SyncDelimiterSelection();
        }
    }

    private Task<string?> PromptForName(string title, string current)
    {
        if (TopLevel.GetTopLevel(this) is Window owner)
            return TextPromptWindow.ShowAsync(owner, title, current);
        return Task.FromResult<string?>(null);
    }

    private void RebuildColumns()
    {
        if (_grid is null || _vm is null) return;
        _grid.Columns.Clear();
        var doc = _vm.Document;
        for (var i = 0; i < doc.Columns.Count; i++)
        {
            var index = i;
            var col = new DataGridTextColumn
            {
                Header = BuildHeader(doc.Columns[i].Name, index),
                Binding = new Binding($"Cells[{index}]", BindingMode.TwoWay),
                Width = new DataGridLength(140)
            };
            _grid.Columns.Add(col);
        }
        SyncDelimiterSelection();
    }

    private Control BuildHeader(string name, int index)
    {
        var text = new TextBlock
        {
            Text = string.IsNullOrEmpty(name) ? SpreadsheetDocument.ColumnLetters(index) : name,
            VerticalAlignment = VerticalAlignment.Center
        };
        var menu = new ContextMenu();

        var sortAsc = new MenuItem { Header = "Sort Ascending" };
        sortAsc.Click += (_, _) => _vm?.SortByColumn(index, true);
        var sortDesc = new MenuItem { Header = "Sort Descending" };
        sortDesc.Click += (_, _) => _vm?.SortByColumn(index, false);
        var rename = new MenuItem { Header = "Rename Column…" };
        rename.Click += async (_, _) => await RenameColumnAsync(index, name);
        var insert = new MenuItem { Header = "Insert Column" };
        insert.Click += (_, _) =>
        {
            _vm?.Document.AddColumn(index: index);
            _vm?.OnCellEdited();
            RebuildColumns();
        };
        var delete = new MenuItem { Header = "Delete Column" };
        delete.Click += (_, _) =>
        {
            _vm?.Document.DeleteColumn(index);
            _vm?.OnCellEdited();
            RebuildColumns();
        };

        menu.Items.Add(sortAsc);
        menu.Items.Add(sortDesc);
        menu.Items.Add(new Separator());
        menu.Items.Add(rename);
        menu.Items.Add(insert);
        menu.Items.Add(delete);
        text.ContextMenu = menu;
        return text;
    }

    private async Task RenameColumnAsync(int index, string current)
    {
        if (TopLevel.GetTopLevel(this) is not Window owner) return;
        var name = await TextPromptWindow.ShowAsync(owner, "Rename Column", current);
        if (string.IsNullOrWhiteSpace(name)) return;
        _vm?.RenameColumn(index, name);
    }

    private void OnCellEditEnded(object? sender, DataGridCellEditEndedEventArgs e) => _vm?.OnCellEdited();

    private void SyncDelimiterSelection()
    {
        if (_delimiterBox is null || _vm is null) return;
        _suppressDelimiter = true;
        _delimiterBox.SelectedItem = _vm.CurrentDelimiter;
        _suppressDelimiter = false;
    }

    private void OnDelimiterChanged(object? sender, SelectionChangedEventArgs e)
    {
        if (_suppressDelimiter || _vm is null) return;
        if (_delimiterBox?.SelectedItem is SpreadsheetDocument.Delimiter d)
            _vm.SetDelimiter(d);
    }
}
