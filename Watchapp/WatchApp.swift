import SwiftUI

@main
struct WatchApp: App {
    @StateObject private var nap = NapController()

    var body: some Scene {
        WindowGroup {
            WatchContentView(nap: nap)
        }
    }
}
