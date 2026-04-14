//
//  ReaderPreferencesView.swift
//  Yomi
//

import SwiftUI
import UniformTypeIdentifiers

struct ReaderPreferencesView: View {
    private enum ImportTarget {
        case referenceAudio
    }

    @AppStorage("app.themePreference") private var themePreferenceRawValue = AppThemePreference.system.rawValue
    @AppStorage("reader.fontScale") private var readerFontScale = 1.0
    @AppStorage("reader.pageMarginsScale") private var readerPageMarginsScale = 1.0
    @AppStorage("reader.fontOption") private var readerFontOptionRawValue = ReaderFontOption.mincho.rawValue
    @AppStorage(ParagraphTTSSettingsStore.serviceBaseURLKey) private var ttsServiceBaseURL = ""
    @AppStorage(ParagraphTTSSettingsStore.referenceTextKey) private var ttsReferenceText = ""

    @State private var activeImportTarget: ImportTarget?
    @State private var settingsError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Reader") {
                    Picker("Font", selection: $readerFontOptionRawValue) {
                        ForEach(ReaderFontOption.allCases) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }

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

                Section("Speech") {
                    LabeledContent("Service URL") {
                        TextField("http://127.0.0.1:8080", text: $ttsServiceBaseURL)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    LabeledContent("Reference Text") {
                        TextField("Reference transcript", text: $ttsReferenceText)
                            .multilineTextAlignment(.trailing)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Reference Audio")
                            .font(.subheadline.weight(.semibold))
                        if let path = ParagraphTTSSettingsStore.referenceAudioPath() {
                            Text(URL(filePath: path).lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Not set")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Button("Import Audio") {
                                activeImportTarget = .referenceAudio
                            }
                            Spacer()
                            Button("Clear Audio", role: .destructive) {
                                ParagraphTTSSettingsStore.clearReferenceAudio()
                            }
                        }
                    }

                    Text("When both reference audio and reference text are set, requests include references.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .fileImporter(
                isPresented: Binding(
                    get: { activeImportTarget != nil },
                    set: { _ in }
                ),
                allowedContentTypes: allowedImportContentTypes,
                allowsMultipleSelection: false
            ) { result in
                let currentTarget = activeImportTarget
                activeImportTarget = nil
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    switch currentTarget {
                    case .referenceAudio:
                        do {
                            _ = try ParagraphTTSSettingsStore.saveReferenceAudio(from: url)
                        } catch {
                            settingsError = error.localizedDescription
                        }
                    case nil:
                        return
                    }
                case .failure(let error):
                    settingsError = error.localizedDescription
                }
            }
            .alert("Settings Error", isPresented: Binding(
                get: { settingsError != nil },
                set: { isPresented in
                    if !isPresented {
                        settingsError = nil
                    }
                }
            ), actions: {
                Button("OK") {
                    settingsError = nil
                }
            }, message: {
                Text(settingsError ?? "")
            })
        }
    }

    private var allowedImportContentTypes: [UTType] {
        switch activeImportTarget {
        case .referenceAudio:
            var types: [UTType] = [.audio]
            let extensions = ["mp3", "wav", "m4a", "flac", "ogg"]
            for ext in extensions {
                if let type = UTType(filenameExtension: ext), !types.contains(type) {
                    types.append(type)
                }
            }
            return types
        case nil:
            return [.data]
        }
    }
}
