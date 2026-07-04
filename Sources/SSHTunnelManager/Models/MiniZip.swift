import Foundation
import Compression

/// A tiny, dependency‑free ZIP archive reader / writer — just enough to read and
/// write Office Open XML (`.xlsx`) packages. Supports the two storage methods
/// those files use in practice: **stored** (method 0, uncompressed) and
/// **deflate** (method 8), the latter via Apple's `Compression` framework whose
/// `ZLIB` algorithm is raw DEFLATE — exactly what a ZIP entry contains.
///
/// This is intentionally minimal: no Zip64, no encryption, no spanning. `.xlsx`
/// files are small collections of XML parts, so a 32‑bit central directory is
/// plenty.
enum MiniZip {

    // MARK: - CRC32

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw {
                c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
            }
        }
        return c ^ 0xFFFF_FFFF
    }

    // MARK: - Deflate / inflate (raw DEFLATE via Compression)

    static func deflate(_ data: Data) -> Data? {
        if data.isEmpty { return Data() }
        return perform(data, operation: COMPRESSION_STREAM_ENCODE,
                       // Encoding shrinks, so a source‑sized buffer is a fine
                       // starting guess; we grow it if the stream needs more.
                       hint: max(64, data.count))
    }

    static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        if data.isEmpty { return Data() }
        return perform(data, operation: COMPRESSION_STREAM_DECODE,
                       hint: max(64, expectedSize))
    }

    /// Run a whole buffer through `compression_stream`, growing the output as
    /// needed. Uses `COMPRESSION_ZLIB`, which is raw DEFLATE (no zlib header).
    private static func perform(_ input: Data, operation: compression_stream_operation,
                                hint: Int) -> Data? {
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
                                        dst_size: 0,
                                        src_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
                                        src_size: 0, state: nil)
        guard compression_stream_init(&stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(&stream) }

        let dstCapacity = max(4096, hint)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
        defer { dst.deallocate() }

        var output = Data()
        let result: Data? = input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            stream.src_ptr = base
            stream.src_size = raw.count
            let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
            while true {
                stream.dst_ptr = dst
                stream.dst_size = dstCapacity
                let status = compression_stream_process(&stream, flags)
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let produced = dstCapacity - stream.dst_size
                    if produced > 0 { output.append(dst, count: produced) }
                    if status == COMPRESSION_STATUS_END { return output }
                default:
                    return nil
                }
            }
        }
        return result
    }

    // MARK: - Reading

    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let crc32: UInt32
        let localHeaderOffset: Int
    }

    struct Reader {
        let data: Data
        private(set) var entries: [Entry] = []
        private var byName: [String: Entry] = [:]

        init?(data: Data) {
            self.data = data
            guard parseCentralDirectory() else { return nil }
        }

        func contains(_ name: String) -> Bool { byName[name] != nil }

        /// The decompressed bytes of an entry, or nil if it's missing / corrupt.
        func fileData(_ name: String) -> Data? {
            guard let e = byName[name] else { return nil }
            let sig = data.u32(e.localHeaderOffset)
            guard sig == 0x0403_4b50 else { return nil }
            let nameLen = Int(data.u16(e.localHeaderOffset + 26))
            let extraLen = Int(data.u16(e.localHeaderOffset + 28))
            let start = e.localHeaderOffset + 30 + nameLen + extraLen
            guard start + e.compressedSize <= data.count else { return nil }
            let comp = data.subdata(in: start..<(start + e.compressedSize))
            switch e.method {
            case 0:  return comp
            case 8:  return MiniZip.inflate(comp, expectedSize: e.uncompressedSize)
            default: return nil
            }
        }

        func text(_ name: String) -> String? {
            fileData(name).map { String(decoding: $0, as: UTF8.self) }
        }

        private mutating func parseCentralDirectory() -> Bool {
            guard let eocd = findEOCD() else { return false }
            let count = Int(data.u16(eocd + 10))
            var offset = Int(data.u32(eocd + 16))
            for _ in 0..<count {
                guard offset + 46 <= data.count, data.u32(offset) == 0x0201_4b50 else { return false }
                let method = data.u16(offset + 10)
                let crc = data.u32(offset + 16)
                let compSize = Int(data.u32(offset + 20))
                let uncompSize = Int(data.u32(offset + 24))
                let nameLen = Int(data.u16(offset + 28))
                let extraLen = Int(data.u16(offset + 30))
                let commentLen = Int(data.u16(offset + 32))
                let localOffset = Int(data.u32(offset + 42))
                let nameStart = offset + 46
                guard nameStart + nameLen <= data.count else { return false }
                let name = String(decoding: data.subdata(in: nameStart..<(nameStart + nameLen)),
                                  as: UTF8.self)
                let entry = Entry(name: name, method: method, compressedSize: compSize,
                                  uncompressedSize: uncompSize, crc32: crc,
                                  localHeaderOffset: localOffset)
                entries.append(entry)
                byName[name] = entry
                offset = nameStart + nameLen + extraLen + commentLen
            }
            return true
        }

        /// Scan backwards for the End Of Central Directory signature.
        private func findEOCD() -> Int? {
            let sig: UInt32 = 0x0605_4b50
            guard data.count >= 22 else { return nil }
            let minStart = max(0, data.count - 22 - 65_536)
            var i = data.count - 22
            while i >= minStart {
                if data.u32(i) == sig { return i }
                i -= 1
            }
            return nil
        }
    }

    // MARK: - Writing

    struct Writer {
        private var output = Data()
        private struct Record {
            let name: String
            let crc: UInt32
            let compSize: Int
            let uncompSize: Int
            let method: UInt16
            let offset: Int
        }
        private var records: [Record] = []

        /// Append a file. Tries deflate; falls back to stored when compression
        /// doesn't help (or for empty files).
        mutating func addFile(_ name: String, data: Data) {
            let crc = MiniZip.crc32(data)
            let nameBytes = Array(name.utf8)
            var method: UInt16 = 0
            var payload = data
            if !data.isEmpty, let deflated = MiniZip.deflate(data), deflated.count < data.count {
                method = 8
                payload = deflated
            }
            let offset = output.count

            var local = Data()
            local.appendLE32(0x0403_4b50)                 // local file header signature
            local.appendLE16(20)                          // version needed
            local.appendLE16(0)                           // flags
            local.appendLE16(method)                      // compression method
            local.appendLE16(0)                           // mod time
            local.appendLE16(0)                           // mod date
            local.appendLE32(crc)                         // crc32
            local.appendLE32(UInt32(payload.count))       // compressed size
            local.appendLE32(UInt32(data.count))          // uncompressed size
            local.appendLE16(UInt16(nameBytes.count))     // file name length
            local.appendLE16(0)                           // extra length
            local.append(contentsOf: nameBytes)
            output.append(local)
            output.append(payload)

            records.append(Record(name: name, crc: crc, compSize: payload.count,
                                  uncompSize: data.count, method: method, offset: offset))
        }

        mutating func addFile(_ name: String, string: String) {
            addFile(name, data: Data(string.utf8))
        }

        /// Emit the central directory + EOCD and return the finished archive.
        mutating func finalize() -> Data {
            let cdStart = output.count
            for r in records {
                let nameBytes = Array(r.name.utf8)
                var cd = Data()
                cd.appendLE32(0x0201_4b50)                // central dir signature
                cd.appendLE16(20)                         // version made by
                cd.appendLE16(20)                         // version needed
                cd.appendLE16(0)                          // flags
                cd.appendLE16(r.method)                   // method
                cd.appendLE16(0)                          // mod time
                cd.appendLE16(0)                          // mod date
                cd.appendLE32(r.crc)                      // crc32
                cd.appendLE32(UInt32(r.compSize))         // compressed size
                cd.appendLE32(UInt32(r.uncompSize))       // uncompressed size
                cd.appendLE16(UInt16(nameBytes.count))    // name length
                cd.appendLE16(0)                          // extra length
                cd.appendLE16(0)                          // comment length
                cd.appendLE16(0)                          // disk number start
                cd.appendLE16(0)                          // internal attrs
                cd.appendLE32(0)                          // external attrs
                cd.appendLE32(UInt32(r.offset))           // local header offset
                cd.append(contentsOf: nameBytes)
                output.append(cd)
            }
            let cdSize = output.count - cdStart

            var eocd = Data()
            eocd.appendLE32(0x0605_4b50)                  // EOCD signature
            eocd.appendLE16(0)                            // this disk
            eocd.appendLE16(0)                            // disk with CD
            eocd.appendLE16(UInt16(records.count))        // entries on this disk
            eocd.appendLE16(UInt16(records.count))        // total entries
            eocd.appendLE32(UInt32(cdSize))               // CD size
            eocd.appendLE32(UInt32(cdStart))              // CD offset
            eocd.appendLE16(0)                            // comment length
            output.append(eocd)
            return output
        }
    }
}

// MARK: - Little-endian helpers

private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[startIndex + offset]) | (UInt16(self[startIndex + offset + 1]) << 8)
    }

    func u32(_ offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[startIndex + offset])
            | (UInt32(self[startIndex + offset + 1]) << 8)
            | (UInt32(self[startIndex + offset + 2]) << 16)
            | (UInt32(self[startIndex + offset + 3]) << 24)
    }

    mutating func appendLE16(_ v: UInt16) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF))
    }

    mutating func appendLE32(_ v: UInt32) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF)); append(UInt8((v >> 24) & 0xFF))
    }
}
