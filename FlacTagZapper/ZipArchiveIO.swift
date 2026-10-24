import Foundation
import Compression
#if canImport(zlib)
import zlib
#endif

enum ZipArchiveError: Error, LocalizedError {
    case noEndOfCentralDirectory
    case malformedCentralDirectory
    case badLocalHeader(String)
    case shortRead(offset: UInt64)
    case inflateFailed
    case checksumMismatch(String)
    case overlappingEntries

    var errorDescription: String? {
        switch self {
        case .noEndOfCentralDirectory:
            return "This doesn't look like a valid zip file (no end-of-archive record found)."
        case .malformedCentralDirectory:
            return "The zip's central directory is damaged or in an unsupported format."
        case .badLocalHeader(let name):
            return "The entry \"\(name)\" has a damaged header."
        case .shortRead(let offset):
            return "The zip ended unexpectedly while reading at byte \(offset). It may be truncated or not fully downloaded."
        case .inflateFailed:
            return "Could not decompress a zip entry."
        case .checksumMismatch(let name):
            return "The entry \"\(name)\" failed its checksum after decompression."
        case .overlappingEntries:
            return "The zip contains overlapping or duplicate entries, which can't be edited safely."
        }
    }
}

extension Data {
    func le16(at offset: Int) -> UInt16 {
        let b0 = UInt16(self[startIndex + offset])
        let b1 = UInt16(self[startIndex + offset + 1])
        return b0 | (b1 << 8)
    }

    func le32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(self[startIndex + offset + i]) << UInt32(8 * i)
        }
        return value
    }

    func le64(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(self[startIndex + offset + i]) << UInt64(8 * i)
        }
        return value
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        for i in 0..<4 {
            append(UInt8((value >> UInt32(8 * i)) & 0xFF))
        }
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        for i in 0..<8 {
            append(UInt8((value >> UInt64(8 * i)) & 0xFF))
        }
    }
}

extension FileHandle {

    func readExactly(at offset: UInt64, count: Int) throws -> Data {
        if count == 0 { return Data() }
        var result = Data()
        result.reserveCapacity(count)
        try seek(toOffset: offset)
        while result.count < count {
            let want = min(count - result.count, 64 << 20)
            guard let part = try read(upToCount: want), !part.isEmpty else {
                throw ZipArchiveError.shortRead(offset: offset + UInt64(result.count))
            }
            result.append(part)
        }
        return result
    }

    func writeAll(_ parts: [Data], at offset: UInt64) throws {
        try seek(toOffset: offset)
        for part in parts where !part.isEmpty {
            try write(contentsOf: part)
        }
    }
}

enum CRC32 {
    #if !canImport(zlib)
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }
    #endif

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        var offset = 0
        let chunkSize = 256 << 20
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            crc = update(crc, with: data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end)))
            offset = end
        }
        return crc
    }

    private static func update(_ crc: UInt32, with chunk: Data) -> UInt32 {
        #if canImport(zlib)
        return chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt32 in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return crc }
            return UInt32(truncatingIfNeeded: zlib.crc32(UInt(crc), base, UInt32(raw.count)))
        }
        #else
        var value = crc ^ 0xFFFFFFFF
        table.withUnsafeBufferPointer { t in
            chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for byte in raw {
                    value = t[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
                }
            }
        }
        return value ^ 0xFFFFFFFF
        #endif
    }
}

enum ZipCodec {

    static func inflate(_ input: Data, expectedSize: Int) throws -> Data {
        if expectedSize == 0 { return Data() }
        var output = Data(count: expectedSize)
        let written: Int = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress,
                      let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dstBase, expectedSize, srcBase, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw ZipArchiveError.inflateFailed }
        return output
    }

    static func deflate(_ input: Data) -> Data? {
        if input.isEmpty { return nil }
        let capacity = input.count + input.count / 8 + 1024
        var output = Data(count: capacity)
        let written: Int = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress,
                      let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(dstBase, capacity, srcBase, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return output.prefix(written)
    }
}

struct ZipEntryRecord {
    var versionMadeBy: UInt16
    var versionNeeded: UInt16
    var flags: UInt16
    var method: UInt16
    var modTime: UInt16
    var modDate: UInt16
    var crc32: UInt32
    var compressedSize: UInt64
    var uncompressedSize: UInt64
    var internalAttributes: UInt16
    var externalAttributes: UInt32
    var localHeaderOffset: UInt64
    var nameBytes: Data

    var extra: Data
    var comment: Data

    var name: String {
        String(decoding: nameBytes, as: UTF8.self)
    }

    var hasValidUTF8Name: Bool {
        String(data: nameBytes, encoding: .utf8) != nil
    }
}

struct ZipArchiveLayout {
    var entries: [ZipEntryRecord]
    var centralDirectoryOffset: UInt64
    var centralDirectorySize: UInt64
    var comment: Data
}

enum ZipArchiveIO {

    private static let sigEOCD: UInt32 = 0x06054B50
    private static let sigEOCD64: UInt32 = 0x06064B50
    private static let sigLocator64: UInt32 = 0x07064B50
    private static let sigCentral: UInt32 = 0x02014B50
    static let sigLocal: UInt32 = 0x04034B50
    private static let marker32: UInt32 = 0xFFFFFFFF

    static func readLayout(from handle: FileHandle, fileSize: UInt64) throws -> ZipArchiveLayout {
        let maxTail = min(fileSize, UInt64(22 + 65535))
        let tailStart = fileSize - maxTail
        let tail = try handle.readExactly(at: tailStart, count: Int(maxTail))

        var eocdIndex: Int?
        var i = tail.count - 22
        while i >= 0 {
            if tail.le32(at: i) == sigEOCD {
                let commentLength = Int(tail.le16(at: i + 20))
                if i + 22 + commentLength <= tail.count {
                    eocdIndex = i
                    break
                }
            }
            i -= 1
        }
        guard let eocd = eocdIndex else { throw ZipArchiveError.noEndOfCentralDirectory }

        let total16 = tail.le16(at: eocd + 10)
        let size32 = tail.le32(at: eocd + 12)
        let offset32 = tail.le32(at: eocd + 16)
        let commentLength = Int(tail.le16(at: eocd + 20))
        let comment = tail.subdata(in: (eocd + 22)..<(eocd + 22 + commentLength))

        var totalEntries = UInt64(total16)
        var cdSize = UInt64(size32)
        var cdOffset = UInt64(offset32)
        let eocdAbsolute = tailStart + UInt64(eocd)

        if (total16 == 0xFFFF || size32 == marker32 || offset32 == marker32) && eocdAbsolute >= 20 {
            let locator = try handle.readExactly(at: eocdAbsolute - 20, count: 20)
            if locator.le32(at: 0) == sigLocator64 {
                let recordOffset = locator.le64(at: 8)
                let record = try handle.readExactly(at: recordOffset, count: 56)
                guard record.le32(at: 0) == sigEOCD64 else { throw ZipArchiveError.malformedCentralDirectory }
                totalEntries = record.le64(at: 32)
                cdSize = record.le64(at: 40)
                cdOffset = record.le64(at: 48)
            }
        }

        guard cdOffset + cdSize <= fileSize, cdSize < (1 << 30) else {
            throw ZipArchiveError.malformedCentralDirectory
        }
        let cd = try handle.readExactly(at: cdOffset, count: Int(cdSize))

        var entries: [ZipEntryRecord] = []
        var pos = 0
        for _ in 0..<totalEntries {
            guard pos + 46 <= cd.count, cd.le32(at: pos) == sigCentral else {
                throw ZipArchiveError.malformedCentralDirectory
            }
            let nameLength = Int(cd.le16(at: pos + 28))
            let extraLength = Int(cd.le16(at: pos + 30))
            let commentLen = Int(cd.le16(at: pos + 32))
            guard pos + 46 + nameLength + extraLength + commentLen <= cd.count else {
                throw ZipArchiveError.malformedCentralDirectory
            }

            let compressed32 = cd.le32(at: pos + 20)
            let uncompressed32 = cd.le32(at: pos + 24)
            let localOffset32 = cd.le32(at: pos + 42)
            var compressed = UInt64(compressed32)
            var uncompressed = UInt64(uncompressed32)
            var localOffset = UInt64(localOffset32)

            let nameStart = pos + 46
            let extraStart = nameStart + nameLength
            let commentStart = extraStart + extraLength
            let nameBytes = cd.subdata(in: nameStart..<extraStart)
            let extraRaw = cd.subdata(in: extraStart..<commentStart)
            let commentBytes = cd.subdata(in: commentStart..<(commentStart + commentLen))

            var keptExtra = Data()
            var ep = 0
            while ep + 4 <= extraRaw.count {
                let fieldID = extraRaw.le16(at: ep)
                let fieldSize = Int(extraRaw.le16(at: ep + 2))
                guard ep + 4 + fieldSize <= extraRaw.count else { break }
                if fieldID == 0x0001 {
                    var p = ep + 4
                    let end = ep + 4 + fieldSize
                    if uncompressed32 == marker32 && p + 8 <= end {
                        uncompressed = extraRaw.le64(at: p)
                        p += 8
                    }
                    if compressed32 == marker32 && p + 8 <= end {
                        compressed = extraRaw.le64(at: p)
                        p += 8
                    }
                    if localOffset32 == marker32 && p + 8 <= end {
                        localOffset = extraRaw.le64(at: p)
                        p += 8
                    }
                } else {
                    keptExtra.append(extraRaw.subdata(in: ep..<(ep + 4 + fieldSize)))
                }
                ep += 4 + fieldSize
            }

            entries.append(ZipEntryRecord(
                versionMadeBy: cd.le16(at: pos + 4),
                versionNeeded: cd.le16(at: pos + 6),
                flags: cd.le16(at: pos + 8),
                method: cd.le16(at: pos + 10),
                modTime: cd.le16(at: pos + 12),
                modDate: cd.le16(at: pos + 14),
                crc32: cd.le32(at: pos + 16),
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                internalAttributes: cd.le16(at: pos + 36),
                externalAttributes: cd.le32(at: pos + 38),
                localHeaderOffset: localOffset,
                nameBytes: nameBytes,
                extra: keptExtra,
                comment: commentBytes
            ))
            pos = commentStart + commentLen
        }

        return ZipArchiveLayout(
            entries: entries, centralDirectoryOffset: cdOffset, centralDirectorySize: cdSize, comment: comment
        )
    }

    static func localHeader(for record: ZipEntryRecord) -> Data {
        var d = Data()
        d.appendUInt32LE(sigLocal)
        d.appendUInt16LE(record.versionNeeded)
        d.appendUInt16LE(record.flags)
        d.appendUInt16LE(record.method)
        d.appendUInt16LE(record.modTime)
        d.appendUInt16LE(record.modDate)
        d.appendUInt32LE(record.crc32)
        d.appendUInt32LE(UInt32(record.compressedSize))
        d.appendUInt32LE(UInt32(record.uncompressedSize))
        d.appendUInt16LE(UInt16(record.nameBytes.count))
        d.appendUInt16LE(0)
        d.append(record.nameBytes)
        return d
    }

    static func serializeCentralDirectory(_ entries: [ZipEntryRecord]) -> Data {
        var d = Data()
        for record in entries {
            let bigSizes = record.compressedSize >= 0xFFFFFFFF || record.uncompressedSize >= 0xFFFFFFFF
            let bigOffset = record.localHeaderOffset >= 0xFFFFFFFF

            var zip64 = Data()
            if bigSizes {
                zip64.appendUInt64LE(record.uncompressedSize)
                zip64.appendUInt64LE(record.compressedSize)
            }
            if bigOffset {
                zip64.appendUInt64LE(record.localHeaderOffset)
            }
            var extra = Data()
            if !zip64.isEmpty {
                extra.appendUInt16LE(0x0001)
                extra.appendUInt16LE(UInt16(zip64.count))
                extra.append(zip64)
            }
            extra.append(record.extra)

            let versionNeeded: UInt16 = zip64.isEmpty ? record.versionNeeded : max(record.versionNeeded, 45)
            let compressed32: UInt32 = bigSizes ? marker32 : UInt32(record.compressedSize)
            let uncompressed32: UInt32 = bigSizes ? marker32 : UInt32(record.uncompressedSize)
            let offset32: UInt32 = bigOffset ? marker32 : UInt32(record.localHeaderOffset)

            d.appendUInt32LE(sigCentral)
            d.appendUInt16LE(record.versionMadeBy)
            d.appendUInt16LE(versionNeeded)
            d.appendUInt16LE(record.flags)
            d.appendUInt16LE(record.method)
            d.appendUInt16LE(record.modTime)
            d.appendUInt16LE(record.modDate)
            d.appendUInt32LE(record.crc32)
            d.appendUInt32LE(compressed32)
            d.appendUInt32LE(uncompressed32)
            d.appendUInt16LE(UInt16(record.nameBytes.count))
            d.appendUInt16LE(UInt16(truncatingIfNeeded: extra.count))
            d.appendUInt16LE(UInt16(record.comment.count))
            d.appendUInt16LE(0)
            d.appendUInt16LE(record.internalAttributes)
            d.appendUInt32LE(record.externalAttributes)
            d.appendUInt32LE(offset32)
            d.append(record.nameBytes)
            d.append(extra)
            d.append(record.comment)
        }
        return d
    }

    static func serializeEnd(entryCount: Int, centralDirectoryOffset: UInt64, centralDirectorySize: UInt64, comment: Data) -> Data {
        var d = Data()
        let needsZip64 = entryCount >= 0xFFFF || centralDirectoryOffset >= 0xFFFFFFFF || centralDirectorySize >= 0xFFFFFFFF
        if needsZip64 {
            d.appendUInt32LE(sigEOCD64)
            d.appendUInt64LE(44)
            d.appendUInt16LE(45)
            d.appendUInt16LE(45)
            d.appendUInt32LE(0)
            d.appendUInt32LE(0)
            d.appendUInt64LE(UInt64(entryCount))
            d.appendUInt64LE(UInt64(entryCount))
            d.appendUInt64LE(centralDirectorySize)
            d.appendUInt64LE(centralDirectoryOffset)

            d.appendUInt32LE(sigLocator64)
            d.appendUInt32LE(0)
            d.appendUInt64LE(centralDirectoryOffset + centralDirectorySize)
            d.appendUInt32LE(1)
        }
        let count16: UInt16 = needsZip64 ? 0xFFFF : UInt16(entryCount)
        let size32: UInt32 = needsZip64 ? marker32 : UInt32(centralDirectorySize)
        let offset32: UInt32 = needsZip64 ? marker32 : UInt32(centralDirectoryOffset)
        d.appendUInt32LE(sigEOCD)
        d.appendUInt16LE(0)
        d.appendUInt16LE(0)
        d.appendUInt16LE(count16)
        d.appendUInt16LE(count16)
        d.appendUInt32LE(size32)
        d.appendUInt32LE(offset32)
        d.appendUInt16LE(UInt16(comment.count))
        d.append(comment)
        return d
    }

    static func removingExtraField(_ fieldID: UInt16, from extra: Data) -> Data {
        var result = Data()
        var p = 0
        while p + 4 <= extra.count {
            let id = extra.le16(at: p)
            let size = Int(extra.le16(at: p + 2))
            guard p + 4 + size <= extra.count else { break }
            if id != fieldID {
                result.append(extra.subdata(in: p..<(p + 4 + size)))
            }
            p += 4 + size
        }
        return result
    }
}
