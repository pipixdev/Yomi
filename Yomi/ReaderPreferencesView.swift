//
//  ReaderPreferencesView.swift
//  Yomi
//

import SwiftUI

struct ReaderPreferencesView: View {
    @AppStorage("reader.fontScale") private var fontScale = 1.0

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

                        Slider(value: $fontScale, in: 0.75 ... 1.4, step: 0.05)
                    }
                }

                Section("Current Scope") {
                    Text("Only EPUB import is supported for now.")
                    Text("The reader always uses the final part-of-speech annotated layout.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
