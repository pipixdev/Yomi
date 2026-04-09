//
//  ReaderPreferencesView.swift
//  Yomi
//

import SwiftUI

struct ReaderPreferencesView: View {
    @AppStorage("app.themePreference") private var themePreferenceRawValue = AppThemePreference.system.rawValue
    @AppStorage("reader.fontScale") private var readerFontScale = 1.0
    @AppStorage("reader.pageMarginsScale") private var readerPageMarginsScale = 1.0

    var body: some View {
        NavigationStack {
            Form {
                Section("Reader") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Font Size")
                            Spacer()
                            Text("\(Int((readerFontScale * 100).rounded()))%")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Slider(value: $readerFontScale, in: 0.7 ... 2.2, step: 0.05)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Page Margins")
                            Spacer()
                            Text("\(Int((readerPageMarginsScale * 100).rounded()))%")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Slider(value: $readerPageMarginsScale, in: 0.0 ... 2.5, step: 0.05)
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
                    Text("Reading is powered by Readium Swift Toolkit.")
                    Text("Japanese segmentation and ruby annotations are injected per resource, and existing ruby markup is preserved.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
