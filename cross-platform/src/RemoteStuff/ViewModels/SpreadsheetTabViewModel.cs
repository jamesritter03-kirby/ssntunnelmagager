using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RemoteStuff.Models;
using RemoteStuff.Services;

namespace RemoteStuff.ViewModels;

/// <summary>
/// A spreadsheet tab: opens/edits/saves CSV, TSV and Excel (.xlsx) files in an
/// editable grid. Wraps <see cref="SpreadsheetDocument"/> and exposes the
/// toolbar commands. Ported from the macOS SpreadsheetTabView.
/// </summary>
public sealed partial class SpreadsheetTabViewModel : TabViewModel
{
    public SpreadsheetDocument Document { get; } = new();

    public override string Glyph => "▦";

    /// <summary>Raised when columns/rows are rebuilt so the view regenerates its grid columns.</summary>
    public event Action? StructureChanged;

    /// <summary>Prompt for a worksheet name (wired by the view). Returns null on cancel.</summary>
    public Func<string, string, Task<string?>>? NameRequested;

    /// <summary>The live rows shown in the grid (mirrors Document.Rows).</summary>
    public ObservableCollection<SpreadsheetDocument.Row> GridRows { get; } = new();

    public ObservableCollection<string> Sheets { get; } = new();

    [ObservableProperty] private bool _isDirty;
    [ObservableProperty] private string _statusText = "";
    [ObservableProperty] private int _selectedRowIndex = -1;
    [ObservableProperty] private int _activeSheetIndex;

    public bool IsExcel => Document.IsExcel;
    public bool HasHeaderRow => Document.HasHeaderRow;
    public SpreadsheetDocument.Delimiter CurrentDelimiter => Document.CurrentDelimiter;

    public IReadOnlyList<SpreadsheetDocument.Delimiter> Delimiters { get; } =
        Enum.GetValues(typeof(SpreadsheetDocument.Delimiter)).Cast<SpreadsheetDocument.Delimiter>().ToList();

    public SpreadsheetTabViewModel(string? path = null)
    {
        if (!string.IsNullOrEmpty(path))
        {
            try { Document.LoadFromDisk(path!); }
            catch (Exception ex) { StatusText = "Open failed: " + ex.Message; }
        }
        SyncFromDocument();
    }

    private void SyncFromDocument()
    {
        GridRows.Clear();
        foreach (var r in Document.Rows) GridRows.Add(r);
        Sheets.Clear();
        foreach (var s in Document.SheetNames) Sheets.Add(s);
        ActiveSheetIndex = Document.ActiveSheetIndex;
        Title = (IsDirty ? "• " : "") + Document.DisplayName;
        OnPropertyChanged(nameof(IsExcel));
        OnPropertyChanged(nameof(HasHeaderRow));
        OnPropertyChanged(nameof(CurrentDelimiter));
        UpdateStatus();
        StructureChanged?.Invoke();
    }

    private void MarkDirty()
    {
        if (!IsDirty) { IsDirty = true; Title = "• " + Document.DisplayName; }
        UpdateStatus();
    }

    private void UpdateStatus() =>
        StatusText = $"{Document.RowCount} rows · {Document.ColumnCount} columns"
            + (Document.IsExcel ? " · Excel workbook" : $" · {SpreadsheetDocument.DelimiterName(Document.CurrentDelimiter)}");

    /// <summary>Called by the grid after a cell edit commits.</summary>
    public void OnCellEdited() => MarkDirty();

    [RelayCommand]
    private void NewSheet()
    {
        Document.NewDocument();
        IsDirty = false;
        SyncFromDocument();
    }

    [RelayCommand]
    private async Task Open()
    {
        var path = await DialogService.OpenFileAsync("Open a CSV, TSV, or Excel file");
        if (string.IsNullOrEmpty(path)) return;
        try
        {
            Document.LoadFromDisk(path!);
            IsDirty = false;
            SyncFromDocument();
        }
        catch (Exception ex) { StatusText = "Open failed: " + ex.Message; }
    }

    [RelayCommand]
    private async Task Save()
    {
        if (Document.FilePath is { } p)
        {
            try { Document.Save(p); IsDirty = false; SyncFromDocument(); }
            catch (Exception ex) { StatusText = "Save failed: " + ex.Message; }
        }
        else await SaveAs();
    }

    [RelayCommand]
    private async Task SaveAs()
    {
        var suggested = Document.FilePath is { } fp
            ? Path.GetFileName(fp)
            : "Untitled." + (Document.IsExcel ? "xlsx" : SpreadsheetDocument.DelimiterExtension(Document.CurrentDelimiter));
        var path = await DialogService.SaveFileAsync(suggested, "Save spreadsheet");
        if (string.IsNullOrEmpty(path)) return;
        try { Document.Save(path!); IsDirty = false; SyncFromDocument(); }
        catch (Exception ex) { StatusText = "Save failed: " + ex.Message; }
    }

    [RelayCommand]
    private void AddRow()
    {
        var at = SelectedRowIndex >= 0 ? SelectedRowIndex + 1 : (int?)null;
        Document.AddRow(at);
        MarkDirty();
        SyncRowsOnly();
    }

    [RelayCommand]
    private void DeleteRow()
    {
        if (SelectedRowIndex < 0) return;
        Document.DeleteRow(SelectedRowIndex);
        MarkDirty();
        SyncRowsOnly();
    }

    [RelayCommand]
    private void AddColumn()
    {
        Document.AddColumn();
        MarkDirty();
        SyncFromDocument();
    }

    [RelayCommand]
    private void DeleteLastColumn()
    {
        if (Document.ColumnCount <= 1) return;
        Document.DeleteColumn(Document.ColumnCount - 1);
        MarkDirty();
        SyncFromDocument();
    }

    [RelayCommand]
    private void ToggleHeader()
    {
        Document.ToggleHeaderRow();
        MarkDirty();
        SyncFromDocument();
    }

    public void SetDelimiter(SpreadsheetDocument.Delimiter d)
    {
        Document.ChangeDelimiter(d);
        MarkDirty();
        SyncFromDocument();
    }

    public void SortByColumn(int columnIndex, bool ascending)
    {
        Document.SortRows(columnIndex, ascending);
        MarkDirty();
        SyncRowsOnly();
    }

    public void RenameColumn(int index, string name)
    {
        Document.RenameColumn(index, name);
        MarkDirty();
        SyncFromDocument();
    }

    [RelayCommand]
    private void AddWorksheet()
    {
        Document.AddSheet();
        MarkDirty();
        SyncFromDocument();
    }

    [RelayCommand]
    private void DeleteWorksheet()
    {
        if (Document.ActiveSheetIndex < 0) return;
        Document.DeleteSheet(Document.ActiveSheetIndex);
        MarkDirty();
        SyncFromDocument();
    }

    [RelayCommand]
    private async Task RenameWorksheet()
    {
        if (NameRequested is null || Document.ActiveSheetIndex < 0) return;
        var current = Document.SheetNames.ElementAtOrDefault(Document.ActiveSheetIndex) ?? "";
        var name = await NameRequested("Rename Worksheet", current);
        if (string.IsNullOrWhiteSpace(name)) return;
        Document.RenameSheet(Document.ActiveSheetIndex, name);
        MarkDirty();
        SyncFromDocument();
    }

    partial void OnActiveSheetIndexChanged(int value)
    {
        if (value < 0 || value == Document.ActiveSheetIndex) return;
        Document.SwitchToSheet(value);
        SyncFromDocument();
    }

    private void SyncRowsOnly()
    {
        GridRows.Clear();
        foreach (var r in Document.Rows) GridRows.Add(r);
        UpdateStatus();
    }
}
