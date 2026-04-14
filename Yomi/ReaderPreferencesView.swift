//
//  ReaderPreferencesView.swift
//  Yomi
//

import SwiftUI
import UniformTypeIdentifiers

struct ReaderPreferencesView: View {
    @AppStorage("app.themePreference") private var themePreferenceRawValue = AppThemePreference.system.rawValue
    @AppStorage("reader.fontScale") private var readerFontScale = 1.0
    @AppStorage("reader.pageMarginsScale") private var readerPageMarginsScale = 1.0
    @AppStorage("reader.fontOption") private var readerFontOptionRawValue = ReaderFontOption.mincho.rawValue
    @AppStorage(ParagraphTTSSettingsStore.serviceBaseURLKey) private var ttsServiceBaseURL = ""

    @State private var ttsReferences: [ParagraphTTSReference]
    @State private var selectedReferenceID: String?
    @State private var editingReference: EditableReference?
    @State private var settingsError: String?

    init() {
        let references = ParagraphTTSSettingsStore.references()
        _ttsReferences = State(initialValue: references)
        _selectedReferenceID = State(initialValue: ParagraphTTSSettingsStore.selectedReferenceID())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ReaderSettingsDetailView(
                            readerFontOptionRawValue: $readerFontOptionRawValue,
                            readerFontScale: $readerFontScale,
                            readerPageMarginsScale: $readerPageMarginsScale
                        )
                    } label: {
                        settingsRow(
                            title: String(localized: "Reader"),
                            systemImage: "textformat.size"
                        )
                    }

                    NavigationLink {
                        AppearanceSettingsDetailView(themePreferenceRawValue: $themePreferenceRawValue)
                    } label: {
                        settingsRow(
                            title: String(localized: "Appearance"),
                            systemImage: "circle.lefthalf.filled"
                        )
                    }

                    NavigationLink {
                        SpeechSettingsDetailView(
                            ttsServiceBaseURL: $ttsServiceBaseURL,
                            references: $ttsReferences,
                            selectedReferenceID: $selectedReferenceID,
                            settingsError: $settingsError,
                            onAddReference: { startCreatingReference() },
                            onEditReference: { reference in startEditingReference(reference) },
                            onDeleteReference: { referenceID in deleteReference(referenceID) },
                            titleForReference: referenceTitle(for:)
                        )
                    } label: {
                        settingsRow(
                            title: String(localized: "Speech"),
                            systemImage: "waveform"
                        )
                    }
                }
            }
            .navigationTitle(String(localized: "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editingReference) { item in
                NavigationStack {
                    SpeechReferenceEditorView(
                        draft: item.reference,
                        onCancel: { editingReference = nil },
                        onSave: { reference in
                            saveReference(reference, isNew: item.isNew)
                            editingReference = nil
                        }
                    )
                }
            }
            .alert(String(localized: "Settings Error"), isPresented: Binding(
                get: { settingsError != nil },
                set: { isPresented in
                    if !isPresented {
                        settingsError = nil
                    }
                }
            ), actions: {
                Button(String(localized: "OK")) {
                    settingsError = nil
                }
            }, message: {
                Text(settingsError ?? "")
            })
        }
    }

    private var selectedReferenceSummary: String {
        guard let selectedReference else {
            return String(localized: "None")
        }
        return referenceTitle(for: selectedReference)
    }

    private var selectedReference: ParagraphTTSReference? {
        guard let selectedReferenceID else {
            return nil
        }
        return ttsReferences.first(where: { $0.id == selectedReferenceID })
    }

    @ViewBuilder
    private func settingsRow(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
    }

    private func startCreatingReference() {
        editingReference = EditableReference(reference: ParagraphTTSReference(), isNew: true)
    }

    private func startEditingReference(_ reference: ParagraphTTSReference) {
        editingReference = EditableReference(reference: reference, isNew: false)
    }

    private func saveReference(_ reference: ParagraphTTSReference, isNew: Bool) {
        if let index = ttsReferences.firstIndex(where: { $0.id == reference.id }) {
            ttsReferences[index] = reference
        } else if isNew {
            ttsReferences.append(reference)
        } else {
            ttsReferences.append(reference)
        }

        ParagraphTTSSettingsStore.saveReferences(ttsReferences)
    }

    private func deleteReference(_ referenceID: String) {
        ParagraphTTSSettingsStore.deleteReference(referenceID)
        ttsReferences = ParagraphTTSSettingsStore.references()
        if selectedReferenceID == referenceID {
            selectedReferenceID = nil
            ParagraphTTSSettingsStore.setSelectedReferenceID(nil)
        }
    }

    private func referenceTitle(for reference: ParagraphTTSReference) -> String {
        if let title = reference.normalizedTitle {
            return title
        }

        return String(localized: "Untitled Reference")
    }
}

private struct ReaderSettingsDetailView: View {
    @Binding var readerFontOptionRawValue: String
    @Binding var readerFontScale: Double
    @Binding var readerPageMarginsScale: Double

    private var fontScaleSummary: String {
        "\(Int((readerFontScale * 100).rounded()))%"
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
                    title: String(localized: "Page Margins"),
                    valueText: pageMarginsSummary,
                    value: $readerPageMarginsScale,
                    range: 0.0 ... 2.5
                )
            } footer: {
                Text(String(localized: "Adjust typography and layout density for the reader."))
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

private struct SpeechSettingsDetailView: View {
    @Binding var ttsServiceBaseURL: String
    @Binding var references: [ParagraphTTSReference]
    @Binding var selectedReferenceID: String?
    @Binding var settingsError: String?

    let onAddReference: () -> Void
    let onEditReference: (ParagraphTTSReference) -> Void
    let onDeleteReference: (String) -> Void
    let titleForReference: (ParagraphTTSReference) -> String

    private var selectedReferenceSummary: String {
        guard let selectedReference else {
            return String(localized: "None")
        }
        return titleForReference(selectedReference)
    }

    private var selectedReference: ParagraphTTSReference? {
        guard let selectedReferenceID else {
            return nil
        }
        return references.first(where: { $0.id == selectedReferenceID })
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Service URL")) {
                    TextField("http://127.0.0.1:8080", text: $ttsServiceBaseURL)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } footer: {
                Text(String(localized: "Leave empty to disable external speech requests."))
            }

            Section {
                NavigationLink {
                    SpeechReferenceSelectionView(
                        references: $references,
                        selectedReferenceID: $selectedReferenceID,
                        onAddReference: onAddReference,
                        onEditReference: onEditReference,
                        onDeleteReference: onDeleteReference,
                        titleForReference: titleForReference
                    )
                } label: {
                    Text(String(localized: "Reference"))
                }
            } footer: {
                Text(String(localized: "Select which reference to use. Choose None to send speech requests without references."))
            }
        }
        .navigationTitle(String(localized: "Speech"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SpeechReferenceSelectionView: View {
    @Binding var references: [ParagraphTTSReference]
    @Binding var selectedReferenceID: String?

    let onAddReference: () -> Void
    let onEditReference: (ParagraphTTSReference) -> Void
    let onDeleteReference: (String) -> Void
    let titleForReference: (ParagraphTTSReference) -> String

    var body: some View {
        List {
            selectionRow(
                title: String(localized: "None"),
                subtitle: String(localized: "Without reference audio or text."),
                isSelected: selectedReferenceID == nil
            ) {
                selectedReferenceID = nil
                ParagraphTTSSettingsStore.setSelectedReferenceID(nil)
            }

            ForEach(references) { reference in
                Button {
                    selectedReferenceID = reference.id
                    ParagraphTTSSettingsStore.setSelectedReferenceID(reference.id)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(titleForReference(reference))
                                .foregroundStyle(.primary)

                            if let text = reference.normalizedText {
                                Text(text)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        if selectedReferenceID == reference.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(String(localized: "Delete"), role: .destructive) {
                        onDeleteReference(reference.id)
                    }
                    Button(String(localized: "Edit")) {
                        onEditReference(reference)
                    }
                    .tint(.blue)
                }
            }
        }
        .navigationTitle(String(localized: "Reference"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onAddReference()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(String(localized: "Add Reference"))
            }
        }
    }

    @ViewBuilder
    private func selectionRow(title: String, subtitle: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SpeechReferenceEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ParagraphTTSReference
    @State private var isImportingAudio = false
    @State private var importError: String?

    let onCancel: () -> Void
    let onSave: (ParagraphTTSReference) -> Void

    init(
        draft: ParagraphTTSReference,
        onCancel: @escaping () -> Void,
        onSave: @escaping (ParagraphTTSReference) -> Void
    ) {
        _draft = State(initialValue: draft)
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    SpeechReferenceSingleFieldEditorView(
                        title: String(localized: "Title"),
                        text: $draft.title,
                        axis: .horizontal
                    )
                } label: {
                    editorRow(
                        title: String(localized: "Title"),
                        showsChevron: false
                    )
                }

                NavigationLink {
                    SpeechReferenceSingleFieldEditorView(
                        title: String(localized: "Text"),
                        text: $draft.text,
                        axis: .vertical
                    )
                } label: {
                    editorRow(
                        title: String(localized: "Text"),
                        showsChevron: false
                    )
                }

                Button {
                    isImportingAudio = true
                } label: {
                    editorRow(
                        title: String(localized: "Audio"),
                        value: audioFilename,
                        isPlaceholder: audioFilename == String(localized: "Not set"),
                        showsChevron: false
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle(String(localized: "Edit Reference"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(String(localized: "Cancel")) {
                    onCancel()
                    dismiss()
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(String(localized: "Done")) {
                    onSave(draft)
                    dismiss()
                }
            }
        }
        .fileImporter(
            isPresented: $isImportingAudio,
            allowedContentTypes: allowedImportContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    let destinationURL = try ParagraphTTSSettingsStore.importReferenceAudio(from: url, for: draft.id)
                    draft.audioPath = destinationURL.path
                } catch {
                    importError = error.localizedDescription
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .alert(String(localized: "Settings Error"), isPresented: Binding(
            get: { importError != nil },
            set: { isPresented in
                if !isPresented {
                    importError = nil
                }
            }
        ), actions: {
            Button(String(localized: "OK")) {
                importError = nil
            }
        }, message: {
            Text(importError ?? "")
        })
    }

    @ViewBuilder
    private func editorRow(title: String, value: String? = nil, isPlaceholder: Bool = false, showsChevron: Bool = true) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(.primary)
                .frame(width: 56, alignment: .leading)

            if let value {
                Text(value)
                    .foregroundStyle(isPlaceholder ? .tertiary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Spacer()
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private var audioFilename: String {
        guard let path = draft.audioPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return String(localized: "Not set")
        }

        return URL(filePath: path).lastPathComponent
    }

    private var allowedImportContentTypes: [UTType] {
        var types: [UTType] = [.audio]
        let extensions = ["mp3", "wav", "m4a", "flac", "ogg"]
        for ext in extensions {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }
}

private struct SpeechReferenceSingleFieldEditorView: View {
    let title: String
    @Binding var text: String
    let axis: Axis

    private var isSingleLine: Bool {
        axis == .horizontal
    }

    var body: some View {
        Form {
            Section {
                if isSingleLine {
                    TextField(title, text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    TextEditor(text: $text)
                        .frame(minHeight: 220)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct EditableReference: Identifiable {
    let id = UUID()
    let reference: ParagraphTTSReference
    let isNew: Bool
}
