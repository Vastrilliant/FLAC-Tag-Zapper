import Foundation

enum FLACStripper {

    enum FLACError: Error, LocalizedError {
        case notAFlacFile
        case truncatedHeader
        case truncatedBlock(type: UInt8, at: Int)
        case blockTooLarge

        var errorDescription: String? {
            switch self {
            case .notAFlacFile:
                return "File does not start with the fLaC magic bytes."
            case .truncatedHeader:
                return "File ended unexpectedly while reading a metadata block header."
            case .truncatedBlock(let type, let offset):
                return "File ended unexpectedly while reading block type \(type) at offset \(offset)."
            case .blockTooLarge:
                return "Metadata block payload exceeds the 24-bit length the FLAC format allows."
            }
        }
    }

    private static let typePadding: UInt8 = 1
    private static let typeSeektable: UInt8 = 3

    static func strip(_ input: Data) throws -> Data {
        guard input.count >= 4, input[input.startIndex..<input.startIndex.advanced(by: 4)].elementsEqual("fLaC".utf8) else {
            throw FLACError.notAFlacFile
        }

        var pos = input.startIndex.advanced(by: 4)
        let end = input.endIndex

        struct Block {
            let type: UInt8
            let data: Data
        }

        var blocks: [Block] = []
        var removedAny = false

        while true {
            guard pos.advanced(by: 4) <= end else { throw FLACError.truncatedHeader }

            let headerByte = input[pos]
            let isLast = (headerByte & 0x80) != 0
            let blockType = headerByte & 0x7F

            let lengthBytes = input[pos.advanced(by: 1)..<pos.advanced(by: 4)]
            let length = lengthBytes.reduce(0) { ($0 << 8) | Int($1) }

            let blockStart = pos
            let dataStart = pos.advanced(by: 4)
            guard dataStart.advanced(by: length) <= end else {
                throw FLACError.truncatedBlock(type: blockType, at: input.distance(from: input.startIndex, to: pos))
            }
            let blockEnd = dataStart.advanced(by: length)

            if blockType != typePadding && blockType != typeSeektable {

                var kept = Data(input[blockStart..<blockEnd])
                kept[kept.startIndex] = blockType
                blocks.append(Block(type: blockType, data: kept))
            } else {
                removedAny = true
            }

            pos = blockEnd
            if isLast { break }
        }

        guard !blocks.isEmpty else {

            return input
        }

        if !removedAny {
            return input
        }

        var lastBlock = blocks[blocks.count - 1].data
        lastBlock[lastBlock.startIndex] |= 0x80
        blocks[blocks.count - 1] = Block(type: blocks[blocks.count - 1].type, data: lastBlock)

        var output = Data()
        output.append(contentsOf: "fLaC".utf8)
        for block in blocks {
            output.append(block.data)
        }
        output.append(input[pos..<end])
        return output
    }

    @discardableResult
    static func stripFile(at sourceURL: URL, writingTo destinationURL: URL? = nil) throws -> Bool {
        let original = try Data(contentsOf: sourceURL)
        let stripped = try strip(original)
        let target = destinationURL ?? sourceURL
        if stripped.count != original.count || target != sourceURL {
            try stripped.write(to: target, options: .atomic)
            return true
        }
        return false
    }

    private static let typeVorbisComment: UInt8 = 4

    static func readTags(from input: Data) -> (artist: String?, title: String?) {
        guard input.count >= 4,
              input[input.startIndex..<input.startIndex.advanced(by: 4)].elementsEqual("fLaC".utf8) else {
            return (nil, nil)
        }

        var pos = input.startIndex.advanced(by: 4)
        let end = input.endIndex

        while true {
            guard pos.advanced(by: 4) <= end else { return (nil, nil) }

            let headerByte = input[pos]
            let isLast = (headerByte & 0x80) != 0
            let blockType = headerByte & 0x7F

            let lengthBytes = input[pos.advanced(by: 1)..<pos.advanced(by: 4)]
            let length = lengthBytes.reduce(0) { ($0 << 8) | Int($1) }

            let dataStart = pos.advanced(by: 4)
            guard dataStart.advanced(by: length) <= end else { return (nil, nil) }
            let blockEnd = dataStart.advanced(by: length)

            if blockType == typeVorbisComment {
                return parseVorbisComment(input[dataStart..<blockEnd])
            }

            pos = blockEnd
            if isLast { break }
        }
        return (nil, nil)
    }

    static func readTags(at url: URL) -> (artist: String?, title: String?) {
        guard let data = try? Data(contentsOf: url) else { return (nil, nil) }
        return readTags(from: data)
    }

    static func writingVorbisComments(_ updates: [(key: String, value: String)], into input: Data) throws -> Data {
        guard input.count >= 4,
              input[input.startIndex..<input.startIndex.advanced(by: 4)].elementsEqual("fLaC".utf8) else {
            throw FLACError.notAFlacFile
        }

        var pos = input.startIndex.advanced(by: 4)
        let end = input.endIndex

        struct Block {
            let type: UInt8
            var data: Data
        }

        var blocks: [Block] = []
        var vorbisIndex: Int?

        while true {
            guard pos.advanced(by: 4) <= end else { throw FLACError.truncatedHeader }

            let headerByte = input[pos]
            let isLast = (headerByte & 0x80) != 0
            let blockType = headerByte & 0x7F

            let lengthBytes = input[pos.advanced(by: 1)..<pos.advanced(by: 4)]
            let length = lengthBytes.reduce(0) { ($0 << 8) | Int($1) }

            let dataStart = pos.advanced(by: 4)
            guard dataStart.advanced(by: length) <= end else {
                throw FLACError.truncatedBlock(type: blockType, at: input.distance(from: input.startIndex, to: pos))
            }
            let blockEnd = dataStart.advanced(by: length)

            var kept = Data(input[pos..<blockEnd])
            kept[kept.startIndex] = blockType
            if blockType == typeVorbisComment { vorbisIndex = blocks.count }
            blocks.append(Block(type: blockType, data: kept))

            pos = blockEnd
            if isLast { break }
        }
        guard !blocks.isEmpty else { return input }

        let existing = vorbisIndex.flatMap { VorbisCommentCodec.parse(blocks[$0].data.dropFirst(4)) }
            ?? VorbisCommentCodec.Comments(vendor: "FlacTagZapper", fields: [])
        let merged = VorbisCommentCodec.upserting(updates, into: existing)
        let newPayload = VorbisCommentCodec.serialize(merged)
        guard newPayload.count <= 0xFF_FFFF else { throw FLACError.blockTooLarge }

        var newBlockData = Data([typeVorbisComment])
        let len = newPayload.count
        newBlockData.append(contentsOf: [UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)])
        newBlockData.append(newPayload)

        if let vorbisIndex {
            blocks[vorbisIndex].data = newBlockData
        } else {

            blocks.insert(Block(type: typeVorbisComment, data: newBlockData), at: min(1, blocks.count))
        }

        blocks[blocks.count - 1].data[blocks[blocks.count - 1].data.startIndex] |= 0x80

        var output = Data()
        output.append(contentsOf: "fLaC".utf8)
        for block in blocks { output.append(block.data) }
        output.append(input[pos..<end])
        return output
    }

    @discardableResult
    static func writeVorbisComments(_ updates: [(key: String, value: String)], toFileAt url: URL) throws -> Bool {
        let original = try Data(contentsOf: url)
        let updated = try writingVorbisComments(updates, into: original)
        try updated.write(to: url, options: .atomic)
        return true
    }

    private static func parseVorbisComment(_ payload: Data) -> (artist: String?, title: String?) {
        var artist: String?
        var title: String?
        var offset = payload.startIndex

        func readUInt32LE() -> Int? {
            guard offset.advanced(by: 4) <= payload.endIndex else { return nil }
            let bytes = payload[offset..<offset.advanced(by: 4)]
            offset = offset.advanced(by: 4)
            var value: UInt32 = 0
            for (i, byte) in bytes.enumerated() {
                value |= UInt32(byte) << (8 * i)
            }
            return Int(value)
        }

        guard let vendorLength = readUInt32LE(), offset.advanced(by: vendorLength) <= payload.endIndex else {
            return (nil, nil)
        }
        offset = offset.advanced(by: vendorLength)

        guard let commentCount = readUInt32LE() else { return (nil, nil) }

        for _ in 0..<commentCount {
            guard let commentLength = readUInt32LE(), offset.advanced(by: commentLength) <= payload.endIndex else {
                break
            }
            let commentData = payload[offset..<offset.advanced(by: commentLength)]
            offset = offset.advanced(by: commentLength)

            guard let comment = String(data: commentData, encoding: .utf8),
                  let eqIndex = comment.firstIndex(of: "=") else { continue }
            let key = comment[comment.startIndex..<eqIndex].uppercased()
            let value = String(comment[comment.index(after: eqIndex)...])

            if key == "ARTIST" && artist == nil { artist = value }
            if key == "TITLE" && title == nil { title = value }
        }

        return (artist, title)
    }
}
