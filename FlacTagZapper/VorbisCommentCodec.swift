import Foundation

enum VorbisCommentCodec {

    struct Comments {
        var vendor: String
        var fields: [(key: String, value: String)]
    }

    static func parse(_ payload: Data) -> Comments? {
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
            return nil
        }
        let vendorData = payload[offset..<offset.advanced(by: vendorLength)]
        let vendor = String(data: vendorData, encoding: .utf8) ?? ""
        offset = offset.advanced(by: vendorLength)

        guard let commentCount = readUInt32LE() else { return nil }

        var fields: [(key: String, value: String)] = []
        fields.reserveCapacity(commentCount)
        for _ in 0..<commentCount {
            guard let commentLength = readUInt32LE(), offset.advanced(by: commentLength) <= payload.endIndex else {
                break
            }
            let commentData = payload[offset..<offset.advanced(by: commentLength)]
            offset = offset.advanced(by: commentLength)

            guard let comment = String(data: commentData, encoding: .utf8),
                  let eqIndex = comment.firstIndex(of: "=") else { continue }
            let key = String(comment[comment.startIndex..<eqIndex])
            let value = String(comment[comment.index(after: eqIndex)...])
            fields.append((key: key, value: value))
        }
        return Comments(vendor: vendor, fields: fields)
    }

    static func serialize(_ comments: Comments) -> Data {
        var payload = Data()

        func appendLengthPrefixed(_ string: String) {
            let bytes = Array(string.utf8)
            var length = UInt32(bytes.count).littleEndian
            withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
            payload.append(contentsOf: bytes)
        }

        appendLengthPrefixed(comments.vendor)
        var count = UInt32(comments.fields.count).littleEndian
        withUnsafeBytes(of: &count) { payload.append(contentsOf: $0) }
        for (key, value) in comments.fields {
            appendLengthPrefixed("\(key)=\(value)")
        }
        return payload
    }

    static func upserting(_ updates: [(key: String, value: String)], into comments: Comments) -> Comments {
        var fields = comments.fields
        for (key, value) in updates {
            if let idx = fields.firstIndex(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
                fields[idx] = (key: key, value: value)
                fields = fields.enumerated()
                    .filter { i, f in i == idx || f.key.caseInsensitiveCompare(key) != .orderedSame }
                    .map { $0.element }
            } else {
                fields.append((key: key, value: value))
            }
        }
        return Comments(vendor: comments.vendor, fields: fields)
    }

    static func removing(keys: [String], from comments: Comments) -> Comments {
        let upperKeys = Set(keys.map { $0.uppercased() })
        let fields = comments.fields.filter { !upperKeys.contains($0.key.uppercased()) }
        return Comments(vendor: comments.vendor, fields: fields)
    }
}
