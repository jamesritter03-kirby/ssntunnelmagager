import Foundation

/// Reads and writes Microsoft Excel `.xlsx` (Office Open XML) workbooks as plain
/// grids of string cells — one `[[String]]` per worksheet — with no external
/// dependencies (it sits on top of ``MiniZip`` and Foundation's `XMLParser`).
///
/// What it understands when **reading**: shared & inline strings, numbers,
/// booleans, and formula cells (using their cached `<v>` value). Numeric cells
/// whose style is a date/time number format are converted to a readable
/// `yyyy-MM-dd` (or with a time component). Every worksheet in the workbook is
/// read, in workbook order.
///
/// What it produces when **writing**: a minimal but valid workbook Excel and
/// Numbers open cleanly. Cells that look like plain numbers are written as
/// numbers; everything else is written as an inline string, so text that merely
/// resembles a number (leading zeros, long digit runs, phone numbers) is
/// preserved exactly.
enum XLSXDocument {

    /// One worksheet: a name plus its rows of string cells (ragged rows are
    /// padded to the widest row by the caller as needed).
    struct Sheet {
        var name: String
        var rows: [[String]]
    }

    enum XLSXError: LocalizedError {
        case notAnArchive
        case noWorksheets
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAnArchive:      return "This file isn’t a valid .xlsx workbook."
            case .noWorksheets:      return "This workbook has no readable worksheets."
            case .writeFailed(let m): return m
            }
        }
    }

    // MARK: - Reading

    static func read(from url: URL) throws -> [Sheet] {
        let data = try Data(contentsOf: url)
        return try read(data: data)
    }

    static func read(data: Data) throws -> [Sheet] {
        guard let zip = MiniZip.Reader(data: data) else { throw XLSXError.notAnArchive }

        let sharedStrings = zip.text("xl/sharedStrings.xml").map(parseSharedStrings) ?? []
        let dateStyles = zip.text("xl/styles.xml").map(parseDateStyles) ?? []

        // Map each sheet's r:id (from workbook.xml) to its part path (from the
        // workbook rels), preserving the workbook's sheet order.
        let workbookXML = zip.text("xl/workbook.xml") ?? ""
        let relsXML = zip.text("xl/_rels/workbook.xml.rels") ?? ""
        let relTargets = parseRelationships(relsXML)          // rId -> target
        let sheetRefs = parseWorkbookSheets(workbookXML)      // [(name, rId)]

        var sheets: [Sheet] = []
        for ref in sheetRefs {
            var target = relTargets[ref.rId] ?? ""
            if target.isEmpty { continue }
            if !target.hasPrefix("/") {
                target = "xl/" + target.replacingOccurrences(of: "../", with: "")
            } else {
                target.removeFirst()
            }
            guard let sheetXML = zip.text(target) else { continue }
            let rows = parseWorksheet(sheetXML, sharedStrings: sharedStrings, dateStyles: dateStyles)
            sheets.append(Sheet(name: ref.name, rows: rows))
        }

        // Fallback: no workbook wiring found — read any worksheet parts directly.
        if sheets.isEmpty {
            let parts = zip.entries
                .map(\.name)
                .filter { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") }
                .sorted()
            for (i, part) in parts.enumerated() {
                guard let sheetXML = zip.text(part) else { continue }
                let rows = parseWorksheet(sheetXML, sharedStrings: sharedStrings, dateStyles: dateStyles)
                sheets.append(Sheet(name: "Sheet\(i + 1)", rows: rows))
            }
        }

        guard !sheets.isEmpty else { throw XLSXError.noWorksheets }
        return sheets
    }

    // MARK: - Writing

    static func write(sheets: [Sheet], to url: URL) throws {
        let data = try archive(sheets: sheets)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw XLSXError.writeFailed(error.localizedDescription)
        }
    }

    static func archive(sheets rawSheets: [Sheet]) throws -> Data {
        let sheets = rawSheets.isEmpty ? [Sheet(name: "Sheet1", rows: [[]])] : rawSheets
        var zip = MiniZip.Writer()

        // [Content_Types].xml
        var contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        """
        for i in sheets.indices {
            contentTypes += "<Override PartName=\"/xl/worksheets/sheet\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        contentTypes += "</Types>"
        zip.addFile("[Content_Types].xml", string: contentTypes)

        // _rels/.rels
        zip.addFile("_rels/.rels", string: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """)

        // xl/workbook.xml
        var workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>
        """
        for (i, sheet) in sheets.enumerated() {
            workbook += "<sheet name=\"\(escapeAttr(sheetName(sheet.name, index: i)))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
        }
        workbook += "</sheets></workbook>"
        zip.addFile("xl/workbook.xml", string: workbook)

        // xl/_rels/workbook.xml.rels
        var wbRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        """
        for i in sheets.indices {
            wbRels += "<Relationship Id=\"rId\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i + 1).xml\"/>"
        }
        let stylesRelID = sheets.count + 1
        wbRels += "<Relationship Id=\"rId\(stylesRelID)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        wbRels += "</Relationships>"
        zip.addFile("xl/_rels/workbook.xml.rels", string: wbRels)

        // xl/styles.xml — the minimal single default style Excel expects.
        zip.addFile("xl/styles.xml", string: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts><fills count="1"><fill><patternFill patternType="none"/></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs></styleSheet>
        """)

        // Worksheets.
        for (i, sheet) in sheets.enumerated() {
            zip.addFile("xl/worksheets/sheet\(i + 1).xml", string: worksheetXML(sheet))
        }

        return zip.finalize()
    }

    // MARK: - Worksheet serialization

    private static func worksheetXML(_ sheet: Sheet) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        """
        for (r, row) in sheet.rows.enumerated() {
            if row.allSatisfy({ $0.isEmpty }) { continue }   // skip fully empty rows
            xml += "<row r=\"\(r + 1)\">"
            for (c, value) in row.enumerated() where !value.isEmpty {
                let ref = "\(columnLetters(c))\(r + 1)"
                if let number = numericValue(value) {
                    xml += "<c r=\"\(ref)\"><v>\(number)</v></c>"
                } else {
                    xml += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escapeText(value))</t></is></c>"
                }
            }
            xml += "</row>"
        }
        xml += "</sheetData></worksheet>"
        return xml
    }

    /// A value that should be written as a real number, or nil to keep it text.
    /// Guards against mangling values that merely look numeric (leading zeros,
    /// a leading `+`, very long digit strings, whitespace).
    private static func numericValue(_ value: String) -> String? {
        let s = value.trimmingCharacters(in: .whitespaces)
        guard s == value, !s.isEmpty else { return nil }
        guard let d = Double(s), d.isFinite else { return nil }
        // Reject forms that wouldn't round‑trip as the same text.
        if s.count > 15 { return nil }
        if s.hasPrefix("+") { return nil }
        if s.hasPrefix("0") && s.count > 1 && !s.hasPrefix("0.") { return nil }
        if s.hasPrefix("-0") && s.count > 2 && !s.hasPrefix("-0.") { return nil }
        return s
    }

    // MARK: - XML escaping

    private static func escapeText(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default:  out.append(ch)
            }
        }
        return out
    }

    private static func escapeAttr(_ s: String) -> String {
        escapeText(s).replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Excel limits sheet names to 31 chars and forbids `[]*?/\:`.
    private static func sheetName(_ raw: String, index: Int) -> String {
        let forbidden = CharacterSet(charactersIn: "[]*?/\\:")
        var name = raw.components(separatedBy: forbidden).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "Sheet\(index + 1)" }
        if name.count > 31 { name = String(name.prefix(31)) }
        return name
    }

    // MARK: - Column letters ⇄ index

    static func columnLetters(_ index: Int) -> String {
        var n = index
        var name = ""
        repeat {
            name = String(UnicodeScalar(UInt8(65 + n % 26))) + name
            n = n / 26 - 1
        } while n >= 0
        return name
    }

    /// Split a cell reference like "AB12" into (columnIndex, rowIndex), 0‑based.
    static func parseCellRef(_ ref: String) -> (col: Int, row: Int)? {
        var col = 0
        var row = 0
        var sawLetter = false, sawDigit = false
        for ch in ref.uppercased() {
            if ch.isLetter, let a = ch.asciiValue {
                col = col * 26 + Int(a - 64)
                sawLetter = true
            } else if ch.isNumber, let d = ch.wholeNumberValue {
                row = row * 10 + d
                sawDigit = true
            }
        }
        guard sawLetter, sawDigit else { return nil }
        return (col - 1, row - 1)
    }

    // MARK: - Parsing helpers (XMLParser-backed)

    private static func parseSharedStrings(_ xml: String) -> [String] {
        let parser = SharedStringsParser()
        parser.run(xml)
        return parser.strings
    }

    /// Returns, indexed by cellXfs position, whether that style is a date/time.
    private static func parseDateStyles(_ xml: String) -> [Bool] {
        let parser = StylesParser()
        parser.run(xml)
        return parser.dateFlags
    }

    private static func parseRelationships(_ xml: String) -> [String: String] {
        let parser = RelationshipsParser()
        parser.run(xml)
        return parser.targets
    }

    private static func parseWorkbookSheets(_ xml: String) -> [(name: String, rId: String)] {
        let parser = WorkbookSheetsParser()
        parser.run(xml)
        return parser.sheets
    }

    private static func parseWorksheet(_ xml: String, sharedStrings: [String],
                                       dateStyles: [Bool]) -> [[String]] {
        let parser = WorksheetParser(sharedStrings: sharedStrings, dateStyles: dateStyles)
        parser.run(xml)
        return parser.grid()
    }
}

// MARK: - XMLParser delegates

private class BaseXMLHandler: NSObject, XMLParserDelegate {
    func run(_ xml: String) {
        guard let data = xml.data(using: .utf8) else { return }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }
}

/// `xl/sharedStrings.xml` → the ordered list of shared strings (concatenating
/// rich‑text runs within each `<si>`).
private final class SharedStringsParser: BaseXMLHandler {
    var strings: [String] = []
    private var current = ""
    private var capturing = false
    private var depth = 0

    func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if name == "si" { current = ""; depth = 0 }
        if name == "t" { capturing = true }
    }

    func parser(_ p: XMLParser, foundCharacters string: String) {
        if capturing { current += string }
    }

    func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        if name == "t" { capturing = false }
        if name == "si" { strings.append(current) }
    }
}

/// `xl/styles.xml` → for each `<cellXfs>/<xf>`, whether its number format is a
/// date/time (built‑in date ids, or a custom format code with date/time tokens).
private final class StylesParser: BaseXMLHandler {
    var dateFlags: [Bool] = []
    private var customDateFormats: Set<Int> = []
    private var inCellXfs = false

    private static let builtinDateIDs: Set<Int> =
        [14, 15, 16, 17, 18, 19, 20, 21, 22, 45, 46, 47]

    func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        switch name {
        case "numFmt":
            if let idStr = attributes["numFmtId"], let id = Int(idStr),
               let code = attributes["formatCode"], Self.looksLikeDate(code) {
                customDateFormats.insert(id)
            }
        case "cellXfs":
            inCellXfs = true
        case "xf" where inCellXfs:
            let id = attributes["numFmtId"].flatMap(Int.init) ?? 0
            let isDate = Self.builtinDateIDs.contains(id) || customDateFormats.contains(id)
            dateFlags.append(isDate)
        default:
            break
        }
    }

    func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        if name == "cellXfs" { inCellXfs = false }
    }

    private static func looksLikeDate(_ code: String) -> Bool {
        // Strip bracketed sections / quoted literals, then look for date tokens.
        let stripped = code.replacingOccurrences(of: "\\", with: "")
        let lower = stripped.lowercased()
        guard lower.contains("y") || lower.contains("d")
                || lower.contains("h") || lower.contains("s")
                || lower.range(of: "mm") != nil else { return false }
        return true
    }
}

/// `xl/_rels/workbook.xml.rels` → relationship id ➜ target part path.
private final class RelationshipsParser: BaseXMLHandler {
    var targets: [String: String] = [:]

    func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if name.hasSuffix("Relationship"), let id = attributes["Id"], let target = attributes["Target"] {
            targets[id] = target
        }
    }
}

/// `xl/workbook.xml` → the ordered `[(sheet name, r:id)]`.
private final class WorkbookSheetsParser: BaseXMLHandler {
    var sheets: [(name: String, rId: String)] = []

    func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        guard name == "sheet" else { return }
        let n = attributes["name"] ?? "Sheet\(sheets.count + 1)"
        let rid = attributes["r:id"] ?? attributes["id"] ?? ""
        sheets.append((n, rid))
    }
}

/// A worksheet part → a dense `[[String]]` grid. Understands `t="s"` (shared),
/// `t="inlineStr"`, `t="str"` (formula string), `t="b"` (boolean), and plain
/// numbers, converting date‑styled numbers to readable strings.
private final class WorksheetParser: BaseXMLHandler {
    private let sharedStrings: [String]
    private let dateStyles: [Bool]

    private var cells: [(row: Int, col: Int, value: String)] = []
    private var maxRow = -1
    private var maxCol = -1

    // Current cell state.
    private var curRow = 0
    private var curCol = 0
    private var curType = ""
    private var curStyle = -1
    private var curText = ""
    private var inValue = false
    private var inInlineString = false

    init(sharedStrings: [String], dateStyles: [Bool]) {
        self.sharedStrings = sharedStrings
        self.dateStyles = dateStyles
    }

    func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        switch name {
        case "c":
            curType = attributes["t"] ?? ""
            curStyle = attributes["s"].flatMap(Int.init) ?? -1
            curText = ""
            if let ref = attributes["r"], let pos = XLSXDocument.parseCellRef(ref) {
                curCol = pos.col
                curRow = pos.row
            } else {
                curCol += 1
            }
        case "v":
            inValue = true; curText = ""
        case "t" where curType == "inlineStr" || inInlineString:
            inValue = true; curText = ""
        case "is":
            inInlineString = true
        default:
            break
        }
    }

    func parser(_ p: XMLParser, foundCharacters string: String) {
        if inValue { curText += string }
    }

    func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        switch name {
        case "v", "t":
            inValue = false
        case "is":
            inInlineString = false
        case "c":
            let value = resolveValue()
            if !value.isEmpty {
                cells.append((curRow, curCol, value))
                maxRow = max(maxRow, curRow)
                maxCol = max(maxCol, curCol)
            }
        default:
            break
        }
    }

    private func resolveValue() -> String {
        switch curType {
        case "s":
            if let idx = Int(curText.trimmingCharacters(in: .whitespaces)),
               sharedStrings.indices.contains(idx) {
                return sharedStrings[idx]
            }
            return ""
        case "inlineStr", "str":
            return curText
        case "b":
            return curText.trimmingCharacters(in: .whitespaces) == "1" ? "TRUE" : "FALSE"
        default:
            // Numeric (or date-styled numeric).
            let raw = curText.trimmingCharacters(in: .whitespaces)
            if raw.isEmpty { return "" }
            if curStyle >= 0, dateStyles.indices.contains(curStyle), dateStyles[curStyle],
               let serial = Double(raw) {
                return XLSXDateFormatter.string(fromSerial: serial)
            }
            return raw
        }
    }

    /// Build a dense, rectangular grid from the sparse captured cells.
    func grid() -> [[String]] {
        guard maxRow >= 0, maxCol >= 0 else { return [] }
        var rows = Array(repeating: Array(repeating: "", count: maxCol + 1), count: maxRow + 1)
        for cell in cells where cell.row >= 0 && cell.col >= 0 {
            rows[cell.row][cell.col] = cell.value
        }
        return rows
    }
}

/// Converts an Excel serial date/time (1900 date system) into a readable string.
private enum XLSXDateFormatter {
    private static let base: Date = {
        var c = DateComponents()
        c.year = 1899; c.month = 12; c.day = 30       // accounts for the 1900 leap-year bug
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }()

    private static let dateOnly: DateFormatter = formatter("yyyy-MM-dd")
    private static let dateTime: DateFormatter = formatter("yyyy-MM-dd HH:mm:ss")

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    static func string(fromSerial serial: Double) -> String {
        let date = base.addingTimeInterval(serial * 86_400)
        let hasTime = serial.truncatingRemainder(dividingBy: 1) != 0
        return (hasTime ? dateTime : dateOnly).string(from: date)
    }
}
