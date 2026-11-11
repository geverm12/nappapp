import SwiftUI

@main
struct SiestaApp: App {
    init() {
        NapConfig.registerDefaults()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
