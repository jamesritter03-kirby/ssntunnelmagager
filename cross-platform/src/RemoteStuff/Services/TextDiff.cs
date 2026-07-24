using System;
using System.Collections.Generic;

namespace RemoteStuff.Services;

/// <summary>Per-row diff classification for the two-pane compare view.</summary>
public enum DiffRowStatus
{
    Equal = 0,   // identical on both sides
    Added = 1,   // present only on the right
    Deleted = 2, // present only on the left
    Changed = 3, // present on both sides but different
    Filler = 4,  // a blank spacer inserted to keep the two sides aligned
}

/// <summary>One aligned row of a side-by-side diff. Both sides always share the
/// same number of rows; filler rows keep them lined up.</summary>
public sealed class DiffRow
{
    public int LeftNumber { get; init; }        // 1-based; 0 for filler
    public string LeftText { get; init; } = "";
    public DiffRowStatus LeftStatus { get; init; }

    public int RightNumber { get; init; }       // 1-based; 0 for filler
    public string RightText { get; init; } = "";
    public DiffRowStatus RightStatus { get; init; }

    public string LeftNumberText => LeftNumber > 0 ? LeftNumber.ToString() : "";
    public string RightNumberText => RightNumber > 0 ? RightNumber.ToString() : "";
}

/// <summary>A small, dependency-free line differ (a C# port of the macOS app's
/// <c>TextDiff</c>). Interns lines to integers, trims the common prefix/suffix,
/// runs a classic LCS over the middle, then pairs adjacent deletes/inserts into
/// "changed" rows and pads each side with filler rows so the panes line up.</summary>
public static class TextDiff
{
    private enum Kind { Equal, Del, Ins }

    private readonly struct Op
    {
        public readonly Kind Kind;
        public readonly int Left;
        public readonly int Right;
        public Op(Kind kind, int left, int right) { Kind = kind; Left = left; Right = right; }
    }

    public static List<DiffRow> Compare(string leftText, string rightText)
    {
        var a = (leftText ?? "").Replace("\r\n", "\n").Replace("\r", "\n").Split('\n');
        var b = (rightText ?? "").Replace("\r\n", "\n").Replace("\r", "\n").Split('\n');

        // Intern lines to integers so the alignment compares ints, not strings.
        var table = new Dictionary<string, int>(a.Length + b.Length);
        int Intern(string s)
        {
            if (table.TryGetValue(s, out var v)) return v;
            v = table.Count; table[s] = v; return v;
        }
        var ai = new int[a.Length];
        var bi = new int[b.Length];
        for (int i = 0; i < a.Length; i++) ai[i] = Intern(a[i]);
        for (int i = 0; i < b.Length; i++) bi[i] = Intern(b[i]);

        var ops = DiffOps(ai, bi);

        var rows = new List<DiffRow>();
        var pendingDel = new List<int>();
        var pendingIns = new List<int>();

        void FlushGap()
        {
            if (pendingDel.Count == 0 && pendingIns.Count == 0) return;
            int k = Math.Min(pendingDel.Count, pendingIns.Count);
            for (int i = 0; i < k; i++)
            {
                int li = pendingDel[i], ri = pendingIns[i];
                rows.Add(new DiffRow
                {
                    LeftNumber = li + 1, LeftText = a[li], LeftStatus = DiffRowStatus.Changed,
                    RightNumber = ri + 1, RightText = b[ri], RightStatus = DiffRowStatus.Changed,
                });
            }
            for (int i = k; i < pendingDel.Count; i++)
            {
                int li = pendingDel[i];
                rows.Add(new DiffRow
                {
                    LeftNumber = li + 1, LeftText = a[li], LeftStatus = DiffRowStatus.Deleted,
                    RightNumber = 0, RightText = "", RightStatus = DiffRowStatus.Filler,
                });
            }
            for (int i = k; i < pendingIns.Count; i++)
            {
                int ri = pendingIns[i];
                rows.Add(new DiffRow
                {
                    LeftNumber = 0, LeftText = "", LeftStatus = DiffRowStatus.Filler,
                    RightNumber = ri + 1, RightText = b[ri], RightStatus = DiffRowStatus.Added,
                });
            }
            pendingDel.Clear();
            pendingIns.Clear();
        }

        foreach (var op in ops)
        {
            switch (op.Kind)
            {
                case Kind.Equal:
                    FlushGap();
                    rows.Add(new DiffRow
                    {
                        LeftNumber = op.Left + 1, LeftText = a[op.Left], LeftStatus = DiffRowStatus.Equal,
                        RightNumber = op.Right + 1, RightText = b[op.Right], RightStatus = DiffRowStatus.Equal,
                    });
                    break;
                case Kind.Del:
                    pendingDel.Add(op.Left);
                    break;
                case Kind.Ins:
                    pendingIns.Add(op.Right);
                    break;
            }
        }
        FlushGap();
        return rows;
    }

    /// <summary>True when the two texts differ line-for-line.</summary>
    public static bool AreDifferent(string leftText, string rightText)
    {
        var l = (leftText ?? "").Replace("\r\n", "\n").Replace("\r", "\n");
        var r = (rightText ?? "").Replace("\r\n", "\n").Replace("\r", "\n");
        return !string.Equals(l, r, StringComparison.Ordinal);
    }

    private static List<Op> DiffOps(int[] a, int[] b)
    {
        var ops = new List<Op>();
        int lo = 0, n = a.Length, m = b.Length;
        while (lo < n && lo < m && a[lo] == b[lo])
        {
            ops.Add(new Op(Kind.Equal, lo, lo)); lo++;
        }

        int hiA = n, hiB = m;
        var suffix = new List<Op>();
        while (hiA > lo && hiB > lo && a[hiA - 1] == b[hiB - 1])
        {
            hiA--; hiB--;
            suffix.Add(new Op(Kind.Equal, hiA, hiB));
        }
        suffix.Reverse();

        ops.AddRange(LcsOps(a, b, lo, hiA, hiB));
        ops.AddRange(suffix);
        return ops;
    }

    private static List<Op> LcsOps(int[] a, int[] b, int lo, int hiA, int hiB)
    {
        int n = hiA - lo, m = hiB - lo;
        var ops = new List<Op>();
        if (n == 0 && m == 0) return ops;
        if (n == 0)
        {
            for (int j = lo; j < hiB; j++) ops.Add(new Op(Kind.Ins, 0, j));
            return ops;
        }
        if (m == 0)
        {
            for (int i = lo; i < hiA; i++) ops.Add(new Op(Kind.Del, i, 0));
            return ops;
        }
        if ((long)n * m > 4_000_000)
        {
            for (int i = lo; i < hiA; i++) ops.Add(new Op(Kind.Del, i, 0));
            for (int j = lo; j < hiB; j++) ops.Add(new Op(Kind.Ins, 0, j));
            return ops;
        }

        int cols = m + 1;
        var dp = new int[(n + 1) * cols];
        for (int i = n - 1; i >= 0; i--)
        {
            for (int j = m - 1; j >= 0; j--)
            {
                if (a[lo + i] == b[lo + j])
                    dp[i * cols + j] = dp[(i + 1) * cols + (j + 1)] + 1;
                else
                    dp[i * cols + j] = Math.Max(dp[(i + 1) * cols + j], dp[i * cols + (j + 1)]);
            }
        }

        int x = 0, y = 0;
        while (x < n && y < m)
        {
            if (a[lo + x] == b[lo + y]) { ops.Add(new Op(Kind.Equal, lo + x, lo + y)); x++; y++; }
            else if (dp[(x + 1) * cols + y] >= dp[x * cols + (y + 1)]) { ops.Add(new Op(Kind.Del, lo + x, 0)); x++; }
            else { ops.Add(new Op(Kind.Ins, 0, lo + y)); y++; }
        }
        while (x < n) { ops.Add(new Op(Kind.Del, lo + x, 0)); x++; }
        while (y < m) { ops.Add(new Op(Kind.Ins, 0, lo + y)); y++; }
        return ops;
    }
}
