import Foundation

enum FlacNaming {
    static func isAppleMetadata(_ path: String) -> Bool {
        if path.hasPrefix("__MACOSX/") || path.contains("/__MACOSX/") { return true }
        let lastComponent = path.split(separator: "/").last.map(String.init) ?? path
        return lastComponent.hasPrefix("._")
    }

    static func strippingFlacExtension(from title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasSuffix(".flac") else { return trimmed }
        return String(trimmed.dropLast(5)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sanitizedFilename(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|\u{0}")
        var result = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            result.append(invalid.contains(scalar) ? "-" : scalar)
        }
        let trimmed = String(result).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}
