import SwiftUI

@main
struct YomiApp: App {
    @StateObject private var store = LibraryStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
