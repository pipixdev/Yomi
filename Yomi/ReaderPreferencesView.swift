//
//  ReaderPreferencesView.swift
//  Yomi
//

import SwiftUI

struct ReaderPreferencesView: View {
    @AppStorage("app.themePreference") private var themePreferenceRawValue = AppThemePreference.system.rawValue
    @AppStorage("reader.fontScale") private var readerFontScale = 1.0
    @AppStorage("analysis.fontScale") private var analysisFontScale = 1.0
    @AppStorage("reader.pageMarginsScale") private var readerPageMarginsScale = 1.0
    @AppStorage("reader.fontOption") private var readerFontOptionRawValue = ReaderFontOption.mincho.rawValue
    @AppStorage(EdgeTTSClient.enabledDefaultsKey) private var isEdgeTTSEnabled = false
    @AppStorage(DictionaryLookupPreferences.externalLookupEnabledKey) private var isExternalDictionaryEnabled = false
    @AppStorage(DictionaryLookupPreferences.externalLookupURLTemplateKey) private var externalDictionaryURLTemplate = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ReaderSettingsDetailView(
                            readerFontOptionRawValue: $readerFontOptionRawValue,
                            readerFontScale: $readerFontScale,
                            analysisFontScale: $analysisFontScale,
                            readerPageMarginsScale: $readerPageMarginsScale,
                            isEdgeTTSEnabled: $isEdgeTTSEnabled,
                            isExternalDictionaryEnabled: $isExternalDictionaryEnabled,
                            externalDictionaryURLTemplate: $externalDictionaryURLTemplate
                        )
                    } label: {
                        Label(String(localized: "Reader"), systemImage: "textformat.size")
                    }

                    NavigationLink {
                        AppearanceSettingsDetailView(themePreferenceRawValue: $themePreferenceRawValue)
                    } label: {
                        Label(String(localized: "Appearance"), systemImage: "circle.lefthalf.filled")
                    }
                }
            }
            .navigationTitle(String(localized: "Settings"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct ReaderSettingsDetailView: View {
    @Binding var readerFontOptionRawValue: String
    @Binding var readerFontScale: Double
    @Binding var analysisFontScale: Double
    @Binding var readerPageMarginsScale: Double
    @Binding var isEdgeTTSEnabled: Bool
    @Binding var isExternalDictionaryEnabled: Bool
    @Binding var externalDictionaryURLTemplate: String

    private var fontScaleSummary: String {
        "\(Int((readerFontScale * 100).rounded()))%"
    }

    private var analysisFontScaleSummary: String {
        "\(Int((analysisFontScale * 100).rounded()))%"
    }

    private var pageMarginsSummary: String {
        "\(Int((readerPageMarginsScale * 100).rounded()))%"
    }

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Font"), selection: $readerFontOptionRawValue) {
                    ForEach(ReaderFontOption.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }

                sliderRow(
                    title: String(localized: "Font Size"),
                    valueText: fontScaleSummary,
                    value: $readerFontScale,
                    range: 0.7 ... 2.2
                )

                sliderRow(
                    title: String(localized: "Parse Font Size"),
                    valueText: analysisFontScaleSummary,
                    value: $analysisFontScale,
                    range: 0.7 ... 2.2
                )

                sliderRow(
                    title: String(localized: "Page Margins"),
                    valueText: pageMarginsSummary,
                    value: $readerPageMarginsScale,
                    range: 0.0 ... 2.5
                )
            } footer: {
                Text(String(localized: "Adjust typography and layout density for the reader and parse view."))
            }

            Section {
                Toggle(String(localized: "Experimental Edge Online Voice"), isOn: $isEdgeTTSEnabled)
            } footer: {
                Text(String(localized: "When enabled, paragraph text is sent to Microsoft's online speech service. Failed requests fall back to the system voice."))
            }

            Section {
                Toggle(String(localized: "Open Words in External Dictionary"), isOn: $isExternalDictionaryEnabled)

                if isExternalDictionaryEnabled {
                    TextField(
                        String(localized: "Dictionary URL Scheme"),
                        text: $externalDictionaryURLTemplate,
                        prompt: Text("mojisho://?search=搜索内容")
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
#if os(iOS)
                    .keyboardType(.URL)
#endif
                }
            } footer: {
                Text(String(localized: "Use 搜索内容 or {term} as the search placeholder. If the URL cannot be opened, Yomi uses the system dictionary."))
            }
        }
        .navigationTitle(String(localized: "Reader"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func sliderRow(title: String, valueText: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(title) {
                Text(valueText)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: value, in: range, step: 0.05)
        }
        .padding(.vertical, 2)
    }
}

private struct AppearanceSettingsDetailView: View {
    @Binding var themePreferenceRawValue: String

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Theme"), selection: $themePreferenceRawValue) {
                    Text(String(localized: "Follow System")).tag(AppThemePreference.system.rawValue)
                    Text(String(localized: "Light")).tag(AppThemePreference.light.rawValue)
                    Text(String(localized: "Dark")).tag(AppThemePreference.dark.rawValue)
                }
            } footer: {
                Text(String(localized: "Choose whether Yomi follows the system appearance or stays fixed."))
            }
        }
        .navigationTitle(String(localized: "Appearance"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
