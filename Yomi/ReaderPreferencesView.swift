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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ReaderSettingsDetailView(
                            readerFontOptionRawValue: $readerFontOptionRawValue,
                            readerFontScale: $readerFontScale,
                            analysisFontScale: $analysisFontScale,
                            readerPageMarginsScale: $readerPageMarginsScale
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
