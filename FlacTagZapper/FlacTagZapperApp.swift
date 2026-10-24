import SwiftUI

@main
struct FlacTagZapperApp: App {
    init() {

        ZipProcessor.cleanupStaleOutputs()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
