import Foundation

enum FolderProcessor {

    enum FolderProcessorError: Error, LocalizedError {
        case cannotCoordinate(underlying: Error?)
        case cannotEnumerate
        case placementFailed(name: String, pendingURL: URL, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .cannotCoordinate:
                return "Could not get write access to the selected folder. It may be read-only, or stored somewhere " +
                       "that doesn't allow in-place edits."
            case .cannotEnumerate:
                return "Could not read the contents of the selected folder."
            case .placementFailed(let name, let pendingURL, let underlying):
                return "Edited \"\(name)\" but could not put it back (\(underlying.localizedDescription)). " +
                       "The edited copy was kept at \(pendingURL.path)."
            }
        }
    }

    typealias Logger = (String, LogLevel) -> Void

    static func process(folderURL: URL, log: @escaping Logger = { _, _ in }) throws -> ZipProcessor.ProcessResult {
        log("Preparing to read folder \(folderURL.lastPathComponent)", .info)

        var coordinatorError: NSError?
        var outcome: Result<ZipProcessor.ProcessResult, Error>?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: folderURL, options: [], error: &coordinatorError) { coordinatedURL in
            outcome = Result { try run(folderURL: coordinatedURL, log: log) }
        }

        if let coordinatorError {
            log("File coordination failed: \(coordinatorError)", .error)
            throw FolderProcessorError.cannotCoordinate(underlying: coordinatorError)
        }
        guard let outcome else { throw FolderProcessorError.cannotEnumerate }
        return try outcome.get()
    }

    private static func run(folderURL: URL, log: Logger) throws -> ZipProcessor.ProcessResult {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw FolderProcessorError.cannotEnumerate
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "flac" else { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            guard !FlacNaming.isAppleMetadata(url.lastPathComponent) else { continue }
            files.append(url)
        }
        files.sort { $0.path < $1.path }
        log("Found \(files.count) FLAC file(s)", .info)

        var stripped = 0
        for (index, url) in files.enumerated() {
            try autoreleasepool {
                log("[\(index + 1)/\(files.count)] \(url.lastPathComponent)", .info)
                if try processFile(at: url, log: log) { stripped += 1 }
            }
        }
        log("FLAC pass complete: stripped \(stripped) of \(files.count) file(s)", .info)
        return ZipProcessor.ProcessResult(outputURL: nil, totalFlacFiles: files.count, strippedFlacFiles: stripped)
    }

    private static func processFile(at url: URL, log: Logger) throws -> Bool {
        let fm = FileManager.default
        let name = url.lastPathComponent

        requestCloudDownloadIfNeeded(for: url, log: log)

        var data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            log("Could not read \(name), leaving it unchanged: \(error.localizedDescription)", .warning)
            return false
        }

        var changed = false
        var didStrip = false
        do {
            let strippedData = try FLACStripper.strip(data)
            if strippedData.count != data.count {
                data = strippedData
                changed = true
                didStrip = true
                log("Stripped SEEKTABLE/PADDING from \(name)", .info)
            } else {
                log("\(name) had nothing to strip", .info)
            }
        } catch {
            log("FLACStripper failed for \(name): \(error)", .warning)
        }

        var targetURL = url
        let tags = FLACStripper.readTags(from: data)
        if let rawTitle = tags.title, !rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cleanedTitle = FlacNaming.strippingFlacExtension(from: rawTitle)
            if cleanedTitle != rawTitle {
                do {
                    data = try FLACStripper.writingVorbisComments([("TITLE", cleanedTitle)], into: data)
                    changed = true
                    log("Stripped stray \".flac\" from TITLE tag in \(name)", .info)
                } catch {
                    log("Could not clean TITLE tag for \(name): \(error)", .warning)
                }
            }
            targetURL = uniqueURL(
                directory: url.deletingLastPathComponent(),
                baseName: FlacNaming.sanitizedFilename(cleanedTitle),
                original: url
            )
        } else {
            log("No TITLE tag found in \(name); keeping original filename", .warning)
        }

        let renamed = targetURL.lastPathComponent != name
        guard changed || renamed else { return false }

        let pendingURL = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zapper-pending")
        do {
            try data.write(to: pendingURL, options: .atomic)
        } catch {
            try? fm.removeItem(at: pendingURL)
            log("Could not write edited copy of \(name), leaving it unchanged: \(error.localizedDescription)", .warning)
            return false
        }
        data = Data()

        do {
            try fm.removeItem(at: url)
        } catch {
            try? fm.removeItem(at: pendingURL)
            log("Could not delete original \(name), leaving it unchanged: \(error.localizedDescription)", .warning)
            return false
        }

        do {
            do {
                try fm.moveItem(at: pendingURL, to: targetURL)
            } catch {
                try fm.copyItem(at: pendingURL, to: targetURL)
                try? fm.removeItem(at: pendingURL)
            }
        } catch {
            log("Could not place edited \(name); edited copy kept at \(pendingURL.path)", .error)
            throw FolderProcessorError.placementFailed(name: name, pendingURL: pendingURL, underlying: error)
        }

        if renamed {
            log("Renamed \(name) → \(targetURL.lastPathComponent) (title-only, artist stripped)", .info)
        }
        return didStrip
    }

    private static func uniqueURL(directory: URL, baseName: String, original: URL) -> URL {
        let fm = FileManager.default
        let originalName = original.lastPathComponent.lowercased()
        var candidate = baseName + ".flac"
        var counter = 2
        while candidate.lowercased() != originalName,
              fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = baseName + " (\(counter)).flac"
            counter += 1
        }
        return directory.appendingPathComponent(candidate)
    }

    private static func requestCloudDownloadIfNeeded(for url: URL, log: Logger) {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true,
              values.ubiquitousItemDownloadingStatus != .current else { return }
        log("\(url.lastPathComponent) is in iCloud and not fully downloaded — requesting download…", .warning)
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            guard let current = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]) else { break }
            if current.ubiquitousItemDownloadingStatus == .current { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        log("Timed out waiting for iCloud download to finish; attempting to continue anyway", .warning)
    }
}
