import SwiftUI

enum AppThemePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

@main
struct YomiApp: App {
    @StateObject private var store = LibraryStore()
    @AppStorage("app.themePreference") private var themePreferenceRawValue = AppThemePreference.system.rawValue

    private var themePreference: AppThemePreference {
        AppThemePreference(rawValue: themePreferenceRawValue) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(themePreference.colorScheme)
        }
    }
}
