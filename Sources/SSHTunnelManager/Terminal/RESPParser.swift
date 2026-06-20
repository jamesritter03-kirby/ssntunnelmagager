import Foundation

/// A decoded **RESP** (REdis Serialization Protocol, v2) value.
enum RESPValue: Equatable {
    case simpleString(String)
    case error(String)
    case integer(Int64)
    case bulk(String?)          // nil = null bulk string ($-1)
    case array([RESPValue]?)    // nil = null array (*-1)

    /// A flat, human‑readable rendering (used by the command console).
    var displayText: String {
        switch self {
        case .simpleString(let s): return s
        case .error(let e): return "(error) \(e)"
        case .integer(let i): return "(integer) \(i)"
        case .bulk(let s): return s ?? "(nil)"
        case .array(let items):
            guard let items, !items.isEmpty else { return items == nil ? "(nil)" : "(empty array)" }
            return items.enumerated()
                .map { "\($0.offset + 1)) \($0.element.displayText)" }
                .joined(separator: "\n")
        }
    }

    /// The string payload of a bulk/simple value (nil for other kinds).
    var stringValue: String? {
        switch self {
        case .bulk(let s): return s
        case .simpleString(let s): return s
        default: return nil
        }
    }

    /// Flatten an array reply to its element strings (bulk/simple), skipping others.
    var arrayStrings: [String] {
        guard case .array(let items?) = self else { return [] }
        return items.compactMap { $0.stringValue }
    }
}

/// Incremental RESP parser: pulls complete values out of a growing byte buffer.
enum RESPParser {
    /// Parse one value beginning at `index`. Returns the value and the index just
    /// past it, or nil when more bytes are needed.
    static func parse(_ bytes: [UInt8], at index: Int) -> (value: RESPValue, next: Int)? {
        guard index < bytes.count else { return nil }
        guard let (line, afterLine) = readLine(bytes, from: index + 1) else { return nil }
        switch bytes[index] {
        case UInt8(ascii: "+"):
            return (.simpleString(line), afterLine)
        case UInt8(ascii: "-"):
            return (.error(line), afterLine)
        case UInt8(ascii: ":"):
            return (.integer(Int64(line) ?? 0), afterLine)
        case UInt8(ascii: "$"):
            let length = Int(line) ?? -1
            if length < 0 { return (.bulk(nil), afterLine) }
            let end = afterLine + length
            guard bytes.count >= end + 2 else { return nil }   // data + trailing CRLF
            let text = String(decoding: bytes[afterLine..<end], as: UTF8.self)
            return (.bulk(text), end + 2)
        case UInt8(ascii: "*"):
            let count = Int(line) ?? -1
            if count < 0 { return (.array(nil), afterLine) }
            var items: [RESPValue] = []
            var cursor = afterLine
            for _ in 0..<count {
                guard let (item, next) = parse(bytes, at: cursor) else { return nil }
                items.append(item)
                cursor = next
            }
            return (.array(items), cursor)
        default:
            return nil
        }
    }

    /// Read up to (and consuming) the next CRLF. Returns the line text and the
    /// index past the CRLF, or nil if no complete line is buffered yet.
    private static func readLine(_ bytes: [UInt8], from start: Int) -> (String, Int)? {
        var i = start
        while i + 1 < bytes.count {
            if bytes[i] == 0x0D && bytes[i + 1] == 0x0A {
                return (String(decoding: bytes[start..<i], as: UTF8.self), i + 2)
            }
            i += 1
        }
        return nil
    }

    /// Encode a command as a RESP array of bulk strings (the inline command form).
    static func encode(command args: [String]) -> Data {
        var data = Data("*\(args.count)\r\n".utf8)
        for arg in args {
            let bytes = Array(arg.utf8)
            data.append(Data("$\(bytes.count)\r\n".utf8))
            data.append(contentsOf: bytes)
            data.append(0x0D); data.append(0x0A)
        }
        return data
    }

    /// Split a typed command line into arguments, honoring simple single/double
    /// quoting (so `SET k "a b"` becomes three args).
    static func tokenize(_ line: String) -> [String] {
        var args: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for ch in line {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                hasToken = true
            } else if ch == " " || ch == "\t" {
                if hasToken { args.append(current); current = ""; hasToken = false }
            } else {
                current.append(ch)
                hasToken = true
            }
        }
        if hasToken { args.append(current) }
        return args
    }
}
