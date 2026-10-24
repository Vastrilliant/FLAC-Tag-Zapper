import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

struct ContentView: View {
    @State private var isImporterPresented = false
    @State private var selectedURL: URL?
    @State private var selectedIsFolder = false
    @State private var isProcessing = false
    @State private var resultURL: URL?
    @State private var statusMessage = "Pick a folder or .zip archive of songs to get started."
    @State private var errorMessage: String?
    @State private var isLogExpanded = false
    @State private var isExportPresented = false
    @State private var editInPlace = true
    @State private var isInPlaceConfirmPresented = false

    @StateObject private var debugLog = ZipDebugLog.shared

    private var zipContentType: UTType {
        UTType(filenameExtension: "zip") ?? .archive
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                        .padding(.top, 24)

                    Text(statusMessage)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    if isProcessing {
                        ProgressView()
                    }

                    VStack(spacing: 12) {
                        Button {
                            isImporterPresented = true
                        } label: {
                            Label(selectedURL == nil ? "Choose Folder or Zip" : "Choose a Different Folder or Zip",
                                  systemImage: "folder")
                        }
                        .buttonStyle(.bordered)

                        if selectedIsFolder {
                            Text("Each FLAC is edited, its original deleted, and the edited file put back in the same folder. " +
                                 "No copy of the folder is made. Keep the app open until it finishes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        } else {
                            Toggle(isOn: $editInPlace) {
                                Label("Edit original zip in place", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .toggleStyle(.switch)
                            .padding(.horizontal)
                            .disabled(isProcessing)

                            Text(editInPlace
                                 ? "No copy is made, so no extra storage is needed. Keep the app open until it " +
                                   "finishes — if it's interrupted partway, the zip can be left damaged."
                                 : "Works on a copy and asks where to save it. Needs free space for the whole result.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }

                        if selectedURL != nil {
                            Button {
                                if selectedIsFolder || editInPlace {
                                    isInPlaceConfirmPresented = true
                                } else {
                                    processSelection()
                                }
                            } label: {
                                Label("Zap Tags", systemImage: "wand.and.stars")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isProcessing)
                        }

                        if resultURL != nil {
                            Button {
                                isExportPresented = true
                            } label: {
                                Label("Save Result…", systemImage: "square.and.arrow.down")
                            }
                        }
                    }
                    .padding(.bottom, 8)

                    DebugLogView(debugLog: debugLog, isExpanded: $isLogExpanded)
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                }
            }
            .navigationTitle("FLAC Tag Zapper")
            .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.folder, zipContentType]) { result in
                switch result {
                case .success(let url):
                    discardUnsavedResultIfAny()
                    selectedURL = url
                    selectedIsFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
                    errorMessage = nil
                    statusMessage = "Selected: \(url.lastPathComponent)"
                    debugLog.log("Selected file: \(url.path)")
                case .failure(let error):
                    errorMessage = error.localizedDescription
                    debugLog.log("File picker failed: \(error.localizedDescription)", level: .error)
                }
            }
            .alert(selectedIsFolder ? "Edit the original folder?" : "Edit the original zip?", isPresented: $isInPlaceConfirmPresented) {
                Button("Cancel", role: .cancel) {}
                Button("Edit in Place", role: .destructive) {
                    processSelection()
                }
            } message: {
                Text(selectedIsFolder
                     ? "This replaces each FLAC in the selected folder with an edited version. If the app is closed " +
                       "or the device dies mid-file, that one file may be lost. Keep a backup if you can."
                     : "This rewrites the selected zip directly. If the app is closed or the device dies before " +
                       "it finishes, the zip can be left damaged. Keep a backup if you can.")
            }
            .sheet(isPresented: $isExportPresented) {
                if let resultURL {
                    DocumentExporter(url: resultURL) { result in
                        switch result {
                        case .success(let savedURL):

                            try? FileManager.default.removeItem(at: resultURL)
                            self.resultURL = nil
                            statusMessage = "Saved to \(savedURL.lastPathComponent)"
                            debugLog.log("Saved output to \(savedURL.path); removed temporary copy")
                        case .failure(let error):

                            errorMessage = error.localizedDescription
                            debugLog.log("Save failed: \(error.localizedDescription)", level: .error)
                        }
                    }
                }
            }
        }
    }

    private func discardUnsavedResultIfAny() {
        if let resultURL {
            try? FileManager.default.removeItem(at: resultURL)
            debugLog.log("Discarded unsaved output at \(resultURL.path)")
        }
        resultURL = nil
    }

    private func processSelection() {
        guard let selectedURL else { return }
        discardUnsavedResultIfAny()
        isProcessing = true
        errorMessage = nil
        debugLog.clear()
        isLogExpanded = true
        #if canImport(UIKit)

        UIApplication.shared.isIdleTimerDisabled = true
        #endif

        let didStartAccess = selectedURL.startAccessingSecurityScopedResource()
        debugLog.log("Security-scoped access started: \(didStartAccess)")
        let shouldEditInPlace = editInPlace
        let isFolder = selectedIsFolder

        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                if didStartAccess {
                    selectedURL.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let logger: (String, LogLevel) -> Void = { message, level in
                    debugLog.log(message, level: level)
                }
                let result: ZipProcessor.ProcessResult
                if isFolder {
                    result = try FolderProcessor.process(folderURL: selectedURL, log: logger)
                } else {
                    result = try ZipProcessor.process(zipURL: selectedURL, inPlace: shouldEditInPlace, log: logger)
                }
                DispatchQueue.main.async {
                    self.isProcessing = false
                    #if canImport(UIKit)
                    UIApplication.shared.isIdleTimerDisabled = false
                    #endif
                    if let outputURL = result.outputURL {
                        self.resultURL = outputURL
                        self.statusMessage = "Stripped \(result.strippedFlacFiles) of \(result.totalFlacFiles) FLAC file(s). Choose where to save it."

                        self.isExportPresented = true
                    } else {
                        self.statusMessage = "Stripped \(result.strippedFlacFiles) of \(result.totalFlacFiles) FLAC file(s) directly in \(selectedURL.lastPathComponent)."
                    }
                }
            } catch {
                debugLog.log("Failed: \(error.localizedDescription)", level: .error)
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                    #if canImport(UIKit)
                    UIApplication.shared.isIdleTimerDisabled = false
                    #endif
                }
            }
        }
    }
}

private struct DebugLogView: View {
    @ObservedObject var debugLog: ZipDebugLog
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 0) {
                if debugLog.entries.isEmpty {
                    Text("No log yet. Run a folder or zip to see step-by-step output here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(debugLog.entries) { entry in
                                    logRow(entry).id(entry.id)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .frame(maxHeight: 260)
                        .onChange(of: debugLog.entries.count) { _ in
                            if let last = debugLog.entries.last {
                                withAnimation {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }

                    HStack {
                        Button {
                            #if canImport(UIKit)
                            UIPasteboard.general.string = debugLog.textDump
                            #endif
                        } label: {
                            Label("Copy Log", systemImage: "doc.on.doc")
                        }
                        .font(.caption)

                        Spacer()

                        Button(role: .destructive) {
                            debugLog.clear()
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                        .font(.caption)
                    }
                    .padding(.top, 6)
                }
            }
        } label: {
            Label("Debug Log", systemImage: "terminal")
                .font(.subheadline)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func logRow(_ entry: ZipLogEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon(for: entry.level))
                .font(.caption2)
                .foregroundStyle(color(for: entry.level))
                .frame(width: 14)
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color(for: entry.level))
                .textSelection(.enabled)
        }
    }

    private func icon(for level: LogLevel) -> String {
        switch level {
        case .info: return "circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }
}
