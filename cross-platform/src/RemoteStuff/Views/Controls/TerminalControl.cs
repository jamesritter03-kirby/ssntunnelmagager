using System;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Threading;
using RemoteStuff.Services.Terminal;
using RemoteStuff.Models;

namespace RemoteStuff.Views.Controls;

/// <summary>
/// An embedded terminal: owns a <see cref="UnixPtyProcess"/> + <see cref="TerminalEmulator"/>,
/// pumps PTY output into the emulator on a background thread, renders the character
/// grid, and forwards keystrokes back to the child. This is the cross-platform
/// analogue of the original app's SwiftTerm view.
/// </summary>
public sealed class TerminalControl : Control
{
    private readonly TerminalEmulator _emu = new(80, 24);
    private UnixPtyProcess? _pty;
    private Thread? _reader;
    private volatile bool _running;

    private readonly Typeface _typeface = new(new FontFamily("Menlo, DejaVu Sans Mono, Cascadia Mono, Consolas, monospace"));
    private double _fontSize = 13;
    private double _charW = 8;
    private double _lineH = 16;

    private int _scrollOffset; // lines scrolled up from the bottom
    private DispatcherTimer? _reapTimer;
    private volatile bool _repaintScheduled;

    // Text selection, in absolute buffer coordinates (line index within the full
    // scrollback+screen, and column). Null when there is no selection.
    private (int line, int col)? _selAnchor;
    private (int line, int col)? _selFocus;
    private bool _selecting;
    private static readonly IBrush SelectionBrush = new SolidColorBrush(Color.FromArgb(0x66, 0x33, 0x66, 0x99));

    private (string exe, string[] args, (string, string)[]? env, string? cwd)? _pending;
    private string? _runOnConnect;
    private volatile bool _runOnConnectArmed;
    private volatile bool _runOnConnectFired;

    private static readonly IBrush DefaultBg = new SolidColorBrush(Color.FromRgb(0x1E, 0x1E, 0x1E));
    private static readonly Color DefaultFgColor = Color.FromRgb(0xD4, 0xD4, 0xD4);

    private TerminalTheme _theme = TerminalTheme.Default;
    private IBrush _bgBrush = new SolidColorBrush(Color.FromRgb(0, 0, 0));
    private Color _fgColor = DefaultFgColor;
    private Color _cursorColor = DefaultFgColor;

    public event Action<int>? Exited;

    /// <summary>Raised once when ssh reports the remote host key changed
    /// ("REMOTE HOST IDENTIFICATION HAS CHANGED" / "Host key verification failed").</summary>
    public event Action? HostKeyChanged;

    public TerminalControl()
    {
        Focusable = true;
        ClipToBounds = true;
        ApplyTheme(TerminalTheme.Default);
        _emu.Changed += OnEmuChanged;
        MeasureFont();
    }

    public TerminalTheme ColorTheme
    {
        get => _theme;
        set { ApplyTheme(value); InvalidateVisual(); }
    }

    private void ApplyTheme(TerminalTheme theme)
    {
        _theme = theme;
        _bgBrush = new SolidColorBrush(FromRgbInt(theme.Background));
        _fgColor = FromRgbInt(theme.Foreground);
        _cursorColor = FromRgbInt(theme.Cursor);
        Background = _bgBrush;
    }

    private static Color FromRgbInt(int rgb)
        => Color.FromRgb((byte)((rgb >> 16) & 0xFF), (byte)((rgb >> 8) & 0xFF), (byte)(rgb & 0xFF));

    public double FontSize
    {
        get => _fontSize;
        set { _fontSize = Math.Max(6, value); MeasureFont(); ResizeToBounds(); InvalidateVisual(); }
    }

    public bool IsRunning => _running;

    public IBrush? Background { get; set; }

    private void MeasureFont()
    {
        var ft = new FormattedText("M", CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            _typeface, _fontSize, Brushes.White);
        _charW = ft.WidthIncludingTrailingWhitespace > 0 ? ft.WidthIncludingTrailingWhitespace : _fontSize * 0.6;
        _lineH = ft.Height > 0 ? ft.Height : _fontSize * 1.3;
    }

    /// <summary>
    /// Queue a session to start once the control has been laid out (so the child
    /// process is created with the correct terminal size). Optionally sends
    /// <paramref name="runOnConnect"/> shortly after the shell is ready.
    /// </summary>
    public void StartDeferred(string executable, string[] args,
        (string, string)[]? env = null, string? workingDirectory = null, string? runOnConnect = null)
    {
        _pending = (executable, args, env, workingDirectory);
        _lastSpec = (executable, args, env, workingDirectory);
        _runOnConnect = string.IsNullOrWhiteSpace(runOnConnect) ? null : runOnConnect;
        _pendingRunOnConnect = _runOnConnect;
        if (Bounds.Width > 0 && Bounds.Height > 0)
            LaunchPending();
    }

    private (string exe, string[] args, (string, string)[]? env, string? cwd)? _lastSpec;

    /// <summary>Restart the last session (used by Reconnect).</summary>
    public void Restart()
    {
        if (_lastSpec is not { } s) return;
        _pty?.Dispose();
        _pty = null;
        _running = false;
        _hostKeyFired = false;
        _hostKeyScanTail = "";
        _emu.Feed("\r\n\u001b[2m— reconnecting —\u001b[0m\r\n".AsSpan());
        _pending = s;
        _runOnConnect = _pendingRunOnConnect;
        if (Bounds.Width > 0 && Bounds.Height > 0) LaunchPending();
    }

    private string? _pendingRunOnConnect;

    /// <summary>Re-point the session at a new command line (host/port/user args) and
    /// optional run-on-connect, then relaunch in place. Backs a tab's
    /// "Edit Connection Settings…" re-point.</summary>
    public void RelaunchWith(string executable, string[] args,
        (string, string)[]? env = null, string? workingDirectory = null, string? runOnConnect = null)
    {
        _lastSpec = (executable, args, env, workingDirectory);
        _pendingRunOnConnect = string.IsNullOrWhiteSpace(runOnConnect) ? null : runOnConnect;
        Restart();
    }

    /// <summary>Update the command auto-run on the next (re)connect, without
    /// relaunching now.</summary>
    public void SetRunOnConnect(string? command)
        => _pendingRunOnConnect = string.IsNullOrWhiteSpace(command) ? null : command;

    private void LaunchPending()
    {
        if (_pending is not { } p || _running) return;
        _pending = null;
        _runOnConnectFired = false;
        _runOnConnectArmed = _runOnConnect is not null;
        Start(p.exe, p.args, p.env, p.cwd);
        if (_runOnConnectArmed)
        {
            // The command is fired when we recognise the first shell prompt (see
            // MaybeFireRunOnConnect, driven off PTY output) so it doesn't run before
            // an SSH login has authenticated. This is only a safety net for unusual
            // shells whose prompt we don't recognise, so the command isn't lost.
            DispatcherTimer.RunOnce(FireRunOnConnect, TimeSpan.FromSeconds(6));
        }
    }

    /// <summary>Send the run-on-connect command exactly once. Must run on the UI
    /// thread (it writes to the PTY via <see cref="SendText"/>).</summary>
    private void FireRunOnConnect()
    {
        if (!_runOnConnectArmed || _runOnConnectFired || !_running) return;
        if (_runOnConnect is not { } cmd) return;
        _runOnConnectFired = true;
        _runOnConnectArmed = false;
        // Curses apps such as btop read TIOCGWINSZ exactly once at startup and abort
        // with "Failed to get size of terminal!" if the (remote) PTY isn't sized yet.
        // Timing-based SIGWINCH nudges are unreliable over SSH (the window-change has
        // to reach the server and be applied before the command reads its size, and
        // back-to-back resizes can collapse into a single signal). Instead we set the
        // size deterministically *in the shell* right before the command runs: `stty`
        // applies the dimensions to the controlling terminal synchronously, so they're
        // guaranteed correct by the time btop reads them — no race, no timing guess.
        var (cols, rows) = ComputeGrid();
        var toRun = cmd;
        if (cols > 0 && rows > 0)
        {
            _emu.Resize(cols, rows);
            _pty?.Resize((ushort)cols, (ushort)rows);
            toRun = $"stty rows {rows} cols {cols} 2>/dev/null; {cmd}";
        }
        DispatcherTimer.RunOnce(() => { if (_running) SendText(toRun + "\r"); },
            TimeSpan.FromMilliseconds(300));
    }

    /// <summary>Called from the PTY reader thread after each chunk of output. Only
    /// reads the emulator here; the actual send is marshalled to the UI thread.
    /// Fires the run-on-connect command once we see a shell prompt, and never
    /// before an outstanding auto-password prompt has been answered.</summary>
    private void MaybeFireRunOnConnect()
    {
        if (!_runOnConnectArmed || _runOnConnectFired) return;
        // Wait for an auto-password prompt to be answered before considering the
        // session "connected".
        if (!string.IsNullOrEmpty(_autoPassword) && _autoPwSent == 0) return;
        var line = _emu.CurrentLineText().TrimEnd();
        if (line.Length == 0) return;
        var lower = line.ToLowerInvariant();
        if (lower.EndsWith("password:") || lower.Contains("password for")) return;
        var last = line[^1];
        if (last is '$' or '#' or '%' or '>')
            Dispatcher.UIThread.Post(FireRunOnConnect);
    }

    /// <summary>Start a PTY session running the given executable.</summary>
    public void Start(string executable, string[] args,
        (string Name, string Value)[]? env = null, string? workingDirectory = null)
    {
        if (!RuntimeInformation.IsOSPlatform(OSPlatform.OSX) &&
            !RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
        {
            _emu.Feed("\r\n  The embedded terminal currently requires macOS or Linux.\r\n".AsSpan());
            InvalidateVisual();
            return;
        }

        var (cols, rows) = ComputeGrid();
        _emu.Resize(cols, rows);

        var baseEnv = new (string, string)[]
        {
            ("TERM", "xterm-256color"),
            ("COLORTERM", "truecolor"),
            ("LANG", Environment.GetEnvironmentVariable("LANG") ?? "en_US.UTF-8"),
        };
        var allEnv = env == null ? baseEnv : Combine(baseEnv, env);

        _pty = new UnixPtyProcess();
        try
        {
            _pty.Start(executable, args, (ushort)cols, (ushort)rows, allEnv, workingDirectory);
        }
        catch (Exception ex)
        {
            _emu.Feed($"\r\n  Failed to start: {ex.Message}\r\n".AsSpan());
            InvalidateVisual();
            return;
        }

        _running = true;
        _reader = new Thread(ReadLoop) { IsBackground = true, Name = "pty-read" };
        _reader.Start();

        _reapTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(400) };
        _reapTimer.Tick += (_, _) =>
        {
            var code = _pty?.TryReap();
            if (code is { } c)
            {
                _reapTimer?.Stop();
                _running = false;
                Exited?.Invoke(c);
            }
        };
        _reapTimer.Start();
    }

    private static (string, string)[] Combine((string, string)[] a, (string Name, string Value)[] b)
    {
        var list = new System.Collections.Generic.List<(string, string)>(a);
        foreach (var (n, v) in b) list.Add((n, v));
        return list.ToArray();
    }

    private void ReadLoop()
    {
        var buf = new byte[8192];
        var decoder = Encoding.UTF8.GetDecoder();
        var chars = new char[8192];
        while (_running)
        {
            int n;
            try { n = _pty!.Read(buf); }
            catch { break; }
            if (n <= 0) break; // EOF or error
            try { _log?.Write(buf, 0, n); } catch { /* logging is best-effort */ }
            var count = decoder.GetChars(buf, 0, n, chars, 0);
            if (count > 0)
            {
                // Guard the emulator + prompt scanning: an unhandled exception on
                // this background thread would abort the entire process, so a
                // stray parsing edge case must never escape here.
                try
                {
                    _emu.Feed(new ReadOnlySpan<char>(chars, 0, count));
                    MaybeAutoTypePassword();
                    MaybeFireRunOnConnect();
                    ScanForHostKeyChange(new ReadOnlySpan<char>(chars, 0, count));
                }
                catch { /* keep the reader alive; a dropped frame beats a crash */ }
            }
        }
        _running = false;
    }

    // ---- Host-key-changed detection ----
    private string _hostKeyScanTail = "";
    private bool _hostKeyFired;

    /// <summary>Watch the raw output for ssh's host-key-changed warning and raise
    /// <see cref="HostKeyChanged"/> a single time per session.</summary>
    private void ScanForHostKeyChange(ReadOnlySpan<char> chunk)
    {
        if (_hostKeyFired) return;
        // Keep a small rolling window so the phrase is caught even when split across reads.
        var combined = _hostKeyScanTail + new string(chunk);
        if (combined.Length > 4096) combined = combined.Substring(combined.Length - 4096);
        _hostKeyScanTail = combined;
        if (combined.Contains("REMOTE HOST IDENTIFICATION HAS CHANGED", StringComparison.Ordinal) ||
            combined.Contains("Host key verification failed", StringComparison.Ordinal))
        {
            _hostKeyFired = true;
            Dispatcher.UIThread.Post(() => HostKeyChanged?.Invoke());
        }
    }

    // ---- Auto password ----
    private string? _autoPassword;
    private string _lastPromptSeen = "";
    private int _autoPwSent;

    public void SetAutoPassword(string? password) => _autoPassword = password;

    private void MaybeAutoTypePassword()
    {
        if (string.IsNullOrEmpty(_autoPassword) || _autoPwSent >= 3) return;
        var line = _emu.CurrentLineText().TrimEnd();
        var lower = line.ToLowerInvariant();
        if (!(lower.EndsWith("password:") || lower.EndsWith("password: ") || lower.Contains("password for")))
            return;
        // Only respond once per distinct prompt line (ssh re-prompts on failure).
        if (line == _lastPromptSeen) return;
        _lastPromptSeen = line;
        _autoPwSent++;
        // This runs on the PTY reader thread; DispatcherTimer must only be used on
        // the UI thread, so marshal there before scheduling the delayed send.
        Dispatcher.UIThread.Post(() =>
            DispatcherTimer.RunOnce(() =>
            {
                if (_running) Send(Encoding.UTF8.GetBytes(_autoPassword + "\n"));
            }, TimeSpan.FromMilliseconds(120)));
    }

    private void OnEmuChanged()
    {
        // Coalesce a burst of emulator changes into a single repaint on the next
        // UI turn. Posting once per burst (guarded by the flag) avoids flooding the
        // dispatcher, while still guaranteeing the *last* chunk of output is drawn
        // (the old 16ms time-gate dropped trailing frames, so keystroke echo lagged).
        if (_repaintScheduled) return;
        _repaintScheduled = true;
        Dispatcher.UIThread.Post(() =>
        {
            _repaintScheduled = false;
            _scrollOffset = 0;
            InvalidateVisual();
        }, DispatcherPriority.Render);
    }

    // ---- Sizing ----

    /// <summary>The most recent arranged size. Used because <see cref="Control.Bounds"/>
    /// isn't updated until *after* <see cref="ArrangeOverride"/> returns, so on the
    /// first layout pass Bounds is still 0×0 and the pending session would never
    /// launch (it would stay queued until a later relayout / manual reconnect).</summary>
    private Size _arrangedSize;

    private (int cols, int rows) ComputeGrid()
    {
        var w = Bounds.Width > 0 ? Bounds.Width : _arrangedSize.Width;
        var h = Bounds.Height > 0 ? Bounds.Height : _arrangedSize.Height;
        var cols = Math.Max(1, (int)(w / _charW));
        var rows = Math.Max(1, (int)(h / _lineH));
        return (cols, rows);
    }

    private void ResizeToBounds()
    {
        var w = Bounds.Width > 0 ? Bounds.Width : _arrangedSize.Width;
        var h = Bounds.Height > 0 ? Bounds.Height : _arrangedSize.Height;
        if (w <= 0 || h <= 0) return;
        var (cols, rows) = ComputeGrid();
        if (cols == _emu.Cols && rows == _emu.Rows) return;
        _emu.Resize(cols, rows);
        _pty?.Resize((ushort)cols, (ushort)rows);
        InvalidateVisual();
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        var r = base.ArrangeOverride(finalSize);
        _arrangedSize = finalSize;
        if (_pending != null && finalSize.Width > 0 && finalSize.Height > 0)
            LaunchPending();
        else
            ResizeToBounds();
        return r;
    }

    // ---- Rendering ----

    public override void Render(DrawingContext context)
    {
        context.FillRectangle(Background ?? DefaultBg, new Rect(Bounds.Size));

        _emu.WithLock(emu =>
        {
            var rows = emu.Rows;
            var cols = emu.Cols;
            var total = emu.TotalLines;
            var firstLine = Math.Max(0, total - rows - _scrollOffset);
            var hasSel = TryGetSelection(out var selS, out var selE);

            for (var screenRow = 0; screenRow < rows; screenRow++)
            {
                var lineIndex = firstLine + screenRow;
                if (lineIndex >= total) break;

                // Selection highlight for this row (drawn under the glyphs).
                if (hasSel && lineIndex >= selS.line && lineIndex <= selE.line)
                {
                    var sc = lineIndex == selS.line ? selS.col : 0;
                    var ec = lineIndex == selE.line ? selE.col : cols;
                    sc = Math.Clamp(sc, 0, cols);
                    ec = Math.Clamp(ec, 0, cols);
                    if (ec > sc)
                        context.FillRectangle(SelectionBrush,
                            new Rect(sc * _charW, screenRow * _lineH, (ec - sc) * _charW, _lineH));
                }

                var line = emu.GetLine(lineIndex);
                DrawLine(context, line, screenRow);
            }

            // Cursor (only when at the live bottom and visible).
            if (emu.CursorVisible && _scrollOffset == 0)
            {
                var cx = emu.CursorX;
                var cy = emu.CursorY;
                var rect = new Rect(cx * _charW, cy * _lineH, _charW, _lineH);
                context.FillRectangle(new SolidColorBrush(_cursorColor, 0.6), rect);
            }
        });
    }

    private void DrawLine(DrawingContext context, TermCell[] line, int screenRow)
    {
        var y = screenRow * _lineH;
        var col = 0;
        while (col < line.Length)
        {
            var cell = line[col];
            // Group a run of cells sharing the same visual attributes.
            var start = col;
            var sb = new StringBuilder();
            while (col < line.Length && SameStyle(line[col], cell))
            {
                sb.Append(line[col].Char == '\0' ? ' ' : line[col].Char);
                col++;
            }
            var text = sb.ToString();
            var x = start * _charW;

            var (fg, bg) = ResolveColors(cell);
            if (bg != null)
                context.FillRectangle(bg, new Rect(x, y, _charW * text.Length, _lineH));

            if (!string.IsNullOrWhiteSpace(text))
            {
                var ft = new FormattedText(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
                    _typeface, _fontSize, fg);
                if ((cell.Flags & 0x08) != 0) ft.SetFontStyle(FontStyle.Italic);
                if ((cell.Flags & 0x01) != 0) ft.SetFontWeight(FontWeight.Bold);
                context.DrawText(ft, new Point(x, y));
            }
        }
    }

    private static bool SameStyle(in TermCell a, in TermCell b)
        => a.Fg == b.Fg && a.Bg == b.Bg && a.Flags == b.Flags;

    private (IBrush fg, IBrush? bg) ResolveColors(in TermCell cell)
    {
        var fgColor = ResolveColor(cell.Fg, _fgColor);
        Color? bgColor = cell.Bg == TermCell.DefaultColor ? null : ResolveColor(cell.Bg, _fgColor);

        if ((cell.Flags & 0x04) != 0) // reverse video
        {
            var bgResolved = bgColor ?? ((SolidColorBrush)_bgBrush).Color;
            (fgColor, bgColor) = (bgResolved, fgColor);
        }
        if ((cell.Flags & 0x10) != 0) // dim
            fgColor = Color.FromArgb(0xB0, fgColor.R, fgColor.G, fgColor.B);

        return (BrushFor(fgColor), bgColor is { } c ? BrushFor(c) : null);
    }

    /// <summary>Cache of solid brushes keyed by ARGB, so the render path reuses
    /// brush instances instead of allocating one per style run every frame.</summary>
    private readonly System.Collections.Generic.Dictionary<uint, IBrush> _brushCache = new();

    private IBrush BrushFor(Color color)
    {
        var key = ((uint)color.A << 24) | ((uint)color.R << 16) | ((uint)color.G << 8) | color.B;
        if (_brushCache.TryGetValue(key, out var brush)) return brush;
        brush = new SolidColorBrush(color);
        _brushCache[key] = brush;
        return brush;
    }

    private Color ResolveColor(int value, Color fallback)
    {
        if (value == TermCell.DefaultColor) return fallback;
        var idx = TerminalEmulator.AnsiIndexOf(value);
        if (idx >= 0) return FromRgbInt(_theme.Ansi[idx]);
        return ToColor(value);
    }

    private static Color ToColor(int rgb)
        => Color.FromRgb((byte)((rgb >> 16) & 0xFF), (byte)((rgb >> 8) & 0xFF), (byte)(rgb & 0xFF));

    // ---- Input ----

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        Focus();
        var pt = e.GetCurrentPoint(this);
        if (pt.Properties.IsLeftButtonPressed)
        {
            _selAnchor = _selFocus = PointToCell(pt.Position);
            _selecting = true;
            e.Pointer.Capture(this);
            InvalidateVisual();
        }
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        if (!_selecting) return;
        _selFocus = PointToCell(e.GetPosition(this));
        InvalidateVisual();
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);
        if (!_selecting) return;
        _selecting = false;
        e.Pointer.Capture(null);
        // A click without a drag clears the selection so the caret behaves normally.
        if (_selAnchor is { } a && _selFocus is { } f && a == f)
        {
            _selAnchor = _selFocus = null;
            InvalidateVisual();
            return;
        }
        // A completed drag-selection is copied to the clipboard immediately, so the
        // user doesn't need to press Cmd/Ctrl+C (matches macOS Terminal / iTerm).
        var sel = GetSelectedText();
        if (!string.IsNullOrEmpty(sel))
            TopLevel.GetTopLevel(this)?.Clipboard?.SetTextAsync(sel);
    }

    /// <summary>Map a control-space point to an absolute (line, col) buffer cell.</summary>
    private (int line, int col) PointToCell(Point p)
    {
        var rows = _emu.Rows;
        var total = _emu.TotalLines;
        var firstLine = Math.Max(0, total - rows - _scrollOffset);
        var screenRow = Math.Clamp((int)(p.Y / _lineH), 0, Math.Max(0, rows - 1));
        var line = Math.Min(firstLine + screenRow, Math.Max(0, total - 1));
        var col = Math.Max(0, (int)Math.Round(p.X / _charW));
        return (line, col);
    }

    /// <summary>Normalised selection bounds (start ≤ end). False when nothing is selected.</summary>
    private bool TryGetSelection(out (int line, int col) start, out (int line, int col) end)
    {
        start = end = default;
        if (_selAnchor is not { } a || _selFocus is not { } b) return false;
        if (a == b) return false;
        if (a.line < b.line || (a.line == b.line && a.col <= b.col)) { start = a; end = b; }
        else { start = b; end = a; }
        return true;
    }

    /// <summary>The currently selected text, or null when there is no selection.</summary>
    public string? GetSelectedText()
    {
        if (!TryGetSelection(out var s, out var e)) return null;
        var sb = new StringBuilder();
        _emu.WithLock(emu =>
        {
            var total = emu.TotalLines;
            for (var line = s.line; line <= e.line && line < total; line++)
            {
                var cells = emu.GetLine(line);
                var sc = line == s.line ? s.col : 0;
                var ec = line == e.line ? e.col : cells.Length;
                sc = Math.Clamp(sc, 0, cells.Length);
                ec = Math.Clamp(ec, 0, cells.Length);
                var lineSb = new StringBuilder();
                for (var c = sc; c < ec; c++)
                    lineSb.Append(cells[c].Char == '\0' ? ' ' : cells[c].Char);
                sb.Append(lineSb.ToString().TrimEnd());
                if (line != e.line) sb.Append('\n');
            }
        });
        return sb.ToString();
    }

    protected override void OnPointerWheelChanged(PointerWheelEventArgs e)
    {
        base.OnPointerWheelChanged(e);
        var maxOffset = Math.Max(0, _emu.ScrollbackCount);
        _scrollOffset = Math.Clamp(_scrollOffset + (int)(e.Delta.Y * 3), 0, maxOffset);
        InvalidateVisual();
        e.Handled = true;
    }

    protected override void OnTextInput(TextInputEventArgs e)
    {
        if (!_running || string.IsNullOrEmpty(e.Text)) { base.OnTextInput(e); return; }
        _inputLine.Append(e.Text);
        var bytes = Encoding.UTF8.GetBytes(e.Text);
        Send(bytes);
        UserInput?.Invoke(this, bytes);
        e.Handled = true;
    }

    private readonly StringBuilder _inputLine = new();

    /// <summary>Raised with each command line the user types and submits (Enter).</summary>
    public event Action<string>? LineEntered;

    protected override void OnKeyDown(KeyEventArgs e)
    {
        var meta = e.KeyModifiers.HasFlag(KeyModifiers.Meta);
        var ctrl = e.KeyModifiers.HasFlag(KeyModifiers.Control);
        var shift = e.KeyModifiers.HasFlag(KeyModifiers.Shift);

        // Copy the selection: Cmd+C (macOS) or Ctrl+Shift+C. Falls through to the
        // normal Ctrl+C (SIGINT) path when there's nothing selected.
        if ((meta || (ctrl && shift)) && e.Key == Key.C)
        {
            var sel = GetSelectedText();
            if (!string.IsNullOrEmpty(sel))
            {
                TopLevel.GetTopLevel(this)?.Clipboard?.SetTextAsync(sel);
                e.Handled = true;
                return;
            }
        }

        // Paste: Cmd+V (macOS) or Ctrl+Shift+V.
        if ((meta || (ctrl && shift)) && e.Key == Key.V)
        {
            if (TopLevel.GetTopLevel(this)?.Clipboard is { } cb)
            {
                _ = PasteFromClipboardAsync(cb);
                e.Handled = true;
                return;
            }
        }

        if (!_running) { base.OnKeyDown(e); return; }

        string? seq = e.Key switch
        {
            Key.Enter => "\r",
            Key.Back => "\x7f",
            Key.Tab => "\t",
            Key.Escape => "\x1b",
            Key.Up => "\x1b[A",
            Key.Down => "\x1b[B",
            Key.Right => "\x1b[C",
            Key.Left => "\x1b[D",
            Key.Home => "\x1b[H",
            Key.End => "\x1b[F",
            Key.PageUp => "\x1b[5~",
            Key.PageDown => "\x1b[6~",
            Key.Delete => "\x1b[3~",
            Key.Insert => "\x1b[2~",
            _ => null
        };

        if (seq != null)
        {
            if (e.Key == Key.Enter) CommitInputLine();
            else if (e.Key == Key.Back && _inputLine.Length > 0) _inputLine.Remove(_inputLine.Length - 1, 1);
            var bytes = Encoding.UTF8.GetBytes(seq);
            Send(bytes);
            UserInput?.Invoke(this, bytes);
            e.Handled = true;
            return;
        }

        // Ctrl+A..Z -> control codes 0x01..0x1A
        if (ctrl && e.Key >= Key.A && e.Key <= Key.Z)
        {
            if (e.Key == Key.C || e.Key == Key.U) _inputLine.Clear();
            var code = (byte)(e.Key - Key.A + 1);
            Send(new[] { code });
            UserInput?.Invoke(this, new[] { code });
            e.Handled = true;
            return;
        }

        base.OnKeyDown(e);
    }

    private void Send(byte[] data)
    {
        try { _pty?.Write(data); } catch { /* pipe closed */ }
    }

    private void CommitInputLine()
    {
        var line = _inputLine.ToString().Trim();
        _inputLine.Clear();
        if (line.Length == 0) return;
        // Never record what looks like a password/passphrase entry.
        var prompt = _emu.CurrentLineText().ToLowerInvariant();
        if (prompt.Contains("password") || prompt.Contains("passphrase")) return;
        LineEntered?.Invoke(line);
    }

    public void SendText(string text) => Send(Encoding.UTF8.GetBytes(text));

    public void Paste(string text)
    {
        if (!string.IsNullOrEmpty(text)) Send(Encoding.UTF8.GetBytes(text));
    }

    private async System.Threading.Tasks.Task PasteFromClipboardAsync(Avalonia.Input.Platform.IClipboard cb)
    {
        try
        {
            var text = await cb.GetTextAsync();
            if (!string.IsNullOrEmpty(text)) Paste(text);
        }
        catch { /* clipboard unavailable */ }
    }

    // ---- Broadcast input (type-to-all) ----

    /// <summary>Raised with the raw bytes the user typed, so a controller can mirror
    /// them to other terminals when broadcast mode is on.</summary>
    public event Action<TerminalControl, byte[]>? UserInput;

    /// <summary>Write bytes to the child without re-raising <see cref="UserInput"/>
    /// (used by the broadcast controller to mirror keystrokes).</summary>
    public void MirrorInput(byte[] data) => Send(data);

    // ---- Session logging ----

    private System.IO.FileStream? _log;

    /// <summary>Begin appending raw session output to <paramref name="path"/>.</summary>
    public void StartLogging(string path)
    {
        try
        {
            System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
            _log = new System.IO.FileStream(path, System.IO.FileMode.Append,
                System.IO.FileAccess.Write, System.IO.FileShare.Read);
        }
        catch { _log = null; }
    }

    public void StopLogging()
    {
        try { _log?.Flush(); _log?.Dispose(); } catch { }
        _log = null;
    }

    /// <summary>The full scrollback + live screen as plain text (for copy / save).</summary>
    public string ScrollbackText() => _emu.AllText();

    /// <summary>Copy the full scrollback to the clipboard.</summary>
    public void CopyScrollback()
        => TopLevel.GetTopLevel(this)?.Clipboard?.SetTextAsync(_emu.AllText());

    /// <summary>Save the full scrollback to a user-chosen text file.</summary>
    public async System.Threading.Tasks.Task SaveScrollbackAsync(string suggestedName)
    {
        if (TopLevel.GetTopLevel(this)?.StorageProvider is not { } sp) return;
        var file = await sp.SaveFilePickerAsync(new Avalonia.Platform.Storage.FilePickerSaveOptions
        {
            SuggestedFileName = suggestedName,
            DefaultExtension = "log"
        });
        if (file is null) return;
        try
        {
            await using var stream = await file.OpenWriteAsync();
            await using var writer = new System.IO.StreamWriter(stream);
            await writer.WriteAsync(_emu.AllText());
        }
        catch { /* couldn't write file */ }
    }

    /// <summary>Clear the scrollback and visible screen (Terminal.app ⌘K).</summary>
    public void Clear()
    {
        _scrollOffset = 0;
        _emu.ClearScrollback();
    }

    public void ZoomIn() => FontSize = Models.TerminalFontMetrics.Clamp(FontSize + Models.TerminalFontMetrics.Step);
    public void ZoomOut() => FontSize = Models.TerminalFontMetrics.Clamp(FontSize - Models.TerminalFontMetrics.Step);
    public void ZoomReset() => FontSize = Models.TerminalFontMetrics.Default;

    public void Terminate()
    {
        _running = false;
        _reapTimer?.Stop();
        _pty?.Terminate();
    }

    public void DisposeSession()
    {
        _running = false;
        _reapTimer?.Stop();
        StopLogging();
        _pty?.Dispose();
        _pty = null;
    }
}
