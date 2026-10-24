import Foundation

enum ZipProcessor {

    enum ZipProcessorError: Error, LocalizedError {
        case cannotReadArchive
        case cannotCreateArchive
        case cannotOpenForEditing(underlying: Error?)
        case sourceNotFullyAvailable(underlying: Error?)
        case emptySourceFile
        case interruptedMidEdit(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .cannotReadArchive:
                return "Could not open the selected zip file. It may be corrupted or in an unsupported format."
            case .cannotCreateArchive:
                return "Could not create the output zip file."
            case .cannotOpenForEditing:
                return "Could not open the zip for editing in place. The file may be read-only, or stored somewhere " +
                       "that doesn't allow in-place writes. Turn off \"Edit original zip in place\" to work on a copy instead."
            case .sourceNotFullyAvailable:
                return "The zip file wasn't fully downloaded to this device yet (common with iCloud Drive, Dropbox, " +
                       "or other cloud-backed files). Wait for it to finish downloading in the Files app, then try again."
            case .emptySourceFile:
                return "The selected zip file is empty or unreadable (0 bytes)."
            case .interruptedMidEdit(let underlying):
                return "Editing stopped partway through (\(underlying.localizedDescription)) and the zip was already " +
                       "partly rewritten, so it may now be damaged. Restore it from a backup if you have one."
            }
        }
    }

    struct ProcessResult {

        let outputURL: URL?
        let totalFlacFiles: Int
        let strippedFlacFiles: Int
    }

    typealias Logger = (String, LogLevel) -> Void

    static func process(zipURL: URL, inPlace: Bool, log: @escaping Logger = { _, _ in }) throws -> ProcessResult {
        log("Preparing to read \(zipURL.lastPathComponent)", .info)
        requestCloudDownloadIfNeeded(for: zipURL, log: log)

        var coordinatorError: NSError?
        var outcome: Result<ProcessResult, Error>?
        let coordinator = NSFileCoordinator()
        let work: (URL) -> Void = { coordinatedURL in
            outcome = Result {
                let session = try ZipSession(sourceURL: coordinatedURL, inPlace: inPlace, log: log)
                return try session.run()
            }
        }
        if inPlace {
            coordinator.coordinate(writingItemAt: zipURL, options: .forMerging, error: &coordinatorError, byAccessor: work)
        } else {
            coordinator.coordinate(readingItemAt: zipURL, options: .withoutChanges, error: &coordinatorError, byAccessor: work)
        }

        if let coordinatorError {
            log("File coordination failed: \(coordinatorError)", .error)
            if inPlace {
                throw ZipProcessorError.cannotOpenForEditing(underlying: coordinatorError)
            }
            throw ZipProcessorError.sourceNotFullyAvailable(underlying: coordinatorError)
        }
        guard let outcome else { throw ZipProcessorError.cannotReadArchive }
        return try outcome.get()
    }

    static func cleanupStaleOutputs() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for url in contents where url.lastPathComponent.hasSuffix("-zapped.zip")
            || url.lastPathComponent.hasSuffix(".zapper-scratch") {
            try? fm.removeItem(at: url)
        }
    }

    private static func requestCloudDownloadIfNeeded(for url: URL, log: @escaping Logger) {
        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
           values.isUbiquitousItem == true,
           values.ubiquitousItemDownloadingStatus != .current {
            log("File is in iCloud and not fully downloaded — requesting download…", .warning)
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            waitForUbiquitousDownload(of: url, log: log)
        }
    }

    private static func waitForUbiquitousDownload(of url: URL, log: @escaping Logger, timeout: TimeInterval = 60) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]) else { break }
            if values.ubiquitousItemDownloadingStatus == .current {
                log("iCloud download finished", .info)
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        log("Timed out waiting for iCloud download to finish; attempting to continue anyway", .warning)
    }
}

private final class ZipSession {

    private struct Rewrite {
        var record: ZipEntryRecord
        var header: Data
        var payload: Data
        var didStrip: Bool
    }

    private struct DeferredEntry {
        var index: Int
        var scratchOffset: UInt64
        var length: Int
    }

    private let inPlace: Bool
    private let log: ZipProcessor.Logger
    private let src: FileHandle
    private let dst: FileHandle
    private let scratch: FileHandle?
    private let scratchURL: URL?
    private let outputURL: URL?

    private var records: [ZipEntryRecord] = []
    private var assignedNames = Set<String>()
    private var pendingNames = Set<String>()
    private var modifiedSource = false

    init(sourceURL: URL, inPlace: Bool, log: @escaping ZipProcessor.Logger) throws {
        let fm = FileManager.default
        let source: FileHandle
        let destination: FileHandle
        var scratchHandle: FileHandle?
        var scratchFileURL: URL?
        var output: URL?

        if inPlace {
            do {
                source = try FileHandle(forUpdating: sourceURL)
            } catch {
                log("Could not open the zip for writing: \(error.localizedDescription)", .error)
                throw ZipProcessor.ZipProcessorError.cannotOpenForEditing(underlying: error)
            }
            destination = source
            let url = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zapper-scratch")
            guard fm.createFile(atPath: url.path, contents: nil),
                  let handle = try? FileHandle(forUpdating: url) else {
                log("Could not create scratch file at \(url.path)", .error)
                try? source.close()
                throw ZipProcessor.ZipProcessorError.cannotCreateArchive
            }
            scratchHandle = handle
            scratchFileURL = url
        } else {
            do {
                source = try FileHandle(forReadingFrom: sourceURL)
            } catch {
                log("Could not open the zip for reading: \(error.localizedDescription)", .error)
                throw ZipProcessor.ZipProcessorError.cannotReadArchive
            }
            let outputName = sourceURL.deletingPathExtension().lastPathComponent + "-zapped.zip"
            let url = fm.temporaryDirectory.appendingPathComponent(outputName)
            try? fm.removeItem(at: url)
            guard fm.createFile(atPath: url.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: url) else {
                log("Could not create destination archive at \(url.path)", .error)
                try? source.close()
                throw ZipProcessor.ZipProcessorError.cannotCreateArchive
            }
            destination = handle
            output = url
        }

        self.inPlace = inPlace
        self.log = log
        self.src = source
        self.dst = destination
        self.scratch = scratchHandle
        self.scratchURL = scratchFileURL
        self.outputURL = output
    }

    func run() throws -> ZipProcessor.ProcessResult {
        do {
            let result = try execute()
            finish(success: true)
            return result
        } catch {
            finish(success: false)
            if inPlace && modifiedSource {
                throw ZipProcessor.ZipProcessorError.interruptedMidEdit(underlying: error)
            }
            throw error
        }
    }

    private func finish(success: Bool) {
        try? src.close()
        if dst !== src { try? dst.close() }
        try? scratch?.close()
        let fm = FileManager.default
        if let scratchURL { try? fm.removeItem(at: scratchURL) }
        if !success, let outputURL { try? fm.removeItem(at: outputURL) }
    }

    private func execute() throws -> ZipProcessor.ProcessResult {
        let fileSize = try src.seekToEnd()
        guard fileSize > 0 else {
            log("Source file is empty", .error)
            throw ZipProcessor.ZipProcessorError.emptySourceFile
        }
        log("Source size: \(fileSize) bytes", .info)

        let layout = try ZipArchiveIO.readLayout(from: src, fileSize: fileSize)
        records = layout.entries
        log("Archive opened: \(records.count) entr\(records.count == 1 ? "y" : "ies")", .info)

        let order = records.indices.sorted { records[$0].localHeaderOffset < records[$1].localHeaderOffset }
        for k in 0..<order.count {
            let start = records[order[k]].localHeaderOffset
            let end = k + 1 < order.count ? records[order[k + 1]].localHeaderOffset : layout.centralDirectoryOffset
            guard start < end else { throw ZipArchiveError.overlappingEntries }
        }

        for record in records { pendingNames.insert(record.name.lowercased()) }

        let firstOffset = order.first.map { records[$0].localHeaderOffset } ?? layout.centralDirectoryOffset
        var writeCursor = firstOffset
        if !inPlace && firstOffset > 0 {
            try copyRange(from: 0, to: 0, length: firstOffset)
        }

        var deferred: [DeferredEntry] = []
        var scratchEnd: UInt64 = 0
        var anyRewrite = false
        var totalFlac = 0
        var stripped = 0

        for (position, index) in order.enumerated() {
            try autoreleasepool {
                let record = records[index]
                let spanStart = record.localHeaderOffset
                let spanEnd = position + 1 < order.count
                    ? records[order[position + 1]].localHeaderOffset
                    : layout.centralDirectoryOffset
                let originalName = record.name
                pendingNames.remove(originalName.lowercased())
                var finalName = originalName

                var rewrite: Rewrite?
                if originalName.lowercased().hasSuffix(".flac") && !FlacNaming.isAppleMetadata(originalName) {
                    totalFlac += 1
                    log("[\(position + 1)/\(order.count)] \(originalName)", .info)
                    rewrite = rewriteFlac(record)
                }

                if let rewrite {
                    anyRewrite = true
                    let newSize = UInt64(rewrite.header.count + rewrite.payload.count)
                    var updated = rewrite.record
                    if !inPlace || writeCursor + newSize <= spanEnd {
                        try dst.writeAll([rewrite.header, rewrite.payload], at: writeCursor)
                        if inPlace { modifiedSource = true }
                        updated.localHeaderOffset = writeCursor
                        writeCursor += newSize
                    } else {
                        guard let scratch else { throw ZipProcessor.ZipProcessorError.cannotCreateArchive }
                        try scratch.writeAll([rewrite.header, rewrite.payload], at: scratchEnd)
                        deferred.append(DeferredEntry(index: index, scratchOffset: scratchEnd, length: Int(newSize)))
                        scratchEnd += newSize
                        log("Larger than its original slot; will be appended at the end", .info)
                    }
                    records[index] = updated
                    if rewrite.didStrip { stripped += 1 }
                    finalName = updated.name
                } else {
                    let length = spanEnd - spanStart
                    try copyRange(from: spanStart, to: writeCursor, length: length)
                    records[index].localHeaderOffset = writeCursor
                    writeCursor += length
                }
                assignedNames.insert(finalName.lowercased())
            }
        }
        log("FLAC pass complete: stripped \(stripped) of \(totalFlac) file(s)", .info)

        if inPlace && !anyRewrite {
            log("Nothing needed changing; the zip was left untouched.", .info)
            return ZipProcessor.ProcessResult(outputURL: nil, totalFlacFiles: totalFlac, strippedFlacFiles: stripped)
        }

        if !deferred.isEmpty {
            log("Appending \(deferred.count) larger entr\(deferred.count == 1 ? "y" : "ies") at the end…", .info)
            guard let scratch else { throw ZipProcessor.ZipProcessorError.cannotCreateArchive }
            for entry in deferred {
                var done = 0
                while done < entry.length {
                    let n = min(8 << 20, entry.length - done)
                    try autoreleasepool {
                        let buffer = try scratch.readExactly(at: entry.scratchOffset + UInt64(done), count: n)
                        try dst.writeAll([buffer], at: writeCursor + UInt64(done))
                    }
                    done += n
                }
                if inPlace { modifiedSource = true }
                records[entry.index].localHeaderOffset = writeCursor
                writeCursor += UInt64(entry.length)
            }
        }

        log("Writing central directory…", .info)
        let centralDirectory = ZipArchiveIO.serializeCentralDirectory(records)
        let end = ZipArchiveIO.serializeEnd(
            entryCount: records.count,
            centralDirectoryOffset: writeCursor,
            centralDirectorySize: UInt64(centralDirectory.count),
            comment: layout.comment
        )
        try dst.writeAll([centralDirectory, end], at: writeCursor)
        if inPlace { modifiedSource = true }
        let finalSize = writeCursor + UInt64(centralDirectory.count) + UInt64(end.count)
        try dst.truncate(atOffset: finalSize)
        try dst.synchronize()
        log("Done. Archive is now \(finalSize) bytes (was \(fileSize))", .info)

        return ZipProcessor.ProcessResult(outputURL: outputURL, totalFlacFiles: totalFlac, strippedFlacFiles: stripped)
    }

    private func rewriteFlac(_ record: ZipEntryRecord) -> Rewrite? {
        let entryName = record.name

        guard record.flags & 0x0001 == 0 else {
            log("Encrypted entry; leaving \(entryName) as-is", .warning)
            return nil
        }
        guard record.method == 0 || record.method == 8 else {
            log("Unsupported compression method \(record.method); leaving \(entryName) as-is", .warning)
            return nil
        }
        guard record.compressedSize < 0xFFFFFFFF, record.uncompressedSize < 0xFFFFFFFF else {
            log("\(entryName) is over 4 GiB; leaving it as-is", .warning)
            return nil
        }

        do {
            let localHeader = try src.readExactly(at: record.localHeaderOffset, count: 30)
            guard localHeader.le32(at: 0) == ZipArchiveIO.sigLocal else {
                throw ZipArchiveError.badLocalHeader(entryName)
            }
            let nameLength = Int(localHeader.le16(at: 26))
            let extraLength = Int(localHeader.le16(at: 28))
            let dataOffset = record.localHeaderOffset + 30 + UInt64(nameLength + extraLength)
            let storedBytes = try src.readExactly(at: dataOffset, count: Int(record.compressedSize))

            var data: Data
            if record.method == 0 {
                data = storedBytes
            } else {
                data = try ZipCodec.inflate(storedBytes, expectedSize: Int(record.uncompressedSize))
                guard CRC32.checksum(data) == record.crc32 else {
                    throw ZipArchiveError.checksumMismatch(entryName)
                }
            }

            var changed = false
            var didStrip = false
            do {
                let strippedData = try FLACStripper.strip(data)
                if strippedData.count != data.count {
                    data = strippedData
                    changed = true
                    didStrip = true
                    log("Stripped SEEKTABLE/PADDING from \(entryName)", .info)
                } else {
                    log("\(entryName) had nothing to strip", .info)
                }
            } catch {

                log("FLACStripper failed for \(entryName): \(error)", .warning)
            }

            var finalName = entryName
            let tags = FLACStripper.readTags(from: data)
            if let rawTitle = tags.title, !rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let cleanedTitle = FlacNaming.strippingFlacExtension(from: rawTitle)
                if cleanedTitle != rawTitle {
                    do {
                        data = try FLACStripper.writingVorbisComments([("TITLE", cleanedTitle)], into: data)
                        changed = true
                        log("Stripped stray \".flac\" from TITLE tag in \(entryName)", .info)
                    } catch {
                        log("Could not clean TITLE tag for \(entryName): \(error)", .warning)
                    }
                }
                if record.hasValidUTF8Name {
                    finalName = uniqueName(
                        directoryPrefix: Self.directoryPrefix(of: entryName),
                        baseName: FlacNaming.sanitizedFilename(cleanedTitle),
                        original: entryName
                    )
                }
            } else {
                log("No TITLE tag found in \(entryName); keeping original filename", .warning)
            }

            let nameChanged = finalName != entryName
            guard changed || nameChanged else { return nil }

            var updated = record
            updated.nameBytes = Data(finalName.utf8)
            if nameChanged {
                updated.extra = ZipArchiveIO.removingExtraField(0x7075, from: record.extra)
                log("Renamed \(entryName) → \(finalName) (title-only, artist stripped)", .info)
            }
            updated.flags = record.flags & ~UInt16(0x0008)
            if updated.nameBytes.contains(where: { $0 >= 0x80 }) {
                updated.flags |= 0x0800
            }
            updated.versionNeeded = 20

            let payload: Data
            if changed {
                updated.crc32 = CRC32.checksum(data)
                updated.uncompressedSize = UInt64(data.count)
                if record.method == 8, let compressed = ZipCodec.deflate(data), compressed.count < data.count {
                    payload = compressed
                    updated.method = 8
                } else {
                    payload = data
                    updated.method = 0
                }
            } else {

                payload = storedBytes
            }
            updated.compressedSize = UInt64(payload.count)
            guard updated.compressedSize < 0xFFFFFFFF else { return nil }

            return Rewrite(
                record: updated,
                header: ZipArchiveIO.localHeader(for: updated),
                payload: payload,
                didStrip: didStrip
            )
        } catch {
            log("Could not process \(entryName), copying it unchanged: \(error.localizedDescription)", .warning)
            return nil
        }
    }

    private func copyRange(from srcOffset: UInt64, to dstOffset: UInt64, length: UInt64) throws {
        if inPlace && srcOffset == dstOffset { return }
        if inPlace { modifiedSource = true }
        var done: UInt64 = 0
        let chunk: UInt64 = 8 << 20
        while done < length {
            let n = Int(min(chunk, length - done))
            try autoreleasepool {
                let buffer = try src.readExactly(at: srcOffset + done, count: n)
                try dst.writeAll([buffer], at: dstOffset + done)
            }
            done += UInt64(n)
        }
    }

    private func isTaken(_ lowercasedName: String) -> Bool {
        assignedNames.contains(lowercasedName) || pendingNames.contains(lowercasedName)
    }

    private func uniqueName(directoryPrefix: String, baseName: String, original: String) -> String {
        let originalLower = original.lowercased()
        var candidate = directoryPrefix + baseName + ".flac"
        var counter = 2
        while candidate.lowercased() != originalLower && isTaken(candidate.lowercased()) {
            candidate = directoryPrefix + baseName + " (\(counter)).flac"
            counter += 1
        }
        return candidate
    }

    private static func directoryPrefix(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex...slash])
    }
}
