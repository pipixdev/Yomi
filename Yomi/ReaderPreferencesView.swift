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

                    NavigationLink {
                        SpeechReferenceSelectionView(
                            references: $ttsReferences,
                            selectedReferenceID: $selectedReferenceID,
                            onAddReference: { startCreatingReference() },
                            onEditReference: { reference in startEditingReference(reference) },
                            onDeleteReference: { referenceID in deleteReference(referenceID) },
                            titleForReference: referenceTitle(for:)
                        )
                    } label: {
                        LabeledContent("Reference") {
                            Text(selectedReferenceSummary)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("Select which reference to use. Choose None to send speech requests without references.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
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

private struct SpeechReferenceSelectionView: View {
    @Binding var references: [ParagraphTTSReference]
    @Binding var selectedReferenceID: String?

    let onAddReference: () -> Void
    let onEditReference: (ParagraphTTSReference) -> Void
    let onDeleteReference: (String) -> Void
    let titleForReference: (ParagraphTTSReference) -> String

    var body: some View {
        List {
            selectionRow(title: String(localized: "None"), subtitle: String(localized: "Without reference audio or text."), isSelected: selectedReferenceID == nil) {
                selectedReferenceID = nil
                ParagraphTTSSettingsStore.setSelectedReferenceID(nil)
            }

            ForEach(references) { reference in
                Button {
                    selectedReferenceID = reference.id
                    ParagraphTTSSettingsStore.setSelectedReferenceID(reference.id)
                } label: {
                    HStack(spacing: 12) {
                        Text(titleForReference(reference))
                            .foregroundStyle(.primary)

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
                    Button("Delete", role: .destructive) {
                        onDeleteReference(reference.id)
                    }
                    Button("Edit") {
                        onEditReference(reference)
                    }
                    .tint(.blue)
                }
            }
        }
        .navigationTitle("Reference")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onAddReference()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Reference")
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
            Section("Reference") {
                TextField("Title", text: $draft.title)

                TextField("Reference transcript", text: $draft.text, axis: .vertical)
                    .lineLimit(3 ... 8)
            }

            Section("Audio") {
                if let path = draft.audioPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                    Text(URL(filePath: path).lastPathComponent)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not set")
                        .foregroundStyle(.secondary)
                }

                Button("Import Audio") {
                    isImportingAudio = true
                }
            }
        }
        .navigationTitle("Edit Reference")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
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
        .alert("Settings Error", isPresented: Binding(
            get: { importError != nil },
            set: { isPresented in
                if !isPresented {
                    importError = nil
                }
            }
        ), actions: {
            Button("OK") {
                importError = nil
            }
        }, message: {
            Text(importError ?? "")
        })
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

private struct EditableReference: Identifiable {
    let id = UUID()
    let reference: ParagraphTTSReference
    let isNew: Bool
}
