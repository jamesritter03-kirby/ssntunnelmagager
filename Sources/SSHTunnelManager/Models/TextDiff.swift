import Foundation

/// Per-row diff status shared with the Scintilla bridge. The raw `Int` values
/// MUST stay in sync with the bridge's interpretation in `SciEditorView.mm`.
enum DiffRowStatus: Int {
    case equal = 0     // identical on both sides
    case added = 1     // present only on the right
    case deleted = 2   // present only on the left
    case changed = 3   // present on both sides but different
    case filler = 4    // a blank spacer inserted to keep the two sides aligned
}

/// One side (left or right) of an aligned diff, already padded with filler rows
/// so both sides have exactly the same number of rows.
struct DiffSide {
    /// Rows joined with "\n"; filler rows are empty lines.
    var text: String
    /// `DiffRowStatus.rawValue` for each row.
    var status: [Int]
    /// Original 1-based line number for each row (0 for filler rows).
    var numbers: [Int]
    /// Start of an intra-line change, in UTF-8 bytes within the row (0 = none).
    var spanStart: [Int]
    /// Length of the intra-line change, in UTF-8 bytes (0 = no intra-line span).
    var spanLength: [Int]
}

/// The result of aligning two documents line-by-line.
struct DiffResult {
    var left: DiffSide
    var right: DiffSide
}

/// A small, dependency-free line differ used by the Scintilla compare view.
///
/// It interns lines to integers, trims the common prefix/suffix, runs a classic
/// longest-common-subsequence alignment on the middle, then pairs adjacent
/// deletes/inserts into "changed" rows and pads each side with filler rows so
/// the two panes line up. For changed rows it also computes a single intra-line
/// highlight span (the differing middle after trimming a common prefix/suffix).
enum TextDiff {

    /// The three primitive alignment operations, carrying original indices.
    private enum Op {
        case equal(Int, Int)   // (leftIndex, rightIndex)
        case del(Int)          // leftIndex only
        case ins(Int)          // rightIndex only
    }

    static func compare(_ leftText: String, _ rightText: String) -> DiffResult {
        let a = leftText.components(separatedBy: "\n")
        let b = rightText.components(separatedBy: "\n")

        // Intern lines to integers so the alignment compares Ints, not Strings.
        var table: [String: Int] = [:]
        table.reserveCapacity(a.count + b.count)
        func intern(_ s: String) -> Int {
            if let v = table[s] { return v }
            let v = table.count; table[s] = v; return v
        }
        let ai = a.map(intern)
        let bi = b.map(intern)

        let ops = diffOps(ai, bi)

        var left = SideBuilder()
        var right = SideBuilder()
        var pendingDel: [Int] = []
        var pendingIns: [Int] = []

        func flushGap() {
            if pendingDel.isEmpty && pendingIns.isEmpty { return }
            let k = min(pendingDel.count, pendingIns.count)
            // Pair up as many delete/insert lines as possible into "changed".
            for i in 0..<k {
                let li = pendingDel[i], ri = pendingIns[i]
                let (ls, ll, rs, rl) = intralineSpan(a[li], b[ri])
                left.add(a[li], .changed, li + 1, ls, ll)
                right.add(b[ri], .changed, ri + 1, rs, rl)
            }
            // Remaining deletes: real on the left, filler on the right.
            for i in k..<pendingDel.count {
                let li = pendingDel[i]
                left.add(a[li], .deleted, li + 1)
                right.add("", .filler, 0)
            }
            // Remaining inserts: filler on the left, real on the right.
            for i in k..<pendingIns.count {
                let ri = pendingIns[i]
                left.add("", .filler, 0)
                right.add(b[ri], .added, ri + 1)
            }
            pendingDel.removeAll(keepingCapacity: true)
            pendingIns.removeAll(keepingCapacity: true)
        }

        for op in ops {
            switch op {
            case .equal(let li, let ri):
                flushGap()
                left.add(a[li], .equal, li + 1)
                right.add(b[ri], .equal, ri + 1)
            case .del(let li):
                pendingDel.append(li)
            case .ins(let ri):
                pendingIns.append(ri)
            }
        }
        flushGap()

        return DiffResult(left: left.side(), right: right.side())
    }

    // MARK: - Alignment

    /// Produces an ordered list of equal/delete/insert operations, trimming the
    /// common prefix and suffix first so the LCS only runs on the middle.
    private static func diffOps(_ a: [Int], _ b: [Int]) -> [Op] {
        var ops: [Op] = []

        var lo = 0
        let n = a.count, m = b.count
        while lo < n && lo < m && a[lo] == b[lo] {
            ops.append(.equal(lo, lo)); lo += 1
        }

        var hiA = n, hiB = m
        var suffix: [Op] = []
        while hiA > lo && hiB > lo && a[hiA - 1] == b[hiB - 1] {
            hiA -= 1; hiB -= 1
            suffix.append(.equal(hiA, hiB))
        }
        suffix.reverse()

        ops.append(contentsOf: lcsOps(a, b, lo: lo, hiA: hiA, hiB: hiB))
        ops.append(contentsOf: suffix)
        return ops
    }

    /// Classic LCS over `a[lo..<hiA]` vs `b[lo..<hiB]`, emitting ops with the
    /// original indices. Falls back to a full replace for very large middles.
    private static func lcsOps(_ a: [Int], _ b: [Int], lo: Int, hiA: Int, hiB: Int) -> [Op] {
        let n = hiA - lo, m = hiB - lo
        if n == 0 && m == 0 { return [] }
        if n == 0 { return (lo..<hiB).map { .ins($0) } }
        if m == 0 { return (lo..<hiA).map { .del($0) } }
        if n * m > 4_000_000 {
            // Too large to align precisely; show the middle as a full replace.
            var ops: [Op] = (lo..<hiA).map { .del($0) }
            ops.append(contentsOf: (lo..<hiB).map { .ins($0) })
            return ops
        }

        // dp[i][j] = LCS length of a[lo+i ..< hiA] and b[lo+j ..< hiB].
        let cols = m + 1
        var dp = [Int](repeating: 0, count: (n + 1) * cols)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if a[lo + i] == b[lo + j] {
                    dp[i * cols + j] = dp[(i + 1) * cols + (j + 1)] + 1
                } else {
                    dp[i * cols + j] = max(dp[(i + 1) * cols + j], dp[i * cols + (j + 1)])
                }
            }
        }

        var ops: [Op] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[lo + i] == b[lo + j] {
                ops.append(.equal(lo + i, lo + j)); i += 1; j += 1
            } else if dp[(i + 1) * cols + j] >= dp[i * cols + (j + 1)] {
                ops.append(.del(lo + i)); i += 1
            } else {
                ops.append(.ins(lo + j)); j += 1
            }
        }
        while i < n { ops.append(.del(lo + i)); i += 1 }
        while j < m { ops.append(.ins(lo + j)); j += 1 }
        return ops
    }

    // MARK: - Intra-line span

    /// Trims a common prefix and suffix (by character) from two differing lines
    /// and returns the byte offset + byte length of the changed middle on each
    /// side, ready to feed Scintilla's UTF-8 positions.
    private static func intralineSpan(_ x: String, _ y: String)
        -> (leftStart: Int, leftLen: Int, rightStart: Int, rightLen: Int) {
        let xc = Array(x), yc = Array(y)
        var p = 0
        while p < xc.count && p < yc.count && xc[p] == yc[p] { p += 1 }
        var s = 0
        while s < (xc.count - p) && s < (yc.count - p)
              && xc[xc.count - 1 - s] == yc[yc.count - 1 - s] { s += 1 }

        let leftPrefix = String(xc[0..<p])
        let leftMiddle = String(xc[p..<(xc.count - s)])
        let rightPrefix = String(yc[0..<p])
        let rightMiddle = String(yc[p..<(yc.count - s)])

        return (leftPrefix.utf8.count, leftMiddle.utf8.count,
                rightPrefix.utf8.count, rightMiddle.utf8.count)
    }

    // MARK: - Side accumulator

    private struct SideBuilder {
        private var lines: [String] = []
        private var status: [Int] = []
        private var numbers: [Int] = []
        private var spanStart: [Int] = []
        private var spanLength: [Int] = []

        mutating func add(_ line: String, _ st: DiffRowStatus, _ number: Int,
                          _ start: Int = 0, _ length: Int = 0) {
            lines.append(line)
            status.append(st.rawValue)
            numbers.append(number)
            spanStart.append(start)
            spanLength.append(length)
        }

        func side() -> DiffSide {
            DiffSide(text: lines.joined(separator: "\n"),
                     status: status, numbers: numbers,
                     spanStart: spanStart, spanLength: spanLength)
        }
    }
}
