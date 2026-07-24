using System;
using System.Collections.Generic;

namespace RemoteStuff.Services.Terminal;

/// <summary>One character cell: glyph plus visual attributes.</summary>
public struct TermCell
{
    public char Char;
    public int Fg;   // int.MinValue = default, else 0xRRGGBB
    public int Bg;   // int.MinValue = default, else 0xRRGGBB
    public byte Flags; // bit0 bold, bit1 underline, bit2 reverse, bit3 italic, bit4 dim

    public const int DefaultColor = int.MinValue;

    public static TermCell Blank => new() { Char = ' ', Fg = DefaultColor, Bg = DefaultColor, Flags = 0 };
}

/// <summary>
/// A compact VT100/xterm terminal emulator: consumes the byte→char stream from a
/// PTY and maintains a screen grid (+ scrollback) that a UI control can render.
/// Supports the common subset used by interactive shells and SSH: cursor motion,
/// erase, SGR colours (16/256/truecolor), scroll regions, insert/delete, and the
/// alternate screen buffer.
/// </summary>
public sealed class TerminalEmulator
{
    public int Cols { get; private set; }
    public int Rows { get; private set; }

    private TermCell[][] _grid = Array.Empty<TermCell[]>();
    private readonly List<TermCell[]> _scrollback = new();
    private const int MaxScrollback = 5000;

    private int _cx, _cy;               // cursor col/row (0-based)
    private int _savedCx, _savedCy;
    private int _scrollTop, _scrollBottom; // region (0-based, inclusive)
    private TermCell _attr = TermCell.Blank;
    public bool CursorVisible { get; private set; } = true;

    // Alternate screen support.
    private TermCell[][]? _savedGrid;
    private int _savedAltCx, _savedAltCy;
    private bool _inAltScreen;

    public string Title { get; private set; } = "";

    public event Action? Changed;

    // Parser state.
    private enum State { Ground, Escape, Csi, Osc, Charset }
    private State _state = State.Ground;
    private readonly List<int> _params = new();
    private string _csiIntermediate = "";
    private bool _csiPrivate;
    private System.Text.StringBuilder _oscBuffer = new();
    private int _curParam = -1;

    public TerminalEmulator(int cols, int rows)
    {
        Resize(cols, rows);
    }

    private object _lock = new();

    public void WithLock(Action<TerminalEmulator> body)
    {
        lock (_lock) body(this);
    }

    // ---- Rendering access (call under WithLock) ----

    /// <summary>Total renderable lines: scrollback + the live screen.</summary>
    public int TotalLines => _scrollback.Count + Rows;

    /// <summary>Get a renderable line by absolute index (0 = oldest scrollback).</summary>
    public TermCell[] GetLine(int index)
    {
        if (index < _scrollback.Count) return _scrollback[index];
        var row = index - _scrollback.Count;
        return (row >= 0 && row < Rows) ? _grid[row] : Array.Empty<TermCell>();
    }

    public int ScrollbackCount => _scrollback.Count;
    public int CursorX => _cx;
    public int CursorY => _cy;

    /// <summary>The plain text of the row the cursor is on (used to detect password prompts).</summary>
    public string CurrentLineText()
    {
        lock (_lock)
        {
            if (_cy < 0 || _cy >= _grid.Length) return "";
            var sb = new System.Text.StringBuilder();
            foreach (var cell in _grid[_cy]) sb.Append(cell.Char == '\0' ? ' ' : cell.Char);
            return sb.ToString();
        }
    }

    /// <summary>The full scrollback + live screen as plain text (for copy / save).</summary>
    public string AllText()
    {
        lock (_lock)
        {
            var sb = new System.Text.StringBuilder();
            var total = _scrollback.Count + Rows;
            for (var i = 0; i < total; i++)
            {
                var line = i < _scrollback.Count
                    ? _scrollback[i]
                    : _grid[i - _scrollback.Count];
                var lineSb = new System.Text.StringBuilder();
                foreach (var cell in line) lineSb.Append(cell.Char == '\0' ? ' ' : cell.Char);
                sb.Append(lineSb.ToString().TrimEnd());
                sb.Append('\n');
            }
            return sb.ToString().TrimEnd('\n');
        }
    }

    // ---- Sizing ----

    public void Resize(int cols, int rows)
    {
        cols = Math.Max(1, cols);
        rows = Math.Max(1, rows);
        lock (_lock)
        {
            _grid = ResizeGrid(_grid, rows, cols);
            // The alternate-screen save buffer holds the primary grid at its old
            // dimensions. It must be resized too, otherwise restoring it on
            // alt-screen exit leaves _grid smaller than Rows/Cols and the next
            // write (on the PTY reader thread) indexes out of bounds and aborts
            // the whole process.
            if (_savedGrid != null) _savedGrid = ResizeGrid(_savedGrid, rows, cols);
            Cols = cols;
            Rows = rows;
            _scrollTop = 0;
            _scrollBottom = rows - 1;
            _cx = Math.Min(_cx, cols - 1);
            _cy = Math.Min(_cy, rows - 1);
        }
    }

    private static TermCell[][] ResizeGrid(TermCell[][] old, int rows, int cols)
    {
        var newGrid = new TermCell[rows][];
        for (var r = 0; r < rows; r++)
        {
            newGrid[r] = new TermCell[cols];
            for (var c = 0; c < cols; c++)
                newGrid[r][c] = (r < old.Length && c < old[r].Length) ? old[r][c] : TermCell.Blank;
        }
        return newGrid;
    }

    // ---- Feed ----

    /// <summary>Clear the scrollback history and the visible screen, homing the
    /// cursor (like Terminal.app's ⌘K). Safe to call from the UI thread.</summary>
    public void ClearScrollback()
    {
        lock (_lock)
        {
            _scrollback.Clear();
            for (var r = 0; r < Rows; r++)
                for (var c = 0; c < Cols; c++)
                    _grid[r][c] = TermCell.Blank;
            _cx = _cy = 0;
        }
        Changed?.Invoke();
    }

    public void Feed(ReadOnlySpan<char> chars)
    {
        lock (_lock)
        {
            foreach (var ch in chars)
                FeedChar(ch);
        }
        Changed?.Invoke();
    }

    private void FeedChar(char ch)
    {
        switch (_state)
        {
            case State.Ground: Ground(ch); break;
            case State.Escape: Escape(ch); break;
            case State.Csi: Csi(ch); break;
            case State.Osc: Osc(ch); break;
            case State.Charset: _state = State.Ground; break; // consume one charset-designation byte
        }
    }

    private void Ground(char ch)
    {
        switch (ch)
        {
            case '\x1b': _state = State.Escape; break;
            case '\r': _cx = 0; break;
            case '\n': LineFeed(); break;
            case '\b': if (_cx > 0) _cx--; break;
            case '\t': _cx = Math.Min(Cols - 1, (_cx / 8 + 1) * 8); break;
            case '\a': break; // bell
            case '\f': LineFeed(); break;
            default:
                if (ch >= ' ') PutChar(ch);
                break;
        }
    }

    private void Escape(char ch)
    {
        switch (ch)
        {
            case '[': _state = State.Csi; _params.Clear(); _curParam = -1; _csiIntermediate = ""; _csiPrivate = false; break;
            case ']': _state = State.Osc; _oscBuffer.Clear(); break;
            case '(': case ')': case '*': case '+': _state = State.Charset; break;
            case 'M': ReverseIndex(); _state = State.Ground; break;
            case 'D': LineFeed(); _state = State.Ground; break;
            case 'E': _cx = 0; LineFeed(); _state = State.Ground; break;
            case '7': _savedCx = _cx; _savedCy = _cy; _state = State.Ground; break;
            case '8': _cx = _savedCx; _cy = _savedCy; _state = State.Ground; break;
            case '=': case '>': _state = State.Ground; break; // keypad modes
            case 'c': FullReset(); _state = State.Ground; break;
            default: _state = State.Ground; break;
        }
    }

    private void Csi(char ch)
    {
        if (ch == '?' || ch == '<' || ch == '=' || ch == '>')
        {
            _csiPrivate = ch == '?';
            return;
        }
        if (ch >= '0' && ch <= '9')
        {
            _curParam = (_curParam < 0 ? 0 : _curParam) * 10 + (ch - '0');
            return;
        }
        if (ch == ';')
        {
            _params.Add(_curParam < 0 ? 0 : _curParam);
            _curParam = -1;
            return;
        }
        if (ch >= ' ' && ch <= '/')
        {
            _csiIntermediate += ch;
            return;
        }
        // Final byte.
        if (_curParam >= 0 || _params.Count == 0) _params.Add(_curParam < 0 ? 0 : _curParam);
        DispatchCsi(ch);
        _state = State.Ground;
    }

    private int P(int i, int def) => i < _params.Count && _params[i] > 0 ? _params[i] : (i < _params.Count && _params[i] == 0 ? 0 : def);
    private int P1(int i) => i < _params.Count ? _params[i] : 0;

    private void DispatchCsi(char ch)
    {
        switch (ch)
        {
            case 'A': _cy = Math.Max(_scrollTop, _cy - Math.Max(1, P(0, 1))); break;
            case 'B': _cy = Math.Min(_scrollBottom, _cy + Math.Max(1, P(0, 1))); break;
            case 'C': _cx = Math.Min(Cols - 1, _cx + Math.Max(1, P(0, 1))); break;
            case 'D': _cx = Math.Max(0, _cx - Math.Max(1, P(0, 1))); break;
            case 'E': _cx = 0; _cy = Math.Min(_scrollBottom, _cy + Math.Max(1, P(0, 1))); break;
            case 'F': _cx = 0; _cy = Math.Max(_scrollTop, _cy - Math.Max(1, P(0, 1))); break;
            case 'G': case '`': _cx = Clamp(P(0, 1) - 1, 0, Cols - 1); break;
            case 'd': _cy = Clamp(P(0, 1) - 1, 0, Rows - 1); break;
            case 'H': case 'f':
                _cy = Clamp(P(0, 1) - 1, 0, Rows - 1);
                _cx = Clamp(P1(1) <= 0 ? 0 : P1(1) - 1, 0, Cols - 1);
                break;
            case 'J': EraseDisplay(P(0, 0)); break;
            case 'K': EraseLine(P(0, 0)); break;
            case 'L': InsertLines(Math.Max(1, P(0, 1))); break;
            case 'M': DeleteLines(Math.Max(1, P(0, 1))); break;
            case 'P': DeleteChars(Math.Max(1, P(0, 1))); break;
            case '@': InsertChars(Math.Max(1, P(0, 1))); break;
            case 'X': EraseChars(Math.Max(1, P(0, 1))); break;
            case 'S': ScrollUp(Math.Max(1, P(0, 1))); break;
            case 'T': ScrollDown(Math.Max(1, P(0, 1))); break;
            case 'r':
                _scrollTop = Clamp((_params.Count > 0 ? P(0, 1) : 1) - 1, 0, Rows - 1);
                _scrollBottom = Clamp((_params.Count > 1 && _params[1] > 0 ? _params[1] : Rows) - 1, 0, Rows - 1);
                if (_scrollBottom <= _scrollTop) { _scrollTop = 0; _scrollBottom = Rows - 1; }
                _cx = 0; _cy = _scrollTop;
                break;
            case 'm': ApplySgr(); break;
            case 'h': SetMode(true); break;
            case 'l': SetMode(false); break;
            case 's': _savedCx = _cx; _savedCy = _cy; break;
            case 'u': _cx = _savedCx; _cy = _savedCy; break;
        }
    }

    private void SetMode(bool set)
    {
        if (!_csiPrivate) return;
        foreach (var p in _params)
        {
            switch (p)
            {
                case 25: CursorVisible = set; break;
                case 47:
                case 1047:
                case 1049: SwitchAltScreen(set); break;
            }
        }
    }

    private void SwitchAltScreen(bool enter)
    {
        if (enter && !_inAltScreen)
        {
            _savedGrid = _grid;
            _savedAltCx = _cx; _savedAltCy = _cy;
            _grid = NewBlankGrid(Rows, Cols);
            _cx = 0; _cy = 0;
            _inAltScreen = true;
        }
        else if (!enter && _inAltScreen && _savedGrid != null)
        {
            _grid = _savedGrid;
            _savedGrid = null;
            _cx = _savedAltCx; _cy = _savedAltCy;
            _inAltScreen = false;
        }
    }

    // ---- OSC (title) ----
    private void Osc(char ch)
    {
        if (ch == '\a' || ch == '\x1b')
        {
            var s = _oscBuffer.ToString();
            // Formats: "0;title", "2;title"
            var semi = s.IndexOf(';');
            if (semi >= 0)
            {
                var code = s[..semi];
                if (code is "0" or "2") Title = s[(semi + 1)..];
            }
            _state = ch == '\x1b' ? State.Escape : State.Ground;
            return;
        }
        _oscBuffer.Append(ch);
    }

    // ---- Screen operations ----

    private void PutChar(char ch)
    {
        if (_cx >= Cols)
        {
            _cx = 0;
            LineFeed();
        }
        var cell = _attr;
        cell.Char = ch;
        _grid[_cy][_cx] = cell;
        _cx++;
    }

    private void LineFeed()
    {
        if (_cy == _scrollBottom)
            ScrollUp(1);
        else if (_cy < Rows - 1)
            _cy++;
    }

    private void ReverseIndex()
    {
        if (_cy == _scrollTop)
            ScrollDown(1);
        else if (_cy > 0)
            _cy--;
    }

    private void ScrollUp(int n)
    {
        for (var k = 0; k < n; k++)
        {
            // Push the top region line to scrollback only for the primary screen
            // when the region is the full screen (normal terminal scrolling).
            if (!_inAltScreen && _scrollTop == 0)
            {
                _scrollback.Add(_grid[_scrollTop]);
                if (_scrollback.Count > MaxScrollback) _scrollback.RemoveAt(0);
            }
            for (var r = _scrollTop; r < _scrollBottom; r++)
                _grid[r] = _grid[r + 1];
            _grid[_scrollBottom] = BlankRow();
        }
    }

    private void ScrollDown(int n)
    {
        for (var k = 0; k < n; k++)
        {
            for (var r = _scrollBottom; r > _scrollTop; r--)
                _grid[r] = _grid[r - 1];
            _grid[_scrollTop] = BlankRow();
        }
    }

    private void InsertLines(int n)
    {
        if (_cy < _scrollTop || _cy > _scrollBottom) return;
        for (var k = 0; k < n; k++)
        {
            for (var r = _scrollBottom; r > _cy; r--)
                _grid[r] = _grid[r - 1];
            _grid[_cy] = BlankRow();
        }
    }

    private void DeleteLines(int n)
    {
        if (_cy < _scrollTop || _cy > _scrollBottom) return;
        for (var k = 0; k < n; k++)
        {
            for (var r = _cy; r < _scrollBottom; r++)
                _grid[r] = _grid[r + 1];
            _grid[_scrollBottom] = BlankRow();
        }
    }

    private void DeleteChars(int n)
    {
        var row = _grid[_cy];
        for (var c = _cx; c < Cols; c++)
            row[c] = c + n < Cols ? row[c + n] : Blank();
    }

    private void InsertChars(int n)
    {
        var row = _grid[_cy];
        for (var c = Cols - 1; c >= _cx; c--)
            row[c] = c - n >= _cx ? row[c - n] : Blank();
    }

    private void EraseChars(int n)
    {
        var row = _grid[_cy];
        for (var c = _cx; c < Math.Min(Cols, _cx + n); c++)
            row[c] = Blank();
    }

    private void EraseDisplay(int mode)
    {
        switch (mode)
        {
            case 0:
                EraseLine(0);
                for (var r = _cy + 1; r < Rows; r++) _grid[r] = BlankRow();
                break;
            case 1:
                for (var r = 0; r < _cy; r++) _grid[r] = BlankRow();
                EraseLine(1);
                break;
            case 2:
            case 3:
                for (var r = 0; r < Rows; r++) _grid[r] = BlankRow();
                break;
        }
    }

    private void EraseLine(int mode)
    {
        var row = _grid[_cy];
        switch (mode)
        {
            case 0: for (var c = _cx; c < Cols; c++) row[c] = Blank(); break;
            case 1: for (var c = 0; c <= Math.Min(_cx, Cols - 1); c++) row[c] = Blank(); break;
            case 2: for (var c = 0; c < Cols; c++) row[c] = Blank(); break;
        }
    }

    // ---- SGR (colours / attributes) ----

    private void ApplySgr()
    {
        if (_params.Count == 0) { ResetAttr(); return; }
        for (var i = 0; i < _params.Count; i++)
        {
            var p = _params[i];
            switch (p)
            {
                case 0: ResetAttr(); break;
                case 1: _attr.Flags |= 0x01; break;
                case 2: _attr.Flags |= 0x10; break;
                case 3: _attr.Flags |= 0x08; break;
                case 4: _attr.Flags |= 0x02; break;
                case 7: _attr.Flags |= 0x04; break;
                case 22: _attr.Flags &= 0x0E; _attr.Flags &= unchecked((byte)~0x10); break;
                case 23: _attr.Flags &= unchecked((byte)~0x08); break;
                case 24: _attr.Flags &= unchecked((byte)~0x02); break;
                case 27: _attr.Flags &= unchecked((byte)~0x04); break;
                case >= 30 and <= 37: _attr.Fg = AnsiIndex(p - 30); break;
                case 38: i = ExtendedColor(i, true); break;
                case 39: _attr.Fg = TermCell.DefaultColor; break;
                case >= 40 and <= 47: _attr.Bg = AnsiIndex(p - 40); break;
                case 48: i = ExtendedColor(i, false); break;
                case 49: _attr.Bg = TermCell.DefaultColor; break;
                case >= 90 and <= 97: _attr.Fg = AnsiIndex(p - 90 + 8); break;
                case >= 100 and <= 107: _attr.Bg = AnsiIndex(p - 100 + 8); break;
            }
        }
    }

    private int ExtendedColor(int i, bool fg)
    {
        // 38;5;n  or  38;2;r;g;b
        if (i + 1 >= _params.Count) return i;
        var mode = _params[i + 1];
        if (mode == 5 && i + 2 < _params.Count)
        {
            var n = _params[i + 2];
            var color = n < 16 ? AnsiIndex(n) : Palette256(n);
            if (fg) _attr.Fg = color; else _attr.Bg = color;
            return i + 2;
        }
        if (mode == 2 && i + 4 < _params.Count)
        {
            var color = (_params[i + 2] << 16) | (_params[i + 3] << 8) | _params[i + 4];
            if (fg) _attr.Fg = color; else _attr.Bg = color;
            return i + 4;
        }
        return i;
    }

    private void ResetAttr()
    {
        _attr = TermCell.Blank;
    }

    // ---- Helpers ----

    private TermCell Blank() { var c = _attr; c.Char = ' '; return c; }
    private TermCell[] BlankRow()
    {
        var row = new TermCell[Cols];
        var blank = Blank();
        for (var c = 0; c < Cols; c++) row[c] = blank;
        return row;
    }
    private static TermCell[][] NewBlankGrid(int rows, int cols)
    {
        var g = new TermCell[rows][];
        for (var r = 0; r < rows; r++)
        {
            g[r] = new TermCell[cols];
            for (var c = 0; c < cols; c++) g[r][c] = TermCell.Blank;
        }
        return g;
    }

    private void FullReset()
    {
        _grid = NewBlankGrid(Rows, Cols);
        _scrollback.Clear();
        _cx = _cy = 0;
        _scrollTop = 0; _scrollBottom = Rows - 1;
        _attr = TermCell.Blank;
        _inAltScreen = false;
        _savedGrid = null;
        CursorVisible = true;
    }

    private static int Clamp(int v, int lo, int hi) => Math.Max(lo, Math.Min(hi, v));

    // Standard xterm 16-colour palette.
    private static readonly int[] Ansi16Palette =
    {
        0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
        0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF
    };
    private static int Ansi16(int i) => Ansi16Palette[Clamp(i, 0, 15)];

    /// <summary>Encode an ANSI palette index (0–15) so the theme can resolve it at render time.</summary>
    public static int AnsiIndex(int i) => -2 - Clamp(i, 0, 15);

    /// <summary>Decode a colour value into an ANSI index, or -1 if it is not an index.</summary>
    public static int AnsiIndexOf(int color) => (color <= -2 && color >= -17) ? -2 - color : -1;

    private static int Palette256(int n)
    {
        n = Clamp(n, 0, 255);
        if (n < 16) return Ansi16(n);
        if (n < 232)
        {
            n -= 16;
            var r = n / 36; var g = (n % 36) / 6; var b = n % 6;
            int Comp(int v) => v == 0 ? 0 : 55 + v * 40;
            return (Comp(r) << 16) | (Comp(g) << 8) | Comp(b);
        }
        var gray = 8 + (n - 232) * 10;
        return (gray << 16) | (gray << 8) | gray;
    }
}
