//
//  ReaderPreferencesView.swift
//  Yomi
//

import SwiftUI

struct ReaderPreferencesView: View {
    @AppStorage("reader.fontScale") private var fontScale = 1.0
    @AppStorage("app.themePreference") private var themePreferenceRawValue = AppThemePreference.system.rawValue

    var body: some View {
        NavigationStack {
            Form {
                Section("Display") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Default font scale")
                            Spacer()
                            Text("\(Int(fontScale * 100))%")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Slider(value: $fontScale, in: 0.5 ... 1.4, step: 0.05)
                    }
                }

                Section("Appearance") {
                    Picker("Theme", selection: $themePreferenceRawValue) {
                        Text("Follow System").tag(AppThemePreference.system.rawValue)
                        Text("Light").tag(AppThemePreference.light.rawValue)
                        Text("Dark").tag(AppThemePreference.dark.rawValue)
                    }
                }

                Section("Current Scope") {
                    Text("Only EPUB import is supported for now.")
                    Text("Part-of-speech annotations can be toggled from the reader toolbar.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
