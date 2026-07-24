using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using ClosedXML.Excel;

namespace RemoteStuff.Models;

/// <summary>
/// The document model behind one spreadsheet tab: a delimited (CSV / TSV) file
/// or an Excel (.xlsx) workbook parsed into a grid of columns and rows, with
/// in-place cell editing, row / column insertion &amp; deletion, sorting, header
/// handling, delimiter switching and save-back to disk. Ported from the macOS
/// <c>SpreadsheetModel</c>.
/// </summary>
public sealed class SpreadsheetDocument
{
    public enum Delimiter { Comma, Tab, Semicolon, Pipe }

    public static char DelimiterChar(Delimiter d) => d switch
    {
        Delimiter.Comma => ',',
        Delimiter.Tab => '\t',
        Delimiter.Semicolon => ';',
        Delimiter.Pipe => '|',
        _ => ','
    };

    public static string DelimiterName(Delimiter d) => d switch
    {
        Delimiter.Comma => "Comma",
        Delimiter.Tab => "Tab",
        Delimiter.Semicolon => "Semicolon",
        Delimiter.Pipe => "Pipe",
        _ => "Comma"
    };

    public static string DelimiterExtension(Delimiter d) => d == Delimiter.Tab ? "tsv" : "csv";

    public sealed class Column
    {
        public Guid Id { get; } = Guid.NewGuid();
        public string Name { get; set; }
        public Column(string name) => Name = name;
    }

    public sealed class Row
    {
        public Guid Id { get; } = Guid.NewGuid();
        /// <summary>Cell text aligned 1:1 to the document's column order.</summary>
        public List<string> Cells { get; } = new();
    }

    private sealed class SheetData
    {
        public string Name = "Sheet1";
        public List<Column> Columns = new();
        public List<Row> Rows = new();
        public bool HasHeaderRow;
    }

    // MARK: state
    public string? FilePath { get; private set; }
    public List<Column> Columns { get; private set; } = new();
    public List<Row> Rows { get; private set; } = new();
    public bool HasHeaderRow { get; private set; } = true;
    public Delimiter CurrentDelimiter { get; private set; } = Delimiter.Comma;
    public bool IsExcel { get; private set; }
    public IReadOnlyList<string> SheetNames => _sheetStore.Select(s => s.Name).ToList();
    public int ActiveSheetIndex { get; private set; }

    private string? _sourceText;
    private readonly List<SheetData> _sheetStore = new();

    public string DisplayName => FilePath is null ? "Untitled" : Path.GetFileName(FilePath);
    public int RowCount => Rows.Count;
    public int ColumnCount => Columns.Count;

    public SpreadsheetDocument() => NewDocument();

    // MARK: new / load
    public void NewDocument()
    {
        Columns = new List<string> { "A", "B", "C" }.Select(n => new Column(n)).ToList();
        Rows = Enumerable.Range(0, 3).Select(_ => MakeEmptyRow()).ToList();
        HasHeaderRow = false;
        FilePath = null;
        _sourceText = null;
        IsExcel = false;
        _sheetStore.Clear();
        ActiveSheetIndex = 0;
    }

    public static bool IsExcelExtension(string ext) =>
        new[] { "xlsx", "xlsm", "xltx", "xltm" }.Contains(ext.TrimStart('.').ToLowerInvariant());

    public void LoadFromDisk(string path)
    {
        var ext = Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        if (IsExcelExtension(ext))
        {
            LoadExcel(path);
            return;
        }
        var text = File.ReadAllText(path);
        CurrentDelimiter = (ext == "tsv" || ext == "tab") ? Delimiter.Tab : DetectDelimiter(text);
        IsExcel = false;
        _sheetStore.Clear();
        ActiveSheetIndex = 0;
        FilePath = path;
        Load(text, hasHeader: true);
    }

    private void Load(string text, bool hasHeader)
    {
        _sourceText = text;
        var records = Parse(text, DelimiterChar(CurrentDelimiter));
        var built = BuildColumnsRows(records, hasHeader);
        Columns = built.columns;
        Rows = built.rows;
        HasHeaderRow = built.hasHeader;
    }

    private (List<Column> columns, List<Row> rows, bool hasHeader) BuildColumnsRows(
        List<List<string>> records, bool hasHeader)
    {
        var recs = records.Count == 0 ? new List<List<string>> { new() } : records;
        var width = Math.Max(recs.Count == 0 ? 0 : recs.Max(r => r.Count), 1);
        var header = hasHeader && recs.Count > 1;
        List<Column> cols;
        IEnumerable<List<string>> dataRecords;
        if (header)
        {
            var head = recs[0];
            cols = Enumerable.Range(0, width).Select(i =>
            {
                var name = i < head.Count ? head[i] : ColumnLetters(i);
                return new Column(string.IsNullOrEmpty(name) ? ColumnLetters(i) : name);
            }).ToList();
            dataRecords = recs.Skip(1);
        }
        else
        {
            cols = Enumerable.Range(0, width).Select(i => new Column(ColumnLetters(i))).ToList();
            dataRecords = recs;
        }
        var rows = new List<Row>();
        foreach (var record in dataRecords)
        {
            var row = new Row();
            for (var i = 0; i < cols.Count; i++)
                row.Cells.Add(i < record.Count ? record[i] : "");
            rows.Add(row);
        }
        return (cols, rows, header);
    }

    private Row MakeEmptyRow()
    {
        var r = new Row();
        for (var i = 0; i < Columns.Count; i++) r.Cells.Add("");
        return r;
    }

    // MARK: Excel
    private void LoadExcel(string path)
    {
        using var wb = new XLWorkbook(path);
        _sheetStore.Clear();
        foreach (var ws in wb.Worksheets)
        {
            var records = new List<List<string>>();
            var used = ws.RangeUsed();
            if (used != null)
            {
                var lastCol = used.ColumnCount();
                foreach (var xlRow in used.Rows())
                {
                    var fields = new List<string>();
                    for (var c = 1; c <= lastCol; c++)
                        fields.Add(xlRow.Cell(c).GetFormattedString());
                    records.Add(fields);
                }
            }
            var built = BuildColumnsRows(records, hasHeader: true);
            _sheetStore.Add(new SheetData
            {
                Name = ws.Name,
                Columns = built.columns,
                Rows = built.rows,
                HasHeaderRow = built.hasHeader
            });
        }
        if (_sheetStore.Count == 0) _sheetStore.Add(BlankSheet("Sheet1"));
        IsExcel = true;
        FilePath = path;
        _sourceText = null;
        LoadSheet(0);
    }

    private static SheetData BlankSheet(string name) => new()
    {
        Name = name,
        Columns = new List<string> { "A", "B", "C" }.Select(n => new Column(n)).ToList(),
        Rows = Enumerable.Range(0, 3).Select(_ =>
        {
            var r = new Row();
            r.Cells.AddRange(new[] { "", "", "" });
            return r;
        }).ToList(),
        HasHeaderRow = false
    };

    private void LoadSheet(int index)
    {
        if (index < 0 || index >= _sheetStore.Count) return;
        ActiveSheetIndex = index;
        var s = _sheetStore[index];
        Columns = s.Columns;
        Rows = s.Rows;
        HasHeaderRow = s.HasHeaderRow;
    }

    private void FlushActiveSheet()
    {
        if (ActiveSheetIndex < 0 || ActiveSheetIndex >= _sheetStore.Count) return;
        _sheetStore[ActiveSheetIndex].Columns = Columns;
        _sheetStore[ActiveSheetIndex].Rows = Rows;
        _sheetStore[ActiveSheetIndex].HasHeaderRow = HasHeaderRow;
    }

    private SheetData CurrentSheetData() => new()
    {
        Name = (ActiveSheetIndex >= 0 && ActiveSheetIndex < _sheetStore.Count)
            ? _sheetStore[ActiveSheetIndex].Name
            : (FilePath != null ? Path.GetFileNameWithoutExtension(FilePath) : "Sheet1"),
        Columns = Columns,
        Rows = Rows,
        HasHeaderRow = HasHeaderRow
    };

    public void SwitchToSheet(int index)
    {
        if (index == ActiveSheetIndex || index < 0 || index >= _sheetStore.Count) return;
        FlushActiveSheet();
        LoadSheet(index);
    }

    public void AddSheet()
    {
        FlushActiveSheet();
        if (_sheetStore.Count == 0)
        {
            _sheetStore.Add(CurrentSheetData());
            ActiveSheetIndex = 0;
        }
        _sheetStore.Add(BlankSheet(UniqueSheetName()));
        IsExcel = true;
        LoadSheet(_sheetStore.Count - 1);
    }

    public void DeleteSheet(int index)
    {
        if (_sheetStore.Count <= 1 || index < 0 || index >= _sheetStore.Count) return;
        FlushActiveSheet();
        _sheetStore.RemoveAt(index);
        var target = ActiveSheetIndex >= index ? ActiveSheetIndex - 1 : ActiveSheetIndex;
        LoadSheet(Math.Min(Math.Max(0, target), _sheetStore.Count - 1));
    }

    public void RenameSheet(int index, string name)
    {
        if (index < 0 || index >= _sheetStore.Count) return;
        var trimmed = name.Trim();
        if (trimmed.Length == 0) return;
        _sheetStore[index].Name = trimmed;
    }

    private string UniqueSheetName()
    {
        var existing = _sheetStore.Select(s => s.Name).ToHashSet();
        var i = _sheetStore.Count + 1;
        while (existing.Contains($"Sheet{i}")) i++;
        return $"Sheet{i}";
    }

    // MARK: delimiter / header
    public void ChangeDelimiter(Delimiter d)
    {
        if (IsExcel || d == CurrentDelimiter) return;
        if (!string.IsNullOrEmpty(_sourceText))
        {
            CurrentDelimiter = d;
            Load(_sourceText!, HasHeaderRow);
        }
        else
        {
            CurrentDelimiter = d;
        }
    }

    public void ToggleHeaderRow()
    {
        if (HasHeaderRow)
        {
            var row = new Row();
            row.Cells.AddRange(Columns.Select(c => c.Name));
            Rows.Insert(0, row);
            for (var i = 0; i < Columns.Count; i++) Columns[i].Name = ColumnLetters(i);
            HasHeaderRow = false;
        }
        else if (Rows.Count > 0)
        {
            var first = Rows[0];
            for (var i = 0; i < Columns.Count; i++)
            {
                var v = i < first.Cells.Count ? first.Cells[i] : "";
                Columns[i].Name = string.IsNullOrEmpty(v) ? ColumnLetters(i) : v;
            }
            Rows.RemoveAt(0);
            HasHeaderRow = true;
        }
        else
        {
            HasHeaderRow = true;
        }
    }

    // MARK: rows / columns
    public void AddRow(int? index = null)
    {
        var i = index.HasValue ? Math.Min(Math.Max(index.Value, 0), Rows.Count) : Rows.Count;
        Rows.Insert(i, MakeEmptyRow());
    }

    public void DeleteRow(int index)
    {
        if (index >= 0 && index < Rows.Count) Rows.RemoveAt(index);
    }

    public void AddColumn(string? name = null, int? index = null)
    {
        var i = index.HasValue ? Math.Min(Math.Max(index.Value, 0), Columns.Count) : Columns.Count;
        Columns.Insert(i, new Column(name ?? ColumnLetters(Columns.Count)));
        foreach (var r in Rows) r.Cells.Insert(Math.Min(i, r.Cells.Count), "");
    }

    public void DeleteColumn(int index)
    {
        if (index < 0 || index >= Columns.Count) return;
        Columns.RemoveAt(index);
        foreach (var r in Rows)
            if (index < r.Cells.Count) r.Cells.RemoveAt(index);
    }

    public void RenameColumn(int index, string name)
    {
        if (index < 0 || index >= Columns.Count) return;
        var trimmed = name.Trim();
        Columns[index].Name = trimmed.Length == 0 ? ColumnLetters(index) : trimmed;
    }

    // MARK: sorting
    public void SortRows(int columnIndex, bool ascending)
    {
        if (columnIndex < 0 || columnIndex >= Columns.Count) return;
        Rows = Rows.OrderBy(r => r, Comparer<Row>.Create((a, b) =>
        {
            var x = columnIndex < a.Cells.Count ? a.Cells[columnIndex] : "";
            var y = columnIndex < b.Cells.Count ? b.Cells[columnIndex] : "";
            int cmp;
            if (double.TryParse(x, NumberStyles.Any, CultureInfo.InvariantCulture, out var nx) &&
                double.TryParse(y, NumberStyles.Any, CultureInfo.InvariantCulture, out var ny) &&
                nx != ny)
                cmp = nx.CompareTo(ny);
            else
                cmp = string.Compare(x, y, StringComparison.OrdinalIgnoreCase);
            return ascending ? cmp : -cmp;
        })).ToList();
    }

    // MARK: saving
    public void Save(string path)
    {
        var ext = Path.GetExtension(path).TrimStart('.');
        if (IsExcelExtension(ext)) WriteExcel(path);
        else WriteDelimited(path);
    }

    private void WriteDelimited(string path)
    {
        var text = Serialize();
        File.WriteAllText(path, text, new UTF8Encoding(false));
        FilePath = path;
        _sourceText = text;
        IsExcel = false;
        _sheetStore.Clear();
        ActiveSheetIndex = 0;
    }

    private void WriteExcel(string path)
    {
        FlushActiveSheet();
        var dataSheets = (IsExcel && _sheetStore.Count > 0)
            ? _sheetStore.ToList()
            : new List<SheetData> { CurrentSheetData() };
        using var wb = new XLWorkbook();
        foreach (var sheet in dataSheets)
        {
            var ws = wb.Worksheets.Add(SafeSheetName(sheet.Name, wb));
            var r = 1;
            if (sheet.HasHeaderRow)
            {
                for (var c = 0; c < sheet.Columns.Count; c++)
                    ws.Cell(r, c + 1).Value = sheet.Columns[c].Name;
                r++;
            }
            foreach (var row in sheet.Rows)
            {
                for (var c = 0; c < sheet.Columns.Count; c++)
                    ws.Cell(r, c + 1).Value = c < row.Cells.Count ? row.Cells[c] : "";
                r++;
            }
        }
        wb.SaveAs(path);
        FilePath = path;
        _sourceText = null;
        if (!IsExcel || _sheetStore.Count == 0)
        {
            _sheetStore.Clear();
            _sheetStore.AddRange(dataSheets);
            ActiveSheetIndex = 0;
        }
        IsExcel = true;
    }

    private static string SafeSheetName(string name, XLWorkbook wb)
    {
        var trimmed = string.IsNullOrWhiteSpace(name) ? "Sheet" : name.Trim();
        foreach (var ch in new[] { '\\', '/', '*', '?', ':', '[', ']' })
            trimmed = trimmed.Replace(ch, '_');
        if (trimmed.Length > 31) trimmed = trimmed[..31];
        var baseName = trimmed;
        var i = 1;
        while (wb.Worksheets.Any(w => string.Equals(w.Name, trimmed, StringComparison.OrdinalIgnoreCase)))
            trimmed = (baseName.Length > 28 ? baseName[..28] : baseName) + "_" + (++i);
        return trimmed;
    }

    public string Serialize()
    {
        var sep = DelimiterChar(CurrentDelimiter);
        var lines = new List<string>();
        if (HasHeaderRow)
            lines.Add(string.Join(sep, Columns.Select(c => Quote(c.Name, sep))));
        foreach (var row in Rows)
            lines.Add(string.Join(sep, Columns.Select((c, i) =>
                Quote(i < row.Cells.Count ? row.Cells[i] : "", sep))));
        return string.Join("\n", lines) + "\n";
    }

    // MARK: parsing helpers
    public static List<List<string>> Parse(string text, char delimiter)
    {
        var records = new List<List<string>>();
        var field = new StringBuilder();
        var record = new List<string>();
        var inQuotes = false;
        var i = 0;
        char? pending = null;

        char? NextChar()
        {
            if (pending.HasValue) { var p = pending; pending = null; return p; }
            if (i < text.Length) return text[i++];
            return null;
        }

        while (NextChar() is { } ch)
        {
            if (inQuotes)
            {
                if (ch == '"')
                {
                    var n = NextChar();
                    if (n == '"') field.Append('"');
                    else if (n.HasValue) { inQuotes = false; pending = n; }
                    else inQuotes = false;
                }
                else field.Append(ch);
            }
            else
            {
                if (ch == '"') inQuotes = true;
                else if (ch == delimiter) { record.Add(field.ToString()); field.Clear(); }
                else if (ch == '\r')
                {
                    var n = NextChar();
                    if (n.HasValue && n != '\n') pending = n;
                    record.Add(field.ToString()); field.Clear();
                    records.Add(record); record = new List<string>();
                }
                else if (ch == '\n')
                {
                    record.Add(field.ToString()); field.Clear();
                    records.Add(record); record = new List<string>();
                }
                else field.Append(ch);
            }
        }
        if (field.Length > 0 || record.Count > 0)
        {
            record.Add(field.ToString());
            records.Add(record);
        }
        return records;
    }

    public static string Quote(string value, char sep)
    {
        var needsQuoting = value.IndexOf(sep) >= 0 || value.Contains('"')
            || value.Contains('\n') || value.Contains('\r');
        if (!needsQuoting) return value;
        return "\"" + value.Replace("\"", "\"\"") + "\"";
    }

    public static Delimiter DetectDelimiter(string text)
    {
        var firstLine = text.Split('\n', '\r').FirstOrDefault(l => l.Length > 0) ?? "";
        var best = Delimiter.Comma;
        var bestCount = 0;
        foreach (Delimiter d in Enum.GetValues(typeof(Delimiter)))
        {
            var c = firstLine.Count(ch => ch == DelimiterChar(d));
            if (c > bestCount) { bestCount = c; best = d; }
        }
        return bestCount > 0 ? best : Delimiter.Comma;
    }

    public static string ColumnLetters(int index)
    {
        var n = index;
        var name = "";
        do
        {
            name = (char)('A' + n % 26) + name;
            n = n / 26 - 1;
        } while (n >= 0);
        return name;
    }
}
